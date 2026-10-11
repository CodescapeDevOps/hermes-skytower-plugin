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
# 토큰/URL을 미리 지정:
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

while [[ $# -gt 0 ]]; do
    case $1 in
        --token)       SKYTOWER_TOKEN="$2"; shift 2 ;;
        --url)         SKYTOWER_URL="$2";   shift 2 ;;
        --ref)         PLUGIN_REF="$2";     shift 2 ;;
        --hermes-home) HERMES_HOME="$2";    shift 2 ;;
        -h|--help)
            echo "Skytower Plugin Installer for Hermes Agent"
            echo ""
            echo "Usage: install-skytower.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --token TOKEN       Skytower agent token (agentId:rawToken)"
            echo "  --url URL           Skytower Relay URL (https://relay.example.com)"
            echo "  --ref TAG_OR_SHA    Pin the plugin to a git tag or commit (default: latest main)"
            echo "  --hermes-home PATH  Hermes data directory (default: ~/.hermes)"
            echo ""
            echo "Environment variables: SKYTOWER_TOKEN, SKYTOWER_URL, SKYTOWER_PLUGIN_REF, HERMES_HOME"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

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

configure_env() {
    local env_file="$HERMES_HOME/.env"
    [ -f "$env_file" ] || touch "$env_file"

    if [ -e /dev/tty ]; then
        if [ -z "$SKYTOWER_TOKEN" ]; then
            printf "\n${CYAN}→${NC} Skytower 에이전트 토큰 입력 (agentId:rawToken, 없으면 Enter): " > /dev/tty
            IFS= read -r SKYTOWER_TOKEN < /dev/tty || SKYTOWER_TOKEN=""
            SKYTOWER_TOKEN="${SKYTOWER_TOKEN#"${SKYTOWER_TOKEN%%[![:space:]]*}"}"
        fi
        if [ -z "$SKYTOWER_URL" ]; then
            printf "${CYAN}→${NC} Skytower Relay URL 입력 (예: https://relay.example.com, 없으면 Enter): " > /dev/tty
            IFS= read -r SKYTOWER_URL < /dev/tty || SKYTOWER_URL=""
            SKYTOWER_URL="${SKYTOWER_URL#"${SKYTOWER_URL%%[![:space:]]*}"}"
        fi
    fi

    local changed=false
    _upsert_env() {
        local key="$1" val="$2"
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$env_file"
        else
            printf "\n# Skytower Relay\n%s=%s\n" "$key" "$val" >> "$env_file"
        fi
    }
    if [ -n "$SKYTOWER_TOKEN" ]; then _upsert_env "SKYTOWER_TOKEN" "$SKYTOWER_TOKEN"; changed=true; fi
    if [ -n "$SKYTOWER_URL" ];   then _upsert_env "SKYTOWER_URL" "$SKYTOWER_URL";     changed=true; fi

    grep -q "^SKYTOWER_ALLOW_ALL_USERS=" "$env_file" 2>/dev/null || printf "SKYTOWER_ALLOW_ALL_USERS=true\n" >> "$env_file"
    grep -q "^SKYTOWER_PRINT_PAIR_CODE=" "$env_file" 2>/dev/null || printf "SKYTOWER_PRINT_PAIR_CODE=0\n" >> "$env_file"

    if [ "$changed" = true ]; then
        log_success "Skytower 설정 저장됨: $env_file"
    else
        log_warn "토큰/URL을 나중에 $env_file 에 직접 추가하세요:"
        log_warn "  SKYTOWER_TOKEN=agentId:rawToken"
        log_warn "  SKYTOWER_URL=https://relay.example.com"
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
