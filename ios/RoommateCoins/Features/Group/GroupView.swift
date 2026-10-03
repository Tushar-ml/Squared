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
                    if let a = state.activation, !a.activated, let eid = a.confirmExpenseId,
                       let e = d.expenses.first(where: { $0.id == eid }), d.coinsEnabled {
                        WelcomeBanner(groupName: d.name, expense: e, firstWin: a.firstWinCoins ?? 50)
                    }
                    if d.coinsEnabled {
                        if let h = household {
                            if let last = h.lastWeek, [2, 3].contains(Calendar.current.component(.weekday, from: Date())) {
                                RecapCard(groupName: d.name, last: last, target: h.target)
                            }
                            HouseholdCard(groupName: d.name, h: h, collapsed: $cardCollapsed,
                                          noExpenses: d.expenses.isEmpty) { showInvite = true }
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
        .overlay(alignment: .bottom) {
            if detail != nil {
                NeoPopFloatingButton(title: "Add expense", shimmer: false) { showAdd = true }
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .task { await load() }
        .onChange(of: state.refreshTick) { Task { await load() } }
        .sheet(isPresented: $showAdd) {
            if let d = detail { AddExpenseView(group: d) { Task { await load() } } }
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
            HStack(spacing: 10) {
                BalanceText(net: d.myNetPaise)
                Spacer()
                NeoPopButton(title: "Invite", style: .stroke, icon: "person.badge.plus", height: 38) { showInvite = true }
                    .frame(width: 120)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func debts(_ d: GroupDetail) -> some View {
        let mine = d.debts.filter(\.youOwe)
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Settle up")
                ForEach(mine, id: \.self) { debt in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Strings.youOwe(debt.creditorName ?? "", Format.inr(paise: debt.amountPaise))).font(Theme.body(17, .bold))
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
                    HStack {
                        Text("\(debt.debtorName ?? "") owes you").font(Theme.body(14)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(Format.inr(paise: debt.amountPaise)).font(Theme.body(14, .bold)).foregroundStyle(Theme.owed)
                    }
                }
            }
        }
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
                    PaymentRow(payment: p, me: state.user?.id ?? 0) { Task { await load() } }
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
    let onInvite: () -> Void

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
            .accessibilityLabel(collapsed ? "Expand household card" : "Collapse household card")
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
                    Label { Text(Strings.sharedPot(h.potCoins)) } icon: { CoinGlyph(size: 14) }
                        .font(Theme.body(13, .semibold)).foregroundStyle(Theme.coin)
                    Text(Strings.weeksSquared(h.weeksSquared)).font(Theme.body(13, .semibold)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 10) {
                    ForEach(h.members, id: \.userId) { m in
                        Avatar(name: m.isYou ? "You" : (m.name ?? "?"), tick: m.confirmedThisWeek, size: 34)
                    }
                    Button(action: onInvite) {
                        Label("Invite", systemImage: "plus").font(Theme.body(13, .bold))
                            .padding(.horizontal, 10).frame(height: 34)
                            .overlay(Rectangle().stroke(h.inviteSuggested ? Theme.coin : Theme.line))
                    }
                    .buttonStyle(.plain)
                }
                if !h.potRedemptions.isEmpty, let r = h.potRedemptions.first {
                    Text("\(r.redeemedBy ?? "A roommate") redeemed a \(r.brand) INR \(r.faceValueInr) voucher from the pot")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                NavigationLink(value: Route.redeem) {
                    Text("Use the pot").font(Theme.body(13, .bold)).underline()
                }.buttonStyle(.plain)
            }
        }
        .neoPopCard(color: UIColor(hex: 0x141414), edge: h.goalMet ? Theme.UI.coin : UIColor(hex: 0x3A3A3A), depth: 6)
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
                     : "Last week was quiet. This week's goal: \(target). A roommate can confirm in one tap.")
                    .font(Theme.body(14))
            }
        }
    }
}

struct ExpenseRow: View {
    let expense: Expense
    let me: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(expense.description).font(Theme.body(16, .bold))
                Spacer()
                Text(Format.inr(paise: expense.amountPaise)).font(Theme.body(16, .heavy))
            }
            Text("\(expense.paidBy == me ? "You" : (expense.paidByName ?? "")) paid, your share \(Format.inr(paise: expense.mySharePaise))")
                .font(Theme.body(13)).foregroundStyle(Theme.muted)
            if let c = expense.confirmation {
                HStack(spacing: 8) {
                    ConfirmationChip(confirmation: c)
                    if let first = c.confirmedBy.first {
                        Text(Strings.confirmedBy(first.name ?? "")).font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                    if !c.waitingOn.isEmpty && c.status == "WAITING" {
                        Text(c.waitingOn.map { "\($0.name ?? ""): waiting" }.joined(separator: " · "))
                            .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    if c.canConfirm { Text("Tap to confirm").font(Theme.body(12, .bold)).foregroundStyle(Theme.coin) }
                    if OfflineQueue.shared.isPending("expense:\(expense.id)") { StatusChip(text: Strings.willSync) }
                }
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
    let onChange: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                Text("\(payment.payerId == me ? "You" : payment.payerName ?? "") paid \(payment.receiverId == me ? "you" : payment.receiverName ?? "")")
                    .font(Theme.body(15, .semibold))
                Spacer()
                Text(Format.inr(paise: payment.amountPaise)).font(Theme.body(15, .heavy))
            }
            if let c = payment.confirmation {
                switch c.status {
                case "PENDING":
                    if c.canConfirm {
                        ReceiptBar(payment: payment, reward: 0, onDone: onChange)
                    } else {
                        StatusChip(text: Strings.waitingReceipt(payment.receiverName ?? ""))
                    }
                case "CONFIRMED": StatusChip(text: "Receipt confirmed", tint: Theme.text)
                case "REJECTED": StatusChip(text: "\(payment.receiverName ?? "They") hasn't received it yet")
                default: StatusChip(text: "Unverified")
                }
            }
        }
        .padding(14)
        .background(Theme.surface)
        .overlay(Rectangle().stroke(Theme.line))
    }
}
