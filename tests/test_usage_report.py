"""턴 사용량·맥락 크기 보고 (usage_report.py, skytower ADR 0016)."""
import threading
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from gateway.config import Platform, PlatformConfig

from skytower_plugin import usage_report


@pytest.fixture(autouse=True)
def _clean_state():
    usage_report._reset_for_tests()
    yield
    usage_report._reset_for_tests()


def _store(mapping=None, peek=None):
    """lookup_by_session_id(sid) → entry(session_key), peek_session_id(key) → sid."""
    mapping = mapping or {}
    store = MagicMock()
    store.lookup_by_session_id.side_effect = (
        lambda sid: SimpleNamespace(session_key=mapping[sid]) if sid in mapping else None)
    store.peek_session_id.side_effect = lambda key: (peek or {}).get(key)
    return store


def _usage(inp=10, read=1000, write=200, out=50):
    return {"input_tokens": inp, "cache_read_tokens": read, "cache_write_tokens": write,
            "output_tokens": out, "prompt_tokens": inp + read + write, "total_tokens": inp + read + write + out}


def _call(session_id="s1", platform="skytower", usage=None, model="claude-opus-5-5", context_length=1_000_000):
    usage_report.on_post_api_request(
        session_id=session_id, platform=platform, model=model,
        usage=_usage() if usage is None else usage, context_length=context_length,
        task_id="t", api_call_count=1)


def _attach_store(store):
    usage_report.on_pre_gateway_dispatch(event=None, gateway=None, session_store=store)


