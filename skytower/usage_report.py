"""턴 사용량과 맥락 크기를 relay 로 보낸다 (skytower docs/plans/2026-11-context-usage.md, ADR 0016).

hermes 는 Claude 를 부를 때마다(도구 호출 한 번도 한 번) ``post_api_request`` 훅에 그 호출의 토큰을 준다.
여기서 세션마다 쌓아 두었다가, 어댑터가 그 방으로 메시지를 내보낼 때 쌓인 몫을 꺼내 싣고 비운다.
답이 여러 메시지로 나가도 메시지마다 "그때까지의 몫" 만 실리므로 합은 정확하다.

  1. ``pre_gateway_dispatch`` 훅에서 세션 스토어를 붙잡고, 이 이벤트의 세션 키 → 세션 id 를 미리 적어 둔다.
  2. ``post_api_request`` 훅(에이전트 스레드)에서 세션 id 로 세션 키를 찾아 그 키의 몫에 더한다.
     skytower 플랫폼이 아니거나 세션을 못 찾는 호출은 버린다.
  3. 어댑터가 ``take(session_key)`` 로 몫을 꺼내 ``usage`` · ``context`` 로 싣는다.

토큰은 종류별로 그대로 보낸다. 비용에 맞춘 환산은 relay 가 한다 — 세는 법을 바꿔도 이 파일은 그대로다.

한계: 백그라운드 검토(background_review)는 부모와 같은 세션 id 로 돌므로 그 호출도 여기 쌓이고, 다음
메시지에 얹힌다. 맥락 크기도 그 호출의 것으로 바뀐다 (부모 맥락 + 검토 지시라 크기는 비슷하다).
"""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

PLATFORM = "skytower"
# 세션 id → 세션 키 캐시의 상한. 넘으면 오래된 것부터 버린다 (세션 수만큼만 자란다).
_MAX_SESSION_IDS = 4096

_lock = threading.Lock()
_session_store: Any = None
_key_by_session_id: Dict[str, str] = {}


@dataclass
class _Pending:
    input_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    output_tokens: int = 0
    api_calls: int = 0
    context_tokens: Optional[int] = None
    context_window: Optional[int] = None
    model: Optional[str] = None


_pending: Dict[str, _Pending] = {}


def _int(value: Any) -> int:
    try:
        n = int(value or 0)
    except (TypeError, ValueError):
        return 0
    return n if n > 0 else 0


def _remember_session_id(session_id: str, session_key: str) -> None:
    """락을 잡은 채 부른다."""
    if session_id in _key_by_session_id:
        _key_by_session_id.pop(session_id)
    elif len(_key_by_session_id) >= _MAX_SESSION_IDS:
        _key_by_session_id.pop(next(iter(_key_by_session_id)))
    _key_by_session_id[session_id] = session_key


def _resolve_session_key(session_id: str) -> Optional[str]:
    if not session_id:
        return None
    with _lock:
        key = _key_by_session_id.get(session_id)
        store = _session_store
    if key:
        return key
    if store is None:
        return None
    try:
        entry = store.lookup_by_session_id(session_id)
    except Exception:  # pragma: no cover - 스토어 구현 차이
        entry = None
    key = getattr(entry, "session_key", None)
    if not key:
        return None
    with _lock:
        _remember_session_id(session_id, key)
    return key


# ── 훅 ─────────────────────────────────────────────────────────────────────

def on_pre_gateway_dispatch(event: Any = None, gateway: Any = None, session_store: Any = None, **_: Any) -> None:
    """세션 스토어를 붙잡고, 이 이벤트의 세션 키 → 세션 id 를 미리 적는다 (기존 세션)."""
    global _session_store
    if session_store is not None:
        with _lock:
            _session_store = session_store
    source = getattr(event, "source", None)
    platform = getattr(getattr(source, "platform", None), "value", None)
    if platform != PLATFORM or gateway is None or session_store is None:
        return None
    try:
        from gateway.config import Platform
        adapter = getattr(gateway, "adapters", {}).get(Platform(PLATFORM))
        key = adapter._event_session_key(event) if adapter else None
        sid = session_store.peek_session_id(key) if key else None
    except Exception as exc:  # pragma: no cover - 방어
        logger.debug("skytower usage: pre-map failed: %s", exc)
        return None
    if key and sid:
        with _lock:
            _remember_session_id(sid, key)
    return None


