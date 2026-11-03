import Foundation
import AVFoundation

@main struct OnboardingRecoveryRegression {
    @MainActor static func main() async {
        let suite = "Echo.Recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = OnboardingJourney(defaults: defaults)
        first.restore(owner: nil, permissionsReady: false)
        precondition(first.route == .welcome)
        first.navigate(.permissions)
        let reopened = OnboardingJourney(defaults: defaults)
        reopened.restore(owner: nil, permissionsReady: false)
        precondition(reopened.route == .permissions, "Permission restart must keep its place.")
        for route in [OnboardingJourney.Route.microphone, .shortcut, .alphabet, .signIn] {
            first.navigate(route)
            reopened.restore(owner: nil, permissionsReady: true)
            precondition(reopened.route == route)
        }
        first.navigate(.shortcut)
        first.requirePermissions()
        first.requirePermissions()
        reopened.restore(owner: nil, permissionsReady: false)
        precondition(reopened.route == .permissions)
        reopened.continueAfterPermissions()
        precondition(reopened.route == .shortcut,
                     "Repeated permission checks and a restart must preserve the interrupted Fn step.")
        first.signedIn(owner: "account-a")
        first.navigate(.practice)
        first.recordVoiceSuccess()
        reopened.restore(owner: "account-a", permissionsReady: true)
        precondition(reopened.route == .practice && reopened.triedVoice)
        reopened.restore(owner: "account-b", permissionsReady: true)
        precondition(reopened.route == .welcome && !reopened.triedVoice, "Never transfer another account's trial.")
        reopened.restore(owner: "account-a", permissionsReady: false)
        precondition(reopened.route == .permissions, "A saved checkpoint never grants a revoked OS permission.")

        let permissionRestart = OnboardingJourney(defaults: defaults)
        permissionRestart.restore(owner: "account-a", permissionsReady: true)
        precondition(permissionRestart.route == .permissions)
        permissionRestart.continueAfterPermissions()
        precondition(permissionRestart.route == .practice, "After granting access, resume the interrupted step.")

        let savedProgress = defaults.data(forKey: "echo.onboarding.v2.account-a")
        let guestProgress = defaults.data(forKey: "echo.onboarding.v2.guest")
        let review = OnboardingJourney(defaults: defaults, persistsProgress: false)
        review.restore(owner: "account-a", permissionsReady: true)
        precondition(review.route == .welcome && !review.triedVoice, "Review starts at the beginning.")
        review.navigate(.microphone)
        review.signedIn(owner: "account-a")
        review.recordVoiceSuccess()
        precondition(defaults.data(forKey: "echo.onboarding.v2.account-a") == savedProgress)
        precondition(defaults.data(forKey: "echo.onboarding.v2.guest") == guestProgress,
                     "Review must not overwrite checkpoints or clear the guest journey.")

        // Model an OS trust result that remains false after permission changes,
        // while a real cross-process AX request starts succeeding. Both paths
        // must unlock onboarding without persisting a grant or prompting again.
        var trustResult = false
        var liveAccess = false
        var probes = 0
        let access = AccessibilityAccess(trusted: { trustResult }, probe: {
            probes += 1
            return liveAccess
        })
        precondition(!access.isGranted)
        liveAccess = true
        precondition(access.isGranted, "A stale false must not block working macOS access.")
        liveAccess = false
        precondition(!access.isGranted, "A previous successful probe must not cache a grant.")
        trustResult = true
        let previousProbes = probes
        precondition(access.isGranted && probes == previousProbes, "Normal grants use the fast OS check.")
        trustResult = false

        var mic = AVAuthorizationStatus.notDetermined
        var ax: Bool {
            get { access.isGranted }
            set { liveAccess = newValue }
        }
        var requests = 0
        var controlRequests = 0
        var urls: [URL] = []
        var opens = true
        let permissions = OnboardingPermissionsService(microphoneStatus: { mic }, accessibilityStatus: { ax },
            requestAudio: { requests += 1; mic = .denied }, requestControl: { controlRequests += 1 },
            openURL: { urls.append($0); return opens })
        await permissions.request(.microphone)
        precondition(requests == 1 && !permissions.ready && permissions.allowed.isEmpty)
        await permissions.request(.microphone)
        precondition(requests == 1 && urls.last?.absoluteString.hasSuffix("Privacy_Microphone") == true)
        mic = .restricted
        permissions.refresh()
        let count = urls.count
        await permissions.request(.microphone)
        precondition(urls.count == count && requests == 1, "Do not repeatedly prompt a managed restriction.")
        mic = .authorized; permissions.refresh()
        precondition(permissions.allowed == [.microphone] && !permissions.ready)
        let urlsBeforePrompt = urls.count
        await permissions.request(.accessibility)
        precondition(controlRequests == 1 && !permissions.ready && permissions.accessibilityRequested,
                     "A native prompt isn't an OS grant.")
        precondition(urls.count == urlsBeforePrompt, "Do not hide the native permission dialog behind Settings.")
        await permissions.request(.accessibility)
        precondition(controlRequests == 1 && urls.last?.absoluteString.hasSuffix("Privacy_Accessibility") == true,
                     "A second click opens Settings without stacking native prompts.")
        permissions.recheckAccessibility()
        precondition(permissions.accessibilityRecheckFailed && !permissions.ready,
                     "An enabled-looking Settings entry is not proof that this signed build is trusted.")
        ax = true; permissions.refresh()
        precondition(permissions.ready && !permissions.accessibilityRecheckFailed,
                     "A real grant must clear recovery guidance and unlock Continue without restarting.")
        await permissions.request(.accessibility)
        precondition(controlRequests == 1 && permissions.ready, "A grant must not prompt again.")
        ax = false; opens = false
        await permissions.request(.accessibility)
        precondition(!permissions.ready && permissions.settingsFailed)
        print("PASS: restart at every setup step, account isolation, restored trial, permission revocation, denial/settings routing, restrictions, real-status gating and failed Settings launch.")
    }
}
