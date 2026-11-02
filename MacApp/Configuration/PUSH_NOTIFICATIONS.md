# Echo server push

Echo uses native macOS alerts (`UserNotifications`). Update notices are local
and work without APNs. Important alerts and news use the authenticated backend
and APNs; the in-app account inbox remains available in non-push builds.

## Apple setup and Release packaging

Use the explicit App ID **`uz.voicelab.desktop`** with Push Notifications enabled
for the same paid Apple team that signs Echo. Download a **Developer ID**
provisioning profile with production APNs and the selected Developer ID
Application certificate. An APNs `.p8` key belongs only on the backend; it is not
needed on the release Mac.

Debug and default Release keep `Configuration/Voicelab.entitlements` (microphone
only). The app enables its remote-push service only when the actual executable
has a signed APNs entitlement. To opt into a push-enabled distribution build,
set these values alongside the normal CDN release configuration:

```sh
export ECHO_PUSH_ENABLED=1
export ECHO_PUSH_PROFILE="$HOME/Library/Developer/Echo/Echo_Developer_ID_Push.provisionprofile"
./scripts/release.sh check
./scripts/release.sh all 2.0.0 BUILD_NUMBER
```

Keep that file outside the source checkout. `check` verifies the CMS signature,
Apple certificate trust chain, exact team and app ID, production APNs, expiration,
Developer ID distribution constraints, and membership of the configured signing
certificate. `build` snapshots the validated bytes and installs the profile in
Xcode's user provisioning-profile directory, preserving Apple's exact UUID
spelling because Xcode's profile lookup is case-sensitive. Archive/export use an app-target-only
profile setting; the wake helper and Sparkle components do not receive APNs
entitlements. Export names the profile explicitly, and every later verification
requires both the exact embedded profile and production signed entitlement.
A missing, expired, changed, incorrectly signed or mismatched profile stops the
release; it never falls back to a non-push build. Keep the same profile/configuration
when resuming an interrupted release.

The CMS helper uses macOS trust services and may need permission to access them
when a build is run inside a sandbox. It checks the local trusted Apple chain
without fetching missing certificates from the network. Future Apple signing
root changes require a reviewed verifier update, not bypassing validation.

Do not add keychain-sharing or app-group entitlements for notifications. Echo's
bundle ID, signing team, Keychain service/account names and storage behavior stay
unchanged. For the first push-enabled upgrade, compare the prior and new signed
designated requirements/entitlements and verify the existing account restores.

Never put `.p8`, provisioning profiles, private keys or certificate exports in
Git, app resources or chat. The required **embedded provisioning profile** is
public signed metadata, not the backend APNs key.

## Backend configuration

The topic/category/preferences contract requires migration **237** in addition
to the original **225–226**. First deploy compatible backend code with expansion
migrations while retaining the legacy provider topic or leaving APNs disabled.
Confirm deployment state records `desktop_push_version: 2`. Activating the new
topic is a separate reviewed step; the backend's monotonic topic-routing guard
then prevents fallback to legacy source or a legacy rollback. Follow the latest
`back/docs/desktop-push.md` deployment and recovery instructions.

Mount the key as a read-only secret, then configure the API process for the
reviewed Echo-topic activation:

```sh
ECHO_APNS_TEAM_ID=<Apple-Team-ID>
ECHO_APNS_KEY_ID=<APNs-Key-ID>
ECHO_APNS_TOPIC=uz.voicelab.desktop
ECHO_APNS_KEY_FILE=/run/secrets/echo-apns.p8
```

No configured values means push is unavailable but the API continues normally.
Partial/invalid configuration fails startup clearly. The provider uses HTTP/2
and caches its ES256 JWT for 50 minutes. Outbound access to Apple's production
and sandbox APNs endpoints on port 443 is required.

## User flow

Settings → **Notifications** → **Enable notifications** is the explicit shared
macOS permission action. Startup, sign-in and category changes never prompt.
After permission is granted, updates, important alerts and news default to on;
each has its own opt-out. Existing authorized users can register automatically
on activation. A denied permission offers System Settings instead of repeatedly
requesting consent.

