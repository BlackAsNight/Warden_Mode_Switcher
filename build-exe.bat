@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM Build a single EXE using built-in IExpress (no installs required)
REM Output: Warden_Switcher.exe next to this script.

set "HERE=%~dp0"
set "OUT=%HERE%Warden_Switcher.exe"
set "SED=%TEMP%\Warden_Switcher.sed"

REM Required payload files
set "BAT=1Run_Toggle_WardenMode.bat"
set "PS1=Toggle-WardenMode.ps1"
set "DOC=Warden_mode_README.txt"

for %%F in ("%HERE%%BAT%" "%HERE%%PS1%" "%HERE%%DOC%") do (
  if not exist "%%~fF" (
    echo [ERROR] Missing required file: %%~nxF
    exit /b 1
  )
)

>"%SED%" (
  echo [Version]
  echo Class=IEXPRESS
  echo SEDVersion=3
  echo 
  echo [Options]
  echo PackagePurpose=InstallApp
  echo ShowInstallProgramWindow=1
  echo HideExtractAnimation=0
  echo UseLongFileName=1
  echo InsideCompressed=0
  echo CAB_FixedSize=0
  echo CAB_ResvCodeSigning=0
  echo RebootMode=I
  echo InstallPrompt=
  echo DisplayLicense=%HERE%%DOC%
  echo FinishMessage=
  echo TargetName=%OUT%
  echo FriendlyName=Warden Mode Switcher
  echo AppLaunched=%BAT%
  echo PostInstallCmd=<None>
  echo AdminQuietInstCmd=
  echo UserQuietInstCmd=
  echo SourceFiles=SourceFiles
  echo 
  echo [Strings]
  echo 
  echo [SourceFiles]
  echo SourceFiles0=%HERE%
  echo 
  echo [SourceFiles0]
  echo %HERE%=
  echo 
  echo [Files]
  echo SourceFiles0#1=%BAT%
  echo SourceFiles0#2=%PS1%
)

echo Building %OUT% ...
set "IEXPRESS=%SystemRoot%\System32\iexpress.exe"
if not exist "%IEXPRESS%" set "IEXPRESS=iexpress.exe"
"%IEXPRESS%" /N /Q "%SED%"
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
  echo [ERROR] IExpress failed with code %ERR%
  echo If 'iexpress' is not found, enable the 'IExpress Wizard' Windows feature or run this as Administrator.
  exit /b %ERR%
)

if exist "%OUT%" (
  echo Done: "%OUT%"
  echo README will NOT be embedded; it was only shown as a license prompt.
  exit /b 0
) else (
  echo [ERROR] Build completed but output EXE was not found.
  exit /b 2
)
