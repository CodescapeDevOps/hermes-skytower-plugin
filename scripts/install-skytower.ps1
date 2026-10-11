# ============================================================================
# Skytower Channel Plugin Installer for Hermes Agent (Windows / PowerShell)
# ============================================================================
# 공식 Hermes Agent에 Skytower 채널 플러그인을 설치합니다.
# 플러그인은 Hermes 의 사용자 플러그인 디렉토리(<HermesHome>\plugins\)에 설치되며,
# 공식 Hermes 저장소 디렉토리는 건드리지 않습니다. 그래서 `hermes update` 와 충돌하지 않습니다.
#
# 1단계 — 공식 Hermes Agent 설치 (아직 설치 안 된 경우):
#   iex (irm https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1)
#
# 2단계 — Skytower 채널 플러그인 설치:
#   iex (irm https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.ps1)
#
# 토큰/URL을 미리 지정:
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
    [string]$HermesHome = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}

$PluginName       = "skytower-platform"
$PluginRepo       = "CodescapeDevOps/hermes-skytower-plugin"
$PluginGitUrl     = "https://github.com/$PluginRepo.git"
$PluginIdentifier = "$PluginRepo/skytower"

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
    Write-Host "  iex (irm https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1)" -ForegroundColor Cyan
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

    if ((Test-Path $targetDir) -and -not $sha) {
        Write-Info "이미 설치됨 - 최신으로 갱신 중 (hermes plugins update $PluginName)..."
        & $HermesCli plugins update $PluginName
        if ($LASTEXITCODE -eq 0) { Write-Success "플러그인 갱신 완료"; return }
        Write-Warn "update 실패 - 다시 설치합니다"
    }

    $cliArgs = @("plugins", "install", $PluginIdentifier, "--no-enable")
    if ($sha) { $cliArgs += @("--ref", $sha) }
    if (Test-Path $targetDir) { $cliArgs += "--force" }
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

function Configure-Env {
    param([string]$HermesHomeDir)

    $envFile = "$HermesHomeDir\.env"
    if (-not (Test-Path $envFile)) { New-Item -ItemType File -Force -Path $envFile | Out-Null }

    if (-not $Token) { $Token = (Read-Host "`nSkytower 에이전트 토큰 입력 (agentId:rawToken, 없으면 Enter)").Trim() }
    if (-not $Url)   { $Url   = (Read-Host "Skytower Relay URL 입력 (예: https://relay.example.com, 없으면 Enter)").Trim() }

    $content = Get-Content $envFile -Raw -ErrorAction SilentlyContinue
    if (-not $content) { $content = "" }

    function Upsert-EnvVar {
        param([string]$Key, [string]$Value)
        if ($content -match "(?m)^${Key}=.*") {
            $script:content = $content -replace "(?m)^${Key}=.*", "${Key}=${Value}"
        } else {
            $script:content += "`n${Key}=${Value}"
        }
    }

    $changed = $false
    if ($Token) { Upsert-EnvVar "SKYTOWER_TOKEN" $Token; $changed = $true }
    if ($Url)   { Upsert-EnvVar "SKYTOWER_URL"   $Url;   $changed = $true }
    if ($content -notmatch "(?m)^SKYTOWER_ALLOW_ALL_USERS=") { $content += "`nSKYTOWER_ALLOW_ALL_USERS=true" }
    if ($content -notmatch "(?m)^SKYTOWER_PRINT_PAIR_CODE=") { $content += "`nSKYTOWER_PRINT_PAIR_CODE=0" }
    Set-Content $envFile $content.TrimStart()

    if ($changed) { Write-Success "Skytower 설정 저장됨: $envFile" }
    else {
        Write-Warn "토큰/URL을 나중에 $envFile 에 직접 추가하세요:"
        Write-Host "  SKYTOWER_TOKEN=agentId:rawToken" -ForegroundColor Yellow
        Write-Host "  SKYTOWER_URL=https://relay.example.com" -ForegroundColor Yellow
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
