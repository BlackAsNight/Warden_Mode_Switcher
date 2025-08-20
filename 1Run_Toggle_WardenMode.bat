@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Run the Toggle-WardenMode.ps1 script from this folder
set "PS1=%~dp0Toggle-WardenMode.ps1"
if not exist "%PS1%" (
  echo [ERROR] Toggle-WardenMode.ps1 not found next to this bat: "%PS1%"
  echo Place this bat in the same folder as Toggle-WardenMode.ps1 and try again.
  pause
  exit /b 1
)

rem Optional args: runWardenToggle.bat [SavePath]
set "SAVEPATH=%~1"

:TOP
cls
echo ============================
echo   Prison Architect - Warden Toggle
echo ============================

rem 1) Ask for restore from backup first (every loop)
:ASK_RESTORE
echo.
set "RESTORE="
set /p RESTORE="Restore from backup first? (Y/N, Q=quit): "
if /I "%RESTORE%"=="Q" goto :QUIT
if /I "%RESTORE%"=="Y" (
  if not defined SAVEPATH (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RestoreOnly
  ) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RestoreOnly -SavePath "%SAVEPATH%"
  )
)

:MENU
echo.
echo 1^) Architect mode
echo 2^) Full Warden mode with Inventory
echo 3^) Warden mode Hybrid (Experimental) = No Inventory! Full zoom is enabled.
echo.
set "CHOICE="
set /p CHOICE="Select option [1-3, Q=quit]: "
if /I "%CHOICE%"=="Q" goto :QUIT
if "%CHOICE%"=="1" goto :MODE1
if "%CHOICE%"=="2" goto :MODE2
if "%CHOICE%"=="3" goto :MODE3
echo Invalid selection. Try again.
goto :MENU

:MODE1
echo Running mode 1 ...
if not defined SAVEPATH (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Desired false
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Desired false -SavePath "%SAVEPATH%"
)
goto :AFTER_RUN

:MODE2
echo Running mode 2 ...
if not defined SAVEPATH (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Desired true -CompatBlock -NoAvatar
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Desired true -CompatBlock -NoAvatar -SavePath "%SAVEPATH%"
)
goto :AFTER_RUN

:MODE3
echo Running mode 3 ...
if not defined SAVEPATH (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Desired true -HybridIsActiveOff
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Desired true -HybridIsActiveOff -SavePath "%SAVEPATH%"
)
goto :AFTER_RUN

:AFTER_RUN
set "ERR=%ERRORLEVEL%"
echo.
if not "%ERR%"=="0" echo [ERROR] PowerShell exited with code %ERR%
echo.
pause
echo.
set "AGAIN="
set /p AGAIN="Would you like to patch again? (Y/N): "
if /I "%AGAIN%"=="Y" goto :TOP
goto :QUIT

:QUIT
echo.
echo Goodbye.
endlocal
exit /b 0
