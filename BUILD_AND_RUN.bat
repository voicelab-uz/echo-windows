@echo off
setlocal
cd /d "%~dp0"

echo Building VoiceLab Echo for Windows (WinUI 3)...
dotnet publish "VoiceLab.WinUI3\VoiceLab.App\VoiceLab.App.csproj" -c Release -r win-x64 -p:Platform=x64 --self-contained true -p:WindowsAppSDKSelfContained=true -p:PublishSingleFile=false -o "artifacts\VoiceLab-Echo-win-x64"
if errorlevel 1 (
    echo Build failed. See the errors above.
    exit /b 1
)

if not exist "artifacts\VoiceLab-Echo-win-x64\VoiceLab.Echo.exe" (
    echo Publish did not produce VoiceLab.Echo.exe.
    exit /b 1
)

echo Starting VoiceLab Echo...
powershell.exe -NoProfile -Command "try { Start-Process -FilePath (Resolve-Path -LiteralPath 'artifacts\VoiceLab-Echo-win-x64\VoiceLab.Echo.exe').Path -ErrorAction Stop; exit 0 } catch { Write-Host ('Launch failed: ' + $_.Exception.Message); exit 1 }"
if errorlevel 1 (
    echo Windows could not start the app. On this PC, Smart App Control blocks unsigned development builds.
    echo See Windows Security ^> App ^& browser control ^> Smart App Control settings.
    exit /b 1
)
exit /b 0
