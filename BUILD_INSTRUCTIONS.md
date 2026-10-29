# Voice Lab Echo - Windows Build Instructions

## Prerequisites

Before building the application, ensure you have the following installed on your Windows machine:

1. **Windows 10 or Windows 11**
2. **Visual Studio 2022** (Community, Professional, or Enterprise)
   - Download from: https://visualstudio.microsoft.com/
   - During installation, select:
     - ".NET desktop development" workload
     - "Desktop development with C++" (optional, for advanced debugging)

3. **.NET 8 SDK**
   - Download from: https://dotnet.microsoft.com/download/dotnet/8.0
   - The SDK is also included with Visual Studio 2022

## Project Structure

```
VoiceLabEcho.Windows/
├── VoiceLabEcho.sln              # Solution file
├── VoiceLabEcho.App/             # WPF application
├── VoiceLabEcho.Core/            # Business logic
├── VoiceLabEcho.Infrastructure/  # External integrations
└── VoiceLabEcho.Tests/           # Unit tests
```

## Building with Visual Studio

### Step 1: Open the Solution
1. Navigate to the `VoiceLabEcho.Windows` directory
2. Double-click `VoiceLabEcho.sln` to open in Visual Studio
3. Wait for Visual Studio to restore NuGet packages (this may take a few minutes)

### Step 2: Restore NuGet Packages
If packages don't restore automatically:
1. Right-click on the solution in Solution Explorer
2. Select "Restore NuGet Packages"
3. Wait for the restore to complete

### Step 3: Build the Solution
1. Select **Build → Build Solution** from the menu (or press `Ctrl+Shift+B`)
2. Check the Output window for any errors
3. If successful, you'll see "Build succeeded" in the output

### Step 4: Run the Application
1. Set `VoiceLabEcho.App` as the startup project (right-click → Set as Startup Project)
2. Press **F5** to run in debug mode, or **Ctrl+F5** to run without debugging
3. The application window should appear

## Building from Command Line

### Using .NET CLI

Open PowerShell or Command Prompt in the `VoiceLabEcho.Windows` directory:

```powershell
# Restore dependencies
dotnet restore

# Build the solution
dotnet build --configuration Release

# Run the application
dotnet run --project VoiceLabEcho.App

# Run tests
dotnet test
```

### Build Output Location

After building, the executable will be located at:
```
VoiceLabEcho.Windows/VoiceLabEcho.App/bin/Release/net8.0-windows/VoiceLabEcho.exe
```

## Common Build Issues

### Issue 1: Missing .NET 8 SDK
**Error:** `The current .NET SDK does not support targeting .NET 8.0`

**Solution:**
- Install .NET 8 SDK from https://dotnet.microsoft.com/download/dotnet/8.0
- Restart Visual Studio

### Issue 2: NuGet Package Restore Failure
**Error:** `Unable to find package [PackageName]`

**Solution:**
```powershell
# Clear NuGet cache
dotnet nuget locals all --clear

# Restore packages
dotnet restore --force
```

### Issue 3: Build Errors Related to Windows API
**Error:** `The type or namespace name 'Windows' could not be found`

**Solution:**
- Ensure the project targets `net8.0-windows`
- Check the `.csproj` file contains: `<TargetFramework>net8.0-windows</TargetFramework>`

### Issue 4: NAudio Package Issues
**Error:** Related to NAudio or audio recording

**Solution:**
```powershell
# Update NAudio package
dotnet add VoiceLabEcho.Infrastructure package NAudio --version 2.2.1
```

## Configuration

### API Endpoint
The application connects to: `https://api.voicelab.uz`

To change this, modify `VoiceLabApiClient.cs`:
```csharp
_httpClient.BaseAddress = new Uri("YOUR_API_ENDPOINT");
```

### Storage Location
User data is stored in: `%APPDATA%\VoiceLabEcho\`

### Credentials Storage
Authentication tokens are stored securely in Windows Credential Manager under the name: `VoiceLabEcho`

## Development Tips

### Hot Reload
Visual Studio 2022 supports XAML Hot Reload:
1. Run the application in debug mode
2. Make changes to XAML files
3. Changes will appear immediately without restarting

### Debugging
- Set breakpoints by clicking in the left margin of code files
- Press F5 to start debugging
- Use F10 (step over) and F11 (step into) to navigate through code

### Testing Audio Recording
The application requires microphone permissions:
1. First run will prompt for microphone access
2. Grant permission in Windows Settings if needed
3. Go to: Settings → Privacy → Microphone → Allow apps to access microphone

## Publishing the Application

### Create a Release Build

```powershell
# Build in Release mode
dotnet publish VoiceLabEcho.App -c Release -r win-x64 --self-contained

# Output will be in:
# VoiceLabEcho.App/bin/Release/net8.0-windows/win-x64/publish/
```

### Create an Installer
To create a Windows installer, you can use:
1. **WiX Toolset** - https://wixtoolset.org/
2. **Inno Setup** - https://jrsoftware.org/isinfo.php
3. **Advanced Installer** - https://www.advancedinstaller.com/

## Running Tests

```powershell
# Run all tests
dotnet test

# Run tests with detailed output
dotnet test --verbosity detailed

# Run tests and generate coverage
dotnet test --collect:"XPlat Code Coverage"
```

## Troubleshooting

### Application Won't Start
1. Check Windows Event Viewer for errors:
   - Open Event Viewer
   - Navigate to Windows Logs → Application
   - Look for errors from "VoiceLabEcho"

2. Run from command line to see error messages:
   ```powershell
   cd VoiceLabEcho.App/bin/Release/net8.0-windows/
   ./VoiceLabEcho.exe
   ```

### Microphone Not Working
1. Check Windows microphone permissions:
   - Settings → Privacy → Microphone
   - Ensure microphone access is enabled for desktop apps

2. Test microphone in Windows Sound settings:
   - Right-click speaker icon in taskbar
   - Select "Sound settings"
   - Test your microphone under "Input"

### API Connection Errors
1. Check internet connection
2. Verify API endpoint is accessible:
   ```powershell
   Invoke-WebRequest -Uri "https://api.voicelab.uz" -Method HEAD
   ```
3. Check Windows Firewall settings

## System Requirements

### Minimum
- Windows 10 version 1809 or later
- .NET 8 Runtime
- 2 GB RAM
- 100 MB disk space
- Microphone

### Recommended
- Windows 11
- 4 GB RAM
- SSD storage
- High-quality microphone

## Next Steps

After successfully building:

1. **Sign In**: Use your VoiceLab credentials to authenticate
2. **Configure Shortcut**: Set up your preferred keyboard shortcut (Settings)
3. **Test Recording**: Try a test recording to ensure audio works
4. **Customize**: Adjust settings, themes, and preferences

## Support

For issues not covered here:
- Check the main README.md file
- Review the code documentation
- Check the GitHub issues page

## License

See LICENSE file in the repository root.
