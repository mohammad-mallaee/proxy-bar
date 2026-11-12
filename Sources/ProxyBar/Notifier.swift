import AppKit
import UserNotifications

/// Posts macOS notifications.
///
/// Uses UserNotifications when running as a real .app bundle. If that's not
/// possible (e.g. under `swift run`, or the system refuses an ad-hoc signed
/// app), falls back to AppleScript's `display notification`. If you turned
/// ProxyBar's notifications off in System Settings, nothing is shown.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// UNUserNotificationCenter crashes outside an app bundle.
    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func setUp() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    @discardableResult
    func requestPermission() async -> Bool {
        guard canUseUserNotifications else { return false }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func post(title: String, body: String) {
        Task {
            guard canUseUserNotifications else {
                fallback(title: title, body: body)
                return
            }
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                await requestPermission()
                status = await center.notificationSettings().authorizationStatus
            }
            switch status {
            case .authorized, .provisional, .ephemeral:
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                do {
                    try await center.add(request)
                } catch {
                    fallback(title: title, body: body)
                }
            case .denied:
                break // respect the user's choice
            default:
                fallback(title: title, body: body)
            }
        }
    }

    private func fallback(title: String, body: String) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title))"]
        try? process.run()
    }

    // Show banners even while ProxyBar's menu is open (the app is "active" then).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
