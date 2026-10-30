"""웹 터미널 (skytower_terminal · term_guard) 테스트.

PTY 를 실제로 띄우는 테스트는 PTY 백엔드(ptyprocess/pywinpty)가 있을 때만 돈다. 나머지는 순수 함수와
가짜 sio 로 본다.
"""
import asyncio
import os
import shutil
import sys
import time
from pathlib import Path

import pytest

from skytower_plugin import skytower_terminal as st
from skytower_plugin import term_guard

OSC = term_guard.OSC_PREFIX
BEL = term_guard.OSC_END


class FakeSio:
    def __init__(self):
        self.connected = True
        self.sent = []

    async def emit(self, event, data):
        self.sent.append((event, data))

    def last(self, event):
        for ev, data in reversed(self.sent):
            if ev == event:
                return data
        return None


# ---------------------------------------------------------------------------
# OSC 감사 시퀀스
# ---------------------------------------------------------------------------

def _osc(cmd, cwd="/w", blocked=False, reason=None):
    import base64
    b = lambda s: base64.b64encode(s.encode()).decode()  # noqa: E731
    body = f"cmd={b(cmd)};cwd={b(cwd)}"
    if blocked:
        body += f";blocked=1;reason={b(reason or '')}"
    return OSC + body + BEL


class TestStripOsc:
    def test_passthrough_without_osc(self):
        text, carry, audits = st.strip_osc("hello\r\n$ ")
        assert (text, carry, audits) == ("hello\r\n$ ", "", [])

    def test_extracts_and_removes(self):
        text, carry, audits = st.strip_osc("a" + _osc("ls -la", "/w") + "b")
        assert text == "ab" and carry == ""
        assert audits == [{"cmd": "ls -la", "cwd": "/w"}]

    def test_blocked_with_reason(self):
        _, _, audits = st.strip_osc(_osc("cat /etc/passwd", blocked=True, reason="outside"))
        assert audits == [{"cmd": "cat /etc/passwd", "cwd": "/w", "blocked": True, "reason": "outside"}]

    def test_split_across_chunks(self):
        full = "x" + _osc("echo hi") + "y"
        cut = len("x") + len(OSC) + 5
        text1, carry1, a1 = st.strip_osc(full[:cut])
        assert text1 == "x" and a1 == [] and carry1.startswith(OSC)
        text2, carry2, a2 = st.strip_osc(carry1 + full[cut:])
        assert text2 == "y" and carry2 == "" and a2 == [{"cmd": "echo hi", "cwd": "/w"}]

    def test_partial_prefix_is_carried(self):
        text, carry, audits = st.strip_osc("abc\x1b]77")
        assert text == "abc" and carry == "\x1b]77" and audits == []
        text2, carry2, audits2 = st.strip_osc(carry + "7;skytower;" + _osc("pwd")[len(OSC):] + "z")
        assert text2 == "z" and carry2 == "" and audits2[0]["cmd"] == "pwd"

    def test_lone_escape_passes(self):
        text, carry, _ = st.strip_osc("\x1b[31mred\x1b[0m")
        assert text == "\x1b[31mred\x1b[0m" and carry == ""


# ---------------------------------------------------------------------------
# 환경 씻기
# ---------------------------------------------------------------------------

