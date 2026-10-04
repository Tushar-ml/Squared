import SwiftUI

struct GroupView: View {
    @Environment(AppState.self) private var state
    let groupId: Int

    @State private var detail: GroupDetail?
    @State private var household: Household?
    @State private var householdUnavailable = false
    @State private var error: String?
    @State private var showAdd = false
    @State private var showInvite = false
    @State private var showIntro = false
    @State private var cardCollapsed = false
    @State private var settleTarget: Debt?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let d = detail {
                    header(d)
                    toolRow(d)
                    if d.coinsEnabled {
                        if let h = household {
                            if let last = h.lastWeek, [2, 3].contains(Calendar.current.component(.weekday, from: Date())) {
                                RecapCard(groupName: d.name, last: last, target: h.target)
                            }
                            HouseholdCard(groupName: d.name, h: h, collapsed: $cardCollapsed, noExpenses: d.expenses.isEmpty,
                                          onInvite: GroupKind(d.groupType) == .direct ? nil : { showInvite = true })
                        } else if householdUnavailable {
                            CoinsUnavailable()
                        } else {
                            Skeleton(height: 180)
                        }
                    }
                    debts(d)
                    activity(d)
                } else if let error {
                    Card { Text(error).foregroundStyle(Theme.muted) }
                } else {
                    VStack(spacing: 12) { ForEach(0..<4, id: \.self) { _ in Skeleton(height: 64) } }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .background(Theme.bg)
        .refreshable { await load() }
        .navigationTitle(detail?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let d = detail, d.coinsEnabled, let b = state.balance {
                    Button { state.open(.wallet) } label: { CoinChip(coins: b, compact: true) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if detail != nil {
                NeoPopFloatingButton(title: "Add expense", shimmer: false) { showAdd = true }
                    .padding(.horizontal, 20).padding(.bottom, 4)
            }
        }
        .task { await load() }
        .onChange(of: state.refreshTick) { Task { await load() } }
        .sheet(isPresented: $showAdd) {
            if let d = detail { ExpenseForm(group: d) { Task { await load() } } }
        }
        .sheet(isPresented: $showInvite) {
            if let d = detail { InviteSheet(groupId: d.id, groupName: d.name, coinsEnabled: d.coinsEnabled) }
        }
        .sheet(item: $settleTarget, onDismiss: { Task { await load() } }) { debt in
            NavigationStack { SettleView(groupId: groupId, creditorId: debt.creditorId) }
        }
        .fullScreenCover(isPresented: $showIntro) { IntroView { markIntroSeen() } }
    }

    private func header(_ d: GroupDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(d.name).font(Theme.title(30))
            if GroupKind(d.groupType) == .direct {
                Label("Just you and \(d.name)", systemImage: "person.2.fill").font(Theme.body(13, .semibold)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 10) {
                BalanceText(net: d.myNetPaise, currency: d.currency)
                Spacer()
                if GroupKind(d.groupType) != .direct {
                    NeoPopButton(title: "People", style: .stroke, icon: "person.2", height: 38) { showInvite = true }
                        .frame(width: 120)
                }
            }
        }
        .padding(.top, 8)
    }

    private func toolRow(_ d: GroupDetail) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tool("Insights", "chart.bar.xaxis", .insights(d.id))
                tool("Recurring", "repeat", .recurring(d.id))
                tool("Search", "magnifyingglass", .search(d.id))
                if GroupKind(d.groupType) != .direct { tool("Settings", "gearshape", .groupSettings(d.id)) }
            }
        }
    }

    private func tool(_ title: String, _ icon: String, _ route: Route) -> some View {
        NavigationLink(value: route) {
            Label(title, systemImage: icon).font(Theme.body(13, .semibold))
                .padding(.horizontal, 12).frame(minHeight: 38)
                .background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
        }
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder
    private func debts(_ d: GroupDetail) -> some View {
        let mine = d.debts.filter(\.youOwe)
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Settle up")
                ForEach(mine, id: \.self) { debt in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Strings.youOwe(debt.creditorName ?? "", Format.money(debt.amountPaise, d.currency))).font(Theme.body(17, .bold))
                        if d.coinsEnabled, let hint = debt.payRewardHint {
                            HStack(spacing: 6) { CoinGlyph(size: 14); Text(Strings.payToday(hint)).font(Theme.body(13, .semibold)) }
                                .foregroundStyle(Theme.coin)
                        }
                        NeoPopButton(title: "Pay", icon: "indianrupeesign", parent: Theme.UI.surface) { settleTarget = debt }
                    }
                    .neoPopCard(depth: 4, padding: 14)
                }
            }
        }
        let owedToMe = d.debts.filter { !$0.youOwe }
        if !owedToMe.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(owedToMe, id: \.self) { debt in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(debt.debtorName ?? "") owes you").font(Theme.body(14)).foregroundStyle(Theme.muted)
                            Text(Format.money(debt.amountPaise, d.currency)).font(Theme.body(15, .bold)).foregroundStyle(Theme.owed)
                        }
                        Spacer()
                        remindButton(debt)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Nobody else has the app, so a reminder is a ready-made message you send them yourself.
    private func remindButton(_ debt: Debt) -> some View {
        ShareLink(item: reminderText(debt)) {
            HStack(spacing: 6) {
                Image(systemName: "bell")
                Text("Remind").font(Theme.body(13, .bold))
            }
            .padding(.horizontal, 12).frame(minHeight: 36)
            .foregroundStyle(Theme.text)
            .background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
        }
        .accessibilityLabel("Send \(debt.debtorName ?? "") a reminder to pay")
    }

    private func reminderText(_ debt: Debt) -> String {
        let amount = Format.money(debt.amountPaise, detail?.currency)
        var text = "Hi \(debt.debtorName ?? ""), a reminder about \(amount) for \(detail?.name ?? "our split")."
        if let upi = state.user?.upiId, !upi.isEmpty {
            var c = URLComponents(); c.scheme = "upi"; c.host = "pay"
            c.queryItems = [.init(name: "pa", value: upi), .init(name: "pn", value: state.user?.name),
                            .init(name: "am", value: String(format: "%.2f", Double(debt.amountPaise) / 100)), .init(name: "cu", value: "INR")]
            text += " You can pay me at \(upi)" + (c.url.map { ": \($0.absoluteString)" } ?? ".")
        }
        return text
    }

    private func activity(_ d: GroupDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Activity")
            let items = timeline(d)
            if items.isEmpty {
                Text("Nothing yet. Add the first shared expense.").font(Theme.body(14)).foregroundStyle(Theme.muted)
            }
            ForEach(items, id: \.id) { item in
                switch item {
                case .expense(let e):
                    NavigationLink(value: Route.expense(e.id)) {
                        ExpenseRow(expense: e, me: state.user?.id ?? 0)
                    }.buttonStyle(.plain)
                case .payment(let p):
                    PaymentRow(payment: p, me: state.user?.id ?? 0, currency: d.currency) { Task { await load() } }
                }
            }
        }
    }

    private enum Item {
        case expense(Expense), payment(Payment)
        var id: String { switch self { case .expense(let e): "e\(e.id)"; case .payment(let p): "p\(p.id)" } }
        var date: String { switch self { case .expense(let e): e.createdAt; case .payment(let p): p.createdAt } }
    }

    private func timeline(_ d: GroupDetail) -> [Item] {
        (d.expenses.map(Item.expense) + d.payments.map(Item.payment)).sorted { $0.date > $1.date }
    }

    private func load() async {
        Task { await state.refreshCoins() }   // keep the header coin chip in step with rewards earned here
        do {
            let d: GroupDetail = try await APIClient.shared.request("GET", "/groups/\(groupId)")
            detail = d
            if d.coinsEnabled {
                do {
                    household = try await APIClient.shared.request("GET", "/groups/\(groupId)/household")
                    householdUnavailable = false
                    APIClient.shared.track("coins_card_viewed", groupId: groupId, props: ["surface": "household"])
                } catch {
                    #if DEBUG
                    print("household load failed: \(error)")
                    #endif
                    householdUnavailable = household == nil
                }
                if state.user?.introSeen == false && !UserDefaults.standard.bool(forKey: "introSeen") && !state.onboarded {
                    showIntro = true  // S10, only for people who skipped the pre-login walkthrough
                }
                await state.refreshActivation()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func markIntroSeen() {
        UserDefaults.standard.set(true, forKey: "introSeen")
        state.user?.introSeen = true
        Task { try? await APIClient.shared.raw("PATCH", "/me", body: ["intro_seen": true]) }
    }
}

extension Debt: Identifiable { public var id: String { "\(debtorId)-\(creditorId)" } }

/// S1 household card.
struct HouseholdCard: View {
    let groupName: String
    let h: Household
    @Binding var collapsed: Bool
    let noExpenses: Bool
    var onInvite: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(.snappy) { collapsed.toggle() } } label: {
                HStack {
                    SectionLabel(Strings.thisWeekTogether, color: h.goalMet ? Theme.coin : Theme.muted)
                    Spacer()
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.muted)
                }
                .frame(minHeight: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Expand weekly goal card" : "Collapse weekly goal card")
            HStack(spacing: 16) {
                ProgressRing(progress: h.progress, target: h.target, met: h.goalMet)
                VStack(alignment: .leading, spacing: 4) {
                    if noExpenses {
                        Text(Strings.householdEmpty).font(Theme.body(14, .semibold)).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(Strings.confirmedOf(min(h.progress, h.target), h.target)).font(Theme.body(16, .bold))
                        Text(h.goalMet ? Strings.goalMet(h.goalReward) : Strings.reachGoal(h.target, h.goalReward))
                            .font(Theme.body(13)).foregroundStyle(h.goalMet ? Theme.coin : Theme.muted)
                    }
                }
            }
            if !collapsed {
                HStack(spacing: 16) {
                    Text(Strings.weeksSquared(h.weeksSquared)).font(Theme.body(13, .semibold)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 10) {
                    ForEach(h.members, id: \.userId) { m in
                        Avatar(name: m.isYou ? "You" : (m.name ?? "?"), tick: m.confirmedThisWeek, size: 34)
                    }
                    if let onInvite {
                        Button(action: onInvite) {
                            Label("Add", systemImage: "plus").font(Theme.body(13, .bold))
                                .padding(.horizontal, 10).frame(height: 34)
                                .overlay(Rectangle().stroke(h.inviteSuggested ? Theme.coin : Theme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
                RecapShareButton(groupName: groupName, h: h)
            }
        }
        .neoPopCard(color: Theme.UI.surface, edge: h.goalMet ? Theme.UI.coin : Theme.UI.edge, depth: 6)
    }
}

struct ProgressRing: View {
    let progress: Int
    let target: Int
    let met: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frac = target > 0 ? min(1, Double(progress) / Double(target)) : 0
        ZStack {
            Circle().stroke(Theme.line, lineWidth: 7)
            Circle().trim(from: 0, to: frac)
                .stroke(met ? Theme.coin : Theme.text, style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .spring(duration: 0.6), value: frac)
            Text("\(min(progress, target))/\(target)").font(.system(size: 14, weight: .heavy, design: .rounded))
        }
        .frame(width: 62, height: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress) of \(target) expenses confirmed this week")
    }
}

/// S11 Monday recap card. Never shaming.
struct RecapCard: View {
    let groupName: String
    let last: LastWeek
    let target: Int
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Last week")
                Text(last.status == "MET"
                     ? "Last week \(groupName) confirmed \(last.progress) expenses and hit the goal. This week's goal: \(target)."
                     : "Last week was quiet. This week's goal: \(target). Anyone can confirm in one tap.")
                    .font(Theme.body(14))
            }
        }
    }
}

struct ExpenseRow: View {
    let expense: Expense
    let me: Int

    private var summary: String {
        let payer = expense.paidBy == me ? "You" : (expense.paidByName ?? "")
        var s = "\(payer) paid, your share \(Format.money(expense.mySharePaise, expense.currency))"
        if let oc = expense.originalCurrency { s += " · in \(oc)" }
        if (expense.splitType ?? "EQUAL") != "EQUAL" { s += " · custom split" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(expense.description).font(Theme.body(16, .bold))
                Spacer()
                Text(Format.money(expense.amountPaise, expense.currency)).font(Theme.body(16, .heavy))
            }
            Text(summary).font(Theme.body(13)).foregroundStyle(Theme.muted)
            if expense.splitType != nil, expense.mySharePaise == 0, expense.paidBy != me {
                Text("Not involving you").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(14)
        .background(Theme.surface)
        .overlay(Rectangle().stroke(Theme.line))
        .accessibilityElement(children: .combine)
    }
}

struct PaymentRow: View {
    let payment: Payment
    let me: Int
    var currency: String? = "INR"
    let onChange: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                Text("\(payment.payerId == me ? "You" : payment.payerName ?? "") paid \(payment.receiverId == me ? "you" : payment.receiverName ?? "")")
                    .font(Theme.body(15, .semibold))
                Spacer()
                Text(Format.money(payment.amountPaise, currency)).font(Theme.body(15, .heavy))
            }
        }
        .padding(14)
        .background(Theme.surface)
        .overlay(Rectangle().stroke(Theme.line))
    }
}


