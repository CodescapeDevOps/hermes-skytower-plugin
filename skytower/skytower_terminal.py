"""웹 터미널 (skytower ``term:*`` 이벤트, docs/plans/2026-10-ssh-terminal.md, ADR 0005).

웹 → relay → 이 핸들러 → 에이전트 PC 의 PTY. relay 는 바이트를 옮길 뿐이고 셸은 여기(hermes 가 도는 PC)에 뜬다.
인바운드 포트도 sshd 도 없다. 다른 호스트로 가고 싶으면 그 PTY 안에서 ``ssh`` 를 치면 되고, 키는 PC 를 떠나지 않는다.

  relay → 플러그인   term:open {session_id, cols, rows, conv_id?, workdir, confine, network, user}
                     term:input {session_id, data}   term:resize {session_id, cols, rows}   term:close {session_id}
  플러그인 → relay   term:opened {session_id, shell, cwd, platform, confine_applied, sandbox, guard}
                     term:output {session_id, data}   term:audit {session_id, cmd, cwd, blocked?, reason?}
                     term:exit {session_id, code}     term:error {session_id, reason, error}

제한 단계(``confine``)는 relay 가 정해 보낸다. 못 맞추면 열지 않고 ``term:error`` 로 답한다 — 낮은 단계로 내려가지
않는다 (relay 도 ``confine_applied`` 가 요청보다 낮으면 세션을 닫는다).

  none     시작 위치만 작업 폴더(없으면 홈). 개인 방.
  guard    L1 안내선 — 셸 훅이 실행 직전 명령줄을 검사하고(``term_guard``) 감사 로그를 남긴다. 우회 가능.
  sandbox  L2 격리 — bwrap(Linux) 또는 docker 안에서 셸. 작업 폴더만 쓰기 가능, 홈·.ssh·.hermes 는 보이지 않는다.

PTY: hermes 코어 의존성인 ``ptyprocess``(POSIX) / ``pywinpty``(Windows, ConPTY). 파이프 폴백은 없다 — 파이프로 뜨면
vi 가 화면을 못 그려 "고장" 처럼 보인다. 환경은 상속하지 않고 통과 목록만 넘긴다 (``SKYTOWER_TOKEN``·API 키 제외).
"""

from __future__ import annotations

import asyncio
import base64
import codecs
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from . import term_guard

try:
    from . import confinement
except Exception:  # pragma: no cover - 배포 환경 차이
    confinement = None

logger = logging.getLogger(__name__)

_IS_WINDOWS = os.name == "nt"
PLUGIN_DIR = Path(__file__).resolve().parent

MAX_SESSIONS = 4
READ_SIZE = 4096
CONFINE_LEVELS = ("none", "guard", "sandbox")

# 환경 통과 목록. 너무 비우면 셸 자체가 안 뜬다 (특히 PowerShell). 그 밖은 전부 버린다 — 플러그인 프로세스 환경에는
# SKYTOWER_TOKEN 과 모델 API 키가 있다. 터미널에서 `env` 한 줄로 보이면 안 된다.
_POSIX_ENV_KEEP = (
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LANGUAGE", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
    "TZ", "TMPDIR", "XDG_RUNTIME_DIR", "XDG_DATA_DIRS", "XDG_CONFIG_DIRS", "DISPLAY", "WAYLAND_DISPLAY",
)
_WIN_ENV_KEEP = (
    "SYSTEMROOT", "SYSTEMDRIVE", "WINDIR", "COMSPEC", "PATH", "PATHEXT", "OS",
    "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "USERNAME", "USERDOMAIN", "COMPUTERNAME",
    "APPDATA", "LOCALAPPDATA", "PROGRAMDATA", "PUBLIC", "ALLUSERSPROFILE", "TEMP", "TMP",
    "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432", "COMMONPROGRAMFILES", "COMMONPROGRAMFILES(X86)",
    "PSMODULEPATH", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER",
)


class TerminalUnavailable(Exception):
    """열 수 없는 이유. ``reason`` 은 relay·웹이 분기하는 짧은 코드, 메시지는 사람에게 보이는 문장."""

    def __init__(self, reason: str, message: str) -> None:
        super().__init__(message)
        self.reason = reason


# ── 환경·능력 ─────────────────────────────────────────────────────────────────

