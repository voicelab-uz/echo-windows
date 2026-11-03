import SwiftUI

struct UpdateSettingsSection: View {
    @Bindable var updates: AppUpdateChecker

    var body: some View {
        SettingsSection("Software updates", footer: "Updates install when Echo quits. Recording and unsaved work are protected.") {
            SettingsGroup {
                SettingsRow("Echo", verbatimDetail: updates.statusTitle) {
                    HStack(spacing: 10) {
                        if [.checking, .downloading, .verifying, .installing].contains(updates.phase) {
                            ProgressView().controlSize(.small).accessibilityLabel(updates.statusTitle)
                        }
                        Button(updates.actionTitle, action: updates.check)
                            .disabled(!updates.canCheck || updates.isInstalling)
                    }
                }
                if updates.isConfigured {
                    Divider()
                    SettingsRow("Automatically check for updates") {
                        Toggle(AppLocalization.text("Automatically check for updates"), isOn: $updates.automaticallyChecks)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    SettingsRow("Download and install automatically", detail: "Install verified updates the next time you quit Echo.") {
                        Toggle(AppLocalization.text("Download and install automatically"), isOn: $updates.automaticallyInstalls)
                            .labelsHidden().toggleStyle(.switch).disabled(!updates.automaticallyChecks)
                    }
                }
                if let message = updates.errorMessage {
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
                        .accessibilityLabel(AppLocalization.text("Update status") + ": " + message)
                } else if updates.hasPendingInstallation, let blocker = updates.blockingMessage {
                    Text(blocker).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
                }
            }
        }
    }
}
