import SwiftUI

/// Signed-in shell: Flats · Activity · Coins · Account.
struct MainTabs: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        TabView(selection: $state.tab) {
            HomeView()
                .tabItem { Label("Flats", systemImage: "house.fill") }
                .tag(AppTab.flats)
            NavigationStack { ActivityView().routeDestinations() }
                .tabItem { Label("Activity", systemImage: "bolt.horizontal.fill") }
                .tag(AppTab.activity)
            if state.coinsLive {
                NavigationStack { WalletView().routeDestinations() }
                    .tabItem { Label("Coins", systemImage: "circle.circle.fill") }
                    .tag(AppTab.coins)
            }
            SettingsView(showsDone: false)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(AppTab.account)
        }
        .tint(Theme.text)
    }
}

extension View {
    /// One place that knows how to show every Route, used by every navigation stack.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .group(let id), .household(let id): GroupView(groupId: id)
            case .expense(let id): ExpenseDetailView(expenseId: id)
            case .wallet: WalletView()
            case .redeem: RedeemView(groupId: nil)
            case .settle(let id): SettleView(groupId: id, creditorId: nil, showsClose: false)
            case .insights(let id): GroupInsightsView(groupId: id)
            case .mySpending: MyInsightsView()
            case .groupSettings(let id): GroupSettingsView(groupId: id)
            case .recurring(let id): RecurringListView(groupId: id)
            case .search(let id): SearchView(groupId: id)
            case .chat(let id): ChatView(groupId: id)
            }
        }
    }
}

/// Everything happening across your flats, newest first.
struct ActivityView: View {
    @Environment(AppState.self) private var state
    @State private var items: [ActivityItem] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && items.isEmpty {
                Text("Nothing yet. Activity from all your flats shows up here.")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted).listRowBackground(Theme.bg)
            }
            ForEach(sections, id: \.0) { day, rows in
                Section {
                    ForEach(rows) { item in
                        row(item).listRowBackground(Theme.surface)
                    }
                } header: {
                    SectionLabel(day)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Activity")
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: state.refreshTick) { Task { await load() } }
    }

    private var sections: [(String, [ActivityItem])] {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM"
        var out: [(String, [ActivityItem])] = []
        for i in items {
            let d = Format.date(i.at).map { Calendar.current.isDateInToday($0) ? "Today" : Calendar.current.isDateInYesterday($0) ? "Yesterday" : f.string(from: $0) } ?? ""
            if out.last?.0 == d { out[out.count - 1].1.append(i) } else { out.append((d, [i])) }
        }
        return out
    }

    @ViewBuilder
    private func row(_ i: ActivityItem) -> some View {
        let content = HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(i)).font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32).background(Theme.surfaceHigh)
            VStack(alignment: .leading, spacing: 3) {
                Text(text(i)).font(Theme.body(14, .semibold)).foregroundStyle(Theme.text)
                if let body = i.body { Text("\u{201C}\(body)\u{201D}").font(Theme.body(13)).foregroundStyle(Theme.muted) }
                Text("\(i.groupName) · \(Format.relative(i.at))").font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if let amount = i.amount, i.kind == "EXPENSE" || i.kind == "PAYMENT" {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.money(amount, i.currency)).font(Theme.body(13, .bold))
                    if i.kind == "EXPENSE", let s = i.myShare, s > 0 {
                        Text("you \(Format.money(s, i.currency))").font(Theme.body(11)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        if let e = i.expenseId, i.kind != "EXPENSE_DELETED" {
            NavigationLink(value: Route.expense(e)) { content }
        } else {
            NavigationLink(value: Route.group(i.groupId)) { content }
        }
    }

    private func icon(_ i: ActivityItem) -> String {
        switch i.kind {
        case "EXPENSE": i.recurring == true ? "repeat" : "receipt"
        case "EXPENSE_DELETED": "trash"
        case "PAYMENT": "indianrupeesign"
        case "CONFIRMED": "checkmark.seal"
        case "DISPUTED": "exclamationmark.bubble"
        case "COMMENT": "text.bubble"
        default: "person.badge.plus"
        }
    }

    private func text(_ i: ActivityItem) -> String {
        let who = i.actorName ?? "Someone"
        switch i.kind {
        case "EXPENSE": return i.recurring == true ? "\(i.title ?? "") was added (recurring)" : "\(who) added \(i.title ?? "")"
        case "EXPENSE_DELETED": return "\(who) deleted \(i.title ?? "")"
        case "PAYMENT":
            let rec = i.receiverName ?? ""
            return "\(who) paid \(rec)" + (i.status == "CONFIRMED" ? " · confirmed" : "")
        case "CONFIRMED": return "\(who) confirmed \(i.title ?? "")"
        case "DISPUTED": return "\(who) flagged \(i.title ?? "") as not right"
        case "COMMENT": return "\(who) commented on \(i.title ?? "")"
        default: return "\(who) joined \(i.groupName)"
        }
    }

    private func load() async {
        if let r: ActivityResponse = try? await APIClient.shared.request("GET", "/me/activity") { items = r.items }
        loaded = true
    }
}
