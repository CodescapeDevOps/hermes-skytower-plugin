# ============================================================================
# Skytower Channel Plugin Installer for Hermes Agent (Windows / PowerShell)
# ============================================================================
# 공식 Hermes Agent에 Skytower 채널 플러그인을 설치합니다.
# 플러그인은 Hermes 의 사용자 플러그인 디렉토리(<HermesHome>\plugins\)에 설치되며,
# 공식 Hermes 저장소 디렉토리는 건드리지 않습니다. 그래서 `hermes update` 와 충돌하지 않습니다.
#
# 1단계 — 공식 Hermes Agent 설치 (아직 설치 안 된 경우):
#   iex (irm https://hermes-agent.nousresearch.com/install.ps1)
#
# 2단계 — Skytower 채널 플러그인 설치:
#   iex (irm https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.ps1)
#
# 토큰이 없으면 Skytower 서버에 새 에이전트를 등록할지 묻고, 등록하면 토큰을 저장하고
# 웹 앱에 입력할 페어링 코드를 보여 줍니다. 서버 URL 만 주면 됩니다:
#   $env:SKYTOWER_URL = "https://relay.example.com"
#   iex (irm https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.ps1)
#
# 묻지 않고 등록:  $env:SKYTOWER_REGISTER = "1"; $env:SKYTOWER_AGENT_NAME = "My Agent"
# 등록하지 않음:   $env:SKYTOWER_REGISTER = "0"
#
# 이미 토큰이 있으면:
#   $env:SKYTOWER_TOKEN = "agentId:rawToken"
#   $env:SKYTOWER_URL   = "https://relay.example.com"
#   iex (irm https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.ps1)
#
# 특정 버전(태그 또는 커밋 SHA)으로 고정:
#   $env:SKYTOWER_PLUGIN_REF = "v1.1.0"
#
# 내부적으로 `hermes plugins install CodescapeDevOps/hermes-skytower-plugin/skytower` 를 실행합니다.
# ============================================================================

param(
    [string]$Token      = $env:SKYTOWER_TOKEN,
    [string]$Url        = $env:SKYTOWER_URL,
    [string]$Ref        = $env:SKYTOWER_PLUGIN_REF,
    [string]$AgentName  = $env:SKYTOWER_AGENT_NAME,
    [string]$Register   = $env:SKYTOWER_REGISTER,   # 1 = 묻지 않고 등록, 0 = 등록 안 함, 비우면 묻는다
    [string]$HermesHome = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}

$PluginName       = "skytower-platform"
$PluginRepo       = "CodescapeDevOps/hermes-skytower-plugin"
$PluginGitUrl     = "https://github.com/$PluginRepo.git"
$PluginIdentifier = "$PluginRepo/skytower"
$DefaultAgentName = "Hermes Agent ($env:COMPUTERNAME)"

# Configure-Env 가 채우고 Write-SuccessBanner 가 읽는다
$script:AgentRegistered = $false
$script:AgentToken      = ""
$script:PairCode        = ""
$script:PairUrl         = ""

# ============================================================================
# Helpers
# ============================================================================

function Write-Banner {
    Write-Host ""
    Write-Host "+---------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host "|         [*] Skytower Channel Plugin Installer           |" -ForegroundColor Magenta
    Write-Host "+---------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host "|  공식 Hermes Agent에 Skytower 채널을 추가합니다         |" -ForegroundColor Magenta
    Write-Host "+---------------------------------------------------------+" -ForegroundColor Magenta
    Write-Host ""
}

function Write-Info    { param([string]$m) Write-Host "-> $m"    -ForegroundColor Cyan    }
function Write-Success { param([string]$m) Write-Host "[OK] $m"  -ForegroundColor Green   }
function Write-Warn    { param([string]$m) Write-Host "[!!] $m"  -ForegroundColor Yellow  }
function Write-Err     { param([string]$m) Write-Host "[XX] $m"  -ForegroundColor Red     }

# ============================================================================
# Hermes 설치 위치 / Home / 실행기 탐색
# ============================================================================

