import Foundation
import UserNotifications
import AppKit

/// Posts a notification when an agent run finishes while the app is in the background.
///
/// Runs are long, so people switch away and wait. Notifying only when the app is not
/// frontmost is the point: alerting someone about something they are already looking
/// at is noise, and noisy apps get their notifications turned off.
@MainActor
final class RunNotifier {
    static let shared = RunNotifier()

    private var hasRequestedAuthorization = false

    private init() {}

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // A refusal is a legitimate answer; the app must keep working either way.
        }
    }

    func runFinished(threadTitle: String, summary: String?) {
        guard !NSApplication.shared.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = threadTitle
        content.body = summary?.singleLineNotificationPreview() ?? "The run finished."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil     // Deliver immediately.
        )
        UNUserNotificationCenter.current().add(request)
    }

    func runFailed(threadTitle: String, message: String) {
        guard !NSApplication.shared.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(threadTitle) — failed"
        content.body = message.singleLineNotificationPreview()
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

private extension String {
    func singleLineNotificationPreview(limit: Int = 180) -> String {
        let collapsed = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
