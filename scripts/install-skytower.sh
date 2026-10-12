#!/bin/bash
# ============================================================================
# Skytower Channel Plugin Installer for Hermes Agent
# ============================================================================
# 공식 Hermes Agent에 Skytower 채널 플러그인을 설치합니다.
# 플러그인은 Hermes 의 사용자 플러그인 디렉토리($HERMES_HOME/plugins/)에 설치되며,
# 공식 Hermes 저장소 디렉토리는 건드리지 않습니다. 그래서 `hermes update` 와 충돌하지 않습니다.
#
# 1단계 — 공식 Hermes Agent 설치 (아직 설치 안 된 경우):
#   curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
#
# 2단계 — Skytower 채널 플러그인 설치:
#   curl -fsSL https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.sh | bash
#
# 토큰이 없으면 Skytower 서버에 새 에이전트를 등록할지 묻고, 등록하면 토큰을 저장하고
# 웹 앱에 입력할 페어링 코드를 보여 줍니다. 서버 URL 만 주면 됩니다:
#   curl -fsSL ... | bash -s -- --url "https://relay.example.com"
#
# 묻지 않고 등록 (CI 등 터미널이 없는 환경):
#   curl -fsSL ... | bash -s -- --url "https://relay.example.com" --register --agent-name "My Agent"
#
# 이미 토큰이 있으면:
#   curl -fsSL ... | bash -s -- --token "agentId:rawToken" --url "https://relay.example.com"
#
# 특정 버전(태그 또는 커밋 SHA)으로 고정:
#   curl -fsSL ... | bash -s -- --ref v1.1.0
#
# 내부적으로 `hermes plugins install CodescapeDevOps/hermes-skytower-plugin/skytower` 를 실행합니다.
# ============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
NC='\033[0m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'

PLUGIN_NAME="skytower-platform"
PLUGIN_REPO="CodescapeDevOps/hermes-skytower-plugin"
PLUGIN_GIT_URL="https://github.com/${PLUGIN_REPO}.git"
PLUGIN_IDENTIFIER="${PLUGIN_REPO}/skytower"   # hermes plugins install <owner/repo/subdir>

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SKYTOWER_TOKEN="${SKYTOWER_TOKEN:-}"
SKYTOWER_URL="${SKYTOWER_URL:-}"
PLUGIN_REF="${SKYTOWER_PLUGIN_REF:-}"
AGENT_NAME="${SKYTOWER_AGENT_NAME:-}"
# 토큰이 없을 때 자동 등록: yes / no / "" (터미널이 있으면 묻는다)
case "${SKYTOWER_REGISTER:-}" in 1|true|yes) AUTO_REGISTER=yes ;; 0|false|no) AUTO_REGISTER=no ;; *) AUTO_REGISTER="" ;; esac

while [[ $# -gt 0 ]]; do
    case $1 in
        --token)       SKYTOWER_TOKEN="$2"; shift 2 ;;
        --url)         SKYTOWER_URL="$2";   shift 2 ;;
        --ref)         PLUGIN_REF="$2";     shift 2 ;;
        --hermes-home) HERMES_HOME="$2";    shift 2 ;;
        --agent-name)  AGENT_NAME="$2";     shift 2 ;;
        --register)    AUTO_REGISTER=yes;   shift ;;
        --no-register) AUTO_REGISTER=no;    shift ;;
        -h|--help)
            echo "Skytower Plugin Installer for Hermes Agent"
            echo ""
            echo "Usage: install-skytower.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --token TOKEN       Skytower agent token (agentId:rawToken)"
            echo "  --url URL           Skytower Relay URL (https://relay.example.com)"
            echo "  --register          No token: register a new agent without asking"
            echo "  --no-register       No token: never register (ask for a token instead)"
            echo "  --agent-name NAME   Name for the newly registered agent (default: Hermes Agent (<hostname>))"
            echo "  --ref TAG_OR_SHA    Pin the plugin to a git tag or commit (default: latest main)"
            echo "  --hermes-home PATH  Hermes data directory (default: ~/.hermes)"
            echo ""
            echo "Without --token, an existing SKYTOWER_TOKEN in \$HERMES_HOME/.env is reused (no new agent)."
            echo ""
            echo "Environment variables: SKYTOWER_TOKEN, SKYTOWER_URL, SKYTOWER_REGISTER (1/0),"
            echo "                       SKYTOWER_AGENT_NAME, SKYTOWER_PLUGIN_REF, HERMES_HOME"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
