#!/usr/bin/env python3
"""
Claude Local Relay gateway.

Behavior:
- Try cloud provider first (Anthropic/OpenAI compatible), if enabled.
- Fallback automatically to local LM Studio on quota/rate-limit/transient errors.
- Optionally rewrite model id and strip unsupported fields for local calls.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from dataclasses import dataclass
from typing import Any, AsyncGenerator, Dict, Iterable, Optional

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse


load_dotenv()


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name, str(default)).strip().lower()
    return raw in {"1", "true", "yes", "on"}


def _env_csv(name: str, default: str) -> list[str]:
    raw = os.getenv(name, default)
    return [item.strip() for item in raw.split(",") if item.strip()]


def _env_int_set(name: str, default: str) -> set[int]:
    out: set[int] = set()
    for token in _env_csv(name, default):
        try:
            out.add(int(token))
        except ValueError:
            continue
    return out


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name, str(default)).strip()
    try:
        return int(raw)
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    listen_host: str
    listen_port: int
    local_base_url: str
    local_api_key: str
    local_model: str
    local_strip_fields: list[str]
    local_max_tokens_cap: int
    relay_model_aliases: list[str]
    fallback_statuses: set[int]
    fallback_keywords: list[str]
    enable_cloud_anthropic: bool
    cloud_anthropic_base_url: str
    cloud_anthropic_api_key: str
    cloud_anthropic_version: str
    enable_cloud_openai: bool
    cloud_openai_base_url: str
    cloud_openai_api_key: str
    smart_context_enabled: bool
    smart_context_store_path: str
    smart_context_keep_recent_messages: int
    smart_context_max_summary_chars: int
    smart_context_max_turn_chars: int
    smart_context_inject_summary: bool

    @staticmethod
    def load() -> "Settings":
        return Settings(
            listen_host=os.getenv("LISTEN_HOST", "127.0.0.1"),
            listen_port=int(os.getenv("LISTEN_PORT", "4000")),
            local_base_url=os.getenv("LOCAL_BASE_URL", "http://127.0.0.1:1234"),
            local_api_key=os.getenv("LOCAL_API_KEY", ""),
            local_model=os.getenv("LOCAL_MODEL", ""),
            local_strip_fields=_env_csv(
                "LOCAL_STRIP_FIELDS", "thinking,service_tier,metadata"
            ),
            local_max_tokens_cap=int(os.getenv("LOCAL_MAX_TOKENS_CAP", "0")),
            relay_model_aliases=_env_csv(
                "RELAY_MODEL_ALIASES",
                "claude-sonnet-4-6,claude-opus-4-7,claude-opus-4-1,sonnet,opus",
            ),
            fallback_statuses=_env_int_set(
                "FALLBACK_ON_STATUS", "402,403,408,409,429,500,502,503,504"
            ),
            fallback_keywords=[kw.lower() for kw in _env_csv(
                "FALLBACK_ERROR_KEYWORDS",
                "quota,insufficient,rate limit,overloaded,credit,billing,retry",
            )],
            enable_cloud_anthropic=_env_bool("ENABLE_CLOUD_ANTHROPIC", True),
            cloud_anthropic_base_url=os.getenv(
                "CLOUD_ANTHROPIC_BASE_URL", "https://api.anthropic.com"
            ),
            cloud_anthropic_api_key=os.getenv("CLOUD_ANTHROPIC_API_KEY", ""),
            cloud_anthropic_version=os.getenv(
                "CLOUD_ANTHROPIC_VERSION", "2023-06-01"
            ),
            enable_cloud_openai=_env_bool("ENABLE_CLOUD_OPENAI", False),
            cloud_openai_base_url=os.getenv(
                "CLOUD_OPENAI_BASE_URL", "https://api.openai.com"
            ),
            cloud_openai_api_key=os.getenv("CLOUD_OPENAI_API_KEY", ""),
            smart_context_enabled=_env_bool("SMART_CONTEXT_ENABLED", True),
            smart_context_store_path=os.getenv(
                "SMART_CONTEXT_STORE_PATH", "/tmp/claude-local-relay-context.json"
            ),
            smart_context_keep_recent_messages=_env_int(
                "SMART_CONTEXT_KEEP_RECENT_MESSAGES", 12
            ),
            smart_context_max_summary_chars=_env_int(
                "SMART_CONTEXT_MAX_SUMMARY_CHARS", 6000
            ),
            smart_context_max_turn_chars=_env_int(
                "SMART_CONTEXT_MAX_TURN_CHARS", 1200
            ),
            smart_context_inject_summary=_env_bool("SMART_CONTEXT_INJECT_SUMMARY", True),
        )


SETTINGS = Settings.load()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
LOGGER = logging.getLogger("claude-local-relay-gateway")

SMART_CONTEXT_LOCK = threading.Lock()
SMART_CONTEXT_STORE: dict[str, dict[str, Any]] = {}

REQUEST_HEADER_DROP = {
    "host",
    "connection",
    "content-length",
    "accept-encoding",
}
RESPONSE_HEADER_DROP = {
    "connection",
    "content-length",
    "content-encoding",
    "transfer-encoding",
}


app = FastAPI(title="claude-local-relay-gateway", version="1.0.0")


@app.on_event("startup")
async def _startup() -> None:
    timeout = httpx.Timeout(connect=20.0, read=None, write=60.0, pool=60.0)
    app.state.http = httpx.AsyncClient(timeout=timeout)
    LOGGER.info(
        "Gateway up on %s:%s, local=%s",
        SETTINGS.listen_host,
        SETTINGS.listen_port,
        SETTINGS.local_base_url,
    )
    if SETTINGS.smart_context_enabled:
        _smart_context_load()
        LOGGER.info("Smart context enabled, store=%s", SETTINGS.smart_context_store_path)


@app.on_event("shutdown")
async def _shutdown() -> None:
    client: httpx.AsyncClient = app.state.http
    await client.aclose()


def _is_anthropic_path(path: str) -> bool:
    return path == "/v1/messages" or path.startswith("/v1/messages/")


def _is_json_content(content_type: str) -> bool:
    return "application/json" in (content_type or "").lower()


def _maybe_parse_json(body: bytes, content_type: str) -> Optional[Dict[str, Any]]:
    if not body or not _is_json_content(content_type):
        return None
    try:
        payload = json.loads(body.decode("utf-8"))
    except ValueError:
        return None
    if isinstance(payload, dict):
        return payload
    return None


def _rewrite_body_for_local(
    body: bytes,
    content_type: str,
    local_model: str,
    strip_fields: Iterable[str],
    max_tokens_cap: int,
) -> bytes:
    payload = _maybe_parse_json(body, content_type)
    if payload is None:
        return body

    if local_model and "model" in payload:
        payload["model"] = local_model

    for field in strip_fields:
        payload.pop(field, None)

    if max_tokens_cap > 0:
        for key in ("max_tokens", "max_completion_tokens"):
            value = payload.get(key)
            if isinstance(value, (int, float)) and value > max_tokens_cap:
                payload[key] = int(max_tokens_cap)

    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def _request_wants_stream(
    body: bytes,
    content_type: str,
    accept_header: str,
) -> bool:
    if "text/event-stream" in (accept_header or "").lower():
        return True
    payload = _maybe_parse_json(body, content_type)
    return bool(payload and payload.get("stream") is True)


def _base_headers_from_request(request: Request) -> Dict[str, str]:
    headers: Dict[str, str] = {}
    for key, value in request.headers.items():
        if key.lower() in REQUEST_HEADER_DROP:
            continue
        headers[key] = value
    return headers


def _response_headers_to_client(resp: httpx.Response) -> Dict[str, str]:
    headers: Dict[str, str] = {}
    for key, value in resp.headers.items():
        if key.lower() in RESPONSE_HEADER_DROP:
            continue
        headers[key] = value
    return headers


def _should_fallback(status_code: int, body_text: str) -> bool:
    if status_code in SETTINGS.fallback_statuses:
        return True
    lowered = (body_text or "").lower()
    normalized = lowered.replace("-", " ").replace("_", " ")
    for keyword in SETTINGS.fallback_keywords:
        candidate = keyword.lower()
        if candidate in lowered:
            return True
        if candidate.replace("-", " ").replace("_", " ") in normalized:
            return True
    return False


def _url(base: str, path: str) -> str:
    return f"{base.rstrip('/')}{path}"


def _inject_model_aliases(
    body: bytes,
    content_type: str,
    aliases: list[str],
) -> bytes:
    if "application/json" not in (content_type or "").lower():
        return body
    if not aliases:
        return body

    try:
        payload = json.loads(body.decode("utf-8"))
    except ValueError:
        return body

    if not isinstance(payload, dict):
        return body
    models = payload.get("data")
    if not isinstance(models, list):
        return body

    existing_ids = {
        item.get("id", "")
        for item in models
        if isinstance(item, dict) and item.get("id")
    }

    for alias in aliases:
        alias = alias.strip()
        if not alias or alias in existing_ids:
            continue
        models.append(
            {
                "id": alias,
                "object": "model",
                "owned_by": "claude-local-relay",
            }
        )

    payload["data"] = models
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def _model_id_from_path(path: str) -> Optional[str]:
    prefix = "/v1/models/"
    if not path.startswith(prefix):
        return None
    model_id = path[len(prefix):].strip()
    if not model_id or "/" in model_id:
        return None
    return model_id


def _rewrite_model_path_alias(path: str) -> str:
    model_id = _model_id_from_path(path)
    if model_id is None:
        return path
    if model_id not in SETTINGS.relay_model_aliases:
        return path
    if not SETTINGS.local_model:
        return path
    return f"/v1/models/{SETTINGS.local_model}"


def _truncate_text(text: str, max_chars: int) -> str:
    if max_chars <= 0 or len(text) <= max_chars:
        return text
    return text[: max_chars - 1].rstrip() + "..."


def _content_to_text(content: Any) -> str:
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                value = block.get("text")
                if isinstance(value, str) and value.strip():
                    parts.append(value.strip())
        return "\n".join(parts)
    return ""


def _extract_conversation_key(payload: dict[str, Any], request: Request) -> str:
    keys = ("conversation_id", "session_id", "chat_id", "thread_id")

    def _first_value(container: Any, key_names: Iterable[str]) -> str:
        if not isinstance(container, dict):
            return ""
        for key in key_names:
            value = container.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        return ""

    metadata = _first_value(payload.get("metadata"), keys)
    if metadata:
        return metadata

    direct = _first_value(payload, keys)
    if direct:
        return direct

    header_map = {
        "x-conversation-id": "conversation_id",
        "x-session-id": "session_id",
        "x-chat-id": "chat_id",
        "anthropic-session-id": "session_id",
    }
    for header in header_map:
        value = request.headers.get(header)
        if isinstance(value, str) and value.strip():
            return value.strip()

    return "default"


def _extract_last_user_text(payload: dict[str, Any]) -> str:
    messages = payload.get("messages")
    if not isinstance(messages, list):
        return ""
    for msg in reversed(messages):
        if not isinstance(msg, dict):
            continue
        if msg.get("role") != "user":
            continue
        return _truncate_text(
            _content_to_text(msg.get("content")),
            SETTINGS.smart_context_max_turn_chars,
        )
    return ""


def _messages_to_compact_text(messages: list[Any], max_chars: int) -> str:
    lines: list[str] = []
    total = 0
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role", "unknown"))
        text = _content_to_text(msg.get("content"))
        if not text:
            continue
        snippet = _truncate_text(text.replace("\n", " "), 300)
        line = f"- {role}: {snippet}"
        lines.append(line)
        total += len(line)
        if total >= max_chars:
            break
    return "\n".join(lines)


def _merge_summary(existing: str, addition: str, max_chars: int) -> str:
    existing = existing.strip()
    addition = addition.strip()
    if not addition:
        return _truncate_text(existing, max_chars)
    if existing:
        merged = f"{existing}\n{addition}"
    else:
        merged = addition
    return _truncate_text(merged, max_chars)


def _inject_summary_into_system(payload: dict[str, Any], summary: str) -> None:
    summary = summary.strip()
    if not summary:
        return
    memory_text = (
        "[Relay memory summary]\n"
        "Use this as soft memory about earlier context. "
        "If it conflicts with newer user messages, prioritize newer messages.\n\n"
        f"{summary}"
    )
    system_value = payload.get("system")
    if system_value is None:
        payload["system"] = memory_text
        return
    if isinstance(system_value, str):
        payload["system"] = f"{system_value}\n\n{memory_text}"
        return
    if isinstance(system_value, list):
        payload["system"] = [
            {"type": "text", "text": memory_text},
            *system_value,
        ]


def _extract_assistant_text_from_response(
    resp_bytes: bytes,
    content_type: str,
) -> str:
    payload = _maybe_parse_json(resp_bytes, content_type)
    if not isinstance(payload, dict):
        return ""
    content = payload.get("content")
    text = _content_to_text(content)
    return _truncate_text(text, SETTINGS.smart_context_max_turn_chars)


def _smart_context_load() -> None:
    path = SETTINGS.smart_context_store_path
    if not path:
        return
    try:
        with open(path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
    except FileNotFoundError:
        return
    except Exception as exc:
        LOGGER.warning("Failed to load smart context store: %s", exc)
        return

    if not isinstance(payload, dict):
        return

    with SMART_CONTEXT_LOCK:
        SMART_CONTEXT_STORE.clear()
        for key, value in payload.items():
            if isinstance(key, str) and isinstance(value, dict):
                SMART_CONTEXT_STORE[key] = value


def _smart_context_save() -> None:
    path = SETTINGS.smart_context_store_path
    if not path:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with SMART_CONTEXT_LOCK:
        snapshot = dict(SMART_CONTEXT_STORE)
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(snapshot, fh, ensure_ascii=False)
    except Exception as exc:
        LOGGER.warning("Failed to save smart context store: %s", exc)


def _apply_smart_context(
    body: bytes,
    content_type: str,
    request: Request,
) -> tuple[bytes, str, str]:
    payload = _maybe_parse_json(body, content_type)
    if payload is None:
        return body, "", ""

    messages = payload.get("messages")
    if not isinstance(messages, list):
        return body, "", ""

    conversation_key = _extract_conversation_key(payload, request)
    keep_recent = max(2, SETTINGS.smart_context_keep_recent_messages)

    summary_before = ""
    with SMART_CONTEXT_LOCK:
        state = SMART_CONTEXT_STORE.get(conversation_key, {})
        summary_before = str(state.get("summary", ""))

    if len(messages) > keep_recent:
        older = messages[:-keep_recent]
        recent = messages[-keep_recent:]
        compact = _messages_to_compact_text(
            older,
            max_chars=max(0, SETTINGS.smart_context_max_summary_chars // 3),
        )
        if compact:
            with SMART_CONTEXT_LOCK:
                state = SMART_CONTEXT_STORE.setdefault(conversation_key, {})
                existing = str(state.get("summary", ""))
                state["summary"] = _merge_summary(
                    existing=existing,
                    addition=compact,
                    max_chars=SETTINGS.smart_context_max_summary_chars,
                )
                state["updated_at"] = int(time.time())
                summary_before = str(state.get("summary", ""))
        payload["messages"] = recent

    if SETTINGS.smart_context_inject_summary and summary_before:
        _inject_summary_into_system(payload, summary_before)

    last_user_text = _extract_last_user_text(payload)
    new_body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return new_body, conversation_key, last_user_text


def _update_smart_context_after_response(
    conversation_key: str,
    user_text: str,
    assistant_text: str,
) -> None:
    if not conversation_key:
        return
    addition_lines: list[str] = []
    if user_text:
        addition_lines.append(f"- user: {user_text}")
    if assistant_text:
        addition_lines.append(f"- assistant: {assistant_text}")
    if not addition_lines:
        return

    addition = "\n".join(addition_lines)
    with SMART_CONTEXT_LOCK:
        state = SMART_CONTEXT_STORE.setdefault(conversation_key, {})
        existing = str(state.get("summary", ""))
        state["summary"] = _merge_summary(
            existing=existing,
            addition=addition,
            max_chars=SETTINGS.smart_context_max_summary_chars,
        )
        state["updated_at"] = int(time.time())

    _smart_context_save()


@app.get("/healthz")
async def healthz() -> JSONResponse:
    local_ok = False
    models: list[str] = []
    try:
        client: httpx.AsyncClient = app.state.http
        resp = await client.get(_url(SETTINGS.local_base_url, "/v1/models"))
        if resp.status_code < 400:
            local_ok = True
            payload = resp.json()
            models = [item.get("id", "") for item in payload.get("data", []) if item.get("id")]
    except Exception:
        local_ok = False

    return JSONResponse(
        {
            "ok": True,
            "local_server_reachable": local_ok,
            "local_model_override": SETTINGS.local_model or None,
            "local_models": models[:20],
            "cloud_anthropic_enabled": bool(
                SETTINGS.enable_cloud_anthropic and SETTINGS.cloud_anthropic_api_key
            ),
            "cloud_openai_enabled": bool(
                SETTINGS.enable_cloud_openai and SETTINGS.cloud_openai_api_key
            ),
        }
    )


@app.api_route(
    "/v1/{rest_of_path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
)
async def proxy(rest_of_path: str, request: Request) -> Response:
    path = f"/v1/{rest_of_path}"
    local_path = _rewrite_model_path_alias(path)
    is_anthropic = _is_anthropic_path(path)

    body = await request.body()
    content_type = request.headers.get("content-type", "")

    smart_conversation_key = ""
    smart_last_user_text = ""
    if is_anthropic and SETTINGS.smart_context_enabled:
        body, smart_conversation_key, smart_last_user_text = _apply_smart_context(
            body=body,
            content_type=content_type,
            request=request,
        )

    stream_mode = _request_wants_stream(
        body=body,
        content_type=content_type,
        accept_header=request.headers.get("accept", ""),
    )

    base_headers = _base_headers_from_request(request)
    query_params = dict(request.query_params)
    method = request.method

    attempts: list[dict[str, Any]] = []

    if is_anthropic:
        if SETTINGS.enable_cloud_anthropic and SETTINGS.cloud_anthropic_api_key:
            cloud_headers = dict(base_headers)
            cloud_headers["x-api-key"] = SETTINGS.cloud_anthropic_api_key
            cloud_headers.setdefault(
                "anthropic-version", SETTINGS.cloud_anthropic_version
            )
            cloud_headers.pop("authorization", None)
            attempts.append(
                {
                    "name": "cloud-anthropic",
                    "url": _url(SETTINGS.cloud_anthropic_base_url, path),
                    "headers": cloud_headers,
                    "body": body,
                }
            )
    else:
        if SETTINGS.enable_cloud_openai and SETTINGS.cloud_openai_api_key:
            cloud_headers = dict(base_headers)
            cloud_headers["Authorization"] = (
                f"Bearer {SETTINGS.cloud_openai_api_key}"
            )
            cloud_headers.pop("x-api-key", None)
            attempts.append(
                {
                    "name": "cloud-openai",
                    "url": _url(SETTINGS.cloud_openai_base_url, path),
                    "headers": cloud_headers,
                    "body": body,
                }
            )

    local_headers = dict(base_headers)
    if SETTINGS.local_api_key:
        local_headers["x-api-key"] = SETTINGS.local_api_key
        local_headers["Authorization"] = f"Bearer {SETTINGS.local_api_key}"
    local_body = _rewrite_body_for_local(
        body=body,
        content_type=content_type,
        local_model=SETTINGS.local_model,
        strip_fields=SETTINGS.local_strip_fields,
        max_tokens_cap=SETTINGS.local_max_tokens_cap,
    )
    attempts.append(
        {
            "name": "local",
            "url": _url(SETTINGS.local_base_url, local_path),
            "headers": local_headers,
            "body": local_body,
        }
    )

    client: httpx.AsyncClient = app.state.http
    last_error_text = ""

    for idx, attempt in enumerate(attempts):
        name = attempt["name"]
        url = attempt["url"]
        headers = attempt["headers"]
        out_body = attempt["body"]

        try:
            upstream_req = client.build_request(
                method=method,
                url=url,
                params=query_params,
                headers=headers,
                content=out_body,
            )
            upstream_resp = await client.send(upstream_req, stream=stream_mode)
        except httpx.RequestError as exc:
            LOGGER.warning("upstream request error for %s: %s", name, exc)
            last_error_text = str(exc)
            continue

        if stream_mode:
            if name != "local" and upstream_resp.status_code >= 400:
                err_bytes = await upstream_resp.aread()
                err_text = err_bytes.decode("utf-8", errors="ignore")
                await upstream_resp.aclose()
                if _should_fallback(upstream_resp.status_code, err_text):
                    LOGGER.info(
                        "fallback %s -> local due to status=%s",
                        name,
                        upstream_resp.status_code,
                    )
                    continue
                return Response(
                    content=err_bytes,
                    status_code=upstream_resp.status_code,
                    headers=_response_headers_to_client(upstream_resp),
                )

            async def _iter() -> AsyncGenerator[bytes, None]:
                try:
                    async for chunk in upstream_resp.aiter_raw():
                        yield chunk
                finally:
                    await upstream_resp.aclose()

            response_headers = _response_headers_to_client(upstream_resp)
            media_type = upstream_resp.headers.get("content-type")

            if is_anthropic and SETTINGS.smart_context_enabled:
                _update_smart_context_after_response(
                    conversation_key=smart_conversation_key,
                    user_text=smart_last_user_text,
                    assistant_text="",
                )

            return StreamingResponse(
                _iter(),
                status_code=upstream_resp.status_code,
                headers=response_headers,
                media_type=media_type,
            )

        resp_bytes = await upstream_resp.aread()
        resp_text = resp_bytes.decode("utf-8", errors="ignore")
        should_fallback = (
            name != "local"
            and _should_fallback(upstream_resp.status_code, resp_text)
        )

        if should_fallback:
            LOGGER.info(
                "fallback %s -> local due to status=%s",
                name,
                upstream_resp.status_code,
            )
            continue

        if idx > 0:
            LOGGER.info("served request from %s", name)
        if path == "/v1/models" and upstream_resp.status_code < 400:
            resp_bytes = _inject_model_aliases(
                body=resp_bytes,
                content_type=upstream_resp.headers.get("content-type", ""),
                aliases=SETTINGS.relay_model_aliases,
            )

        if is_anthropic and SETTINGS.smart_context_enabled:
            assistant_text = _extract_assistant_text_from_response(
                resp_bytes=resp_bytes,
                content_type=upstream_resp.headers.get("content-type", ""),
            )
            _update_smart_context_after_response(
                conversation_key=smart_conversation_key,
                user_text=smart_last_user_text,
                assistant_text=assistant_text,
            )

        return Response(
            content=resp_bytes,
            status_code=upstream_resp.status_code,
            headers=_response_headers_to_client(upstream_resp),
        )

    return JSONResponse(
        status_code=502,
        content={
            "error": {
                "message": (
                    "All upstreams failed (cloud and local). "
                    "Check LM Studio server and API keys."
                ),
                "last_error": last_error_text or None,
            }
        },
    )
