@echo on
setlocal EnableExtensions

REM Commit and push this folder to GitHub.
REM Requires: git installed and network access. Optional: GitHub auth already configured.

set "HERE=%~dp0"
pushd "%HERE%" >nul
echo Working directory: "%HERE%"

REM 1) Check git
git --version >nul 2>&1
if errorlevel 1 (
  echo [ERROR] git is not installed or not on PATH.
  echo Install Git for Windows: https://git-scm.com/download/win
  popd >nul
  exit /b 1
)

REM 2) Initialize repo if needed
if not exist .git (
  echo Initializing new git repository...
  git init || goto :err
  git branch -M main 2>nul
)
echo Current git status:
git status -sb || echo (status not available)
git branch --show-current
git remote -v

REM 3) Create a helpful .gitignore if missing
if not exist .gitignore (
  >.gitignore (
    echo # Build artifacts
    echo Warden_Switcher.exe
    echo Warden_SwitchER.sed
    echo *.7z
    echo *.zip
    echo *.bak
    echo *.tmp
    echo Backups/
    echo *.log
  )
)

REM 4) Stage changes
echo Staging files...
git add -A || goto :err

REM 5) Commit
set "MSG="
set /p MSG="Commit message [default: update]: "
if "%MSG%"=="" set "MSG=update"
git commit -m "%MSG%" || goto :err
echo ---
echo Remotes:
git remote -v

REM 6) Set remote if missing
for /f "tokens=2" %%R in ('git remote -v ^| findstr /i "(fetch)" ^| findstr /i "origin"') do set "HASREMOTE=1"
if not defined HASREMOTE (
  set "REMOTE_URL=https://github.com/BlackAsNight/Warden_Mode_Switcher.git"
  echo Setting remote origin to: %REMOTE_URL%
  git remote add origin "%REMOTE_URL%" || goto :err
)

REM 7) Push
echo Pushing to origin main...
git push -u origin main || goto :err

echo Done.
git remote -v
git branch --show-current
pause
popd >nul
exit /b 0

:err
echo [ERROR] A git command failed. Check the output above.
echo - If this is a private repo, ensure you are authenticated (git credential manager or PAT).
echo - If the branch doesn't exist on remote, run once: git push -u origin main
pause
popd >nul
exit /b 1
