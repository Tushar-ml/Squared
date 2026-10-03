import SwiftUI

/// First-launch walkthrough, before sign-in. Each slide shows the real UI it describes,
/// so the first time a user meets a confirm card or household ring it already feels familiar.
/// Also covers S10 (earn, confirm, redeem), so the in-group intro is skipped afterwards.
struct WalkthroughView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    let onDone: () -> Void

    private let slides: [(label: String, title: String, body: String)] = [
        ("Split", "Shared bills,\nminus the chasing", "Rent, wifi, groceries. Log it once and everyone in the flat sees their share."),
        ("Confirm", "Roommates agree\nin one tap", "No more \"did you see my message?\". A quick Confirm and the expense is settled as fair."),
        ("Together", "Keep the flat square,\nearn together", "Confirming and settling up earn coins. Hit the weekly goal and the whole flat gets a bonus."),
        ("Spend", "Coins become\nvouchers", "Groceries, food, broadband. 4 coins = INR 1, and your first voucher is just 100 coins."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    CoinGlyph(size: 22)
                    Text("ROOMMATE COINS").font(.system(size: 13, weight: .black)).tracking(1.6)
                }
                Spacer()
                Button("Skip") { finish(skipped: true) }
                    .font(Theme.body(15, .semibold)).foregroundStyle(Theme.muted).frame(minHeight: 44)
                    .opacity(page < slides.count - 1 ? 1 : 0)       // keep the header height stable
                    .disabled(page == slides.count - 1)
            }
            .padding(.horizontal, 24)

            if state.pendingJoinToken != nil {
                HStack(spacing: 10) {
                    Image(systemName: "envelope.open.fill").foregroundStyle(Theme.onAccent)
                    Text("You've been invited to a flat. Sign up to join.").font(Theme.body(14, .bold)).foregroundStyle(Theme.onAccent)
                    Spacer()
                }
                .padding(12).background(Theme.coin)
                .padding(.horizontal, 24).padding(.top, 8)
            }

            TabView(selection: $page) {
                ForEach(slides.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 18) {
                        Spacer(minLength: 8)
                        demo(i)
                            .frame(maxWidth: .infinity)
                            .frame(height: 250)
                        Spacer(minLength: 8)
                        SectionLabel("\(i + 1) · \(slides[i].label)", color: Theme.coin)
                        Text(slides[i].title).font(Theme.title(32)).fixedSize(horizontal: false, vertical: true)
                        Text(slides[i].body).font(Theme.body(16)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 24)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(reduceMotion ? nil : .snappy, value: page)

            VStack(spacing: 14) {
                PageBars(count: slides.count, current: page)
                NeoPopFloatingButton(title: page < slides.count - 1 ? "Next" : "Get started") {
                    if page < slides.count - 1 { page += 1 } else { finish(skipped: false) }
                }
                Button("I already have an account") { finish(skipped: true) }
                    .font(Theme.body(14, .semibold)).foregroundStyle(Theme.muted).frame(minHeight: 44)
            }
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .background(Theme.bg)
        .onAppear { APIClient.shared.track("onboarding_viewed") }
    }

    private func finish(skipped: Bool) {
        if !skipped { APIClient.shared.track("onboarding_completed", props: ["last_page": page]) }
        onDone()
    }

    @ViewBuilder
    private func demo(_ i: Int) -> some View {
        switch i {
        case 0: DemoExpenseCard()
        case 1: DemoConfirmCard()
        case 2: DemoHouseholdCard()
        default: DemoVoucherCard()
        }
    }
}

struct PageBars: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Rectangle().fill(i <= current ? Theme.text : Theme.line).frame(height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Slide demos (static replicas of real screens)

private struct DemoExpenseCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([("Rent", "INR 36,000", "INR 12,000"), ("Wifi bill", "INR 799", "INR 266"), ("Groceries", "INR 1,200", "INR 400")],
                    id: \.0) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(Theme.body(15, .bold))
                        Text("your share \(row.2)").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(row.1).font(Theme.body(15, .heavy))
                }
                .padding(12).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DemoConfirmCard: View {
    @State private var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rahul added Wifi bill").font(Theme.body(16, .bold))
            Text("INR 799 · your share INR 266").font(Theme.body(13)).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .black))
                    Text(confirmed ? "CONFIRMED" : "CONFIRM +2").font(.system(size: 13, weight: .heavy))
                }
                .foregroundStyle(Theme.bg)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(confirmed ? Theme.owed : Theme.text)
                Text("NOT RIGHT").font(.system(size: 13, weight: .heavy))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Rectangle().stroke(Theme.text))
            }
            HStack(spacing: 6) {
                Avatar(name: "Aman", tick: true, size: 26); Avatar(name: "Priya", tick: confirmed, size: 26)
                Text(confirmed ? "Everyone agrees" : "Aman confirmed").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
        }
        .neoPopCard(depth: 5)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.spring) { confirmed.toggle() }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DemoHouseholdCard: View {
    @State private var progress = 3
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(Strings.thisWeekTogether, color: progress >= 5 ? Theme.coin : Theme.muted)
            HStack(spacing: 16) {
                ProgressRing(progress: progress, target: 5, met: progress >= 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.confirmedOf(progress, 5)).font(Theme.body(16, .bold))
                    Text(progress >= 5 ? Strings.goalMet(120) : Strings.reachGoal(5, 120))
                        .font(Theme.body(13)).foregroundStyle(progress >= 5 ? Theme.coin : Theme.muted)
                }
            }
            HStack(spacing: 8) {
                ForEach(["A", "P", "R"], id: \.self) { Avatar(name: $0, tick: true, size: 30) }
            }
        }
        .neoPopCard(color: Theme.UI.surface, edge: progress >= 5 ? Theme.UI.coin : Theme.UI.edge, depth: 6)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation { progress = progress >= 5 ? 3 : progress + 1 }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DemoVoucherCard: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([("FreshBasket", 25, 100), ("FoodRun", 100, 400)], id: \.0) { v in
                VStack(alignment: .leading, spacing: 8) {
                    Text(v.0).font(Theme.body(15, .heavy))
                    Text("INR \(v.1)").font(Theme.number(26))
                    HStack(spacing: 4) {
                        CoinGlyph(size: 13)
                        Text("\(v.2)").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(Theme.coin)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                .neoPopCard(color: Theme.UI.surface, edge: Theme.UI.coin, depth: 4, padding: 12)
            }
        }
        .accessibilityHidden(true)
    }
}
