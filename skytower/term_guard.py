"""웹 터미널의 L1 안내선 (skytower, docs/plans/2026-10-ssh-terminal.md "작업 폴더 제한").

두 가지 일을 한다.

1. **셸 훅 파일 생성** (``write_hooks``): 셸이 실행 직전의 *완성된* 명령줄을 넘겨주는 훅을 세션 폴더에 쓴다.
   키 입력을 플러그인이 조립하지 않는다 — 히스토리(``↑``)·탭 완성이 끝난 줄을 셸이 직접 준다.

   - bash: ``shopt -s extdebug`` + ``trap … DEBUG``. 훅이 0 이 아닌 값을 돌려주면 그 명령은 건너뛴다.
   - zsh: ``accept-line`` 위젯을 덮어 ``$BUFFER`` 를 검사하고 통과할 때만 원래 위젯을 부른다.
   - PowerShell: PSReadLine 의 Enter 핸들러가 ``GetBufferState`` 의 줄을 검사하고 통과하면 ``AcceptLine``.

   훅은 통과한 명령도 OSC 시퀀스(``ESC ] 777 ; skytower ; cmd=<b64> … BEL``)로 출력에 섞어 보낸다.
   플러그인(``skytower_terminal``)이 걷어 내어 ``term:audit`` 로 relay 에 보내고, 화면에는 보이지 않는다.
   폴더 밖으로 나갔으면 다음 프롬프트에서 작업 폴더로 되돌린다.

2. **검사기 CLI** (``python term_guard.py --workdir … --cwd … -- <cmd>``): 훅이 명령마다 부른다. ``confinement``
   의 경로 토큰 검사를 그대로 써서 작업 폴더 밖 경로가 있으면 사유를 찍고 1 로 끝낸다. 표준 라이브러리만 쓰므로
   격리 상자(bwrap·docker) 안의 아무 python3 으로도 돈다.

못 막는 것(정직하게): ``bash --norc``, ``trap - DEBUG``, ``python -c``, 동적 경로, 심볼릭 링크. 전부 감사 로그에는
남는다. "막는다" 가 아니라 "실수를 막고 흔적을 남긴다" 가 L1 의 약속이다. 실제 강제는 L2(격리) 뿐이다.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Dict, Optional

# OSC 777 — 사설 번호. 훅이 쓰고 플러그인이 읽는다. 끝은 BEL.
OSC_PREFIX = "\x1b]777;skytower;"
OSC_END = "\x07"

GUARD_SHELLS = ("bash", "zsh", "pwsh", "powershell")


# ── 셸 훅 템플릿 ─────────────────────────────────────────────────────────────

def _sh_quote(s: str) -> str:
    return "'" + str(s).replace("'", "'\\''") + "'"


_BASH_RC = r"""# skytower web terminal guard (L1) — session {sid}
# 사용자의 평소 설정을 먼저 읽는다 (프롬프트·alias 유지). 그 다음 안내선을 얹는다.
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
export SKYTOWER_WORKDIR={wd}
SKYTOWER_PY={py}
SKYTOWER_GUARD_PY={guard}
__skytower_b64() {{ printf '%s' "$1" | base64 | tr -d '\n'; }}
__skytower_audit() {{
  printf '\033]777;skytower;cmd=%s;cwd=%s%s\007' "$(__skytower_b64 "$1")" "$(__skytower_b64 "$PWD")" "$2"
}}
__skytower_guard() {{
  local cmd="$BASH_COMMAND"
  # 자기 자신, 함수 안의 명령(프롬프트 함수 등), PROMPT_COMMAND 의 조각은 보지 않는다 — 사람이 친 줄만.
  case "$cmd" in __skytower_*) return 0;; esac
  [ ${{#FUNCNAME[@]}} -gt 1 ] && return 0
  case "$PROMPT_COMMAND" in *"$cmd"*) return 0;; esac
  if [ -n "$SKYTOWER_WORKDIR" ] && command -v "$SKYTOWER_PY" >/dev/null 2>&1; then
    case "$cmd" in */*|*~*|*\\*)
      local verdict
      verdict="$("$SKYTOWER_PY" "$SKYTOWER_GUARD_PY" --workdir "$SKYTOWER_WORKDIR" --cwd "$PWD" -- "$cmd" 2>&1)" || {{
        printf '\n\033[33m%s\033[0m\n' "$verdict" >&2
        __skytower_audit "$cmd" ";blocked=1;reason=$(__skytower_b64 "$verdict")"
        return 1
      }};;
    esac
  fi
  __skytower_audit "$cmd" ""
  return 0
}}
__skytower_cd_check() {{
  [ -z "$SKYTOWER_WORKDIR" ] && return 0
  local cur base
  cur=$(printf '%s' "$PWD" | tr '[:upper:]' '[:lower:]')
  base=$(printf '%s' "$SKYTOWER_WORKDIR" | tr '[:upper:]' '[:lower:]')
  case "$cur" in "$base"|"$base"/*) ;;
    *) cd "$SKYTOWER_WORKDIR" && printf '\033[33m[skytower] 작업 폴더 밖이라 %s 로 되돌렸습니다\033[0m\n' "$SKYTOWER_WORKDIR";;
  esac
}}
shopt -s extdebug
PROMPT_COMMAND="__skytower_cd_check${{PROMPT_COMMAND:+;$PROMPT_COMMAND}}"
trap '__skytower_guard' DEBUG
"""

_ZSH_RC = r"""# skytower web terminal guard (L1) — session {sid}
export ZDOTDIR="$HOME"
[ -f "$HOME/.zshrc" ] && . "$HOME/.zshrc"
export SKYTOWER_WORKDIR={wd}
SKYTOWER_PY={py}
SKYTOWER_GUARD_PY={guard}
__skytower_b64() {{ printf '%s' "$1" | base64 | tr -d '\n'; }}
__skytower_audit() {{
  printf '\033]777;skytower;cmd=%s;cwd=%s%s\007' "$(__skytower_b64 "$1")" "$(__skytower_b64 "$PWD")" "$2"
}}
__skytower_accept_line() {{
  local cmd="$BUFFER"
  if [[ -n "$SKYTOWER_WORKDIR" && "$cmd" == *[/~\\]* ]] && command -v "$SKYTOWER_PY" >/dev/null 2>&1; then
    local verdict
    verdict="$("$SKYTOWER_PY" "$SKYTOWER_GUARD_PY" --workdir "$SKYTOWER_WORKDIR" --cwd "$PWD" -- "$cmd" 2>&1)" || {{
      zle -M "$verdict"
      __skytower_audit "$cmd" ";blocked=1;reason=$(__skytower_b64 "$verdict")"
      return 1
    }}
  fi
  [[ -n "$cmd" ]] && __skytower_audit "$cmd" ""
  zle .accept-line
}}
zle -N accept-line __skytower_accept_line
__skytower_cd_check() {{
  [[ -z "$SKYTOWER_WORKDIR" ]] && return 0
  local cur="${{PWD:l}}" base="${{SKYTOWER_WORKDIR:l}}"
  case "$cur" in "$base"|"$base"/*) ;;
    *) cd "$SKYTOWER_WORKDIR" && printf '\033[33m[skytower] 작업 폴더 밖이라 %s 로 되돌렸습니다\033[0m\n' "$SKYTOWER_WORKDIR";;
  esac
}}
precmd_functions+=(__skytower_cd_check)
"""

_PWSH_GUARD = r"""# skytower web terminal guard (L1) — session {sid}
$global:SkytowerWorkdir = {wd}
$global:SkytowerPy = {py}
$global:SkytowerGuardPy = {guard}
# Windows 의 기본 코드페이지는 UTF-8 이 아니다. xterm 은 UTF-8 만 안다.
try {{
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
  [Console]::InputEncoding = [Console]::OutputEncoding
  $global:OutputEncoding = [Console]::OutputEncoding
}} catch {{}}
if (Test-Path $PROFILE) {{ try {{ . $PROFILE }} catch {{ Write-Host "[skytower] profile error: $_" -ForegroundColor Yellow }} }}
function global:__SkytowerB64([string]$s) {{ [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }}
function global:__SkytowerAudit([string]$cmd, [string]$extra) {{
  $esc = [char]27; $bel = [char]7
  [Console]::Write("$esc]777;skytower;cmd=$(__SkytowerB64 $cmd);cwd=$(__SkytowerB64 $PWD.Path)$extra$bel")
}}
function global:__SkytowerInside([string]$p) {{
  if (-not $global:SkytowerWorkdir) {{ return $true }}
  $cur = ($p -replace '/', '\').TrimEnd('\') + '\'
  $base = ($global:SkytowerWorkdir -replace '/', '\').TrimEnd('\') + '\'
  return $cur.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)
}}
if (Get-Module -ListAvailable PSReadLine) {{
  Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {{
    $line = $null; $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($global:SkytowerWorkdir -and $line -match '[/\\~]' -and (Get-Command $global:SkytowerPy -ErrorAction SilentlyContinue)) {{
      $verdict = (& $global:SkytowerPy $global:SkytowerGuardPy --workdir $global:SkytowerWorkdir --cwd $PWD.Path -- $line 2>&1 | Out-String).Trim()
      if ($LASTEXITCODE -ne 0) {{
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
        Write-Host "`n$verdict" -ForegroundColor Yellow
        __SkytowerAudit $line ";blocked=1;reason=$(__SkytowerB64 $verdict)"
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
        return
      }}
    }}
    if ($line.Trim()) {{ __SkytowerAudit $line '' }}
    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
  }}
}} else {{
  Write-Host "[skytower] PSReadLine 이 없어 명령 검사 없이 엽니다 (감사 로그 없음)" -ForegroundColor Yellow
}}
$global:__SkytowerPrevPrompt = (Get-Command prompt -ErrorAction SilentlyContinue).ScriptBlock
function global:prompt {{
  if (-not (__SkytowerInside $PWD.Path)) {{
    Set-Location $global:SkytowerWorkdir
    Write-Host "[skytower] 작업 폴더 밖이라 $global:SkytowerWorkdir 로 되돌렸습니다" -ForegroundColor Yellow
  }}
  if ($global:__SkytowerPrevPrompt) {{ & $global:__SkytowerPrevPrompt }} else {{ "PS $($PWD.Path)> " }}
}}
"""

_PWSH_PLAIN = r"""# skytower web terminal (L0) — session {sid}
try {{
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
  [Console]::InputEncoding = [Console]::OutputEncoding
  $global:OutputEncoding = [Console]::OutputEncoding
}} catch {{}}
if (Test-Path $PROFILE) {{ try {{ . $PROFILE }} catch {{ Write-Host "[skytower] profile error: $_" -ForegroundColor Yellow }} }}
"""


def _ps_quote(s: str) -> str:
    return "'" + str(s).replace("'", "''") + "'"


def write_hooks(
    session_dir: str,
    shell: str,
    *,
    session_id: str,
    workdir: Optional[str],
    py: str,
    guard_py: str,
) -> Dict[str, object]:
    """셸 훅 파일을 ``session_dir`` 에 쓰고, 셸을 어떻게 띄울지 돌려준다.

    반환: ``{"argv_tail": [...], "env": {...}, "files": [...]}``.
      bash → ``--rcfile <rc> -i``, zsh → ``ZDOTDIR`` + ``-i``, pwsh/powershell → ``-File <guard.ps1>``.
    ``workdir`` 가 없으면 경로 검사는 꺼지고 감사(OSC)만 남는다. ``py``·``guard_py`` 는 셸 *안에서* 보이는
    경로(격리 상자·WSL 이면 그 안의 경로)여야 한다.
    """
    sd = Path(session_dir)
    sd.mkdir(parents=True, exist_ok=True)
    wd = workdir or ""
    if shell == "bash":
        rc = sd / "guard.bashrc"
        rc.write_text(_BASH_RC.format(sid=session_id, wd=_sh_quote(wd), py=_sh_quote(py), guard=_sh_quote(guard_py)),
                      encoding="utf-8", newline="\n")
        return {"argv_tail": ["--rcfile", str(rc), "-i"], "env": {}, "files": [str(rc)]}
    if shell == "zsh":
        rc = sd / ".zshrc"
        rc.write_text(_ZSH_RC.format(sid=session_id, wd=_sh_quote(wd), py=_sh_quote(py), guard=_sh_quote(guard_py)),
                      encoding="utf-8", newline="\n")
        return {"argv_tail": ["-i"], "env": {"ZDOTDIR": str(sd)}, "files": [str(rc)]}
    if shell in ("pwsh", "powershell"):
        ps1 = sd / "guard.ps1"
        ps1.write_text(_PWSH_GUARD.format(sid=session_id, wd=_ps_quote(wd), py=_ps_quote(py), guard=_ps_quote(guard_py)),
                       encoding="utf-8-sig", newline="\r\n")
        return {"argv_tail": ["-NoLogo", "-NoExit", "-ExecutionPolicy", "Bypass", "-File", str(ps1)], "env": {}, "files": [str(ps1)]}
    raise ValueError(f"guard hooks not supported for shell {shell!r}")


def write_plain_pwsh(session_dir: str, *, session_id: str) -> Dict[str, object]:
    """L0 PowerShell: 인코딩만 맞추고 프로필을 읽는다. 검사·감사 없음."""
    sd = Path(session_dir)
    sd.mkdir(parents=True, exist_ok=True)
    ps1 = sd / "plain.ps1"
    ps1.write_text(_PWSH_PLAIN.format(sid=session_id), encoding="utf-8-sig", newline="\r\n")
    return {"argv_tail": ["-NoLogo", "-NoExit", "-ExecutionPolicy", "Bypass", "-File", str(ps1)], "env": {}, "files": [str(ps1)]}


# ── 검사기 (CLI) ─────────────────────────────────────────────────────────────

def check_command(cmd: str, *, workdir: str, cwd: str) -> Optional[str]:
    """작업 폴더 밖 경로가 있으면 거부 사유, 없으면 None. ``confinement`` 와 같은 규칙."""
    if not workdir:
        return None
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import confinement  # noqa: E402  (플러그인 폴더의 모듈. 격리 상자 안에서도 같은 폴더가 바인드된다)

    bad = confinement._offending_tokens(cmd, cwd, workdir)
    if not bad:
        return None
    return confinement._deny(workdir, "명령의 경로 " + ", ".join(bad[:3]))["message"]


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(prog="term_guard", add_help=False)
    parser.add_argument("--workdir", default="")
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("cmd", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    parts = list(args.cmd)
    if parts and parts[0] == "--":
        parts = parts[1:]
    cmd = " ".join(parts)
    reason = check_command(cmd, workdir=args.workdir, cwd=args.cwd)
    if reason:
        print(reason)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
