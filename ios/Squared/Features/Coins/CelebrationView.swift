import SwiftUI

/// S6: shown once per rewarded settlement or first win; auto-dismisses after 4 s; never blocks.
struct CelebrationView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let celebration: Celebration
    @State private var appear = false
    @State private var burst = false
    @State private var showOdds = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea().onTapGesture { state.dismissCelebration() }
            VStack(spacing: 18) {
                ZStack {
                    if !reduceMotion { CoinBurst(active: burst) }
                    CoinGlyph(size: 84).scaleEffect(appear ? 1 : 0.4)
                }
                .frame(height: 170)
                Text("+\(celebration.coins) coins").font(Theme.number(40)).foregroundStyle(Theme.coin)
                Text(celebration.title).font(Theme.body(17, .semibold)).multilineTextAlignment(.center)
                if let m = celebration.bonusMultiplier, celebration.bonusCoins > 0 {
                    Text("Surprise: \(m)x bonus!  +\(celebration.bonusCoins) more")
                        .font(Theme.body(16, .heavy)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.coin)
                }
                if celebration.kind == "SETTLEMENT" {
                    Button("How bonuses work") { showOdds = true }.font(Theme.body(13)).underline().foregroundStyle(Theme.muted)
                }
                HStack(spacing: 12) {
                    NeoPopButton(title: "My coins", style: .elevatedCoin, parent: Theme.UI.surface) {
                        state.dismissCelebration()
                        state.open(.wallet)
                    }
                    NeoPopButton(title: "Done", style: .stroke, parent: Theme.UI.surface) { state.dismissCelebration() }
                }
                .padding(.top, 6)
            }
            .padding(24)
            .neoPopCard(color: Theme.UI.surface, edge: Theme.UI.coin, depth: 7, padding: 8)
            .padding(24)
            .opacity(appear ? 1 : 0)
        }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .spring(duration: 0.6, bounce: 0.4)) { appear = true }
            if !reduceMotion { withAnimation(.easeOut(duration: 0.6)) { burst = true } }
            var text = "You earned \(celebration.coins) coins. \(celebration.title)."
            if celebration.bonusCoins > 0 { text += " Surprise bonus, \(celebration.bonusCoins) more." }
            state.announce(text)
        }
        .task {
            try? await Task.sleep(for: .seconds(4))
            if !showOdds && state.celebration?.id == celebration.id { state.dismissCelebration() }
        }
        .sheet(isPresented: $showOdds) { BonusOddsSheet() }
    }
}

/// 600 ms burst of coins radiating from the centre.
struct CoinBurst: View {
    let active: Bool
    private let count = 14
    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let angle = Double(i) / Double(count) * 2 * .pi
                CoinGlyph(size: CGFloat(10 + (i % 3) * 4))
                    .offset(x: active ? cos(angle) * 110 : 0, y: active ? sin(angle) * 80 : 0)
                    .opacity(active ? 0 : 1)
                    .animation(.easeOut(duration: 0.6).delay(Double(i % 4) * 0.02), value: active)
            }
        }
    }
}

/// Published odds (honest economy; FR-4).
struct BonusOddsSheet: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let s = state.config?.surprise
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("How bonuses work")
            Text("Every confirmed settlement has a chance of a surprise bonus. It's free: no purchase, nothing at stake.")
                .font(Theme.body(15))
            oddsRow("2x coins", s?.p2x ?? 0.15)
            oddsRow("3x coins", s?.p3x ?? 0.05)
            oddsRow("No bonus", 1 - (s?.pAny ?? 0.20))
            Text("The draw happens once per payment on our server, so retrying can't change it.")
                .font(Theme.body(12)).foregroundStyle(Theme.muted)
            Text("Coins have no cash value. Apple is not a sponsor of, and is not involved in, this programme.")
                .font(Theme.body(12)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationBackground(Theme.bg)
    }

    private func oddsRow(_ label: String, _ p: Double) -> some View {
        HStack {
            Text(label).font(Theme.body(15, .semibold))
            Spacer()
            Text("\(Int((p * 100).rounded()))%").font(Theme.body(15, .heavy))
        }
        .padding(.vertical, 6)
    }
}