function Find-HermesInstall {
    $candidates = @(
        "$env:LOCALAPPDATA\hermes\hermes-agent",   # 공식 Windows 기본값
        "$env:USERPROFILE\.hermes\hermes-agent",   # 레거시 / WSL 스타일
        "$env:HERMES_INSTALL_DIR"
    )
    $hermesCmd = Get-Command hermes -ErrorAction SilentlyContinue
    if ($hermesCmd) {
        $real = (Get-Item $hermesCmd.Source -ErrorAction SilentlyContinue)
        if ($real -and $real.Target) {
            $inferred = Split-Path (Split-Path (Split-Path $real.Target))
            if (Test-Path "$inferred\pyproject.toml") { $candidates = @($inferred) + $candidates }
        }
    }
    foreach ($dir in $candidates) {
        if (-not $dir) { continue }
        if ((Test-Path "$dir\pyproject.toml") -and (Test-Path "$dir\gateway")) {
            Write-Success "Hermes 설치 위치: $dir"
            return $dir
        }
    }
    Write-Err "Hermes Agent 설치를 찾을 수 없습니다."
    Write-Host ""
    Write-Host "  먼저 공식 Hermes Agent를 설치해주세요:" -ForegroundColor Yellow
    Write-Host "  iex (irm https://hermes-agent.nousresearch.com/install.ps1)" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

function Resolve-HermesHome {
    param([string]$InstallDir)
    if ($HermesHome -ne "") { return $HermesHome }
    if ($env:HERMES_HOME)   { return $env:HERMES_HOME }
    $parent = Split-Path $InstallDir
    if (Test-Path "$parent\.env") { return $parent }
    return "$env:LOCALAPPDATA\hermes"
}

function Find-Python {
    param([string]$InstallDir)
    $venvPython = "$InstallDir\venv\Scripts\python.exe"
    if (Test-Path $venvPython) { return $venvPython }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) { return $py.Source }
    return $null
}

# PM(패키지 관리자) 을 쓰는 Hermes 인가: 설치 폴더 venv 가 없고 installs\ 아래 기록이 있다.
function Test-PmManaged {
    param([string]$InstallDir, [string]$HermesHomeDir)
    return (-not (Test-Path "$InstallDir\venv")) -and [bool](Get-ChildItem "$HermesHomeDir\installs\*\facts.json" -ErrorAction SilentlyContinue)
}

# Hermes 가 실제로 도는 파이썬 (PM 관리 설치는 <HermesHome>\installs\<key>\environments\<hash>\venv).
function Find-RuntimePython {
    param([string]$InstallDir, [string]$HermesHomeDir)
    $venvPython = "$InstallDir\venv\Scripts\python.exe"
    if (Test-Path $venvPython) { return $venvPython }
    $facts = @()
    try {
        $full = (Get-Item $InstallDir).FullName.TrimEnd('\')
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($full)) | ForEach-Object { $_.ToString("x2") })
        $facts += "$HermesHomeDir\installs\$($hash.Substring(0, 16))\facts.json"
    } catch {}
    $facts += @(Get-ChildItem "$HermesHomeDir\installs\*\facts.json" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($f in $facts) {
        if (-not (Test-Path $f)) { continue }
        try { $envDir = (Get-Content $f -Raw | ConvertFrom-Json).packages.venv.environment } catch { continue }
        if ($envDir -and (Test-Path "$envDir\Scripts\python.exe")) { return "$envDir\Scripts\python.exe" }
    }
    return $null
}

function Find-HermesCli {
    param([string]$InstallDir, [string]$HermesHomeDir)
    $cmd = Get-Command hermes -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$HermesHomeDir\bin\hermes.exe", "$HermesHomeDir\bin\hermes.cmd", "$InstallDir\venv\Scripts\hermes.exe")) {
        if (Test-Path $p) { return $p }
    }
    Write-Err "hermes 명령을 찾을 수 없습니다. 플러그인 설치에는 hermes CLI 가 필요합니다."
    exit 1
}

function Find-Uv {
    param([string]$InstallDir)
    $bundled = "$InstallDir\venv\Scripts\uv.exe"
    if (Test-Path $bundled) { return $bundled }
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if ($uv) { return $uv.Source }
    return $null
}