class TestAccumulate:
    def test_sums_calls_and_keeps_last_context(self):
        _attach_store(_store({"s1": "key-1"}))
        _call(usage=_usage(inp=4, read=1000, write=100, out=20))
        _call(usage=_usage(inp=6, read=1100, write=50, out=30))

        out = usage_report.take("key-1")

        assert out["usage"] == {
            "input_tokens": 10, "cache_read_tokens": 2100, "cache_write_tokens": 150, "output_tokens": 50,
            "api_calls": 2, "model": "claude-opus-5-5", "cache_ttl": out["usage"]["cache_ttl"],
        }
        # 맥락 = 마지막 호출이 보낸 양 (6 + 1100 + 50)
        assert out["context"] == {"tokens": 1156, "window": 1_000_000}

    def test_take_resets(self):
        _attach_store(_store({"s1": "key-1"}))
        _call()
        assert usage_report.take("key-1") is not None
        assert usage_report.take("key-1") is None

    def test_other_platform_ignored(self):
        _attach_store(_store({"s1": "key-1"}))
        _call(platform="cron")
        assert usage_report.take("key-1") is None

    def test_unresolvable_session_ignored(self):
        _attach_store(_store({}))
        _call(session_id="unknown")
        assert usage_report._pending == {}

    def test_without_store_ignored(self):
        _call()
        assert usage_report._pending == {}

    def test_missing_usage_ignored(self):
        _attach_store(_store({"s1": "key-1"}))
        usage_report.on_post_api_request(session_id="s1", platform="skytower", usage=None)
        assert usage_report.take("key-1") is None

    def test_prompt_tokens_fallback_and_missing_window(self):
        _attach_store(_store({"s1": "key-1"}))
        _call(usage={"input_tokens": 3, "cache_read_tokens": 7, "cache_write_tokens": 0, "output_tokens": 1},
              context_length=None)
        out = usage_report.take("key-1")
        assert out["context"] == {"tokens": 10, "window": None}

    def test_pre_dispatch_maps_existing_session(self):
        store = _store({}, peek={"key-9": "s9"})
        adapter = MagicMock()
        adapter._event_session_key.return_value = "key-9"
        gateway = SimpleNamespace(adapters={Platform("skytower"): adapter})
        event = SimpleNamespace(source=SimpleNamespace(platform=Platform("skytower")))

        usage_report.on_pre_gateway_dispatch(event=event, gateway=gateway, session_store=store)
        _call(session_id="s9")

        assert usage_report.take("key-9")["usage"]["api_calls"] == 1
        store.lookup_by_session_id.assert_not_called()

    def test_threads_do_not_lose_counts(self):
        _attach_store(_store({"s1": "key-1"}))
        per_thread, threads = 200, 8

        def work():
            for _ in range(per_thread):
                _call(usage=_usage(inp=1, read=2, write=3, out=4))

        ts = [threading.Thread(target=work) for _ in range(threads)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()

        u = usage_report.take("key-1")["usage"]
        n = per_thread * threads
        assert (u["api_calls"], u["input_tokens"], u["cache_read_tokens"], u["cache_write_tokens"],
                u["output_tokens"]) == (n, n, 2 * n, 3 * n, 4 * n)

    def test_put_back_merges_with_newer(self):
        _attach_store(_store({"s1": "key-1"}))
        _call(usage=_usage(inp=1, read=10, write=0, out=1))
        first = usage_report.take("key-1")
        _call(usage=_usage(inp=2, read=20, write=0, out=2))

        usage_report.put_back("key-1", first)

        out = usage_report.take("key-1")
        assert out["usage"]["api_calls"] == 2
        assert out["usage"]["input_tokens"] == 3
        assert out["context"]["tokens"] == 22  # 더 최근 호출의 맥락


class TestCacheTtl:
    @pytest.mark.parametrize("configured,expected", [("5m", "5m"), ("1h", "1h"), ("off", None), ("weird", None)])
    def test_fixed_values(self, configured, expected):
        with patch("hermes_cli.config.load_config_readonly", return_value={"prompt_caching": {"cache_ttl": configured}}):
            assert usage_report.cache_ttl() == expected

    def test_auto_follows_hermes_choice_for_skytower(self):
        from agent.prompt_caching import AUTO_CACHE_TTL, auto_cache_ttl_for_source
        with patch("hermes_cli.config.load_config_readonly", return_value={"prompt_caching": {"cache_ttl": AUTO_CACHE_TTL}}):
            assert usage_report.cache_ttl() == auto_cache_ttl_for_source("skytower")

    def test_default_is_5m(self):
        with patch("hermes_cli.config.load_config_readonly", return_value={}):
            assert usage_report.cache_ttl() == "5m"


# ---------------------------------------------------------------------------
# 어댑터: send / edit_message 에 싣기
# ---------------------------------------------------------------------------

def _adapter(capabilities=None):
    from skytower_plugin.adapter import SkyTowerAdapter
    adapter = SkyTowerAdapter(PlatformConfig(enabled=True, extra={
        "token": "testAgentId:testRawToken", "url": "http://localhost:4000"}))
    adapter._sio = AsyncMock()
    adapter._sio.connected = True
    adapter._relay_capabilities = {"usage_detail": True, **(capabilities or {})}
    return adapter


CHAT = "skytower:testAgentId:7:3"


def _pend(key="key-1"):
    _attach_store(_store({"s1": key}))
    _call(usage=_usage(inp=5, read=900, write=100, out=40))


class TestAdapterAttach:
    @pytest.mark.asyncio
    async def test_send_attaches_and_resets(self):
        adapter = _adapter()
        adapter._session_key_by_chat[CHAT] = "key-1"
        _pend()

        await adapter.send(CHAT, "답")
        payload = adapter._sio.emit.call_args[0][1]
        assert payload["usage"]["output_tokens"] == 40
        assert payload["usage"]["api_calls"] == 1
        assert payload["context"] == {"tokens": 1005, "window": 1_000_000}

        await adapter.send(CHAT, "두 번째")
        assert "usage" not in adapter._sio.emit.call_args[0][1]

    @pytest.mark.asyncio
    async def test_no_capability_no_usage_and_kept(self):
        adapter = _adapter()
        adapter._relay_capabilities = {}
        adapter._session_key_by_chat[CHAT] = "key-1"
        _pend()

        await adapter.send(CHAT, "답")

        assert "usage" not in adapter._sio.emit.call_args[0][1]
        assert usage_report.take("key-1") is not None  # 꺼내지 않았다

    @pytest.mark.asyncio
    async def test_nothing_pending_sends_plain_payload(self):
        adapter = _adapter()
        adapter._session_key_by_chat[CHAT] = "key-1"
        await adapter.send(CHAT, "답")
        adapter._sio.emit.assert_called_once_with("message_done", {
            "content": "답", "type": "text", "target_conversation_id": 3})

    @pytest.mark.asyncio
    async def test_send_failure_puts_back(self):
        adapter = _adapter()
        adapter._sio.emit.side_effect = RuntimeError("network error")
        adapter._session_key_by_chat[CHAT] = "key-1"
        _pend()

        result = await adapter.send(CHAT, "답")

        assert result.success is False
        assert usage_report.take("key-1")["usage"]["output_tokens"] == 40

    @pytest.mark.asyncio
    async def test_finalize_edit_attaches_non_final_does_not(self):
        adapter = _adapter({"edit_message": True})
        adapter._sio.call.return_value = {"success": True}
        adapter._session_key_by_chat[CHAT] = "key-1"
        _pend()

        await adapter.edit_message(CHAT, "101", "중간", finalize=False)
        assert "usage" not in adapter._sio.call.call_args[0][1]

        await adapter.edit_message(CHAT, "101", "끝", finalize=True)
        payload = adapter._sio.call.call_args[0][1]
        assert payload["finalize"] is True
        assert payload["usage"]["output_tokens"] == 40
        assert payload["context"]["tokens"] == 1005

    @pytest.mark.asyncio
    async def test_failed_finalize_puts_back(self):
        adapter = _adapter({"edit_message": True})
        adapter._sio.call.return_value = {"success": False, "error": "Message not found"}
        adapter._session_key_by_chat[CHAT] = "key-1"
        _pend()

        await adapter.edit_message(CHAT, "101", "끝", finalize=True)

        assert usage_report.take("key-1") is not None

    @pytest.mark.asyncio
    async def test_current_session_used_only_for_its_own_chat(self):
        adapter = _adapter()
        adapter._current_chat_id.set(CHAT)
        adapter._current_session_key.set("key-1")
        adapter._session_key_by_chat["skytower:testAgentId:7:4"] = "key-2"
        _pend("key-1")

        # 처리 중인 방 A 의 컨텍스트에서 방 B 로 보내도 A 의 몫은 B 에 실리지 않는다
        await adapter.send("skytower:testAgentId:7:4", "다른 방")
        assert "usage" not in adapter._sio.emit.call_args[0][1]

        await adapter.send(CHAT, "자기 방")
        assert adapter._sio.emit.call_args[0][1]["usage"]["api_calls"] == 1

    @pytest.mark.asyncio
    async def test_relay_message_remembers_session_key(self):
        adapter = _adapter()
        adapter.handle_message = AsyncMock()
        await adapter._handle_relay_message({
            "direction": "outbound", "type": "text", "content": "안녕", "user_id": 7,
            "conversation_id": 3, "id": 42,
        })
        event = adapter.handle_message.call_args[0][0]
        assert adapter._session_key_by_chat[CHAT] == adapter._source_session_key(event.source)


def test_register_adds_usage_hooks():
    from skytower_plugin.adapter import register
    ctx = MagicMock()
    register(ctx)
    hooks = [c.args[0] for c in ctx.register_hook.call_args_list]
    assert "post_api_request" in hooks
    assert hooks.count("pre_gateway_dispatch") >= 1
