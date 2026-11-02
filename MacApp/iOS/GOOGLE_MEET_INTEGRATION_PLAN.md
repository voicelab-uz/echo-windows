# Google Meet Integration Plan - iOS Echo App

## Frontend (Web) Tahlili

### Asosiy Funksiyalar:
1. **Google Meet URL Validation**
   - Format: `https://meet.google.com/xxx-yyyy-zzz`
   - Regex: `/^\/(?:meet\/)?[a-z]{3}-[a-z]{4}-[a-z]{3}\/?$/`

2. **Live Meeting Session API**
   - `POST /api/v1/live-meetings` - Yangi live session yaratish
   - `GET /api/v1/live-meetings` - Barcha sessionlarni olish
   - `GET /api/v1/live-meetings/{id}` - Bitta sessionni olish
   - `DELETE /api/v1/live-meetings/{id}` - Sessionni to'xtatish

3. **Live Meeting Statuslari**
   - `starting` - Boshlanyapti
   - `requested` - So'rov yuborilgan
   - `joining` - Qo'shilyapti
   - `awaiting_admission` - Kirish kutilmoqda
   - `active` - Faol (recording)
   - `stopping` - To'xtayapti
   - `completed` - Tugallandi
   - `processing` - Qayta ishlanmoqda
   - `ready` - Tayyor (transcript tayyor)
   - `failed` - Xatolik

4. **Meeting Recording Options**
   - Upload audio file
   - Record locally
   - **Google Meet link** (live recording)

## Backend (Vexa Bot) Tahlili

### Google Meet Bot Funksiyalari:
1. **Puppeteer-based bot** - Headless browser orqali meeting'ga qo'shilish
2. **Humanized interaction** - Mouse movements, clicks
3. **Audio capture** - System audio recording
4. **Admission handling** - "Join now" / "Ask to join" buttons
5. **Real-time transcription** - Audio → Text

## iOS Implementation Plan

### 1. **Backend API Client** (Priority: HIGH)

#### Yangi API Endpoints:
```swift
// LiveMeetingSession model
struct LiveMeetingSession: Codable {
    let id: String
    let title: String
    let language: String
    let status: LiveMeetingStatus
    let error: String?
    let createdAt: Date
    let updatedAt: Date
}

enum LiveMeetingStatus: String, Codable {
    case starting, requested, joining
    case awaitingAdmission = "awaiting_admission"
    case active, stopping, completed
    case processing, ready, failed
}

// API Client methods
class MeetingAPIClient {
    func createLiveMeeting(title: String, meetingUrl: String, language: String) async throws -> LiveMeetingSession
    func listLiveMeetings() async throws -> [LiveMeetingSession]
    func getLiveMeeting(id: String) async throws -> LiveMeetingSession
    func stopLiveMeeting(id: String) async throws -> LiveMeetingSession
}
```

**Location:** `/Users/macbookair/Voicelab/iOS/Echo/API/MeetingAPIClient.swift`

---

### 2. **UI Components** (Priority: HIGH)

#### A. Meeting Setup Screen
- **Meeting URL Input Field**
  - Placeholder: "https://meet.google.com/xxx-yyyy-zzz"
  - Validation: Real-time URL check
  - Error states: Invalid URL format
  
- **Meeting Title Input**
  - Default: "Meeting {date}"
  - Editable

- **Language Selector**
  - Dropdown with supported languages
  - Default: Uzbek

- **Start Recording Button**
  - Disabled until URL valid
  - Shows credit estimate

**Location:** `/Users/macbookair/Voicelab/iOS/Echo/Views/MeetingSetupView.swift`

#### B. Active Meeting Screen
- **Status Indicator**
  - Current status (joining, active, etc.)
  - Animated while in progress
  
- **Timer**
  - Recording duration
  
- **Stop Button**
  - Confirmation dialog
  
- **Error Handling**
  - Failed states with retry option

**Location:** `/Users/macbookair/Voicelab/iOS/Echo/Views/ActiveMeetingView.swift`

#### C. Meeting Library Screen
- **List of Meetings**
  - Recent meetings
  - Status badges (active, ready, failed)
  
- **Meeting Details**
  - Tap to view transcript
  - Play audio
  - View summary/notes

**Location:** `/Users/macbookair/Voicelab/iOS/Echo/Views/MeetingLibraryView.swift`

---

### 3. **URL Validation** (Priority: MEDIUM)

