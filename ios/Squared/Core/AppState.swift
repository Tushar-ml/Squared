import Foundation
import Observation
import Security
import SwiftUI

enum Route: Hashable {
    case group(Int)
    case expense(Int)
    case wallet
    case household(Int)
    case settle(Int)
    case insights(Int)
    case mySpending
    case groupSettings(Int)
    case recurring(Int)
    case search(Int)
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
        token = "local"     // offline app: there are no accounts or sessions
        NotificationCenter.default.addObserver(forName: .coinsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshCoins() }
        }
    }

    var signedIn: Bool { user != nil }
    var coinValue: Double { config?.coinValueInr ?? 0.25 }
    var coinsLive: Bool { (config?.enabled ?? true) && !(config?.killSwitch ?? false) && !(user?.hideCoins ?? false) }

    func bootstrap() async {
        await refreshConfig()
        #if DEBUG
        await DebugAutomation.run(self)
        #endif
        guard onboarded else { return }      // the walkthrough comes first; it calls startLocal()
        await startLocal()
    }

    /// Load (or create) you, the one person using this app, and add any recurring bills that are due.
    func startLocal() async {
        LocalAPI.shared.ensureMe()
        user = try? await api.request("GET", "/me")
        needsProfile = user?.name.isEmpty ?? true
        await LocalAPI.shared.runDueRecurring()
        await refreshCoins()
        await refreshActivation()
        NotificationManager.shared.requestAuthorization()   // for recurring-bill and budget alerts
    }

    /// After "Erase all data": back to a fresh start.
    func resetAfterErase() {
        WidgetSnapshot.clear()
        user = nil
        balance = nil
        path = []
        onboarded = false
    }

    func refreshActivation() async {
        if let a: Activation = try? await api.request("GET", "/me/activation") { activation = a }
    }

    /// Where a brand-new account goes after profile setup.
    func routeAfterProfile() async {
        await refreshActivation()
        if activation?.group == nil { showFlatSetup = true }
    }

    func refreshConfig() async {
        if let c: CoinConfig = try? await api.request("GET", "/config/coins") {
            if config?.killSwitch == false && c.killSwitch { api.track("kill_switch_observed") }
            config = c
        }
    }

    func refreshCoins(celebrate: Bool = true) async {
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
        guard url.scheme == "squared" else { return }
        #if DEBUG
        if DebugAutomation.handle(url, self) { return }
        #endif
        // squared://open?route=group&id=3 (the widget uses route=home)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = q.first { $0.name == "id" }?.value.flatMap(Int.init)
        switch q.first(where: { $0.name == "route" })?.value {
        case "group": if let id { open(.group(id)) }
        case "expense": if let id { open(.expense(id)) }
        case "wallet": open(.wallet)
        default: break
        }
    }

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
