import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationManager.shared.configure()
        application.registerForRemoteNotifications()   // APNs token goes to the backend when push is configured
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "apnsToken")
        Task { try? await APIClient.shared.raw("POST", "/me/devices", body: ["token": token, "platform": "ios"]) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator / no push entitlement: local delivery via /me/notifications/deliver keeps working.
    }
}

@main
struct SquaredApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .preferredColorScheme(state.appearance.scheme)
                .tint(Theme.text)
                .onOpenURL { state.handle(url: $0) }
                .task {
                    if state.faceIDEnabled && state.signedIn == false && Keychain.read("token") != nil { state.locked = true }
                    await state.bootstrap()
                }
                .onChange(of: phase) { _, p in
                    if p == .active {
                        NotificationManager.shared.startPolling()
                        OfflineQueue.shared.flush()
                        Task { await state.refreshConfig(); await state.refreshCoins() }
                    } else if p == .background {
                        NotificationManager.shared.stopPolling()
                        if state.faceIDEnabled && state.signedIn { state.locked = true }
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        ZStack {
            Theme.bg.ignoresSafeArea()
            if !state.signedIn && !state.onboarded {
                WalkthroughView { withAnimation { state.onboarded = true } }
                    .transition(.opacity)
            } else if !state.signedIn {
                PhoneEntryView()
            } else if state.needsProfile {
                ProfileSetupView()
            } else {
                MainTabs()
            }
            if state.locked { LockScreen().transition(.opacity).zIndex(10) }
            if let toast = state.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(Theme.body(14, .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Theme.surfaceHigh)
                        .overlay(Rectangle().stroke(Theme.line))
                        .padding(.bottom, 90)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .animation(.easeOut, value: state.toast)
            }
        }
        .fullScreenCover(isPresented: $state.showFlatSetup) { FlatSetupFlow() }
        .fullScreenCover(item: $state.celebration) { c in
            CelebrationView(celebration: c)
                .presentationBackground(.clear)
        }
        .sheet(isPresented: Binding(get: { state.pendingJoinToken != nil && state.signedIn && !state.needsProfile },
                                    set: { if !$0 { state.pendingJoinToken = nil } })) {
            JoinGroupSheet(token: state.pendingJoinToken ?? "")
                .presentationDetents([.medium])
        }
    }
}
