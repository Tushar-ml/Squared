import LocalAuthentication
import SwiftUI

enum AppLock {
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Covers the app until Face ID (or the passcode) succeeds.
struct LockScreen: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            CoinGlyph(size: 60)
            Text("Roommate Coins is locked").font(Theme.title(24))
            NeoPopButton(title: "Unlock", icon: "faceid") { Task { await unlock() } }.frame(width: 220)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        // Prompt as soon as the app is actually in front; a request made while backgrounded just fails.
        .task { if phase == .active { await unlock() } }
        .onChange(of: phase) { _, p in if p == .active { Task { await unlock() } } }
    }

    private func unlock() async {
        if await AppLock.authenticate(reason: "Unlock Roommate Coins") { state.locked = false }
    }
}
