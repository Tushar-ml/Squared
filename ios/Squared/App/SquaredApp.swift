import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationManager.shared.configure()   // local notifications only: recurring bills, budgets
        return true
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
                    if state.faceIDEnabled && state.onboarded { state.locked = true }
                    await state.bootstrap()
                }
                .onChange(of: phase) { _, p in
                    if p == .active {
                        Task {
                            await LocalAPI.shared.runDueRecurring()
                            await state.refreshCoins()
                            state.refreshTick += 1
                        }
                    } else if p == .background {
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
            if !state.onboarded {
                WalkthroughView {
                    withAnimation { state.onboarded = true }
                    Task { await state.startLocal() }
                }
                .transition(.opacity)
            } else if !state.signedIn {
                ProgressView()
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
    }
}
