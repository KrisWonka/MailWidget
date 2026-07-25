import SwiftUI
import AppKit

/// Three-step first-run guide: grant Full Disk Access, start automatic refresh,
/// add the widget to the desktop. Hosted in a plain `NSWindow` created by
/// `AppDelegate` (this is an `LSUIElement` menu bar app with no default window).
struct OnboardingView: View {
    @State private var probeReport = ProviderProbe.run()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to MailWidget")
                    .font(.title2.bold())
                Text("Three quick steps to get unread mail on your desktop.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            OnboardingStepRow(
                number: 1,
                title: "Grant Full Disk Access",
                detail: "MailWidget reads Mail's local database to show unread counts instantly.",
                isDone: probeReport.envelopeIndexAvailable
            ) {
                Button("Open System Settings…") {
                    openPrivacySettings()
                }
            }

            OnboardingStepRow(
                number: 2,
                title: "Start automatic refresh",
                detail: "MailWidget checks for new mail in the background on the interval you choose in Settings.",
                isDone: true
            ) {
                Button("Refresh Now") {
                    Task { _ = await RefreshScheduler.shared.refreshNow() }
                }
            }

            OnboardingStepRow(
                number: 3,
                title: "Add the widget to your desktop",
                detail: "Right-click your desktop, choose Edit Widgets…, search \u{201C}MailWidget\u{201D}, then drag it onto your desktop.",
                isDone: false
            ) {
                EmptyView()
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    closeWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 460)
        .onAppear {
            probeReport = ProviderProbe.run()
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

private struct OnboardingStepRow<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let isDone: Bool
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 26, height: 26)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                action()
            }
        }
    }
}
