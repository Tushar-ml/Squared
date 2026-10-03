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
    @State private var showRedeem = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if unavailable {
                    CoinsUnavailable()
                } else if let w = wallet {
                    balanceCard(w)
                    HStack(spacing: 12) {
                        NeoPopButton(title: "Redeem", style: .elevatedCoin, icon: "gift.fill", enabled: !w.redemptionFrozen) {
                            showRedeem = true
                        }
                        if let pot = w.householdPots.first {
                            NeoPopButton(title: "Pot: \(pot.coins)", style: .stroke, icon: "house.fill") {
                                state.open(.group(pot.groupId))
                            }
                        }
                    }
                    if let notice = w.capNotice {
                        Text(notice.message).font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                    if w.pending > 0 {
                        Text("\(w.pending) coins are being reviewed and will show up soon.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                    if w.deficit > 0 {
                        Text("Redemption is paused until \(w.deficit) reversed coins are earned back.")
                            .font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                    if w.redemptionFrozen {
                        Text("Redemption is paused on your account. Contact support.").font(Theme.body(13)).foregroundStyle(Theme.muted)
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
        .navigationDestination(isPresented: $showRedeem) { RedeemView(groupId: nil) }
    }

    private func balanceCard(_ w: Wallet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Coins")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CoinGlyph(size: 30)
                Text("\(w.balance)").font(Theme.number(48)).foregroundStyle(Theme.coin)
                Text("(\(Format.coinsInr(w.balance, coinValue: state.coinValue)))").font(Theme.body(15, .semibold)).foregroundStyle(Theme.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(w.balance) coins, \(Format.coinsInr(w.balance, coinValue: state.coinValue))")
            Text("\(w.coinsPerInr) coins = INR 1").font(Theme.body(12)).foregroundStyle(Theme.muted)
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
                way("checkmark.seal", "Confirm", "+\(earn?.expenseConfirmer ?? 2) each")
                way("indianrupeesign.circle", "Settle", "+\((earn?.settlePayer ?? 20) + (earn?.settleQuickBonus ?? 10)) quick")
                way("person.badge.plus", "Invite", "+\(earn?.inviteEach ?? 50) each")
                way("house", "Weekly goal", "+\(earn?.householdGoal ?? 120) pot")
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

/// S8 Redeem flow.
struct RedeemView: View {
    @Environment(AppState.self) private var state
    let groupId: Int?
    @State private var catalog: Catalog?
    @State private var pots: [HouseholdPot] = []
    @State private var potGroup: Int?
    @State private var confirmItem: CatalogItem?
    @State private var result: Redemption?
    @State private var failed: CatalogItem?
    @State private var busy = false
    @State private var history: [Redemption] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let c = catalog {
                    HStack {
                        CoinChip(coins: c.balance)
                        Text(Format.coinsInr(c.balance, coinValue: state.coinValue)).font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                    section("Personal", items: c.items.filter { $0.scope == "USER" })
                    if !pots.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if pots.count > 1 {
                                Picker("Household", selection: $potGroup) {
                                    ForEach(pots, id: \.groupId) { Text($0.groupName).tag(Optional($0.groupId)) }
                                }.pickerStyle(.segmented)
                            }
                            if let pb = c.potBalance { Text("Shared pot: \(pb) coins").font(Theme.body(13, .semibold)).foregroundStyle(Theme.coin) }
                        }
                        section("Household", items: c.items.filter { $0.scope == "GROUP" })
                    }
                    if !history.isEmpty { historySection }
                } else if let error {
                    Card { Text(error).foregroundStyle(Theme.muted) }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                        ForEach(0..<4, id: \.self) { _ in Skeleton(height: 130) }
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Redeem")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: potGroup) { Task { await loadCatalog() } }
        .sheet(item: $confirmItem) { item in confirmSheet(item) }
        .sheet(item: $result) { r in successSheet(r) }
        .sheet(item: $failed) { item in failureSheet(item) }
    }

    private func section(_ title: String, items: [CatalogItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(items) { item in
                    Button { if item.affordable { confirmItem = item } } label: { VoucherCard(item: item) }
                        .buttonStyle(.plain)
                        .disabled(!item.affordable)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Your vouchers")
            ForEach(history) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.brand) INR \(r.faceValueInr)").font(Theme.body(14, .bold))
                        Text(statusText(r)).font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if let code = r.code {
                        Button { UIPasteboard.general.string = code; state.showToast("Code copied") } label: {
                            Text(code).font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func statusText(_ r: Redemption) -> String {
        switch r.status {
        case "HELD": Strings.readyIn48
        case "FULFILLED": "Ready · \(Format.shortDate(r.createdAt))"
        case "REFUNDED": "Didn't go through · coins refunded"
        default: "Processing"
        }
    }

    private func confirmSheet(_ item: CatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(item.scope == "GROUP" ? "From the shared pot" : "Redeem")
            Text("Spend \(item.coinCost) coins for an INR \(item.faceValueInr) voucher?").font(Theme.title(24))
            Text(item.brand + (item.scope == "GROUP" ? " · everyone in the flat will see who redeemed it" : ""))
                .font(Theme.body(14)).foregroundStyle(Theme.muted)
            NeoPopButton(title: "Spend \(item.coinCost) coins", style: .elevatedCoin, enabled: !busy, loading: busy) {
                Task { await redeem(item) }
            }
            NeoPopButton(title: "Cancel", style: .stroke) { confirmItem = nil }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.height(330)])
        .presentationBackground(Theme.bg)
    }

    private func successSheet(_ r: Redemption) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            CoinGlyph(size: 44)
            if r.status == "HELD" {
                Text("Redeemed. \(Strings.readyIn48)").font(Theme.title(24))
                Text("Your first voucher gets a quick check. You'll find the code here and in your email.")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted)
            } else if let code = r.code {
                Text("Your INR \(r.faceValueInr) \(r.brand) voucher").font(Theme.title(22))
                HStack {
                    Text(code).font(.system(size: 22, weight: .heavy, design: .monospaced))
                    Spacer()
                    NeoPopButton(title: "Copy", style: .stroke, icon: "doc.on.doc", height: 40) {
                        UIPasteboard.general.string = code
                        state.showToast("Code copied")
                    }.frame(width: 110)
                }
                .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.coin))
                Text(Strings.alsoEmailed).font(Theme.body(13)).foregroundStyle(Theme.muted)
            } else {
                Text("Redeemed. We'll have your code shortly.").font(Theme.title(22))
            }
            NeoPopButton(title: "Done") { result = nil }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.height(360)])
        .presentationBackground(Theme.bg)
    }

    private func failureSheet(_ item: CatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.redeemFailed).font(Theme.title(22))
            NeoPopButton(title: "Retry", enabled: !busy) { failed = nil; Task { await redeem(item) } }
            NeoPopButton(title: "Close", style: .stroke) { failed = nil }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.height(250)])
        .presentationBackground(Theme.bg)
    }

    private func redeem(_ item: CatalogItem) async {
        busy = true
        defer { busy = false }
        APIClient.shared.track("redeem_started", groupId: item.scope == "GROUP" ? potGroup : nil,
                               props: ["catalog_item_id": item.id, "coins": item.coinCost])
        do {
            let r: Redemption = try await APIClient.shared.request(
                "POST", "/coins/redemptions",
                body: ["catalog_item_id": item.id, "group_id": item.scope == "GROUP" ? potGroup : nil],
                idempotencyKey: UUID().uuidString)
            confirmItem = nil
            try? await Task.sleep(for: .milliseconds(350))
            if r.status == "REFUNDED" || r.status == "FAILED" { failed = item } else { result = r }
            await load()
            await state.refreshCoins()
        } catch let e as APIError {
            confirmItem = nil
            if e.isOffline || e.status >= 500 { try? await Task.sleep(for: .milliseconds(350)); failed = item }
            else { state.showToast(e.message) }
        } catch {}
    }

    private func load() async {
        if let w: Wallet = try? await APIClient.shared.request("GET", "/coins/wallet") {
            pots = w.householdPots
            if potGroup == nil { potGroup = groupId ?? pots.first?.groupId }
        }
        await loadCatalog()
        if let h: RedemptionsResponse = try? await APIClient.shared.request("GET", "/coins/redemptions") { history = h.redemptions }
    }

    private func loadCatalog() async {
        do {
            catalog = try await APIClient.shared.request("GET", "/coins/catalog" + (potGroup.map { "?group_id=\($0)" } ?? ""))
        } catch { self.error = error.localizedDescription }
    }
}

struct VoucherCard: View {
    let item: CatalogItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.category.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Theme.muted)
            Text(item.brand).font(Theme.body(16, .heavy))
            Text("INR \(item.faceValueInr)").font(Theme.number(24))
            HStack(spacing: 4) {
                CoinGlyph(size: 13)
                Text("\(item.coinCost)").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(Theme.coin)
            }
            if !item.affordable {
                Text("\(item.coinsNeeded) more coins needed").font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .neoPopCard(color: item.affordable ? Theme.UI.surface : Theme.UI.surface,
                    edge: item.affordable ? Theme.UI.coin : Theme.UI.edge, depth: 4, padding: 12)
        .opacity(item.affordable ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.affordable ? "Double tap to redeem" : "\(item.coinsNeeded) more coins needed")
    }
}