```swift
struct MeetingURLValidator {
    static func isValid(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https",
              url.host == "meet.google.com" else {
            return false
        }
        
        // Regex: /^\/(?:meet\/)?[a-z]{3}-[a-z]{4}-[a-z]{3}\/?$/
        let pattern = "^\\/(?:meet\\/)?[a-z]{3}-[a-z]{4}-[a-z]{3}\\/?$"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(url.path.startIndex..<url.path.endIndex, in: url.path)
        return regex?.firstMatch(in: url.path, range: range) != nil
    }
}
```

**Location:** `/Users/macbookair/Voicelab/iOS/Echo/Utils/MeetingURLValidator.swift`

---

### 4. **State Management** (Priority: HIGH)

```swift
@Observable
class MeetingViewModel {
    var activeSessions: [LiveMeetingSession] = []
    var completedMeetings: [MeetingNote] = []
    var isLoading = false
    var error: Error?
    
    func startLiveMeeting(title: String, url: String, language: String) async
    func stopLiveMeeting(id: String) async
    func refreshSessions() async
    func pollActiveSession(id: String) async
}
```

**Location:** `/Users/macbookair/Voicelab/iOS/Echo/ViewModels/MeetingViewModel.swift`

---

### 5. **Polling & Real-time Updates** (Priority: MEDIUM)

- **Status Polling:**
  - Poll every 3-5 seconds while status is `joining`, `active`, or `processing`
  - Stop polling when status is `ready`, `failed`, or `completed`

- **Background Updates:**
  - Continue polling in foreground only
  - Show notification when meeting ready

---

### 6. **Integration Points** (Priority: LOW)

#### Existing Echo App:
- Add "Meeting AI" tab to main TabView
- Reuse existing audio player for playback
- Reuse transcript viewer components
- Share API authentication

---

## Implementation Steps

### Phase 1: Backend Integration (2-3 hours)
1. ✅ Create `LiveMeetingSession` model
2. ✅ Create `MeetingAPIClient` with endpoints
3. ✅ Add URL validator
4. ✅ Write unit tests

### Phase 2: Basic UI (3-4 hours)
1. ✅ Create `MeetingSetupView` with URL input
2. ✅ Create `ActiveMeetingView` with status
3. ✅ Create `MeetingLibraryView` list
4. ✅ Add navigation flow

### Phase 3: State Management (2-3 hours)
1. ✅ Create `MeetingViewModel`
2. ✅ Implement polling logic
3. ✅ Handle error states
4. ✅ Persist active sessions

### Phase 4: Polish & Testing (2-3 hours)
1. ✅ Add animations and transitions
2. ✅ Improve error messaging
3. ✅ Add loading states
4. ✅ Integration testing
5. ✅ UI/UX refinements

### Phase 5: Advanced Features (Optional)
1. ⏸️ Push notifications when meeting ready
2. ⏸️ Calendar integration
3. ⏸️ Auto-join scheduled meetings

---

## Technical Notes

### API Request Example:
```json
POST /api/v1/live-meetings
{
  "title": "Product Sync Meeting",
  "meeting_url": "https://meet.google.com/abc-defg-hij",
  "language": "uz"
}

Response:
{
  "id": "live_abc123",
  "title": "Product Sync Meeting",
  "language": "uz",
  "status": "starting",
  "created_at": "2024-10-30T12:00:00Z",
  "updated_at": "2024-10-30T12:00:00Z"
}
```

### Polling Strategy:
```swift
func pollSession(id: String) async {
    while true {
        let session = try await apiClient.getLiveMeeting(id: id)
        
        switch session.status {
        case .ready, .failed, .completed:
            return // Stop polling
        case .starting, .joining, .active, .processing:
            try await Task.sleep(for: .seconds(3))
        default:
            try await Task.sleep(for: .seconds(5))
        }
    }
}
```

---

## File Structure

```
iOS/Echo/
├── API/
│   └── MeetingAPIClient.swift (NEW)
├── Models/
│   └── LiveMeetingSession.swift (NEW)
├── ViewModels/
│   └── MeetingViewModel.swift (NEW)
├── Views/
│   ├── MeetingSetupView.swift (NEW)
│   ├── ActiveMeetingView.swift (NEW)
│   └── MeetingLibraryView.swift (NEW)
└── Utils/
    └── MeetingURLValidator.swift (NEW)
```

---

## Next Steps
1. Tasdiqlash: Reja to'g'rimi?
2. Qaysi Phase'dan boshlashimiz kerak?
3. Qo'shimcha talablar bormi?