# ============================================================================
# 플러그인 설치 (hermes plugins install)
# ============================================================================

# $Ref 가 태그/브랜치면 커밋 SHA 로 바꾼다 (hermes plugins install --ref 는 40자 SHA 만 받는다).
function Resolve-PluginRef {
    param([string]$RefValue)
    if (-not $RefValue) { return "" }
    if ($RefValue -match '^[0-9a-fA-F]{40}$') { return $RefValue }
    $lines = & git ls-remote $PluginGitUrl "refs/tags/$RefValue^{}" "refs/tags/$RefValue" "refs/heads/$RefValue" 2>$null
    $first = @($lines | Where-Object { $_ })[0]
    if (-not $first) {
        Write-Err "--ref '$RefValue' 를 $PluginGitUrl 에서 찾지 못했습니다 (태그/브랜치/커밋 SHA)"
        exit 1
    }
    $sha = ($first -split "\s+")[0]
    Write-Info "ref '$RefValue' -> $sha"
    return $sha
}

function Install-Plugin {
    param([string]$HermesCli, [string]$HermesHomeDir, [string]$ScriptDir)

    $targetDir = "$HermesHomeDir\plugins\$PluginName"
    $localPluginDir = Join-Path $ScriptDir "..\skytower"

    # 로컬 개발 모드: 이 스크립트가 플러그인 저장소 안에 있으면 그 작업 트리를 그대로 복사한다.
    if (Test-Path "$localPluginDir\plugin.yaml") {
        Write-Info "로컬 소스에서 플러그인 복사 중 -> $targetDir"
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        Copy-Item "$localPluginDir\*" -Destination $targetDir -Recurse -Force
        Write-Success "플러그인 복사 완료"
        return
    }

    $env:HERMES_HOME = $HermesHomeDir
    $sha = Resolve-PluginRef -RefValue $Ref
    # 최신 Hermes 는 켜져 있는 플러그인을 다시 설치(update 포함)할 때 Python 의존성 설치 동의를 묻고,
    # 터미널이 아니면 거절한다 ("Reinstall declined: dependency install skipped (non-interactive)").
    # 이 설치기를 실행한 것이 곧 동의이니 지원하면 --yes-deps 로 미리 답한다. plugins update 에는
    # 이 옵션이 없어 그때는 install --force 로 갱신한다. 구버전 Hermes 는 동의 절차도 없어 update 를 쓴다.
    # PS 5.1 은 Stop 에서 stderr 한 줄(경고 등)만 나와도 중단하므로 이 확인에서만 Continue 로 둔다.
    $installHelp = & { $ErrorActionPreference = "Continue"; & $HermesCli plugins install --help 2>$null } | Out-String
    $yesDeps = $installHelp -match '--yes-deps'

    if ((Test-Path $targetDir) -and -not $sha -and -not $yesDeps) {
        Write-Info "이미 설치됨 - 최신으로 갱신 중 (hermes plugins update $PluginName)..."
        & $HermesCli plugins update $PluginName
        if ($LASTEXITCODE -eq 0) { Write-Success "플러그인 갱신 완료"; return }
        Write-Warn "update 실패 - 다시 설치합니다"
    }

    $cliArgs = @("plugins", "install", $PluginIdentifier, "--no-enable")
    if ($sha) { $cliArgs += @("--ref", $sha) }
    if (Test-Path $targetDir) { $cliArgs += "--force" }
    if ($yesDeps) { $cliArgs += "--yes-deps" }
    Write-Info "플러그인 설치 중 (hermes $($cliArgs -join ' '))..."
    & $HermesCli @cliArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Err "플러그인 설치 실패. 직접 실행해 보세요:"
        Write-Host "  hermes $($cliArgs -join ' ')" -ForegroundColor Yellow
        exit 1
    }
    Write-Success "플러그인 설치 완료: $targetDir"
}

# ============================================================================
# 의존성 설치 / 활성화 / .env
# ============================================================================

