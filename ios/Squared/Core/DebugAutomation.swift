#if DEBUG
import Foundation

/// DEBUG-only hooks for headless screenshots against the local stack:
///   -RCLoginPhone +919000000001   signs in with the dev OTP from backend/.env.dev
///   -RCNoFocus                    skips keyboard autofocus
///   -RCRoute wallet|redeem|group:1|expense:2|settle:1   opens a screen after launch
///   -RCNoPrompt                   don't ask for notification permission
///   squared://open?route=wallet|redeem|group|expense|settle&id=N
enum DebugAutomation {
    static let devOTP = "123456"
    static var noFocus: Bool { ProcessInfo.processInfo.arguments.contains("-RCNoFocus") }
    static var noPrompt: Bool { ProcessInfo.processInfo.arguments.contains("-RCNoPrompt") }

    @MainActor
    static func run(_ state: AppState) async {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-RCLoginPhone"), i + 1 < args.count {
            let phone = args[i + 1]
            state.signOut(local: true)
            do {
                try await APIClient.shared.raw("POST", "/auth/otp/request", body: ["phone": phone])
                let r: AuthResponse = try await APIClient.shared.request(
                    "POST", "/auth/otp/verify", body: ["phone": phone, "otp": devOTP, "device_id": APIClient.deviceId])
                await state.didSignIn(r)
                if !r.user.name.isEmpty { state.needsProfile = false }
            } catch { print("debug login failed: \(error)") }
        }
        if let i = args.firstIndex(of: "-RCRoute"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            var url = "squared://open?route=\(parts[0])"
            if parts.count > 1 { url += "&id=\(parts[1])" }
            try? await Task.sleep(for: .milliseconds(600))
            if let u = URL(string: url) { _ = handle(u, state) }
        }
    }

    @MainActor
    static func handle(_ url: URL, _ state: AppState) -> Bool {
        guard url.host == "open", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let id = Int(q["id"] ?? "") ?? 0
        switch q["route"] {
        case "wallet": state.open(.wallet)
        case "redeem": state.open(.redeem)
        case "group": state.open(.group(id))
        case "expense": state.open(.expense(id))
        case "settle": state.open(.settle(id))
        case "home": state.path = []
        case "mySpending": state.open(.mySpending)
        case "insights": state.open(.insights(id))
        case "recurring": state.open(.recurring(id))
        case "search": state.open(.search(id))
        case "chat": state.open(.chat(id))
        case "groupSettings": state.open(.groupSettings(id))
        case "activity": state.tab = .activity
        case "account": state.tab = .account
        default: return false
        }
        return true
    }
}
#endif