def scrub_env(source: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """통과 목록만 남긴 환경. 거기에 TERM·COLORTERM·UTF-8 LANG 을 더한다 (vi 등 전체 화면 프로그램의 전제)."""
    src = dict(os.environ if source is None else source)
    keep = _WIN_ENV_KEEP if _IS_WINDOWS else _POSIX_ENV_KEEP
    out: Dict[str, str] = {}
    for k, v in src.items():
        if (k.upper() if _IS_WINDOWS else k) in keep:
            out[k] = v
    out["TERM"] = "xterm-256color"
    out["COLORTERM"] = "truecolor"
    if not _IS_WINDOWS:
        lang = out.get("LANG") or ""
        if "utf" not in lang.lower():
            out["LANG"] = "C.UTF-8"
    out["SKYTOWER_TERM"] = "1"
    return out


def _pty_available() -> bool:
    try:
        if _IS_WINDOWS:
            import winpty  # noqa: F401
        else:
            import ptyprocess  # noqa: F401
        return True
    except Exception:
        return False


def _which(name: str) -> Optional[str]:
    return shutil.which(name)


def _run_quiet(argv: List[str], timeout: float = 10.0) -> Tuple[int, str]:
    kwargs: Dict[str, Any] = {}
    if _IS_WINDOWS:
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, **kwargs)
        return p.returncode, (p.stdout or "").strip()
    except Exception:
        return 1, ""


def probe_capabilities() -> dict:
    """이 PC 가 지원하는 것. 하트비트에 실려 가서 웹 설정 화면이 "이 PC 는 격리 불가" 를 미리 보여 준다.
    느린 검사(wsl.exe)가 있으니 스레드에서 부르고 결과는 캐시한다 (``TerminalHandler.capabilities``).
    """
    shells: List[str] = []
    if _IS_WINDOWS:
        for s in ("pwsh", "powershell"):
            if _which(s):
                shells.append(s)
    else:
        for s in ("bash", "zsh", "fish", "sh"):
            if _which(s):
                shells.append(s)
    sandbox: List[str] = []
    if not _IS_WINDOWS and _which("bwrap"):
        sandbox.append("bwrap")
    if _which("docker"):
        sandbox.append("docker")
    if _IS_WINDOWS and _which("wsl.exe"):
        code, out = _run_quiet(["wsl.exe", "-e", "sh", "-c", "command -v bwrap"], timeout=15)
        if code == 0 and out:
            sandbox.append("wsl")
    return {
        "pty": _pty_available(),
        "platform": sys.platform,
        "shells": shells,
        "guard": [s for s in shells if s in term_guard.GUARD_SHELLS],
        "sandbox": sandbox,
    }


# ── OSC 감사 시퀀스 ───────────────────────────────────────────────────────────

def _b64d(s: str) -> str:
    try:
        return base64.b64decode(s.encode("ascii"), validate=False).decode("utf-8", errors="replace")
    except Exception:
        return ""


def strip_osc(text: str) -> Tuple[str, str, List[dict]]:
    """훅이 섞어 보낸 ``ESC ] 777 ; skytower ; k=v;… BEL`` 을 걷어 낸다.

    반환: (화면에 보낼 텍스트, 다음 청크에 이어 붙일 꼬리, 감사 항목들).
    꼬리는 시퀀스가 청크 경계에서 잘렸을 때 — 시작은 왔는데 BEL 이 아직 안 왔거나, 접두어 일부만 온 경우.
    """
    out: List[str] = []
    audits: List[dict] = []
    i = 0
    n = len(text)
    while i < n:
        j = text.find(term_guard.OSC_PREFIX, i)
        if j < 0:
            # 접두어의 앞부분만 끝에 걸려 있으면 꼬리로 남긴다
            tail = ""
            for k in range(1, len(term_guard.OSC_PREFIX)):
                if text.endswith(term_guard.OSC_PREFIX[:k], i):
                    tail = term_guard.OSC_PREFIX[:k]
            out.append(text[i:n - len(tail)])
            return "".join(out), tail, audits
        out.append(text[i:j])
        end = text.find(term_guard.OSC_END, j)
        if end < 0:
            return "".join(out), text[j:], audits
        body = text[j + len(term_guard.OSC_PREFIX):end]
        item: dict = {}
        for part in body.split(";"):
            if "=" not in part:
                continue
            k, v = part.split("=", 1)
            if k in ("cmd", "cwd", "reason"):
                item[k] = _b64d(v)
            elif k == "blocked":
                item["blocked"] = v in ("1", "true")
        if item.get("cmd"):
            audits.append(item)
        i = end + 1
    return "".join(out), "", audits


# ── 세션 ──────────────────────────────────────────────────────────────────────