function Install-Deps {
    param([string]$InstallDir, [string]$HermesHomeDir, [string]$PythonExe, [string]$UvExe)
    if (Test-PmManaged -InstallDir $InstallDir -HermesHomeDir $HermesHomeDir) {
        Write-Info "PM 관리 환경 - 의존성은 플러그인 활성화 때 Hermes 가 설치합니다"
        return
    }
    if (-not $PythonExe -and -not $UvExe) {
        Write-Err "Python을 찾을 수 없습니다. Hermes가 올바르게 설치됐는지 확인하세요."
        exit 1
    }
    Write-Info "Skytower 의존성 설치 중 (python-socketio)..."
    $pkgs = @("python-socketio[asyncio_client]>=5.11,<6")
    if ($UvExe) {
        $env:VIRTUAL_ENV = "$InstallDir\venv"
        & $UvExe pip install @pkgs -q
    } else {
        $pipExe = "$InstallDir\venv\Scripts\pip.exe"
        if (Test-Path $pipExe) { & $pipExe install @pkgs -q } else { & $PythonExe -m pip install @pkgs -q }
    }
    if ($LASTEXITCODE -ne 0) { Write-Err "의존성 설치 실패"; exit 1 }
    Write-Success "의존성 설치 완료"
}

function Enable-Plugin {
    param([string]$HermesCli, [string]$HermesHomeDir)
    Write-Info "플러그인 활성화 중 (hermes plugins enable $PluginName)..."
    $env:HERMES_HOME = $HermesHomeDir
    & $HermesCli plugins enable $PluginName
    if ($LASTEXITCODE -eq 0) { Write-Success "플러그인 활성화 완료" }
    else { Write-Warn "플러그인 활성화 실패 - 직접 실행하세요: hermes plugins enable $PluginName" }
}

# ============================================================================
# 토큰 - 기존 값 재사용 / 자동 등록 / 직접 입력
# ============================================================================

# irm | iex 는 콘솔에서 돌아 Read-Host 가 된다. 입력이 리디렉션된 환경(CI)에서는 묻지 않는다.
function Test-Interactive {
    try { return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { return $false }
}

function Get-EnvValue {
    param([string]$Content, [string]$Key)
    if ($Content -match "(?m)^$([regex]::Escape($Key))=(.*)$") { return $Matches[1].Trim() }
    return ""
}

function Set-EnvValue {
    param([string]$Content, [string]$Key, [string]$Value)
    $pattern = "(?m)^$([regex]::Escape($Key))=.*$"
    $line = "$Key=$Value"
    # -replace 는 값 안의 $ 를 치환 패턴으로 읽는다 - 평가자로 그대로 넣는다
    if ($Content -match $pattern) { return [regex]::Replace($Content, $pattern, { param($m) $line }.GetNewClosure()) }
    if ($Content -and -not $Content.EndsWith("`n")) { $Content += "`n" }
    return $Content + "$line`n"
}

# POST /api/agents/register - 인증 없이 이름만으로 에이전트를 만들고 agentId:rawToken 을 돌려준다.
function Register-Agent {
    param([string]$RelayUrl, [string]$Name)
    Write-Info "Skytower 서버에 에이전트 등록 중: $Name"
    try {
        $body = [System.Text.Encoding]::UTF8.GetBytes((@{ name = $Name } | ConvertTo-Json -Compress))
        $resp = Invoke-RestMethod -Method Post -Uri "$RelayUrl/api/agents/register" -ContentType 'application/json; charset=utf-8' -Body $body
    } catch {
        Write-Err "에이전트 등록 실패 ($RelayUrl): $($_.Exception.Message)"
        return $null
    }
    if ("$($resp.token)" -notmatch '^[^:]+:.+$') {
        Write-Err "등록 응답을 해석하지 못했습니다: $($resp | ConvertTo-Json -Compress)"
        return $null
    }
    Write-Success "에이전트 등록 완료: $($resp.token.Split(':')[0])"
    return [string]$resp.token
}

# 새 에이전트는 아직 누구의 계정에도 연결돼 있지 않다 - 웹 앱에 입력할 페어링 코드를 받아 둔다.
# 게이트웨이가 꺼져 있어도 발급된다. 서버는 본문이 없으면 500 이라 {} 를 보낸다.
function Get-PairCode {
    param([string]$RelayUrl, [string]$AgentToken)
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$RelayUrl/api/agents/pairing-code" -Headers @{ Authorization = "Bearer $AgentToken" } -ContentType 'application/json' -Body '{}'
        $script:PairCode = [string]$resp.code
        $script:PairUrl  = [string]$resp.pairUrl
        return [bool]$script:PairCode
    } catch { return $false }
}

