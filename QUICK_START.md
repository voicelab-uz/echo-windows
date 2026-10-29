# Voice Lab Echo - Quick Start Guide

## Installation

1. Download the latest release from the releases page
2. Run the installer or extract the portable version
3. Launch `VoiceLabEcho.exe`

## First Time Setup

### 1. Sign In
- Click "Sign In" when prompted
- Your default browser will open
- Log in with your VoiceLab credentials
- The browser will redirect back to the app automatically
- You should see your profile and remaining minutes

### 2. Grant Microphone Permission
- Windows will ask for microphone access
- Click "Allow" to grant permission
- If you missed it, go to Windows Settings → Privacy → Microphone

### 3. Configure Keyboard Shortcut (Optional)
- Go to Settings
- The default shortcut is **Ctrl+Alt+Space**
- Click "Change" to customize if desired
- Test the shortcut to ensure it works

## Using Voice Dictation

### Method 1: Keyboard Shortcut (Recommended)
1. Place cursor in any text field (Word, Email, Browser, etc.)
2. Press **Ctrl+Alt+Space** (or your custom shortcut)
3. Speak clearly into your microphone
4. Press the shortcut again to stop and transcribe
5. Text appears automatically in your application

### Method 2: Manual Recording
1. Click the "🎤 Start Recording" button
2. Speak into your microphone
3. Click "Stop" when finished
4. Text is copied to clipboard (paste with Ctrl+V)

## Features

### 📜 History
- View all your past transcriptions
- Search through history
- Copy any transcription
- Edit transcriptions

### 📚 Vocabulary
- **Dictionary**: Add custom words for better recognition
  - Click "Dictionary" tab
  - Enter word and click "Add Word"
  - Words are saved locally

- **Snippets**: Create text shortcuts
  - Click "Snippets" tab
  - Enter trigger (e.g., "addr") and expansion (e.g., your full address)
  - When you say the trigger, it expands to full text

### 📝 Notes
- Create notes directly in the app
- Notes are encrypted locally
- Sync across devices (if enabled)
- Pin important notes to the top

### 📊 Statistics
- View your usage statistics
- Total recordings and words
- Average words per minute
- Track your productivity

### ⚙️ Settings
- **Theme**: Choose Light, Dark, or System theme
- **Startup**: Launch automatically with Windows
- **Shortcuts**: Customize keyboard shortcuts
- **Account**: View profile and sign out

## Tips & Tricks

### For Best Results
- Speak clearly and at a moderate pace
- Use a good quality microphone
- Minimize background noise
- Speak naturally, not robotically

### Useful Shortcuts
- **Ctrl+Alt+Space** - Start/Stop recording (default)
- **Ctrl+N** - New note
- **Ctrl+,** - Open settings
- **Esc** - Cancel recording

### Using with Different Apps
✅ **Works Great With:**
- Microsoft Word
- Outlook Email
- Google Chrome / Edge
- Notepad / Notepad++
- Visual Studio Code
- Slack
- Discord
- Any text editor

⚠️ **May Need Clipboard Mode:**
- Some secure input fields
- Password managers
- Terminal applications

## Troubleshooting

### Recording Not Starting
- Check microphone permissions in Windows Settings
- Ensure microphone is plugged in and working
- Try restarting the application

### Text Not Inserting
- Ensure the cursor is in a text field
- Try clicking in the text field first
- Switch to "Clipboard" mode in Settings
- Check that no other app is using the microphone

### Poor Transcription Quality
- Check microphone position (6-12 inches from mouth)
- Reduce background noise
- Speak more clearly and slowly
- Use a better quality microphone

### App Won't Start
- Ensure .NET 8 Runtime is installed
- Check Windows Event Viewer for errors
- Run as Administrator once
- Reinstall the application

### Shortcut Not Working
- Check if another app is using the same shortcut
- Try a different key combination
- Restart the application
- Check keyboard hook permissions

## System Tray

When you close the main window, the app continues running in the system tray (bottom-right corner).

**Tray Icon Menu:**
- **Show** - Open main window
- **Start Recording** - Quick record
- **Settings** - Open settings
- **Exit** - Quit application

**Right-click** the tray icon to access the menu.

## Privacy & Security

- **Authentication tokens** are stored securely in Windows Credential Manager
- **Local data** is encrypted with AES-GCM encryption
- **Audio files** are deleted after transcription
- **Transcriptions** are sent to VoiceLab servers for processing
- **Notes** are encrypted locally and optionally synced

## Getting Help

### Common Questions

**Q: How much does it cost?**  
A: Check your profile for remaining minutes. Plans vary.

**Q: Can I use it offline?**  
A: No, transcription requires an internet connection. However, notes and vocabulary work offline.

**Q: What languages are supported?**  
A: The app supports automatic language detection. Primary support for Uzbek, English, and Russian.

**Q: Can I dictate in multiple languages?**  
A: Yes, use automatic language detection in settings.

**Q: How accurate is the transcription?**  
A: Accuracy depends on audio quality, accent, and speaking clarity. Typically 90-95% for clear speech.

## Support

For additional help:
- Check the [GitHub repository](https://github.com/yourusername/voicelab-echo)
- Email support: support@voicelab.uz
- Documentation: docs.voicelab.uz

## Updates

The app will notify you when updates are available. Always keep your app updated for the best experience and latest features.

---

**Enjoy using Voice Lab Echo for Windows!**

Made with ❤️ for productivity
