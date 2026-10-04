import SwiftUI

/// S7 Coins wallet.
struct WalletView: View {
    @Environment(AppState.self) private var state
    @State private var wallet: Wallet?
    @State private var entries: [LedgerEntry] = []
    @State private var cursor: String?
    @State private var unavailable = false
    @State private var loadingMore = false
    @State private var showOdds = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if unavailable {
                    CoinsUnavailable()
                } else if let w = wallet {
                    balanceCard(w)
                    Text("Coins are your own score for keeping things square: log expenses, settle up, hit weekly goals.")
                        .font(Theme.body(13)).foregroundStyle(Theme.muted)
                    if let notice = w.capNotice {
                        Text(notice.message).font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                    history
                    waysToEarn
                } else {
                    Skeleton(height: 150); Skeleton(height: 50)
                    ForEach(0..<4, id: \.self) { _ in Skeleton(height: 44) }
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Coins")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: state.refreshTick) { Task { await load() } }
        .sheet(isPresented: $showOdds) { BonusOddsSheet() }
    }

    private func balanceCard(_ w: Wallet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Coins")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CoinGlyph(size: 30)
                Text("\(w.balance)").font(Theme.number(48)).foregroundStyle(Theme.coin)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(w.balance) coins")
            if w.expiringSoon.coins > 0 {
                Text("\(w.expiringSoon.coins) coins expire on \(Format.shortDate(w.expiringSoon.date))")
                    .font(Theme.body(13, .semibold))
            }
        }
        .neoPopCard(color: Theme.UI.surface, edge: Theme.UI.coin, depth: 6, padding: 18)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("History")
            if entries.isEmpty {
                Text(Strings.walletEmpty).font(Theme.body(14)).foregroundStyle(Theme.muted).padding(.vertical, 8)
            }
            ForEach(entries) { e in
                HStack(alignment: .top, spacing: 12) {
                    Text(e.amount > 0 ? "+\(e.amount)" : "\(e.amount)")
                        .font(.system(size: 15, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(e.amount > 0 ? Theme.coin : Theme.muted)
                        .frame(width: 54, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.text).font(Theme.body(14))
                        HStack(spacing: 6) {
                            Text(Format.relative(e.createdAt)).font(Theme.body(11)).foregroundStyle(Theme.muted)
                            if e.status == "PENDING" { StatusChip(text: "In review") }
                            if e.status == "REJECTED" { StatusChip(text: "Not granted") }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                .accessibilityElement(children: .combine)
                .onAppear { if e.id == entries.last?.id { Task { await more() } } }
            }
            if loadingMore { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    private var waysToEarn: some View {
        let earn = state.config?.earn
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Ways to earn")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                way("plus.circle", "Log an expense", "+\(earn?.expenseAdder ?? 5) each")
                way("indianrupeesign.circle", "Settle up", "+\(earn?.settlePayer ?? 20), bonus chance")
                way("star", "First expense", "+\(earn?.firstWin ?? 50) once")
                way("calendar", "Weekly goal", "+\(earn?.householdGoal ?? 120) for \(earn?.householdGoalTarget ?? 5) in a week")
            }
            Button("How surprise bonuses work") { showOdds = true }.font(Theme.body(13)).underline().foregroundStyle(Theme.muted)
        }
    }

    private func way(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold))
            Text(title).font(Theme.body(14, .bold))
            Text(detail).font(Theme.body(12)).foregroundStyle(Theme.coin)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .overlay(Rectangle().stroke(Theme.line))
    }

    private func load() async {
        do {
            wallet = try await APIClient.shared.request("GET", "/coins/wallet")
            let page: LedgerPage = try await APIClient.shared.request("GET", "/coins/ledger?limit=30")
            entries = page.entries
            cursor = page.nextCursor
            unavailable = false
            state.balance = wallet?.balance
            APIClient.shared.track("coins_card_viewed", props: ["surface": "wallet"])
        } catch let e as APIError where e.isCoinsUnavailable || e.isOffline {
            unavailable = wallet == nil
        } catch {}
    }

    private func more() async {
        guard let cursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let enc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cursor
        if let page: LedgerPage = try? await APIClient.shared.request("GET", "/coins/ledger?limit=30&cursor=\(enc)") {
            entries += page.entries
            self.cursor = page.nextCursor
        }
    }
}