# 토큰이 없을 때: 자동 등록(묻거나 SKYTOWER_REGISTER=1) -> 실패하거나 거절하면 직접 입력
function Get-AgentToken {
    param([string]$RelayUrl, [bool]$Interactive)
    $want = switch -Regex ("$Register") { '^(1|true|yes)$' { 'yes' } '^(0|false|no)$' { 'no' } default { '' } }
    if (-not $want) {
        if ($Interactive) {
            Write-Host ""
            Write-Host "  Skytower 에이전트 토큰이 없습니다. 서버에 새 에이전트를 등록할 수 있습니다." -ForegroundColor Cyan
            $ans = "$(Read-Host '자동 등록할까요? (Y/n)')".Trim()
            $want = if ($ans -match '^[Nn]') { 'no' } else { 'yes' }
        } else { $want = 'no' }
    }

    if ($want -eq 'yes') {
        if (-not $RelayUrl) {
            Write-Err "서버 URL 이 없어 에이전트를 등록할 수 없습니다 (SKYTOWER_URL)"
        } else {
            $name = $AgentName
            if (-not $name -and $Interactive) { $name = "$(Read-Host "에이전트 이름 (기본값: $DefaultAgentName)")".Trim() }
            if (-not $name) { $name = $DefaultAgentName }
            $registered = Register-Agent -RelayUrl $RelayUrl -Name $name
            if ($registered) { $script:AgentRegistered = $true; return $registered }
        }
    }

    if ($Interactive) { return "$(Read-Host 'Skytower 에이전트 토큰 입력 (agentId:rawToken, 없으면 Enter)')".Trim() }
    return ""
}