/// FR-17: the week's household recap as an image for WhatsApp / Instagram.
struct RecapShareButton: View {
    let groupName: String
    let h: Household
    @State private var image: Image?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                ShareLink(item: image, preview: SharePreview("\(groupName) this week", image: image)) {
                    Label("Share recap", systemImage: "square.and.arrow.up").font(Theme.body(13, .bold))
                }
            } else {
                Button { render() } label: { Label("Share recap", systemImage: "square.and.arrow.up").font(Theme.body(13, .bold)) }
            }
        }
        .foregroundStyle(Theme.text)
        .onAppear(perform: render)
    }

    @MainActor private func render() {
        let r = ImageRenderer(content: RecapCardView(groupName: groupName, h: h).environment(\.colorScheme, .dark))
        r.scale = scale
        if let ui = r.uiImage { image = Image(uiImage: ui) }
    }
}

struct RecapCardView: View {
    let groupName: String
    let h: Household
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                CoinGlyph(size: 26)
                Text("SQUARED").font(.system(size: 12, weight: .black)).tracking(1.6).foregroundStyle(.white)
                Spacer()
            }
            Text(groupName).font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
            HStack(spacing: 18) {
                ProgressRing(progress: h.progress, target: h.target, met: h.goalMet)
                VStack(alignment: .leading, spacing: 4) {
                    Text(h.goalMet ? "Goal met this week" : "\(h.progress) of \(h.target) confirmed this week")
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    Text("\(h.weeksSquared) week\(h.weeksSquared == 1 ? "" : "s") squared · pot \(h.potCoins) coins")
                        .font(.system(size: 13)).foregroundStyle(Color(hex: 0xBDBDBD))
                }
            }
            HStack(spacing: 8) {
                ForEach(h.members, id: \.userId) { m in Avatar(name: m.name ?? "?", tick: m.confirmedThisWeek, size: 34) }
            }
            Text("Keeping it square, together.").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0xF5B301))
        }
        .padding(24)
        .frame(width: 360, alignment: .leading)
        .background(Color(hex: 0x111111))
        .overlay(Rectangle().stroke(Color(hex: 0xF5B301), lineWidth: 2))
    }
}
