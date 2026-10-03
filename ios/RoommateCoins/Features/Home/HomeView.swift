import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var state
    @State private var groups: [GroupSummary] = []
    @State private var inbox: [NeedsYouItem] = []
    @State private var inboxUnavailable = false
    @State private var loading = true
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showSettings = false
    @State private var showNotifications = false
    @State private var unread = 0

    var body: some View {
        @Bindable var state = state
        NavigationStack(path: $state.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if state.coinsLive {
                        if inboxUnavailable { CoinsUnavailable() }
                        else if !inbox.isEmpty { NeedsYouSection(items: inbox) { Task { await load() } } }
                    }
                    groupsSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .refreshable { await load() }
            .background(Theme.bg)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .group(let id): GroupView(groupId: id)
                case .expense(let id): ExpenseDetailView(expenseId: id)
                case .wallet: WalletView()
                case .redeem: RedeemView(groupId: nil)
                case .household(let id): GroupView(groupId: id)
                case .settle(let id): SettleView(groupId: id, creditorId: nil, showsClose: false)
                }
            }
            .overlay(alignment: .bottom) {
                NeoPopFloatingButton(title: "New flat") { showCreate = true }
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await load() }
        .onChange(of: state.refreshTick) { Task { await load() } }
        .sheet(isPresented: $showCreate) { CreateGroupSheet { id in Task { await load(); state.open(.group(id)) } } }
        .sheet(isPresented: $showJoin) { PasteInviteSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNotifications, onDismiss: { Task { await load() } }) { NotificationsInboxView() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Hi \(state.user?.name ?? "")")
                Text("Your flats").font(Theme.title(30))
            }
            Spacer()
            if state.coinsLive, let balance = state.balance {
                Button { state.open(.wallet) } label: { CoinChip(coins: balance) }
                    .accessibilityHint("Opens your coins")
            }
            iconButton(unread > 0 ? "bell.badge" : "bell", label: "Notifications") { showNotifications = true }
            iconButton("gearshape", label: "Settings") { showSettings = true }
        }
        .padding(.top, 12)
    }

    private func iconButton(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Groups")
                Spacer()
                Button("Join with a link") { showJoin = true }.font(Theme.body(13, .semibold)).foregroundStyle(Theme.muted)
            }
            if loading && groups.isEmpty {
                ForEach(0..<2, id: \.self) { _ in Skeleton(height: 72) }
            } else if groups.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No flats yet").font(Theme.body(17, .bold))
                        Text("Create your flat and invite roommates. Every confirmed expense earns you both coins.")
                            .font(Theme.body(14)).foregroundStyle(Theme.muted)
                    }
                }
            }
            ForEach(groups) { g in
                Button { state.open(.group(g.id)) } label: { GroupRow(group: g) }.buttonStyle(.plain)
            }
        }
    }

    private func load() async {
        defer { loading = false }
        if let r: GroupsResponse = try? await APIClient.shared.request("GET", "/groups") { groups = r.groups }
        do {
            let r: NeedsYou = try await APIClient.shared.request("GET", "/me/inbox/needs-you")
            inbox = r.items
            inboxUnavailable = false
            if !r.items.isEmpty { APIClient.shared.track("coins_card_viewed", props: ["surface": "inbox"]) }
        } catch let e as APIError where e.isCoinsUnavailable {
            inboxUnavailable = true
        } catch {}
        if let n: NotificationsResponse = try? await APIClient.shared.request("GET", "/me/notifications") { unread = n.unread ?? 0 }
        await state.refreshCoins()
    }
}

struct GroupRow: View {
    let group: GroupSummary
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: group.groupType == "HOME" ? "house.fill" : "person.3.fill")
                .font(.system(size: 18, weight: .bold))
                .frame(width: 44, height: 44)
                .background(Theme.surfaceHigh)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(Theme.body(17, .bold))
                Text("\(group.memberCount) member\(group.memberCount == 1 ? "" : "s")").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            BalanceText(net: group.myNetPaise)
        }
        .neoPopCard(depth: 4, padding: 14)
        .accessibilityElement(children: .combine)
    }
}

struct BalanceText: View {
    let net: Int
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if net == 0 {
                Text("balanced").font(Theme.body(13, .semibold)).foregroundStyle(Theme.muted)
            } else {
                Text(net > 0 ? "you are owed" : "you owe").font(Theme.body(11)).foregroundStyle(Theme.muted)
                Text(Format.inr(paise: abs(net))).font(Theme.body(15, .heavy)).foregroundStyle(net > 0 ? Theme.owed : Theme.owe)
            }
        }
    }
}

/// S4: pending confirmations and receipts across groups, each with inline one-tap actions.
struct NeedsYouSection: View {
    let items: [NeedsYouItem]
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Needs you", color: Theme.coin)
                Text("\(items.count)").font(.system(size: 11, weight: .black)).foregroundStyle(Theme.bg)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.coin)
            }
            ForEach(items) { item in
                if let e = item.expense {
                    NeedsYouExpenseRow(expense: e, groupName: item.groupName, onDone: onChange)
                } else if let p = item.payment {
                    NeedsYouPaymentRow(payment: p, groupName: item.groupName, reward: item.receiverReward ?? 0, onDone: onChange)
                }
            }
        }
    }
}

struct NeedsYouExpenseRow: View {
    let expense: Expense
    let groupName: String
    let onDone: () -> Void
    @State private var showDispute = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(expense.createdByName ?? "A roommate") added \(expense.description)").font(Theme.body(15, .bold))
                    Text("\(Format.inr(paise: expense.amountPaise)) · your share \(Format.inr(paise: expense.mySharePaise)) · \(groupName)")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            ConfirmBar(expense: expense, source: "inbox", compact: true, onDone: onDone, onDispute: { showDispute = true })
        }
        .neoPopCard(depth: 4, padding: 14)
        .sheet(isPresented: $showDispute) { NotRightSheet(expense: expense) { onDone() } }
    }
}

struct NeedsYouPaymentRow: View {
    let payment: Payment
    let groupName: String
    let reward: Int
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(payment.payerName ?? "A roommate") says they paid you \(Format.inr(paise: payment.amountPaise))")
                .font(Theme.body(15, .bold))
            Text(groupName).font(Theme.body(12)).foregroundStyle(Theme.muted)
            ReceiptBar(payment: payment, reward: reward, onDone: onDone)
        }
        .neoPopCard(depth: 4, padding: 14)
    }
}