def on_post_api_request(
    session_id: str = "",
    platform: str = "",
    model: Optional[str] = None,
    usage: Optional[Dict[str, Any]] = None,
    context_length: Optional[int] = None,
    **_: Any,
) -> None:
    """에이전트 스레드에서 API 호출마다 불린다. 예외를 밖으로 내지 않는다."""
    try:
        if str(platform or "") != PLATFORM or not isinstance(usage, dict):
            return None
        key = _resolve_session_key(str(session_id or ""))
        if not key:
            return None
        input_tokens = _int(usage.get("input_tokens"))
        cache_read = _int(usage.get("cache_read_tokens"))
        cache_write = _int(usage.get("cache_write_tokens"))
        prompt = _int(usage.get("prompt_tokens")) or (input_tokens + cache_read + cache_write)
        window = _int(context_length) or None
        with _lock:
            p = _pending.setdefault(key, _Pending())
            p.input_tokens += input_tokens
            p.cache_read_tokens += cache_read
            p.cache_write_tokens += cache_write
            p.output_tokens += _int(usage.get("output_tokens"))
            p.api_calls += 1
            p.context_tokens = prompt
            if window:
                p.context_window = window
            if model:
                p.model = str(model)
    except Exception as exc:  # pragma: no cover - 훅은 에이전트를 막지 않는다
        logger.debug("skytower usage: post_api_request failed: %s", exc)
    return None


def register_hooks(ctx: Any) -> None:
    ctx.register_hook("pre_gateway_dispatch", on_pre_gateway_dispatch)
    ctx.register_hook("post_api_request", on_post_api_request)


# ── 어댑터가 쓰는 쪽 ────────────────────────────────────────────────────────

def cache_ttl() -> Optional[str]:
    """이 게이트웨이의 프롬프트 캐시 TTL — ``"5m"`` · ``"1h"``, 모르거나 꺼져 있으면 None.

    ``prompt_caching.cache_ttl`` 이 ``auto`` 면 hermes 가 skytower 출처에 고르는 값을 따른다
    (사람이 치는 메시징 플랫폼이라 보통 ``1h``). 세션 환경 변수를 보는 ``session_source_for`` 는
    어댑터 쪽에서는 다른 세션의 값을 볼 수 있어 쓰지 않고 플랫폼 이름을 그대로 넘긴다.
    """
    try:
        from hermes_cli.config import load_config_readonly
        ttl = ((load_config_readonly() or {}).get("prompt_caching") or {}).get("cache_ttl", "5m")
    except Exception:
        return None
    if ttl in ("5m", "1h"):
        return ttl
    try:
        from agent.prompt_caching import AUTO_CACHE_TTL, auto_cache_ttl_for_source
        if ttl == AUTO_CACHE_TTL:
            chosen = auto_cache_ttl_for_source(PLATFORM)
            return chosen if chosen in ("5m", "1h") else None
    except Exception:
        return None
    return None


def take(session_key: Optional[str]) -> Optional[Dict[str, Any]]:
    """그 세션에 쌓인 몫을 꺼내고 비운다. 쌓인 호출이 없으면 None.

    돌려주는 모양 (relay 의 message_done · message_edit 에 그대로 합친다)::

        {"usage": {"input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens",
                   "api_calls", "model", "cache_ttl"},
         "context": {"tokens", "window"}}
    """
    if not session_key:
        return None
    with _lock:
        p = _pending.pop(session_key, None)
    if p is None or p.api_calls <= 0:
        return None
    return {
        "usage": {
            "input_tokens": p.input_tokens,
            "cache_read_tokens": p.cache_read_tokens,
            "cache_write_tokens": p.cache_write_tokens,
            "output_tokens": p.output_tokens,
            "api_calls": p.api_calls,
            "model": p.model,
            "cache_ttl": cache_ttl(),
        },
        "context": {"tokens": p.context_tokens, "window": p.context_window},
    }


def put_back(session_key: Optional[str], fields: Optional[Dict[str, Any]]) -> None:
    """보내기에 실패한 몫을 되돌린다. 그사이 쌓인 몫과 합치고, 맥락은 더 최근 값을 남긴다."""
    if not session_key or not isinstance(fields, dict):
        return
    u = fields.get("usage") or {}
    c = fields.get("context") or {}
    with _lock:
        newer = _pending.get(session_key)
        p = _Pending(
            input_tokens=_int(u.get("input_tokens")),
            cache_read_tokens=_int(u.get("cache_read_tokens")),
            cache_write_tokens=_int(u.get("cache_write_tokens")),
            output_tokens=_int(u.get("output_tokens")),
            api_calls=_int(u.get("api_calls")),
            context_tokens=c.get("tokens"),
            context_window=c.get("window"),
            model=u.get("model"),
        )
        if newer is not None:
            p.input_tokens += newer.input_tokens
            p.cache_read_tokens += newer.cache_read_tokens
            p.cache_write_tokens += newer.cache_write_tokens
            p.output_tokens += newer.output_tokens
            p.api_calls += newer.api_calls
            p.context_tokens = newer.context_tokens
            p.context_window = newer.context_window or p.context_window
            p.model = newer.model or p.model
        _pending[session_key] = p


def _reset_for_tests() -> None:
    global _session_store
    with _lock:
        _pending.clear()
        _key_by_session_id.clear()
        _session_store = None