class _Session:
    def __init__(self, session_id: str, proc: Any, *, session_dir: Optional[str], meta: dict) -> None:
        self.id = session_id
        self.proc = proc
        self.session_dir = session_dir
        self.meta = meta
        self.reader: Optional[asyncio.Task] = None
        self.closing = False
        self.started = time.time()

    def read(self) -> Any:
        return self.proc.read(READ_SIZE)

    def write(self, text: str) -> None:
        if _IS_WINDOWS:
            self.proc.write(text)
        else:
            self.proc.write(text.encode("utf-8"))

    def resize(self, cols: int, rows: int) -> None:
        self.proc.setwinsize(rows, cols)

    def alive(self) -> bool:
        try:
            return bool(self.proc.isalive())
        except Exception:
            return False

    def terminate(self) -> None:
        try:
            if self.alive():
                self.proc.terminate(force=True)
        except Exception:
            pass

    def exit_code(self) -> Optional[int]:
        try:
            code = self.proc.exitstatus
            return int(code) if code is not None else None
        except Exception:
            return None

    def cleanup(self) -> None:
        if self.session_dir:
            shutil.rmtree(self.session_dir, ignore_errors=True)
            self.session_dir = None


def _spawn(argv: List[str], *, cwd: str, env: Dict[str, str], cols: int, rows: int) -> Any:
    if _IS_WINDOWS:
        from winpty import PtyProcess
    else:
        from ptyprocess import PtyProcess
    return PtyProcess.spawn(argv, cwd=cwd, env=env, dimensions=(rows, cols))


def _clamp(v: Any, lo: int, hi: int, dflt: int) -> int:
    try:
        n = int(v)
    except Exception:
        return dflt
    return max(lo, min(hi, n))


