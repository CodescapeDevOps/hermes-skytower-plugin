@echo off
REM ============================================================================
REM Skytower Channel Plugin Installer for Hermes Agent (Windows / CMD wrapper)
REM ============================================================================
REM 공식 Hermes Agent에 Skytower 채널 플러그인을 설치합니다.
REM 먼저 공식 Hermes Agent가 설치되어 있어야 합니다.
REM
REM 1단계 - 공식 Hermes Agent 설치 (아직 설치 안 된 경우):
REM   curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.cmd -o install.cmd && install.cmd && del install.cmd
REM
REM 2단계 - Skytower 채널 플러그인 설치:
REM   curl -fsSL https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.cmd -o install-skytower.cmd && install-skytower.cmd && del install-skytower.cmd
REM
REM 토큰이 없으면 서버에 새 에이전트를 등록할지 묻습니다. 서버 URL 만 주면 됩니다:
REM   set SKYTOWER_URL=https://relay.example.com
REM   install-skytower.cmd
REM
REM 묻지 않고 등록: set SKYTOWER_REGISTER=1 (이름: set SKYTOWER_AGENT_NAME=My Agent)
REM
REM 이미 토큰이 있으면:
REM   set SKYTOWER_TOKEN=agentId:rawToken
REM   set SKYTOWER_URL=https://relay.example.com
REM   install-skytower.cmd
REM
REM PowerShell을 직접 사용할 수 있다면:
REM   iex (irm https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.ps1)
REM ============================================================================

echo.
echo  +---------------------------------------------------------+
echo  ^|        [*] Skytower Channel Plugin Installer           ^|
echo  +---------------------------------------------------------+
echo  ^|  공식 Hermes Agent에 Skytower 채널을 추가합니다        ^|
echo  +---------------------------------------------------------+
echo.
echo  PowerShell 설치 스크립트를 실행합니다...
echo.

powershell -ExecutionPolicy ByPass -NoProfile -Command ^
  "$env:SKYTOWER_TOKEN='%SKYTOWER_TOKEN%'; $env:SKYTOWER_URL='%SKYTOWER_URL%'; $env:SKYTOWER_PLUGIN_REF='%SKYTOWER_PLUGIN_REF%'; $env:SKYTOWER_REGISTER='%SKYTOWER_REGISTER%'; $env:SKYTOWER_AGENT_NAME='%SKYTOWER_AGENT_NAME%'; iex (irm https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.ps1)"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  [XX] 설치 실패. PowerShell에서 직접 실행해보세요:
    echo.
    echo    powershell -ExecutionPolicy ByPass -c "iex (irm https://raw.githubusercontent.com/CodescapeDevOps/hermes-skytower-plugin/main/scripts/install-skytower.ps1)"
    echo.
    pause
    exit /b 1
)
