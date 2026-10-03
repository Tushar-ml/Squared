import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationManager.shared.configure()
        return true
    }
}

@main
struct RoommateCoinsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .preferredColorScheme(.dark)
                .tint(Theme.text)
                .onOpenURL { state.handle(url: $0) }
                .task { await state.bootstrap() }
                .onChange(of: phase) { _, p in
                    if p == .active {
                        NotificationManager.shared.startPolling()
                        OfflineQueue.shared.flush()
                        Task { await state.refreshConfig(); await state.refreshCoins() }
                    } else if p == .background {
                        NotificationManager.shared.stopPolling()
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
            if !state.signedIn {
                PhoneEntryView()
            } else if state.needsProfile {
                ProfileSetupView()
            } else {
                HomeView()
            }
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