Update notices are silent, deduplicated by channel/build, and suppressed during
foreground use, manual update checks, recording, onboarding, unsaved work or
installation. Clicking one opens the existing update UI; it never installs an
update. Old installed-build and other-channel notices are removed at startup.

Remote registration always supplies `topic: "uz.voicelab.desktop"` and
`preferences: {important: true, news: true}` (using the user's actual choices).
Deploy the topic/category/preferences-capable backend before releasing this
client. Never retry a registration by omitting `topic`: older clients use the
legacy `com.screensaver.Voicelab` topic, and a current Echo token must not be
assigned to that provider. Categories are `important` or `news`; missing category
means important for compatibility. Device opt-outs suppress native banners,
while inbox history remains visible.

The token belongs to a server-validated desktop session, not a user ID supplied
by the client. Expired/revoked sessions and disabled users are excluded from
delivery. Token rotation retires the previous token. Logout unregisters the
native client and clears only that account's remote alerts; it preserves local
update notices. Disabling all remote categories awaits in-flight registration
before deleting the subscription. Transient registration errors appear in
Settings with retry; activation also retries without continuous polling.

## Inbox and admin console

The workspace bell opens Echo’s account-bound inbox with unread count, dates,
click-through navigation and mark-all-read. The app fetches on activation,
opening the inbox and foreground push receipt; it does not poll continuously.
Read state is stored on the server and follows the account across Macs. Fetches
are coalesced and pagination uses a server cursor. Mark-all-read uses a snapshot
watermark so a later notification stays unread. Logout clears the visible inbox.
System alerts retain the native macOS appearance.

The admin composer is a separate, pending admin-project change. Do not assume
recipient search, preview or campaign progress UI is deployed. The backend send
API requires `desktop_push:send`; default staff groups do not receive it
automatically. Confirm the current admin implementation and review the exact
test audience/message before sending. Real operator-to-device delivery remains
a release smoke test after backend, admin and signed-client deployment.

API contract and queue operations: `back/docs/desktop-push.md`.
Allowed destinations: `home`, `notes`, `vocabulary`, `settings`. No external URLs
or remote commands. Clicks require the matching account; cold-launch clicks wait
for session restoration. Use non-sensitive announcements, never dictated text
or note contents: an already in-flight native banner cannot be recalled at logout.

Delivery is asynchronous with bounded workers, durable PostgreSQL jobs and
retry/backoff for explicit temporary APNs rejections. This reduces server-side
waiting but does not guarantee immediate delivery: Focus mode, connectivity and
Apple policy still apply. Offline users can read stored messages in the inbox.

## Validation

```sh
SWIFT_MACRO_SANDBOX_DISABLED=1 zsh scripts/test-push-notifications.sh
SWIFT_MACRO_SANDBOX_DISABLED=1 zsh scripts/test-notification-inbox.sh
# In the backend:
go test -race ./internal/desktoppush -run 'Test(Delivery|APNs|CampaignAudience|Push)'
go test ./internal/httpapi -run '^TestDesktopPushUnavailableDoesNotPanic$'
# With a disposable PostgreSQL test database configured:
go test ./internal/desktoppush -run TestCampaignQueuePostgres
go test ./internal/httpapi -run '^TestDesktopPushHTTPContract$'
```

For device verification, use the signed push-enabled distribution build: enable
notifications explicitly, then send a test to a consenting test account. Click
while foreground/background/quit, deny permission, opt out of each category,
and log out/switch accounts. Verify no cross-account routing and that local
update notices survive sign-out. Test a background update alert and cold-launch
click separately, including an active recording and an installed-build cleanup.
Focus mode and Apple delivery policy can suppress banners. No real notification
is sent by unit tests. Provisioning regression checks run with
`python3 Tests/PushProfileRegression.py`; `scripts/test-release.sh` also checks
that normal non-push packaging still works and required push cannot fall back.

Apple references:
- https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns
- https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
- https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
- https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- https://www.apple.com/certificateauthority/
