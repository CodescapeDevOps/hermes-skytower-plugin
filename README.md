# hermes-skytower-plugin

[Hermes Agent](https://github.com/NousResearch/hermes-agent)용 Skytower 채널 플러그인입니다.
Skytower Relay 서버에 Socket.IO로 접속해 Skytower 웹 클라이언트와 Hermes 에이전트 사이의 메시지를 중계합니다.

이 플러그인은 Hermes 코어를 수정하지 않는 순수 플러그인입니다. Hermes의 사용자 플러그인 디렉토리(`~/.hermes/plugins/`)에 설치되며 `hermes plugins install`, `hermes plugins update`로 관리합니다.

## 요구 사항

- 공식 Hermes Agent가 설치되어 있어야 합니다. 플러그인 레지스트리 API(`platform_hint`, `standalone_sender_fn`, `env_enablement_fn`)를 쓰므로 2026년 9월 이후 버전이 필요합니다.
- `git` (플러그인 설치에 Hermes가 git clone을 사용합니다)
- Python 패키지 `python-socketio[asyncio_client]` (설치 스크립트가 넣어 줍니다)

Hermes Agent가 없다면 먼저 설치하세요.

```bash
# Linux / macOS / WSL2
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

```powershell
# Windows
iex (irm https://hermes-agent.nousresearch.com/install.ps1)
```

설치가 끝나면 새 터미널을 열거나 `source ~/.bashrc`(zsh 는 `~/.zshrc`)로 셸을 다시 읽은 뒤 다음 단계로 넘어갑니다. Windows 는 새 PowerShell 창을 엽니다. 공식 설치 주소는 [Hermes README](https://github.com/NousResearch/hermes-agent#quick-install) 를 따릅니다. CMD 래퍼(`install.cmd`)는 공식 주소에 없어 `install-skytower.cmd` 안내는 GitHub 의 `scripts/install.cmd` 를 그대로 씁니다.

## 설치

### 스크립트로 설치 (권장)

Skytower 서버 URL만 주면 됩니다. 토큰이 없으면 서버에 새 에이전트를 등록할지 묻고, 등록하면 토큰을 저장한 뒤 웹 앱에 입력할 **페어링 코드**를 보여 줍니다.

**Linux / macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.sh \
  | bash -s -- --url "https://relay.example.com"
```

**Windows (PowerShell)**

```powershell
$env:SKYTOWER_URL = "https://relay.example.com"
iex (irm https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.ps1)
```

**Windows (CMD)**

```bat
set SKYTOWER_URL=https://relay.example.com
curl -fsSL https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.cmd -o install-skytower.cmd && install-skytower.cmd && del install-skytower.cmd
```

설치가 끝나면 이렇게 나옵니다. 코드를 웹 앱 좌측 상단 에이전트 추가 버튼에 입력하면 에이전트가 내 계정에 연결됩니다.

```
새 에이전트 토큰 (다시 볼 수 없습니다 — 안전한 곳에 보관하세요):
  AbC123xyz:Qw3...
Skytower 웹 앱과 연결:
  페어링 코드: K7Q2MX   (10분 유효, 1회)
```

**토큰 처리 규칙**

| 상황 | 동작 |
|---|---|
| `--token`(`SKYTOWER_TOKEN`)을 줌 | 그 토큰을 씀 |
| `~/.hermes/.env`에 이미 `SKYTOWER_TOKEN`이 있음 | 그대로 재사용 — 다시 실행해도 새 에이전트를 만들지 않음 |
| 둘 다 없음, 터미널에서 실행 | 자동 등록할지(Y/n)와 에이전트 이름을 물음. `n`이면 토큰을 직접 입력 |
| 둘 다 없음, 터미널 없음(CI 등) | `--register`가 있어야 등록. 없으면 토큰 없이 끝남 |

| bash 옵션 | PowerShell / CMD 환경 변수 | 설명 |
|---|---|---|
| `--url URL` | `SKYTOWER_URL` | Skytower 서버 URL |
| `--token TOKEN` | `SKYTOWER_TOKEN` | 이미 있는 토큰 (`agentId:rawToken`) |
| `--register` / `--no-register` | `SKYTOWER_REGISTER=1` / `0` | 토큰이 없을 때 묻지 않고 등록 / 등록하지 않음 |
| `--agent-name NAME` | `SKYTOWER_AGENT_NAME` | 새 에이전트 이름. 기본값 `Hermes Agent (<호스트 이름>)` |

```bash
# 묻지 않고 등록 (CI, 프로비저닝 스크립트)
curl -fsSL .../install-skytower.sh | bash -s -- --url "https://relay.example.com" --register --agent-name "build-server"

# 이미 토큰이 있을 때
curl -fsSL .../install-skytower.sh | bash -s -- --token "agentId:rawToken" --url "https://relay.example.com"
```

토큰은 서버에 해시로만 저장되어 다시 볼 수 없습니다. 잃어버리면 새로 등록하고 다시 페어링해야 합니다.

스크립트가 하는 일은 다음과 같습니다.

1. `hermes plugins install CodescapeDevOps/hermes-skytower-plugin/skytower` 실행 (이미 있으면 갱신 — Hermes 가 `--yes-deps` 를 지원하면 `install --force --yes-deps`, 아니면 `hermes plugins update`)
2. `python-socketio` 설치 (PM 관리 설치에서는 Hermes가 활성화 시 직접 설치)
3. `hermes plugins enable skytower-platform`
4. 토큰 확보 — 기존 값 재사용, 없으면 자동 등록(`POST /api/agents/register`) 또는 직접 입력
5. `~/.hermes/.env`에 `SKYTOWER_TOKEN`, `SKYTOWER_URL` 기록
6. 새로 등록했으면 페어링 코드 발급(`POST /api/agents/pairing-code`)
7. Hermes가 실제로 쓰는 Python에서 플러그인 import 확인

### 수동 설치

```bash
hermes plugins install CodescapeDevOps/hermes-skytower-plugin/skytower
pip install "python-socketio[asyncio_client]>=5.11,<6"   # Hermes venv 안에서
hermes plugins enable skytower-platform
```

토큰이 없으면 서버에 에이전트를 등록해 받습니다. 응답의 `token`이 토큰입니다.

```bash
curl -fsSL -X POST https://relay.example.com/api/agents/register \
  -H "Content-Type: application/json" -d '{"name":"My Hermes Agent"}'
```

그 다음 `~/.hermes/.env`에 토큰과 URL을 적습니다.

```env
SKYTOWER_TOKEN=agentId:rawToken
SKYTOWER_URL=https://relay.example.com
SKYTOWER_ALLOW_ALL_USERS=true
SKYTOWER_PRINT_PAIR_CODE=0
```

### 특정 버전으로 고정

운영 서버에서는 태그로 고정하는 것을 권합니다. 스크립트는 태그를 커밋 SHA로 바꿔 `hermes plugins install --ref`에 넘깁니다.

```bash
curl -fsSL .../install-skytower.sh | bash -s -- --ref v1.1.0
```

고정된 플러그인은 `hermes plugins update`로 바뀌지 않습니다. 버전을 올리려면 다른 `--ref`로 다시 설치하세요.

## 환경 변수

| 변수 | 필수 | 설명 |
|---|---|---|
| `SKYTOWER_TOKEN` | 예 | 에이전트 토큰. `agentId:rawToken` 형식 |
| `SKYTOWER_URL` | 예 | Relay 서버 URL. 끝에 `/` 없이 |
| `SKYTOWER_ALLOW_ALL_USERS` | 아니오 | `true`면 모든 Skytower 사용자 허용. 설치 스크립트 기본값 `true` |
| `SKYTOWER_ALLOWED_USERS` | 아니오 | 허용할 사용자 ID 목록(쉼표 구분). 허용 목록이 있으면 미인가 DM은 조용히 무시됩니다 |
| `SKYTOWER_PRINT_PAIR_CODE` | 아니오 | 접속 시 페어링 코드를 터미널에 출력. `1` 출력, `0` 숨김 |

`config.yaml`의 `platforms.skytower` 아래에 토큰과 URL, 대화방별 스킬 바인딩(`channel_skill_bindings`, `default_skill`), 대화방 프롬프트(`channel_prompts`), 표시명(`channel_names`)을 둘 수도 있습니다. 예시는 [skytower/adapter.py](skytower/adapter.py) 머리말에 있습니다.

## 게이트웨이 시작

```bash
hermes gateway            # 한 번 실행
hermes gateway install    # systemd / Windows 서비스로 등록
```

접속이 되면 로그에 `✓ skytower connected`와 `SkyTower connected: <url> (agentId=...)`가 찍힙니다.

## 채팅 명령어

| 명령어 | 설명 |
|---|---|
| `/chatid` | 현재 대화의 JID 확인 |
| `/sethome` | 현재 대화를 홈 채널로 설정 |
| `/skills` | 사용 가능한 스킬 목록 |
| `/paircode` | 친구 추가 코드 발급 (10분 유효, 1회 사용) |

## 업데이트

```bash
hermes plugins update skytower-platform
hermes gateway restart
```

Hermes 자체는 평소대로 `hermes update`로 갱신합니다. 플러그인이 Hermes 저장소 밖에 있어서 업데이트와 충돌하지 않습니다.

최신 Hermes는 켜져 있는 플러그인을 갱신할 때 Python 의존성(`python-socketio`) 설치에 동의하는지 묻습니다. 터미널에서는 `y`로 답하면 됩니다. SSH 자동화처럼 답할 수 없는 곳에서는 `Reinstall declined: dependency install skipped (non-interactive)`로 거절되므로, 동의를 미리 주고 다시 설치합니다. 설치 스크립트를 다시 실행해도 같은 방법으로 갱신됩니다.

```bash
hermes plugins install CodescapeDevOps/hermes-skytower-plugin/skytower --force --yes-deps
```

## 문제 해결

**플러그인이 로드되지 않을 때**

```bash
hermes plugins list        # skytower-platform 이 enabled 인지
hermes plugins doctor
```

`python-socketio`가 없다는 경고가 나오면 Hermes venv에 설치하세요. PM 관리 설치에서는 `hermes pm install`이 `plugin.yaml`의 `python_dependencies`를 반영합니다.

**접속이 되지 않을 때**

1. `SKYTOWER_URL`이 맞는지, 끝에 `/`가 없는지 확인합니다.
2. `SKYTOWER_TOKEN`이 `agentId:rawToken` 형식인지 확인합니다.
3. 로그에서 `skytower error:` 줄을 찾습니다. `unexpected keyword argument`류 오류는 Hermes와 플러그인의 버전이 어긋난 것이므로 둘 다 최신으로 올립니다.

**접속은 되는데 응답이 없을 때**

허용 목록(`SKYTOWER_ALLOWED_USERS`)이 설정되어 있으면 목록 밖 사용자의 메시지는 로그 없이 무시됩니다. 확인용으로 `SKYTOWER_ALLOW_ALL_USERS=true`를 잠시 켜 보세요.

## 저장소 구조

```
skytower/               플러그인 본체 (이 디렉토리가 ~/.hermes/plugins/skytower-platform 에 설치됨)
  plugin.yaml           매니페스트: 이름, 의존성, 환경 변수
  __init__.py           register(ctx) 진입점
  adapter.py            SkyTowerAdapter — Socket.IO 접속, 메시지 중계, 스트리밍, 스레드, 공유 방, 페르소나 두 겹
  confinement.py        공유 프로젝트 방의 도구 호출을 작업 폴더 안으로 제한하는 훅
  skytower_files.py     웹 UI 파일 브라우저용 file:* 이벤트 핸들러
scripts/                설치 스크립트 (bash, PowerShell, CMD)
tests/                  pytest 스위트. upstream hermes-agent 체크아웃이 필요
.github/workflows/      upstream main에 대고 매일 테스트하는 CI
docs/                   설계 배경 문서
```

## 개발

### 테스트

테스트는 upstream Hermes 소스를 import합니다. 체크아웃 위치를 `HERMES_AGENT_SRC`로 알려주거나, 이 저장소 옆에 `hermes-agent/`로 두면 자동으로 찾습니다.

```bash
# upstream 체크아웃과 그 개발 환경 준비 (한 번만)
git clone https://github.com/NousResearch/hermes-agent.git ../hermes-agent
(cd ../hermes-agent && uv sync --frozen --python 3.14 --group dev && uv pip install "python-socketio[asyncio_client]")

# 테스트 실행
HERMES_AGENT_SRC=../hermes-agent ../hermes-agent/.venv/bin/python -m pytest -q
```

테스트 하네스(`tests/conftest.py`)는 임시 `HERMES_HOME`에 플러그인을 복사하고 활성화한 뒤 upstream의 실제 플러그인 탐색으로 로드합니다. 운영 환경과 같은 경로를 타므로 레지스트리 등록 문제를 테스트에서 잡을 수 있습니다.

### 로컬에서 설치해 보기

저장소 안에서 설치 스크립트를 실행하면 GitHub 대신 작업 트리를 `~/.hermes/plugins/skytower-platform`에 복사합니다.

```bash
bash scripts/install-skytower.sh
hermes gateway
```

Windows PowerShell 5.1에서 파일을 직접 실행하면 BOM 없는 UTF-8을 ANSI로 읽어 한글 때문에 구문 오류가 납니다. PowerShell 7을 쓰거나 아래처럼 UTF-8로 읽어 실행하세요. `irm | iex` 설치 경로는 영향이 없습니다.

```powershell
iex (Get-Content -Raw -Encoding UTF8 scripts\install-skytower.ps1)
```

### CI

`.github/workflows/ci.yml`은 push, PR, 그리고 매일 03:00 UTC에 NousResearch/hermes-agent의 main을 받아 테스트와 upstream 플러그인 스캐너를 돌립니다. upstream이 어댑터 API를 바꾸면 운영 서버가 아니라 여기서 먼저 빨간불이 켜집니다.

### 릴리스

1. `skytower/plugin.yaml`의 `version`을 올립니다.
2. 태그를 만듭니다: `git tag v1.1.0 && git push origin v1.1.0`
3. 운영 서버는 `--ref v1.1.0`으로 설치하거나, 고정하지 않았다면 `hermes plugins update skytower-platform`으로 받습니다.

## 라이선스

Apache License 2.0. [LICENSE](LICENSE)를 참고하세요.