class TerminalHandler:
    """``term:*`` 이벤트. 어댑터가 ``connect()`` 에서 만들고 ``disconnect()`` 에서 ``close_all`` 을 부른다."""

    def __init__(self, sio: Any, *, enabled: Optional[bool] = None) -> None:
        self._sio = sio
        self._sessions: Dict[str, _Session] = {}
        if enabled is None:
            enabled = os.getenv("SKYTOWER_TERMINAL", "1").strip().lower() not in ("0", "false", "no", "off")
        self.enabled = enabled
        self._caps: Optional[dict] = None

    def bind(self, sio: Any) -> None:
        """어댑터가 (재)접속할 때 새 소켓을 붙인다. 능력 캐시는 그대로."""
        self._sio = sio

    # ── 공통 ──

    async def _emit(self, event: str, data: dict) -> None:
        if self._sio and getattr(self._sio, "connected", False):
            await self._sio.emit(event, data)

    async def _error(self, session_id: Any, reason: str, message: str) -> None:
        logger.warning("term:error session=%s reason=%s: %s", session_id, reason, message)
        await self._emit("term:error", {"session_id": session_id, "reason": reason, "error": message})

    def capabilities(self) -> dict:
        """하트비트용. 첫 호출에서 한 번 조사하고 캐시한다 (스레드에서 부를 것)."""
        if self._caps is None:
            try:
                caps = probe_capabilities()
            except Exception as exc:  # pragma: no cover
                logger.warning("terminal capability probe failed: %s", exc)
                caps = {"pty": False, "platform": sys.platform, "shells": [], "guard": [], "sandbox": []}
            caps["enabled"] = self.enabled
            self._caps = caps
        return self._caps

    # ── term:open ──

    async def handle_open(self, data: dict) -> None:
        sid = data.get("session_id")
        if not isinstance(sid, str) or not sid:
            return
        if not self.enabled:
            return await self._error(sid, "disabled", "이 에이전트 PC 에서는 터미널이 꺼져 있습니다 (SKYTOWER_TERMINAL=0).")
        if sid in self._sessions:
            return await self._error(sid, "bad_request", "이미 열린 세션입니다.")
        if len(self._sessions) >= MAX_SESSIONS:
            return await self._error(sid, "limit", f"이 PC 에는 터미널이 이미 {MAX_SESSIONS}개 열려 있습니다.")
        confine = data.get("confine") or "none"
        if confine not in CONFINE_LEVELS:
            return await self._error(sid, "bad_request", f"모르는 제한 단계: {confine}")
        cols = _clamp(data.get("cols"), 10, 500, 80)
        rows = _clamp(data.get("rows"), 3, 200, 24)
        try:
            spec = await asyncio.to_thread(
                self._build_spec, sid, confine, data.get("workdir"), data.get("network", True) is not False,
            )
            proc = await asyncio.to_thread(_spawn, spec["argv"], cwd=spec["cwd"], env=spec["env"], cols=cols, rows=rows)
        except TerminalUnavailable as exc:
            return await self._error(sid, exc.reason, str(exc))
        except Exception as exc:
            logger.exception("terminal spawn failed session=%s", sid)
            return await self._error(sid, "spawn_failed", f"셸을 띄우지 못했습니다: {exc}")

        session = _Session(sid, proc, session_dir=spec.get("session_dir"), meta=spec)
        self._sessions[sid] = session
        session.reader = asyncio.create_task(self._read_loop(session))
        await self._emit("term:opened", {
            "session_id": sid,
            "shell": spec["shell"],
            "cwd": spec["cwd_display"],
            "platform": sys.platform,
            "confine_applied": spec["confine_applied"],
            "sandbox": spec["sandbox"],
            "guard": spec["guard"],
        })
        logger.info("terminal opened session=%s shell=%s confine=%s sandbox=%s cwd=%s user=%s",
                    sid, spec["shell"], spec["confine_applied"], spec["sandbox"], spec["cwd_display"],
                    (data.get("user") or {}).get("id"))

    # ── 셸·격리 결정 ──

    def _build_spec(self, sid: str, confine: str, workdir: Any, network: bool) -> dict:
        caps = self.capabilities()
        if not caps.get("pty"):
            raise TerminalUnavailable("pty_unavailable", "이 PC 에 PTY 라이브러리(ptyprocess/pywinpty)가 없습니다.")

        local_wd: Optional[str] = None
        if isinstance(workdir, str) and workdir.strip():
            local_wd = confinement.to_local_path(workdir) if confinement is not None else workdir.strip()
            local_wd = os.path.normpath(local_wd)
            if not os.path.isdir(local_wd):
                if confine != "none":
                    raise TerminalUnavailable("workdir_missing", f"작업 폴더가 이 PC 에 없습니다: {local_wd}")
                local_wd = None
        if confine == "sandbox" and not local_wd:
            raise TerminalUnavailable("workdir_required", "격리 터미널은 프로젝트에 작업 폴더가 있어야 합니다.")

        home = str(Path.home())
        cwd = local_wd or home
        session_dir = tempfile.mkdtemp(prefix="skytower-term-")
        env = scrub_env()
        env["SKYTOWER_TERM_SESSION"] = sid
        shell = self._pick_shell(caps)
        use_guard = confine in ("guard", "sandbox") and shell in term_guard.GUARD_SHELLS
        spec: dict = {
            "shell": shell, "cwd": cwd, "cwd_display": cwd, "env": env, "session_dir": session_dir,
            "confine_applied": "none", "sandbox": None, "guard": False,
        }

        if confine == "sandbox":
            backend = self._pick_sandbox(caps)
            if backend is None:
                raise TerminalUnavailable(
                    "sandbox_unavailable",
                    "이 PC 에는 격리 수단(bwrap · docker)이 없습니다. 프로젝트 설정에서 '안내선' 을 고르거나 docker 를 설치하세요.",
                )
            if backend == "bwrap":
                spec.update(self._bwrap_spec(sid, local_wd, home, env, session_dir, network, use_guard))
            elif backend == "docker":
                spec.update(self._docker_spec(sid, local_wd, env, session_dir, network))
            elif backend == "wsl":
                spec.update(self._wsl_spec(sid, local_wd, env, session_dir, network))
            spec["confine_applied"] = "sandbox"
            spec["sandbox"] = backend
            return spec

        argv = self._shell_argv(shell, use_guard, session_dir, sid, local_wd, py=sys.executable,
                                guard_py=str(PLUGIN_DIR / "term_guard.py"), env=env)
        spec["argv"] = argv
        spec["guard"] = use_guard
        if confine == "guard":
            spec["confine_applied"] = "guard"
        return spec

    @staticmethod
    def _pick_shell(caps: dict) -> str:
        shells = caps.get("shells") or []
        if _IS_WINDOWS:
            for s in ("pwsh", "powershell"):
                if s in shells:
                    return s
            return "powershell"
        preferred = os.path.basename(os.environ.get("SHELL") or "")
        if preferred in ("bash", "zsh") and preferred in shells:
            return preferred
        for s in ("bash", "zsh", "sh"):
            if s in shells:
                return s
        return "sh"

    @staticmethod
    def _pick_sandbox(caps: dict) -> Optional[str]:
        avail = caps.get("sandbox") or []
        for b in ("bwrap", "docker", "wsl"):
            if b in avail:
                return b
        return None

    def _shell_argv(self, shell: str, use_guard: bool, session_dir: str, sid: str, local_wd: Optional[str],
                    *, py: str, guard_py: str, env: Dict[str, str]) -> List[str]:
        exe = _which(shell) or shell
        if use_guard:
            hooks = term_guard.write_hooks(session_dir, shell, session_id=sid, workdir=local_wd, py=py, guard_py=guard_py)
            env.update(hooks["env"])  # type: ignore[arg-type]
            return [exe, *hooks["argv_tail"]]  # type: ignore[misc]
        if shell in ("pwsh", "powershell"):
            plain = term_guard.write_plain_pwsh(session_dir, session_id=sid)
            return [exe, *plain["argv_tail"]]  # type: ignore[misc]
        if shell in ("bash", "zsh"):
            return [exe, "-il"]
        return [exe, "-i"]

    # ── 격리 ──

    @staticmethod
    def _bwrap_args(wd: str, home: str, ro_extra: List[str], network: bool) -> List[str]:
        args = ["bwrap", "--ro-bind", "/usr", "/usr"]
        for p in ("/bin", "/sbin", "/lib", "/lib32", "/lib64", "/etc", "/opt", "/var/lib", "/snap", "/nix"):
            args += ["--ro-bind-try", p, p]
        for p in ro_extra:
            args += ["--ro-bind-try", p, p]
        args += ["--bind", wd, wd, "--tmpfs", home, "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
                 "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--die-with-parent", "--chdir", wd]
        if not network:
            args.append("--unshare-net")
        return args

    def _bwrap_spec(self, sid: str, wd: str, home: str, env: Dict[str, str], session_dir: str, network: bool,
                    use_guard: bool) -> dict:
        shell = "bash" if _which("bash") else "sh"
        guard = use_guard and shell == "bash"
        # 상자 안에서도 훅·검사기·파이썬이 보여야 한다: 세션 폴더, 플러그인 폴더, 지금 파이썬의 prefix 를 읽기 전용으로.
        ro_extra = [session_dir, str(PLUGIN_DIR), sys.prefix, sys.base_prefix]
        inner = self._shell_argv(shell, guard, session_dir, sid, wd, py=sys.executable,
                                 guard_py=str(PLUGIN_DIR / "term_guard.py"), env=env)
        return {"argv": self._bwrap_args(wd, home, ro_extra, network) + inner, "shell": shell, "cwd": wd,
                "cwd_display": wd, "guard": guard}

    @staticmethod
    def _docker_image() -> str:
        img = os.getenv("SKYTOWER_TERMINAL_IMAGE") or os.getenv("TERMINAL_DOCKER_IMAGE")
        if img:
            return img
        try:
            from hermes_cli.config import load_config_readonly  # type: ignore

            cfg = load_config_readonly() or {}
            img = (cfg.get("terminal") or {}).get("docker_image")
            if isinstance(img, str) and img.strip():
                return img.strip()
        except Exception:
            pass
        return "python:3.12-slim"

    def _docker_spec(self, sid: str, wd: str, env: Dict[str, str], session_dir: str, network: bool) -> dict:
        wd_in = "/work" if _IS_WINDOWS else wd
        plugin_in = "/skytower-plugin"
        sess_in = "/skytower-session"
        # 훅은 상자 안 경로(python3 · /skytower-plugin)로 쓴다. 이미지에 python3 이 없으면 훅이 검사를 건너뛰고 감사만 남긴다.
        term_guard.write_hooks(session_dir, "bash", session_id=sid, workdir=wd_in, py="python3",
                               guard_py=f"{plugin_in}/term_guard.py")
        rc_in = f"{sess_in}/guard.bashrc"
        argv = ["docker", "run", "--rm", "-it",
                "-v", f"{wd}:{wd_in}", "-v", f"{str(PLUGIN_DIR)}:{plugin_in}:ro", "-v", f"{session_dir}:{sess_in}:ro",
                "-w", wd_in, "-e", "TERM=xterm-256color", "-e", "COLORTERM=truecolor", "-e", "LANG=C.UTF-8",
                "-e", f"SKYTOWER_TERM_SESSION={sid}"]
        if not network:
            argv += ["--network", "none"]
        argv += [self._docker_image(), "bash", "--rcfile", rc_in, "-i"]
        return {"argv": argv, "shell": "bash", "cwd": wd, "cwd_display": wd_in, "guard": True}

    def _wsl_spec(self, sid: str, wd: str, env: Dict[str, str], session_dir: str, network: bool) -> dict:
        """Windows: WSL 안의 bwrap. 경로는 wslpath 로 바꾼다. 상자 안 HOME 은 tmpfs."""
        def wslpath(p: str) -> str:
            code, out = _run_quiet(["wsl.exe", "-e", "wslpath", "-a", p])
            if code != 0 or not out:
                raise TerminalUnavailable("sandbox_unavailable", f"WSL 경로 변환 실패: {p}")
            return out
        wd_l = wslpath(wd)
        sess_l = wslpath(session_dir)
        plugin_l = wslpath(str(PLUGIN_DIR))
        term_guard.write_hooks(session_dir, "bash", session_id=sid, workdir=wd_l, py="python3",
                               guard_py=f"{plugin_l}/term_guard.py")
        q = term_guard._sh_quote
        bw = self._bwrap_args(wd_l, "$HOME", [sess_l, plugin_l], network)
        # "$HOME" 은 WSL 셸이 풀어야 하므로 그 토큰만 따옴표 없이 둔다
        parts = [tok if tok == "$HOME" else q(tok) for tok in bw]
        inner = " ".join(parts) + f" bash --rcfile {q(sess_l + '/guard.bashrc')} -i"
        argv = ["wsl.exe", "--cd", wd_l, "-e", "bash", "-lc", f"export TERM=xterm-256color COLORTERM=truecolor; exec {inner}"]
        return {"argv": argv, "shell": "bash", "cwd": wd, "cwd_display": wd_l, "guard": True}

    # ── 입출력 ──

    async def _read_loop(self, session: _Session) -> None:
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        carry = ""
        try:
            while True:
                try:
                    chunk = await asyncio.to_thread(session.read)
                except EOFError:
                    break
                except Exception as exc:
                    if session.alive():
                        logger.warning("terminal read error session=%s: %s", session.id, exc)
                    break
                if not chunk:
                    if not session.alive():
                        break
                    continue
                text = decoder.decode(chunk) if isinstance(chunk, (bytes, bytearray)) else str(chunk)
                text, carry, audits = strip_osc(carry + text)
                for item in audits:
                    await self._emit("term:audit", {"session_id": session.id, **item})
                if text:
                    await self._emit("term:output", {"session_id": session.id, "data": text})
        finally:
            if carry and not carry.startswith(term_guard.OSC_PREFIX):
                await self._emit("term:output", {"session_id": session.id, "data": carry})
            await asyncio.to_thread(session.terminate)
            code = await asyncio.to_thread(session.exit_code)
            session.cleanup()
            self._sessions.pop(session.id, None)
            if not session.closing:
                await self._emit("term:exit", {"session_id": session.id, "code": code})
            logger.info("terminal closed session=%s code=%s after %.0fs", session.id, code, time.time() - session.started)

    async def handle_input(self, data: dict) -> None:
        session = self._sessions.get(data.get("session_id"))
        text = data.get("data")
        if session is None or not isinstance(text, str) or not text:
            return
        try:
            await asyncio.to_thread(session.write, text)
        except Exception as exc:
            logger.warning("terminal write failed session=%s: %s", session.id, exc)

    async def handle_resize(self, data: dict) -> None:
        session = self._sessions.get(data.get("session_id"))
        if session is None:
            return
        cols = _clamp(data.get("cols"), 10, 500, 80)
        rows = _clamp(data.get("rows"), 3, 200, 24)
        try:
            await asyncio.to_thread(session.resize, cols, rows)
        except Exception as exc:
            logger.debug("terminal resize failed session=%s: %s", session.id, exc)

    async def handle_close(self, data: dict) -> None:
        session = self._sessions.get(data.get("session_id"))
        if session is None:
            return
        await self._close(session)

    async def _close(self, session: _Session) -> None:
        session.closing = True
        await asyncio.to_thread(session.terminate)
        if session.reader is not None:
            try:
                await asyncio.wait_for(session.reader, timeout=5)
            except Exception:
                pass
        session.cleanup()
        self._sessions.pop(session.id, None)

    async def close_all(self) -> None:
        for session in list(self._sessions.values()):
            await self._close(session)

    @property
    def session_count(self) -> int:
        return len(self._sessions)


__all__ = ["TerminalHandler", "TerminalUnavailable", "probe_capabilities", "scrub_env", "strip_osc", "MAX_SESSIONS"]
