# Voice Lab Echo - Windows Edition

A native Windows voice dictation application built with .NET 8 and WPF.

## Features

- 🎤 Voice recording and cloud transcription
- 🔐 Secure authentication with OAuth 2.0
- 📝 Encrypted local notes storage
- 📚 Custom vocabulary and text snippets
- 📊 Usage statistics and history
- ⌨️ Global keyboard shortcuts
- 🌓 Light/Dark theme support
- 🔄 Cloud sync for notes and history

## Requirements

- Windows 10/11
- .NET 8 Runtime
- Microphone access
- Internet connection for transcription

## Installation

1. Download the latest release from the releases page
2. Run the installer or extract the portable version
3. Launch VoiceLabEcho.App.exe
4. Complete the onboarding process

## Building from Source

### Prerequisites
- Visual Studio 2022 or JetBrains Rider
- .NET 8 SDK

### Build Steps
```bash
git clone <repository-url>
cd VoiceLabEcho.Windows
dotnet restore
dotnet build
dotnet run --project VoiceLabEcho.App
```

## Architecture

The application is structured into multiple projects:

- **VoiceLabEcho.App** - WPF UI layer with XAML views and ViewModels
- **VoiceLabEcho.Core** - Business logic and domain models
- **VoiceLabEcho.Infrastructure** - External integrations (API, audio, storage)
- **VoiceLabEcho.Tests** - Unit and integration tests

## Configuration

Application data is stored in:
- `%APPDATA%\VoiceLabEcho\` - User data and settings
- Windows Credential Manager - Secure credential storage

## Usage

1. **Sign In**: Authenticate with your VoiceLab account
2. **Record**: Press the global shortcut (default: Ctrl+Alt+Space) or click Record
3. **Transcribe**: Audio is automatically sent for transcription
4. **Insert**: Text is inserted into your active application

## Keyboard Shortcuts

- `Ctrl+Alt+Space` - Start/Stop recording (configurable)
- `Ctrl+N` - New note
- `Ctrl+,` - Open settings
- `Esc` - Cancel recording

## Development

### Project Structure
```
VoiceLabEcho.Windows/
├── VoiceLabEcho.App/              # WPF Application
├── VoiceLabEcho.Core/             # Business Logic
├── VoiceLabEcho.Infrastructure/   # External Services
└── VoiceLabEcho.Tests/            # Tests
```

### Key Technologies
- WPF with XAML for UI
- MVVM pattern with CommunityToolkit.Mvvm
- NAudio for audio recording
- HttpClient for API communication
- AES-GCM for encryption

## API Endpoints

The application communicates with VoiceLab API:
- Base URL: `https://api.voicelab.uz`
- Authentication: OAuth 2.0 with PKCE
- Transcription: `/v1/desktop/stt`
- History: `/v1/desktop/transcriptions`
- Notes: `/v1/desktop/notes`

## License

[Your License Here]

## Support

For issues and feature requests, please use the GitHub issue tracker.