DEFAULT_AGENT_NAME="Hermes Agent ($(hostname 2>/dev/null || uname -n))"
AGENT_REGISTERED=false
PAIR_CODE=""; PAIR_URL=""

log_info()    { echo -e "${CYAN}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

print_banner() {
    echo ""
    echo -e "${MAGENTA}${BOLD}"
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│          🗼 Skytower Channel Plugin Installer           │"
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│  공식 Hermes Agent에 Skytower 채널을 추가합니다         │"
    echo "└─────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
}

# ============================================================================
# Hermes 설치 위치 / 실행기 탐색
# ============================================================================

find_hermes_install() {
    local candidates=("$HERMES_HOME/hermes-agent" "$HOME/.local/lib/hermes-agent" "/usr/local/lib/hermes-agent")
    local hermes_bin; hermes_bin="$(command -v hermes 2>/dev/null || true)"
    if [ -n "$hermes_bin" ] && [ -L "$hermes_bin" ]; then
        local real_bin; real_bin="$(readlink -f "$hermes_bin")"
        local inferred; inferred="$(dirname "$(dirname "$(dirname "$real_bin")")")"
        [ -f "$inferred/pyproject.toml" ] && candidates=("$inferred" "${candidates[@]}")
    fi
    for dir in "${candidates[@]}"; do
        if [ -f "$dir/pyproject.toml" ] && [ -d "$dir/gateway" ]; then
            HERMES_INSTALL_DIR="$dir"
            log_success "Hermes 설치 위치: $HERMES_INSTALL_DIR"
            return 0
        fi
    done
    log_error "Hermes Agent 설치를 찾을 수 없습니다."
    echo ""
    echo "  먼저 공식 Hermes Agent를 설치해주세요:"
    echo "  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"
    echo ""
    exit 1
}

find_python() {
    if [ -x "$HERMES_INSTALL_DIR/venv/bin/python" ]; then HERMES_PYTHON="$HERMES_INSTALL_DIR/venv/bin/python"
    elif command -v python3 &>/dev/null; then HERMES_PYTHON="python3"
    else HERMES_PYTHON="python"; fi

    UV_CMD=""
    for loc in "$(command -v uv 2>/dev/null)" "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
        [ -n "$loc" ] && [ -x "$loc" ] && UV_CMD="$loc" && break
    done

    # hermes CLI (curl | bash 는 로그인 셸이 아니라 PATH 에 없을 수 있다)
    HERMES_CLI=""
    for loc in "$(command -v hermes 2>/dev/null)" "$HOME/.local/bin/hermes" "$HERMES_INSTALL_DIR/venv/bin/hermes"; do
        [ -n "$loc" ] && [ -x "$loc" ] && HERMES_CLI="$loc" && break
    done
    if [ -z "$HERMES_CLI" ]; then
        log_error "hermes 명령을 찾을 수 없습니다. 플러그인 설치에는 hermes CLI 가 필요합니다."
        exit 1
    fi
}

# Hermes 가 실제로 도는 파이썬. PM(패키지 관리자) 관리 설치는 설치 폴더 venv 가 없고
# $HERMES_HOME/installs/<key>/environments/<hash>/venv 에서 돈다.
find_runtime_python() {
    RUNTIME_PYTHON=""
    if [ -x "$HERMES_INSTALL_DIR/venv/bin/python" ]; then
        RUNTIME_PYTHON="$HERMES_INSTALL_DIR/venv/bin/python"; return 0
    fi
    local key facts env
    key="$("$HERMES_PYTHON" -c 'import hashlib, pathlib, sys; print(hashlib.sha256(str(pathlib.Path(sys.argv[1]).resolve()).encode()).hexdigest()[:16])' "$HERMES_INSTALL_DIR" 2>/dev/null || true)"
    for facts in ${key:+"$HERMES_HOME/installs/$key/facts.json"} "$HERMES_HOME"/installs/*/facts.json; do
        [ -f "$facts" ] || continue
        env="$(grep -o '"environment": *"[^"]*"' "$facts" | sed 's/.*"\([^"]*\)"$/\1/' | grep '/environments/' | head -1)"
        if [ -n "$env" ] && [ -x "$env/bin/python" ]; then RUNTIME_PYTHON="$env/bin/python"; return 0; fi
    done
    return 1
}

is_pm_managed() {
    [ ! -d "$HERMES_INSTALL_DIR/venv" ] && compgen -G "$HERMES_HOME/installs/*/facts.json" >/dev/null
}

# ============================================================================
# 플러그인 설치 (hermes plugins install)
# ============================================================================

# --ref 가 태그/브랜치면 커밋 SHA 로 바꾼다 (hermes plugins install --ref 는 40자 SHA 만 받는다).
resolve_ref() {
    [ -n "$PLUGIN_REF" ] || return 0
    if [[ "$PLUGIN_REF" =~ ^[0-9a-fA-F]{40}$ ]]; then return 0; fi
    local sha
    sha="$(git ls-remote "$PLUGIN_GIT_URL" "refs/tags/${PLUGIN_REF}^{}" "refs/tags/$PLUGIN_REF" "refs/heads/$PLUGIN_REF" 2>/dev/null | head -1 | cut -f1)"
    if [ -z "$sha" ]; then
        log_error "--ref '$PLUGIN_REF' 를 $PLUGIN_GIT_URL 에서 찾지 못했습니다 (태그/브랜치/커밋 SHA)"
        exit 1
    fi
    log_info "ref '$PLUGIN_REF' → $sha"
    PLUGIN_REF="$sha"
}

install_plugin() {
    local target_dir="$HERMES_HOME/plugins/$PLUGIN_NAME"
    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    local local_plugin_dir="$script_dir/../skytower"

    # 로컬 개발 모드: 이 스크립트가 플러그인 저장소 안에 있으면 그 작업 트리를 그대로 복사한다.
    if [ -f "$local_plugin_dir/plugin.yaml" ]; then
        log_info "로컬 소스에서 플러그인 복사 중 → $target_dir"
        mkdir -p "$target_dir"
        cp -r "$local_plugin_dir/." "$target_dir/"
        log_success "플러그인 복사 완료"
        return 0
    fi

    resolve_ref
    local ref_args=()
    [ -n "$PLUGIN_REF" ] && ref_args=(--ref "$PLUGIN_REF")

    if [ -d "$target_dir" ] && [ -z "$PLUGIN_REF" ]; then
        log_info "이미 설치됨 — 최신으로 갱신 중 (hermes plugins update $PLUGIN_NAME)..."
        if HERMES_HOME="$HERMES_HOME" "$HERMES_CLI" plugins update "$PLUGIN_NAME" </dev/null; then
            log_success "플러그인 갱신 완료"; return 0
        fi
        log_warn "update 실패 — 다시 설치합니다"
    fi

    local force_args=()
    [ -d "$target_dir" ] && force_args=(--force)
    log_info "플러그인 설치 중 (hermes plugins install $PLUGIN_IDENTIFIER ${ref_args[*]} ${force_args[*]})..."
    if HERMES_HOME="$HERMES_HOME" "$HERMES_CLI" plugins install "$PLUGIN_IDENTIFIER" --no-enable "${ref_args[@]}" "${force_args[@]}" </dev/null; then
        log_success "플러그인 설치 완료: $target_dir"
    else
        log_error "플러그인 설치 실패. 직접 실행해 보세요:"
        echo "  hermes plugins install $PLUGIN_IDENTIFIER ${ref_args[*]} ${force_args[*]}"
        exit 1
    fi
}

# ============================================================================
# 의존성 설치 / 활성화 / .env
# ============================================================================

install_deps() {
    # PM 관리 환경에 손으로 깔면 다음 hermes update 때 사라진다.
    # 거기서는 plugin.yaml 의 python_dependencies 를 활성화 시 Hermes 가 설치한다.
    if is_pm_managed; then
        log_info "PM 관리 환경 — 의존성은 플러그인 활성화 때 Hermes 가 설치합니다"
        return 0
    fi
    log_info "Skytower 의존성 설치 중 (python-socketio)..."
    local pkgs=("python-socketio[asyncio_client]>=5.11,<6")
    if [ -n "$UV_CMD" ] && [ -d "$HERMES_INSTALL_DIR/venv" ]; then
        VIRTUAL_ENV="$HERMES_INSTALL_DIR/venv" "$UV_CMD" pip install "${pkgs[@]}" -q
    elif [ -x "$HERMES_INSTALL_DIR/venv/bin/pip" ]; then
        "$HERMES_INSTALL_DIR/venv/bin/pip" install "${pkgs[@]}" -q
    elif [ -x "$HERMES_INSTALL_DIR/venv/bin/python" ]; then
        "$HERMES_INSTALL_DIR/venv/bin/python" -m pip install "${pkgs[@]}" -q
    else
        $HERMES_PYTHON -m pip install "${pkgs[@]}" -q
    fi
    log_success "의존성 설치 완료"
}

# 사용자 플러그인은 plugins.enabled 에 있어야 로드된다. PM 은 이 목록의 python_dependencies 를 환경에 넣는다.
enable_plugin() {
    log_info "플러그인 활성화 중 (hermes plugins enable $PLUGIN_NAME)..."
    if HERMES_HOME="$HERMES_HOME" "$HERMES_CLI" plugins enable "$PLUGIN_NAME" </dev/null; then
        log_success "플러그인 활성화 완료"
    else
        log_warn "플러그인 활성화 실패 — 직접 실행하세요: hermes plugins enable $PLUGIN_NAME"
    fi
}

# ============================================================================
# 토큰 — 기존 값 재사용 / 자동 등록 / 직접 입력
# ============================================================================

# curl | bash 는 stdin 이 스크립트라 /dev/tty 로 묻는다. CI 처럼 제어 터미널이 없으면
# /dev/tty 가 있어도 열리지 않으므로 실제로 열어 본다.
has_tty() { (exec < /dev/tty) 2>/dev/null; }

# 앞뒤 공백을 뗀 한 줄을 REPLY_VALUE 에
tty_read() {
    printf "%b" "$1" > /dev/tty
    IFS= read -r REPLY_VALUE < /dev/tty || REPLY_VALUE=""
    REPLY_VALUE="${REPLY_VALUE#"${REPLY_VALUE%%[![:space:]]*}"}"
    REPLY_VALUE="${REPLY_VALUE%"${REPLY_VALUE##*[![:space:]]}"}"
}

env_get() { grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true; }

json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# 응답 JSON 에서 "key": "value" 하나를 꺼낸다 (값에 따옴표가 없는 문자열 필드만 — 토큰·코드·URL)
json_field() { printf '%s' "$1" | grep -o "\"$2\" *: *\"[^\"]*\"" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'; }

# POST /api/agents/register — 인증 없이 이름만으로 에이전트를 만들고 agentId:rawToken 을 돌려준다.
register_agent() {
    local name="$1" resp token
    if ! command -v curl &>/dev/null; then log_error "curl 이 없어 에이전트를 등록할 수 없습니다"; return 1; fi
    log_info "Skytower 서버에 에이전트 등록 중: $name"
    # 본문은 stdin 으로 — 인자로 넘기면 환경에 따라 비ASCII 이름이 다른 인코딩으로 바뀐다
    if ! resp="$(printf '{"name":"%s"}' "$(json_escape "$name")" | curl -fsS -X POST "$SKYTOWER_URL/api/agents/register" \
            -H "Content-Type: application/json; charset=utf-8" --data-binary @- 2>&1)"; then
        log_error "에이전트 등록 실패 ($SKYTOWER_URL): $resp"
        return 1
    fi
    token="$(json_field "$resp" token)"
    if [[ ! "$token" =~ ^[^:]+:.+$ ]]; then
        log_error "등록 응답을 해석하지 못했습니다: $resp"
        return 1
    fi
    SKYTOWER_TOKEN="$token"
    AGENT_REGISTERED=true
    log_success "에이전트 등록 완료: ${token%%:*}"
}

# 새 에이전트는 아직 누구의 계정에도 연결돼 있지 않다 — 웹 앱에 입력할 페어링 코드를 받아 둔다.
# 게이트웨이가 꺼져 있어도 발급된다. 서버는 본문이 없으면 500 이라 {} 를 보낸다.
fetch_pair_code() {
    local resp
    resp="$(curl -fsS -X POST "$SKYTOWER_URL/api/agents/pairing-code" \
        -H "Authorization: Bearer $SKYTOWER_TOKEN" -H "Content-Type: application/json" -d '{}' 2>/dev/null)" || return 1
    PAIR_CODE="$(json_field "$resp" code)"
    PAIR_URL="$(json_field "$resp" pairUrl)"
    [ -n "$PAIR_CODE" ]
}

# 토큰이 없을 때: 자동 등록(묻거나 --register) → 실패하거나 거절하면 직접 입력
obtain_token() {
    local tty="$1" want="$AUTO_REGISTER"
    if [ -z "$want" ]; then
        if [ "$tty" = true ]; then
            printf "\n${CYAN}  Skytower 에이전트 토큰이 없습니다. 서버에 새 에이전트를 등록할 수 있습니다.${NC}\n" > /dev/tty
            tty_read "${CYAN}→${NC} 자동 등록할까요? (Y/n): "
            if [[ "$REPLY_VALUE" =~ ^[Nn] ]]; then want=no; else want=yes; fi
        else
            want=no
        fi
    fi

    if [ "$want" = yes ]; then
        if [ -z "$SKYTOWER_URL" ]; then
            log_error "서버 URL 이 없어 에이전트를 등록할 수 없습니다 (--url)"
        else
            local name="$AGENT_NAME"
            if [ -z "$name" ] && [ "$tty" = true ]; then
                tty_read "${CYAN}→${NC} 에이전트 이름 (기본값: $DEFAULT_AGENT_NAME): "
                name="$REPLY_VALUE"
            fi
            register_agent "${name:-$DEFAULT_AGENT_NAME}" && return 0
        fi
    fi

    if [ "$tty" = true ]; then
        tty_read "${CYAN}→${NC} Skytower 에이전트 토큰 입력 (agentId:rawToken, 없으면 Enter): "
        SKYTOWER_TOKEN="$REPLY_VALUE"
    fi
}

configure_env() {
    ENV_FILE="$HERMES_HOME/.env"
    [ -f "$ENV_FILE" ] || touch "$ENV_FILE"
    local tty=false
    has_tty && tty=true

    # 이미 저장된 값을 먼저 쓴다 — 다시 실행해도 에이전트를 새로 등록하지 않는다.
    [ -n "$SKYTOWER_URL" ] || SKYTOWER_URL="$(env_get SKYTOWER_URL)"
    if [ -z "$SKYTOWER_URL" ] && [ "$tty" = true ]; then
        tty_read "\n${CYAN}→${NC} Skytower 서버 URL 입력 (예: https://relay.example.com, 없으면 Enter): "
        SKYTOWER_URL="$REPLY_VALUE"
    fi
    SKYTOWER_URL="${SKYTOWER_URL%/}"

    if [ -z "$SKYTOWER_TOKEN" ]; then
        SKYTOWER_TOKEN="$(env_get SKYTOWER_TOKEN)"
        if [ -n "$SKYTOWER_TOKEN" ]; then
            log_info "기존 토큰 사용 (agentId=${SKYTOWER_TOKEN%%:*}) — $ENV_FILE"
        else
            obtain_token "$tty"
        fi
    fi

    local changed=false
    _upsert_env() {
        local key="$1" val="$2"
        if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
        else
            printf "\n# Skytower Relay\n%s=%s\n" "$key" "$val" >> "$ENV_FILE"
        fi
    }
    if [ -n "$SKYTOWER_TOKEN" ]; then _upsert_env "SKYTOWER_TOKEN" "$SKYTOWER_TOKEN"; changed=true; fi
    if [ -n "$SKYTOWER_URL" ];   then _upsert_env "SKYTOWER_URL" "$SKYTOWER_URL";     changed=true; fi

    grep -q "^SKYTOWER_ALLOW_ALL_USERS=" "$ENV_FILE" 2>/dev/null || printf "SKYTOWER_ALLOW_ALL_USERS=true\n" >> "$ENV_FILE"
    grep -q "^SKYTOWER_PRINT_PAIR_CODE=" "$ENV_FILE" 2>/dev/null || printf "SKYTOWER_PRINT_PAIR_CODE=0\n" >> "$ENV_FILE"

    if [ "$changed" = true ]; then
        log_success "Skytower 설정 저장됨: $ENV_FILE"
    else
        log_warn "토큰/URL을 나중에 $ENV_FILE 에 직접 추가하세요:"
        log_warn "  SKYTOWER_TOKEN=agentId:rawToken"
        log_warn "  SKYTOWER_URL=https://relay.example.com"
    fi

    if [ "$AGENT_REGISTERED" = true ] && ! fetch_pair_code; then
        log_warn "페어링 코드를 받지 못했습니다 — 게이트웨이를 켠 뒤 대화에서 /paircode 를 쓰거나"
        log_warn "  $ENV_FILE 에 SKYTOWER_PRINT_PAIR_CODE=1 을 넣고 게이트웨이를 재시작하세요"
    fi
}

# ============================================================================
# 동작 확인 — Hermes 가 실제로 도는 파이썬에서 플러그인을 로더와 같은 방식으로 import 한다
# ============================================================================

_runtime_check() {
    "$RUNTIME_PYTHON" - "$HERMES_INSTALL_DIR" "$HERMES_HOME/plugins/$PLUGIN_NAME" 2>/dev/null <<'PY' | grep -q "^OK"
import importlib.util, sys, types
install_dir, plugin_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, install_dir)
import socketio  # noqa: F401  (adapter imports it lazily, so check it explicitly)
ns = types.ModuleType("hermes_plugins"); ns.__path__ = []; sys.modules["hermes_plugins"] = ns
name = "hermes_plugins.skytower_platform"
spec = importlib.util.spec_from_file_location(name, plugin_dir + "/__init__.py", submodule_search_locations=[plugin_dir])
mod = importlib.util.module_from_spec(spec); mod.__package__ = name; sys.modules[name] = mod
spec.loader.exec_module(mod)
assert callable(mod.register)
print("OK")
PY
}

verify_plugin() {
    log_info "플러그인 로드 확인 중..."
    if ! find_runtime_python; then
        log_warn "Hermes 실행 환경을 찾지 못해 확인을 건너뜁니다"; return 0
    fi
    if _runtime_check; then
        log_success "플러그인 로드 확인 완료 ($RUNTIME_PYTHON)"; return 0
    fi
    if is_pm_managed; then
        log_info "python-socketio 가 없습니다 — Hermes 환경 동기화 중 (hermes pm install)..."
        if HERMES_HOME="$HERMES_HOME" "$HERMES_CLI" pm install </dev/null && find_runtime_python && _runtime_check; then
            log_success "플러그인 로드 확인 완료 ($RUNTIME_PYTHON)"; return 0
        fi
    fi
    log_warn "플러그인 로드 확인 실패 — python-socketio 가 Hermes 환경($RUNTIME_PYTHON)에 없거나 플러그인 import 가 실패했습니다"
    log_warn "  hermes plugins doctor 로 상태를 확인하세요"
}

print_success() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│         ✓ Skytower 채널 플러그인 설치 완료!            │"
    echo "└─────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
    echo -e "${CYAN}${BOLD}설치된 위치:${NC}"
    echo "  플러그인:  $HERMES_HOME/plugins/$PLUGIN_NAME/"
    echo "  설정:      $HERMES_HOME/.env"
    echo ""
    echo -e "${CYAN}${BOLD}시작 방법:${NC}"
    echo -e "  ${GREEN}hermes gateway${NC}              게이트웨이 시작"
    echo -e "  ${GREEN}hermes gateway install${NC}      systemd 서비스로 등록"
    echo ""
    echo -e "${CYAN}${BOLD}업데이트:${NC}"
    echo -e "  ${GREEN}hermes plugins update $PLUGIN_NAME${NC}"
    echo ""
    echo -e "${CYAN}${BOLD}Skytower 채팅 명령어:${NC}"
    echo -e "  ${GREEN}/chatid${NC}    현재 대화 JID 확인     ${GREEN}/sethome${NC}  현재 대화를 홈 채널로"
    echo -e "  ${GREEN}/skills${NC}    사용 가능한 스킬 목록   ${GREEN}/paircode${NC} 친구 추가 코드 발급"
    echo ""
    if [ "$AGENT_REGISTERED" = true ]; then
        echo -e "${YELLOW}${BOLD}새 에이전트 토큰 (다시 볼 수 없습니다 — 안전한 곳에 보관하세요):${NC}"
        echo -e "  ${GREEN}${BOLD}$SKYTOWER_TOKEN${NC}"
        echo "  저장 위치: $HERMES_HOME/.env"
        echo ""
        if [ -n "$PAIR_CODE" ]; then
            echo -e "${CYAN}${BOLD}Skytower 웹 앱과 연결:${NC}"
            echo -e "  페어링 코드: ${GREEN}${BOLD}$PAIR_CODE${NC}   (10분 유효, 1회)"
            [ -n "$PAIR_URL" ] && echo "  바로 열기:   $PAIR_URL"
            echo "  웹 앱 좌측 상단 에이전트 추가 버튼에 코드를 입력하세요."
            echo ""
        fi
    fi
    local token_val; token_val=$(grep "^SKYTOWER_TOKEN=" "$HERMES_HOME/.env" 2>/dev/null | cut -d'=' -f2-)
    if [ -z "$token_val" ]; then
        echo -e "${YELLOW}⚠  SKYTOWER_TOKEN이 아직 설정되지 않았습니다.${NC}"
        echo "   $HERMES_HOME/.env 에 추가 후 게이트웨이를 재시작하세요."
        echo ""
    fi
}

main() {
    print_banner
    find_hermes_install
    find_python
    install_plugin
    install_deps
    enable_plugin
    configure_env
    verify_plugin
    print_success
}

main