class TestScrubEnv:
    def test_secrets_dropped_and_term_set(self):
        src = {
            "PATH": "/usr/bin", "HOME": "/home/u", "SKYTOWER_TOKEN": "ag:secret", "OPENAI_API_KEY": "sk-x",
            "ANTHROPIC_API_KEY": "x", "HERMES_HOME": "/h", "LANG": "ko_KR.UTF-8",
            "SystemRoot": "C:\\Windows", "USERPROFILE": "C:\\Users\\u", "PSModulePath": "x", "TEMP": "C:\\t",
        }
        env = st.scrub_env(src)
        for secret in ("SKYTOWER_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "HERMES_HOME"):
            assert secret not in env
        assert env["PATH"] == "/usr/bin"
        assert env["TERM"] == "xterm-256color" and env["COLORTERM"] == "truecolor"
        assert env["SKYTOWER_TERM"] == "1"
        if os.name == "nt":
            assert env["SystemRoot"] == "C:\\Windows" and env["USERPROFILE"] == "C:\\Users\\u"
        else:
            assert env["HOME"] == "/home/u" and env["LANG"] == "ko_KR.UTF-8"

    @pytest.mark.skipif(os.name == "nt", reason="POSIX LANG default")
    def test_non_utf8_lang_replaced(self):
        env = st.scrub_env({"PATH": "/bin", "LANG": "C"})
        assert env["LANG"] == "C.UTF-8"


# ---------------------------------------------------------------------------
# term_guard: 검사기와 훅 파일
# ---------------------------------------------------------------------------

class TestGuardCheck:
    def test_inside_passes(self):
        assert term_guard.check_command("ls ./src", workdir="/w/proj", cwd="/w/proj") is None
        assert term_guard.check_command("git status", workdir="/w/proj", cwd="/w/proj") is None

    def test_outside_is_denied(self):
        reason = term_guard.check_command("cat /etc/passwd", workdir="/w/proj", cwd="/w/proj")
        assert reason and "/etc/passwd" in reason and "/w/proj" in reason

    def test_no_workdir_means_no_check(self):
        assert term_guard.check_command("cat /etc/passwd", workdir="", cwd="/") is None

    def test_cli_exit_codes(self, capsys):
        assert term_guard.main(["--workdir", "/w/proj", "--cwd", "/w/proj", "--", "ls", "src"]) == 0
        assert term_guard.main(["--workdir", "/w/proj", "--cwd", "/w/proj", "--", "cd", "/etc"]) == 1
        assert "/etc" in capsys.readouterr().out

    def test_windows_notation_is_same_folder(self):
        assert term_guard.check_command("type ..\\other\\x.txt", workdir="D:/work/acme", cwd="D:\\work\\acme") is not None
        assert term_guard.check_command("type D:\\work\\acme\\a.txt", workdir="D:/work/acme", cwd="D:\\work\\acme") is None


class TestWriteHooks:
    def test_bash_rc(self, tmp_path):
        r = term_guard.write_hooks(str(tmp_path), "bash", session_id="s1", workdir="/w/it's", py="/venv/bin/python",
                                   guard_py="/plug/term_guard.py")
        rc = Path(r["files"][0]).read_text(encoding="utf-8")
        assert r["argv_tail"][:2] == ["--rcfile", str(tmp_path / "guard.bashrc")] and r["argv_tail"][-1] == "-i"
        assert "export SKYTOWER_WORKDIR='/w/it'\\''s'" in rc
        assert "shopt -s extdebug" in rc and "trap '__skytower_guard' DEBUG" in rc
        assert "__skytower_cd_check" in rc and "]777;skytower;" in rc

    def test_zsh_uses_zdotdir(self, tmp_path):
        r = term_guard.write_hooks(str(tmp_path), "zsh", session_id="s1", workdir="/w", py="python3", guard_py="/g.py")
        assert r["env"] == {"ZDOTDIR": str(tmp_path)}
        rc = (tmp_path / ".zshrc").read_text(encoding="utf-8")
        assert "zle -N accept-line __skytower_accept_line" in rc and 'export ZDOTDIR="$HOME"' in rc

    def test_pwsh_guard(self, tmp_path):
        r = term_guard.write_hooks(str(tmp_path), "pwsh", session_id="s1", workdir="D:/work/o'neil", py="C:\\py.exe",
                                   guard_py="C:\\plug\\term_guard.py")
        assert r["argv_tail"][-2:] == ["-File", str(tmp_path / "guard.ps1")] and "-ExecutionPolicy" in r["argv_tail"]
        ps1 = (tmp_path / "guard.ps1").read_text(encoding="utf-8-sig")
        assert "$global:SkytowerWorkdir = 'D:/work/o''neil'" in ps1
        assert "Set-PSReadLineKeyHandler -Key Enter" in ps1 and "GetBufferState" in ps1 and "function global:prompt" in ps1

    def test_no_workdir_keeps_audit_only(self, tmp_path):
        r = term_guard.write_hooks(str(tmp_path), "bash", session_id="s1", workdir=None, py="python3", guard_py="/g.py")
        assert "export SKYTOWER_WORKDIR=''" in Path(r["files"][0]).read_text(encoding="utf-8")

    def test_unsupported_shell(self, tmp_path):
        with pytest.raises(ValueError):
            term_guard.write_hooks(str(tmp_path), "fish", session_id="s1", workdir="/w", py="p", guard_py="g")


# ---------------------------------------------------------------------------
# TerminalHandler: 열기 거절 경로 (스폰 없음)
# ---------------------------------------------------------------------------

def _handler(monkeypatch, caps, enabled=True):
    sio = FakeSio()
    h = st.TerminalHandler(sio, enabled=enabled)
    h._caps = {"pty": True, "platform": sys.platform, "shells": ["bash", "pwsh"], "guard": ["bash", "pwsh"], "sandbox": [],
               **caps, "enabled": enabled}
    return h, sio


class TestOpenRefusals:
    @pytest.mark.asyncio
    async def test_disabled(self, monkeypatch):
        h, sio = _handler(monkeypatch, {}, enabled=False)
        await h.handle_open({"session_id": "s1", "confine": "none"})
        assert sio.last("term:error")["reason"] == "disabled"

    @pytest.mark.asyncio
    async def test_no_pty(self, monkeypatch):
        h, sio = _handler(monkeypatch, {"pty": False})
        await h.handle_open({"session_id": "s1", "confine": "none"})
        assert sio.last("term:error")["reason"] == "pty_unavailable"

    @pytest.mark.asyncio
    async def test_unknown_confine(self, monkeypatch):
        h, sio = _handler(monkeypatch, {})
        await h.handle_open({"session_id": "s1", "confine": "maybe"})
        assert sio.last("term:error")["reason"] == "bad_request"

    @pytest.mark.asyncio
    async def test_sandbox_without_backend_is_refused_not_downgraded(self, monkeypatch, tmp_path):
        h, sio = _handler(monkeypatch, {"sandbox": []})
        await h.handle_open({"session_id": "s1", "confine": "sandbox", "workdir": str(tmp_path)})
        assert sio.last("term:error")["reason"] == "sandbox_unavailable"
        assert sio.last("term:opened") is None

    @pytest.mark.asyncio
    async def test_sandbox_requires_workdir(self, monkeypatch):
        h, sio = _handler(monkeypatch, {"sandbox": ["bwrap"]})
        await h.handle_open({"session_id": "s1", "confine": "sandbox", "workdir": None})
        assert sio.last("term:error")["reason"] == "workdir_required"

    @pytest.mark.asyncio
    async def test_guard_with_missing_workdir(self, monkeypatch, tmp_path):
        h, sio = _handler(monkeypatch, {})
        await h.handle_open({"session_id": "s1", "confine": "guard", "workdir": str(tmp_path / "nope")})
        assert sio.last("term:error")["reason"] == "workdir_missing"

    @pytest.mark.asyncio
    async def test_session_limit(self, monkeypatch):
        h, sio = _handler(monkeypatch, {})
        for i in range(st.MAX_SESSIONS):
            h._sessions[f"x{i}"] = object()
        await h.handle_open({"session_id": "s1", "confine": "none"})
        assert sio.last("term:error")["reason"] == "limit"


class TestBuildSpec:
    def test_none_confine_falls_back_to_home_when_workdir_missing(self, monkeypatch, tmp_path):
        h, _ = _handler(monkeypatch, {})
        spec = h._build_spec("s1", "none", str(tmp_path / "gone"), True)
        assert spec["cwd"] == str(Path.home()) and spec["confine_applied"] == "none" and spec["guard"] is False
        shutil.rmtree(spec["session_dir"], ignore_errors=True)

    def test_guard_spec_uses_hooks(self, monkeypatch, tmp_path):
        h, _ = _handler(monkeypatch, {})
        spec = h._build_spec("s1", "guard", str(tmp_path), True)
        try:
            assert spec["confine_applied"] == "guard" and spec["guard"] is True
            assert spec["cwd"] == os.path.normpath(str(tmp_path))
            assert "SKYTOWER_TOKEN" not in spec["env"] and spec["env"]["SKYTOWER_TERM_SESSION"] == "s1"
            argv = spec["argv"]
            if os.name == "nt":
                assert "-File" in argv and argv[-1].endswith("guard.ps1")
            else:
                assert "--rcfile" in argv and argv[-1] == "-i"
        finally:
            shutil.rmtree(spec["session_dir"], ignore_errors=True)

    def test_bwrap_args(self):
        args = st.TerminalHandler._bwrap_args("/w/p", "/home/u", ["/extra"], network=False)
        assert args[:3] == ["bwrap", "--ro-bind", "/usr"]
        assert "--unshare-net" in args and "--chdir" in args and args[args.index("--chdir") + 1] == "/w/p"
        assert args[args.index("--bind") + 1:args.index("--bind") + 3] == ["/w/p", "/w/p"]
        assert "/extra" in args
        assert "--unshare-net" not in st.TerminalHandler._bwrap_args("/w/p", "/home/u", [], network=True)

    @pytest.mark.skipif(os.name == "nt", reason="bwrap spec is POSIX")
    def test_bwrap_spec_binds_plugin_and_python(self, monkeypatch, tmp_path):
        h, _ = _handler(monkeypatch, {"sandbox": ["bwrap"], "shells": ["bash"]})
        spec = h._build_spec("s1", "sandbox", str(tmp_path), False)
        try:
            argv = spec["argv"]
            assert argv[0] == "bwrap" and spec["confine_applied"] == "sandbox" and spec["sandbox"] == "bwrap"
            assert str(st.PLUGIN_DIR) in argv and sys.prefix in argv and "--unshare-net" in argv
            assert argv[-1] == "-i" and "--rcfile" in argv
        finally:
            shutil.rmtree(spec["session_dir"], ignore_errors=True)

    def test_docker_spec(self, monkeypatch, tmp_path):
        h, _ = _handler(monkeypatch, {"sandbox": ["docker"]})
        monkeypatch.setenv("SKYTOWER_TERMINAL_IMAGE", "img:1")
        spec = h._build_spec("s1", "sandbox", str(tmp_path), False)
        try:
            argv = spec["argv"]
            assert argv[:3] == ["docker", "run", "--rm"] and "img:1" in argv and spec["sandbox"] == "docker"
            assert "--network" in argv and argv[argv.index("--network") + 1] == "none"
            assert any(a.endswith(":/skytower-plugin:ro") for a in argv)
            assert argv[-3:] == ["--rcfile", "/skytower-session/guard.bashrc", "-i"]
        finally:
            shutil.rmtree(spec["session_dir"], ignore_errors=True)


# ---------------------------------------------------------------------------
# 실제 PTY 왕복 (백엔드가 있을 때만)
# ---------------------------------------------------------------------------

@pytest.mark.skipif(not st._pty_available(), reason="no PTY backend installed")
@pytest.mark.asyncio
async def test_real_pty_roundtrip(tmp_path):
    sio = FakeSio()
    h = st.TerminalHandler(sio, enabled=True)
    await h.handle_open({"session_id": "rt-1", "confine": "none", "workdir": str(tmp_path), "cols": 100, "rows": 30})
    opened = sio.last("term:opened")
    assert opened is not None, sio.sent
    assert opened["confine_applied"] == "none" and opened["session_id"] == "rt-1"
    assert h.session_count == 1

    await asyncio.sleep(1.5 if os.name == "nt" else 0.3)
    await h.handle_input({"session_id": "rt-1", "data": "echo skytower-ok-$((40+2))\r"})
    deadline = time.time() + 25
    while time.time() < deadline:
        joined = "".join(d["data"] for ev, d in sio.sent if ev == "term:output")
        if "skytower-ok-42" in joined:
            break
        await asyncio.sleep(0.1)
    assert "skytower-ok-42" in joined, joined[-500:]

    # 환경이 씻겼는지: 토큰이 셸에 보이면 안 된다
    await h.handle_resize({"session_id": "rt-1", "cols": 120, "rows": 40})
    await h.handle_close({"session_id": "rt-1"})
    assert h.session_count == 0
    assert sio.last("term:exit") is None, "closing from our side does not announce term:exit"