function Configure-Env {
    param([string]$HermesHomeDir)

    $envFile = "$HermesHomeDir\.env"
    if (-not (Test-Path $envFile)) { New-Item -ItemType File -Force -Path $envFile | Out-Null }
    $content = [System.IO.File]::ReadAllText($envFile)
    $interactive = Test-Interactive

    # 이미 저장된 값을 먼저 쓴다 - 다시 실행해도 에이전트를 새로 등록하지 않는다.
    $relayUrl = $Url
    if (-not $relayUrl) { $relayUrl = Get-EnvValue $content "SKYTOWER_URL" }
    if (-not $relayUrl -and $interactive) { $relayUrl = "$(Read-Host "`nSkytower 서버 URL 입력 (예: https://relay.example.com, 없으면 Enter)")".Trim() }
    $relayUrl = "$relayUrl".TrimEnd('/')

    $agentToken = $Token
    if (-not $agentToken) {
        $agentToken = Get-EnvValue $content "SKYTOWER_TOKEN"
        if ($agentToken) { Write-Info "기존 토큰 사용 (agentId=$($agentToken.Split(':')[0])) - $envFile" }
        else { $agentToken = Get-AgentToken -RelayUrl $relayUrl -Interactive $interactive }
    }
    $script:AgentToken = $agentToken

    $changed = $false
    if ($agentToken) { $content = Set-EnvValue $content "SKYTOWER_TOKEN" $agentToken; $changed = $true }
    if ($relayUrl)   { $content = Set-EnvValue $content "SKYTOWER_URL"   $relayUrl;   $changed = $true }
    if ($content -notmatch "(?m)^SKYTOWER_ALLOW_ALL_USERS=") { $content = Set-EnvValue $content "SKYTOWER_ALLOW_ALL_USERS" "true" }
    if ($content -notmatch "(?m)^SKYTOWER_PRINT_PAIR_CODE=") { $content = Set-EnvValue $content "SKYTOWER_PRINT_PAIR_CODE" "0" }
    # Hermes 는 .env 를 UTF-8 로 읽는다. Set-Content(5.1) 의 기본 ANSI 로 쓰면 비ASCII 주석이 깨진다.
    [System.IO.File]::WriteAllText($envFile, $content.TrimStart(), (New-Object System.Text.UTF8Encoding $false))

    if ($changed) { Write-Success "Skytower 설정 저장됨: $envFile" }
    else {
        Write-Warn "토큰/URL을 나중에 $envFile 에 직접 추가하세요:"
        Write-Host "  SKYTOWER_TOKEN=agentId:rawToken" -ForegroundColor Yellow
        Write-Host "  SKYTOWER_URL=https://relay.example.com" -ForegroundColor Yellow
    }

    if ($script:AgentRegistered -and -not (Get-PairCode -RelayUrl $relayUrl -AgentToken $agentToken)) {
        Write-Warn "페어링 코드를 받지 못했습니다 - 게이트웨이를 켠 뒤 대화에서 /paircode 를 쓰거나"
        Write-Warn "  $envFile 에 SKYTOWER_PRINT_PAIR_CODE=1 을 넣고 게이트웨이를 재시작하세요"
    }
}

# ============================================================================
# 동작 확인 - Hermes 가 실제로 도는 파이썬에서 플러그인을 로더와 같은 방식으로 import 한다
# ============================================================================

function Test-RuntimeImport {
    param([string]$InstallDir, [string]$HermesHomeDir, [string]$RuntimePython)
    $pluginDir = "$HermesHomeDir\plugins\$PluginName"
    $code = @"
import importlib.util, sys, types
sys.path.insert(0, r'$InstallDir')
try:
    import socketio
    plugin_dir = r'$pluginDir'
    ns = types.ModuleType('hermes_plugins'); ns.__path__ = []; sys.modules['hermes_plugins'] = ns
    name = 'hermes_plugins.skytower_platform'
    spec = importlib.util.spec_from_file_location(name, plugin_dir + '/__init__.py', submodule_search_locations=[plugin_dir])
    mod = importlib.util.module_from_spec(spec); mod.__package__ = name; sys.modules[name] = mod
    spec.loader.exec_module(mod)
    assert callable(mod.register)
    print('OK')
except Exception as e:
    print('FAIL:', e)
"@
    $result = & $RuntimePython -c $code 2>$null
    return [bool]($result -match "^OK")
}

function Test-Plugin {
    param([string]$InstallDir, [string]$HermesHomeDir, [string]$HermesCli)
    Write-Info "플러그인 로드 확인 중..."
    $runtimePython = Find-RuntimePython -InstallDir $InstallDir -HermesHomeDir $HermesHomeDir
    if (-not $runtimePython) { Write-Warn "Hermes 실행 환경을 찾지 못해 확인을 건너뜁니다"; return }
    if (Test-RuntimeImport -InstallDir $InstallDir -HermesHomeDir $HermesHomeDir -RuntimePython $runtimePython) {
        Write-Success "플러그인 로드 확인 완료 ($runtimePython)"; return
    }
    if (Test-PmManaged -InstallDir $InstallDir -HermesHomeDir $HermesHomeDir) {
        Write-Info "python-socketio 가 없습니다 - Hermes 환경 동기화 중 (hermes pm install)..."
        $env:HERMES_HOME = $HermesHomeDir
        & $HermesCli pm install
        $pmOk = ($LASTEXITCODE -eq 0)
        $runtimePython = Find-RuntimePython -InstallDir $InstallDir -HermesHomeDir $HermesHomeDir
        if ($pmOk -and $runtimePython -and (Test-RuntimeImport -InstallDir $InstallDir -HermesHomeDir $HermesHomeDir -RuntimePython $runtimePython)) {
            Write-Success "플러그인 로드 확인 완료 ($runtimePython)"; return
        }
    }
    Write-Warn "플러그인 로드 확인 실패 - python-socketio 가 Hermes 환경($runtimePython)에 없거나 플러그인 import 가 실패했습니다"
    Write-Warn "  hermes plugins doctor 로 상태를 확인하세요"
}

function Write-SuccessBanner {
    param([string]$HermesHomeDir)
    Write-Host ""
    Write-Host "+---------------------------------------------------------+" -ForegroundColor Green
    Write-Host "|         [OK] Skytower 채널 플러그인 설치 완료!          |" -ForegroundColor Green
    Write-Host "+---------------------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "설치된 위치:" -ForegroundColor Cyan
    Write-Host "  플러그인:  $HermesHomeDir\plugins\$PluginName\"
    Write-Host "  설정:      $HermesHomeDir\.env"
    Write-Host ""
    Write-Host "시작 방법:" -ForegroundColor Cyan
    Write-Host "  hermes gateway              " -NoNewline; Write-Host "게이트웨이 시작" -ForegroundColor Green
    Write-Host "  hermes gateway install      " -NoNewline; Write-Host "Windows 서비스로 등록" -ForegroundColor Green
    Write-Host ""
    Write-Host "업데이트:" -ForegroundColor Cyan
    Write-Host "  hermes plugins update $PluginName" -ForegroundColor Green
    Write-Host ""
    Write-Host "Skytower 채팅 명령어:" -ForegroundColor Cyan
    Write-Host "  /chatid    현재 대화 JID 확인        /sethome   현재 대화를 홈 채널로"
    Write-Host "  /skills    사용 가능한 스킬 목록      /paircode  친구 추가 코드 발급"
    Write-Host ""
    if ($script:AgentRegistered) {
        Write-Host "새 에이전트 토큰 (다시 볼 수 없습니다 - 안전한 곳에 보관하세요):" -ForegroundColor Yellow
        Write-Host "  $($script:AgentToken)" -ForegroundColor Green
        Write-Host "  저장 위치: $HermesHomeDir\.env"
        Write-Host ""
        if ($script:PairCode) {
            Write-Host "Skytower 웹 앱과 연결:" -ForegroundColor Cyan
            Write-Host "  페어링 코드: " -NoNewline; Write-Host $script:PairCode -ForegroundColor Green -NoNewline; Write-Host "   (10분 유효, 1회)"
            if ($script:PairUrl) { Write-Host "  바로 열기:   $($script:PairUrl)" }
            Write-Host "  웹 앱 좌측 상단 에이전트 추가 버튼에 코드를 입력하세요."
            Write-Host ""
        }
    }
    $envFile = "$HermesHomeDir\.env"
    $tokenVal = (Get-Content $envFile -ErrorAction SilentlyContinue | Where-Object { $_ -match "^SKYTOWER_TOKEN=" }) -replace "^SKYTOWER_TOKEN=", ""
    if (-not $tokenVal) {
        Write-Host "[!!] SKYTOWER_TOKEN이 아직 설정되지 않았습니다." -ForegroundColor Yellow
        Write-Host "     $envFile 에 추가 후 게이트웨이를 재시작하세요." -ForegroundColor Yellow
        Write-Host ""
    }
}

# ============================================================================
# Main
# ============================================================================

Write-Banner

$InstallDir         = Find-HermesInstall
$HermesHomeResolved = Resolve-HermesHome -InstallDir $InstallDir
$PythonExe          = Find-Python   -InstallDir $InstallDir
$UvExe              = Find-Uv       -InstallDir $InstallDir
$HermesCli          = Find-HermesCli -InstallDir $InstallDir -HermesHomeDir $HermesHomeResolved
$ScriptDir          = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = $PWD.Path }

Install-Plugin      -HermesCli $HermesCli -HermesHomeDir $HermesHomeResolved -ScriptDir $ScriptDir
Install-Deps        -InstallDir $InstallDir -HermesHomeDir $HermesHomeResolved -PythonExe $PythonExe -UvExe $UvExe
Enable-Plugin       -HermesCli $HermesCli -HermesHomeDir $HermesHomeResolved
Configure-Env       -HermesHomeDir $HermesHomeResolved
Test-Plugin         -InstallDir $InstallDir -HermesHomeDir $HermesHomeResolved -HermesCli $HermesCli

Write-SuccessBanner -HermesHomeDir $HermesHomeResolved
