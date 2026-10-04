import Foundation
import Observation
import Security
import SwiftUI

enum Route: Hashable {
    case group(Int)
    case expense(Int)
    case wallet
    case redeem
    case household(Int)
    case settle(Int)
    case insights(Int)
    case mySpending
    case groupSettings(Int)
    case recurring(Int)
    case search(Int)
    case chat(Int)
}

enum AppTab: Hashable { case flats, activity, coins, account }

enum Appearance: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var label: String { switch self { case .system: "System"; case .dark: "Dark"; case .light: "Light" } }
    var scheme: ColorScheme? { switch self { case .system: nil; case .dark: .dark; case .light: .light } }
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var user: User?
    /// Mirrors APIClient.token as observable state. `signedIn` must read observable values only,
    /// otherwise SwiftUI never re-renders RootView after sign-in.
    private(set) var token: String? {
        didSet { api.token = token }
    }
    var config: CoinConfig?
    var balance: Int?
    var coinsUnavailable = false
    var celebration: Celebration?
    var path: [Route] = []
    /// Invite token from a deep link. Persisted so it survives signup and app restarts.
    var pendingJoinToken: String? = UserDefaults.standard.string(forKey: "pendingJoinToken") {
        didSet { UserDefaults.standard.set(pendingJoinToken, forKey: "pendingJoinToken") }
    }
    var activation: Activation?
    var tab: AppTab = .flats
    var appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "dark") ?? .dark {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    var locked = false
    var faceIDEnabled = UserDefaults.standard.bool(forKey: "faceID") {
        didSet { UserDefaults.standard.set(faceIDEnabled, forKey: "faceID") }
    }
    var showFlatSetup = false
    var onboarded = UserDefaults.standard.bool(forKey: "onboarded") {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }
    var toast: String?
    var needsProfile = false
    var refreshTick = 0     // bump to make visible screens reload

    private var celebrationQueue: [Celebration] = []
    private var seenCelebrations = Set<String>()
    let api = APIClient.shared

    init() {
        token = Keychain.read("token")
        api.token = token
        NotificationCenter.default.addObserver(forName: .sessionExpired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.signOut(local: true) }
        }
    }

    var signedIn: Bool { token != nil && user != nil }
    var coinValue: Double { config?.coinValueInr ?? 0.25 }
    var coinsLive: Bool { (config?.enabled ?? true) && !(config?.killSwitch ?? false) && !(user?.hideCoins ?? false) }

    func bootstrap() async {
        await refreshConfig()
        #if DEBUG
        await DebugAutomation.run(self)
        #endif
        guard api.token != nil else { return }
        do {
            user = try await api.request("GET", "/me")
            needsProfile = user?.name.isEmpty ?? true
            await refreshCoins()
            await refreshActivation()
            OfflineQueue.shared.flush()
            NotificationManager.shared.requestAuthorization()   // no-op once the user has decided
        } catch let e as APIError where e.status == 401 {
            signOut(local: true)
        } catch {}
    }

    func didSignIn(_ r: AuthResponse) async {
        #if DEBUG
        print("[state] didSignIn user=\(r.user.id) isNew=\(r.isNew)")
        #endif
        Keychain.save("token", r.token)
        token = r.token
        user = r.user
        needsProfile = r.isNew || r.user.name.isEmpty
        api.flushQueuedEvents()
        if onboarded && !r.user.introSeen {
            // the walkthrough already covered the coin intro (S10); don't show it twice
            user?.introSeen = true
            Task { try? await api.raw("PATCH", "/me", body: ["intro_seen": true]) }
        }
        await refreshCoins()
        await refreshActivation()
        NotificationManager.shared.requestAuthorization()
    }

    func signOut(local: Bool = false) {
        #if DEBUG
        print("[state] signOut local=\(local)")
        #endif
        if !local { Task { try? await api.raw("POST", "/auth/logout") } }
        Keychain.delete("token")
        token = nil
        WidgetSnapshot.clear()
        user = nil
        balance = nil
        path = []
    }

    func refreshActivation() async {
        guard api.token != nil else { return }
        if let a: Activation = try? await api.request("GET", "/me/activation") { activation = a }
    }

    /// Where a brand-new account goes after profile setup.
    func routeAfterProfile() async {
        await refreshActivation()
        if pendingJoinToken != nil { return }          // JoinGroupSheet takes over
        if activation?.group == nil { showFlatSetup = true }
    }

    func refreshConfig() async {
        if let c: CoinConfig = try? await api.request("GET", "/config/coins") {
            if config?.killSwitch == false && c.killSwitch { api.track("kill_switch_observed") }
            config = c
        }
    }

    func refreshCoins(celebrate: Bool = true) async {
        guard api.token != nil else { return }
        do {
            let w: Wallet = try await api.request("GET", "/coins/wallet")
            balance = w.balance
            coinsUnavailable = false
        } catch let e as APIError where e.isCoinsUnavailable || e.isOffline {
            coinsUnavailable = true
        } catch {}
        if celebrate { await pollCelebrations() }
    }

    /// Rewards are written asynchronously by the server; poll briefly after a rewarded action.
    func expectReward() {
        Task {
            for delay in [0.8, 1.5, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                await refreshCoins()
                if celebration != nil { break }
            }
            refreshTick += 1
        }
    }

    func pollCelebrations() async {
        guard let r: CelebrationsResponse = try? await api.request("GET", "/coins/celebrations") else { return }
        for c in r.celebrations where !seenCelebrations.contains(c.id) {
            seenCelebrations.insert(c.id)
            celebrationQueue.append(c)
        }
        showNextCelebration()
    }

    func showNextCelebration() {
        guard celebration == nil, !celebrationQueue.isEmpty else { return }
        celebration = celebrationQueue.removeFirst()
    }

    func dismissCelebration() {
        if let c = celebration {
            Task { try? await api.raw("POST", "/coins/celebrations/\(c.id)/seen") }
        }
        celebration = nil
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            showNextCelebration()
        }
    }

    func handle(url: URL) {
        // Universal Link: https://<link domain>/j/<token> opens straight into the join flow
        if url.scheme == "https", url.pathComponents.count == 3, url.pathComponents[1] == "j" {
            pendingJoinToken = url.pathComponents[2]
            return
        }
        guard url.scheme == "squared" else { return }
        #if DEBUG
        if DebugAutomation.handle(url, self) { return }
        #endif
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.host == "join", let token = comps?.queryItems?.first(where: { $0.name == "token" })?.value {
            pendingJoinToken = token
        }
    }

    /// Vouchers launch later; until then the catalogue is a preview and coins just accrue.
    var redemptionLive: Bool { config?.redemption?.enabled ?? false }

    func open(_ route: Route) {
        tab = .flats
        path = [route]
    }

    func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast == text { toast = nil }
        }
    }
}

enum Keychain {
    private static let service = "app.squared.ios"

    static func save(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
