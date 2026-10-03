import Foundation
import UserNotifications

/// Actionable pushes (N1 Confirm / Not right, N2 Yes got it / Not yet).
///
/// Local dev transport: the app pulls SENT notifications from /me/notifications/deliver and shows
/// them as local notifications with the same categories APNs would use. Buttons call the normal,
/// authenticated confirmation endpoints (no one-time links, PRD 8.6).
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    enum Category: String { case expenseConfirm = "EXPENSE_CONFIRM", paymentReceipt = "PAYMENT_RECEIPT" }
    enum ActionID: String { case confirm = "CONFIRM", notRight = "NOT_RIGHT", gotIt = "GOT_IT", notYet = "NOT_YET" }

    private var timer: Timer?

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let confirm = UNNotificationAction(identifier: ActionID.confirm.rawValue, title: "Confirm", options: [.authenticationRequired])
        let notRight = UNNotificationAction(identifier: ActionID.notRight.rawValue, title: "Not right", options: [.foreground])
        let gotIt = UNNotificationAction(identifier: ActionID.gotIt.rawValue, title: "Yes, got it", options: [.authenticationRequired])
        let notYet = UNNotificationAction(identifier: ActionID.notYet.rawValue, title: "Not yet", options: [.authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.expenseConfirm.rawValue, actions: [confirm, notRight], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.paymentReceipt.rawValue, actions: [gotIt, notYet], intentIdentifiers: []),
        ])
    }

    func requestAuthorization() {
        #if DEBUG
        if DebugAutomation.noPrompt { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func poll() {
        guard APIClient.shared.token != nil else { return }
        Task {
            guard let r: NotificationsResponse = try? await APIClient.shared.request("GET", "/me/notifications/deliver") else { return }
            for n in r.notifications { show(n) }
            if !r.notifications.isEmpty {
                await MainActor.run { AppState.shared.refreshTick += 1 }
            }
        }
    }

    private func show(_ n: AppNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = .default
        content.categoryIdentifier = n.payload["category"]?.stringValue ?? ""
        var info: [String: Any] = ["notification_uuid": n.id, "nid": n.notificationId]
        for (k, v) in n.payload {
            if let i = v.intValue { info[k] = i } else if let s = v.stringValue { info[k] = s }
        }
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
    }

    // Show banners while the app is open too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let uuid = info["notification_uuid"] as? String
        let expenseId = info["expense_id"] as? Int
        let paymentId = info["payment_id"] as? Int
        let groupId = info["group_id"] as? Int
        let api = APIClient.shared
        switch ActionID(rawValue: response.actionIdentifier) {
        case .confirm?:
            if let expenseId {
                _ = try? await api.raw("POST", "/expenses/\(expenseId)/confirmations", body: ["status": "CONFIRMED", "source": "push"])
                await MainActor.run { AppState.shared.expectReward() }
            }
            event(uuid, "actioned")
        case .gotIt?:
            if let paymentId {
                _ = try? await api.raw("POST", "/payments/\(paymentId)/confirmation", body: ["status": "CONFIRMED"])
                await MainActor.run { AppState.shared.expectReward() }
            }
            event(uuid, "actioned")
        case .notYet?:
            if let paymentId { _ = try? await api.raw("POST", "/payments/\(paymentId)/confirmation", body: ["status": "REJECTED"]) }
            event(uuid, "actioned")
        case .notRight?:
            event(uuid, "opened")
            if let expenseId { await MainActor.run { AppState.shared.open(.expense(expenseId)) } }
        default:
            event(uuid, "opened")
            await MainActor.run {
                let route = info["route"] as? String
                let state = AppState.shared
                if let expenseId { state.open(.expense(expenseId)) }
                else if route == "wallet" { state.open(.wallet) }
                else if route == "redeem" { state.open(.redeem) }
                else if route == "settle", let groupId { state.open(.settle(groupId)) }
                else if route == "household", let groupId { state.open(.household(groupId)) }
                else if let groupId { state.open(.group(groupId)) }
            }
        }
    }

    private func event(_ uuid: String?, _ e: String) {
        guard let uuid else { return }
        Task { try? await APIClient.shared.raw("POST", "/me/notifications/\(uuid)/event", body: ["event": e]) }
    }
}
