import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var state
    @State private var groups: [GroupSummary] = []
    @State private var friends: [Friend] = []
    @State private var showAddFriend = false
    @State private var loading = true
    @State private var showCreate = false
    @State private var showSync = false

    var body: some View {
        @Bindable var state = state
        NavigationStack(path: $state.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    groupsSection
                    FriendsSection(friends: friends) { showAddFriend = true }
                    if !groups.isEmpty || !friends.isEmpty { mySpending }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .refreshable { await load() }
            .background(Theme.bg)
            .routeDestinations()
            .safeAreaInset(edge: .bottom) {
                NeoPopFloatingButton(title: groups.isEmpty && !loading ? "Start a group" : "New group") {
                    if groups.isEmpty { state.showFlatSetup = true } else { showCreate = true }
                }
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await load() }
        .onChange(of: state.refreshTick) { Task { await load() } }
        .sheet(isPresented: $showCreate) { CreateGroupSheet { id in Task { await load(); state.open(.group(id)) } } }
        .sheet(isPresented: $showSync, onDismiss: { Task { await load() } }) { SyncView() }
        .sheet(isPresented: $showAddFriend) { AddFriendSheet { id in Task { await load(); state.open(.group(id)) } } }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Hi \(state.user?.name ?? "")")
                Text("Squared").font(Theme.title(30))
            }
            Spacer()
            if state.coinsLive, let balance = state.balance {
                Button { state.open(.wallet) } label: { CoinChip(coins: balance) }
                    .accessibilityHint("Opens your coins")
            }
        }
        .padding(.top, 12)
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Groups")
                Spacer()
                Button { showSync = true } label: {
                    Label("Sync nearby", systemImage: "antenna.radiowaves.left.and.right").font(Theme.body(13, .semibold))
                }
                .foregroundStyle(Theme.muted)
            }
            if loading && groups.isEmpty {
                ForEach(0..<2, id: \.self) { _ in Skeleton(height: 72) }
            } else if groups.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No groups yet").font(Theme.body(17, .bold))
                        Text("Start one for your home, a trip, friends or work in under a minute.")
                            .font(Theme.body(14)).foregroundStyle(Theme.muted)
                    }
                }
            }
            ForEach(groups) { g in
                Button { state.open(.group(g.id)) } label: { GroupRow(group: g) }.buttonStyle(.plain)
            }
        }
    }

    private var mySpending: some View {
        Button { state.open(.mySpending) } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.pie.fill").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44)
                    .background(Theme.surfaceHigh)
                VStack(alignment: .leading, spacing: 2) {
                    Text("My spending").font(Theme.body(16, .bold))
                    Text("Your share across groups and friends, by category and month").font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
            }
            .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        defer { loading = false }
        if let r: GroupsResponse = try? await APIClient.shared.request("GET", "/groups") { groups = r.groups }
        if let r: FriendsResponse = try? await APIClient.shared.request("GET", "/friends") { friends = r.friends }
        await state.refreshCoins(celebrate: false)
        let nets = groups.map(\.myNetPaise) + friends.map(\.myNetPaise)
        let owe = nets.filter { $0 < 0 }.reduce(0, +)
        let owed = nets.filter { $0 > 0 }.reduce(0, +)
        WidgetSnapshot(name: state.user?.name ?? "", coins: state.coinsLive ? state.balance : nil, youOwe: -owe, youAreOwed: owed,
                       currency: groups.first?.currency ?? "INR", needsYou: 0, updated: Date()).save()
        // a full-screen celebration presented mid pull-to-refresh leaves the refresh control stuck;
        // show it once the list has settled
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            await state.pollCelebrations()
        }
    }
}

struct GroupRow: View {
    let group: GroupSummary
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: GroupKind(group.groupType).icon)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 44, height: 44)
                .background(Theme.surfaceHigh)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(Theme.body(17, .bold))
                Text("\(group.memberCount) member\(group.memberCount == 1 ? "" : "s")").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            BalanceText(net: group.myNetPaise, currency: group.currency)
        }
        .neoPopCard(depth: 4, padding: 14)
        .accessibilityElement(children: .combine)
    }
}

struct BalanceText: View {
    let net: Int
    var currency: String? = "INR"
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if net == 0 {
                Text("balanced").font(Theme.body(13, .semibold)).foregroundStyle(Theme.muted)
            } else {
                Text(net > 0 ? "you are owed" : "you owe").font(Theme.body(11)).foregroundStyle(Theme.muted)
                Text(Format.money(abs(net), currency)).font(Theme.body(15, .heavy)).foregroundStyle(net > 0 ? Theme.owed : Theme.owe)
            }
        }
    }
}
