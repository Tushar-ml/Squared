import SwiftUI

// MARK: - Group settings & members

struct GroupSettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let groupId: Int
    @State private var detail: GroupDetail?
    @State private var name = ""
    @State private var simplify = false
    @State private var showCurrency = false
    @State private var confirmLeave = false
    @State private var removing: Member?
    @State private var showInvite = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let d = detail {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Name")
                        HStack {
                            TextField("Group name", text: $name).font(Theme.body(18, .bold))
                                .padding(12).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                            NeoPopButton(title: "Save", style: .stroke, enabled: name != d.name && !name.isEmpty, height: 44) {
                                Task { await patch(["name": name]) }
                            }.frame(width: 90)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Money")
                        NeoPopToggle(label: "Simplify debts", isOn: $simplify)
                        Text("Shows the fewest payments to settle everyone (A pays C instead of A→B→C). Totals stay the same.")
                            .font(Theme.body(12)).foregroundStyle(Theme.muted)
                        Button { showCurrency = true } label: {
                            HStack {
                                Text("Group currency").font(Theme.body(15, .semibold))
                                Spacer()
                                Text(d.currency ?? "INR").font(Theme.body(15, .heavy))
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                            }.frame(minHeight: 44)
                        }
                        .foregroundStyle(Theme.text)
                        .disabled(!d.expenses.isEmpty || !d.payments.isEmpty)
                        if !d.expenses.isEmpty {
                            Text("Currency is fixed once the first expense is added. Expenses can still be entered in any currency.")
                                .font(Theme.body(12)).foregroundStyle(Theme.muted)
                        }
                        NavigationLink(value: Route.recurring(groupId)) {
                            HStack { Label("Recurring bills", systemImage: "repeat").font(Theme.body(15, .semibold)); Spacer(); Image(systemName: "chevron.right") }
                                .frame(minHeight: 44)
                        }.foregroundStyle(Theme.text)
                        if d.defaultSplit != nil {
                            HStack {
                                Text("Default split saved").font(Theme.body(14))
                                Spacer()
                                Button("Clear") { Task { await patch(["default_split": [String: Any]()]) } }.font(Theme.body(13, .bold))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { SectionLabel("Members · \(d.members.count)"); Spacer(); Button("Invite") { showInvite = true }.font(Theme.body(13, .bold)) }
                        ForEach(d.members) { m in
                            HStack(spacing: 12) {
                                Avatar(name: m.isYou ? "You" : (m.name ?? "?"), size: 34)
                                Text(m.isYou ? "You" : (m.name ?? "")).font(Theme.body(15, .semibold))
                                if m.id == d.createdBy { StatusChip(text: "Created the group") }
                                Spacer()
                                if d.createdBy == state.user?.id && !m.isYou {
                                    Button { removing = m } label: { Image(systemName: "person.badge.minus").frame(width: 44, height: 44) }
                                        .foregroundStyle(Theme.muted).accessibilityLabel("Remove \(m.name ?? "")")
                                }
                            }
                        }
                        Text("People can leave or be removed once their balance is settled.").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                    NeoPopButton(title: "Leave group", style: .flatStroke, height: 44) { confirmLeave = true }
                        .padding(.top, 8)
                } else {
                    Skeleton(height: 200)
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Group settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: simplify) { _, v in if let d = detail, d.simplifyDebts != v { Task { await patch(["simplify_debts": v]) } } }
        .sheet(isPresented: $showCurrency) {
            CurrencyPicker(selected: detail?.currency ?? "INR", reference: "INR") { c in Task { await patch(["currency": c]) } }
        }
        .sheet(isPresented: $showInvite) { if let d = detail { InviteSheet(groupId: d.id, groupName: d.name, coinsEnabled: d.coinsEnabled) } }
        .confirmationDialog("Leave \(detail?.name ?? "")?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await remove(state.user?.id ?? 0, leaving: true) } }
        } message: { Text("You'll stop seeing this group's expenses. Your coins stay yours.") }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let m = removing { Task { await remove(m.id, leaving: false) } } }
        }
    }

    private func load() async {
        if let d: GroupDetail = try? await APIClient.shared.request("GET", "/groups/\(groupId)") {
            detail = d; name = d.name; simplify = d.simplifyDebts ?? false
        }
    }

    private func patch(_ body: [String: Any?]) async {
        do {
            try await APIClient.shared.raw("PATCH", "/groups/\(groupId)", body: body)
            await load()
            state.refreshTick += 1
            state.showToast("Saved")
        } catch { state.showToast(error.localizedDescription) }
    }

    private func remove(_ uid: Int, leaving: Bool) async {
        do {
            try await APIClient.shared.raw("DELETE", "/groups/\(groupId)/members/\(uid)")
            state.refreshTick += 1
            if leaving { state.path = []; state.showToast("You left the group") } else { await load() }
        } catch { state.showToast(error.localizedDescription) }
    }
}

// MARK: - Recurring bills (FR-16)

struct RecurringListView: View {
    @Environment(AppState.self) private var state
    let groupId: Int
    @State private var items: [Recurring] = []
    @State private var showNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rent, wifi, maid: add them once and they're added automatically. Everyone gets a heads-up the day before.")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted)
                if items.isEmpty {
                    Card { Text("No recurring bills yet.").font(Theme.body(15, .semibold)) }
                }
                ForEach(items) { r in
                    HStack(spacing: 12) {
                        Image(systemName: ExpenseCategory(rawValue: r.category)?.icon ?? "repeat").frame(width: 36, height: 36).background(Theme.surfaceHigh)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.description).font(Theme.body(15, .bold))
                            Text("\(Format.money(r.amountMinor, r.currency)) · \(schedule(r)) · \(r.paidByName ?? "") pays")
                                .font(Theme.body(12)).foregroundStyle(Theme.muted)
                            Text("Next: \(Format.shortDate(r.nextRun + "T00:00:00+05:30"))").font(Theme.body(12, .semibold)).foregroundStyle(Theme.coin)
                        }
                        Spacer()
                        Button { Task { await pause(r) } } label: { Image(systemName: "pause.circle").font(.system(size: 20)).frame(width: 44, height: 44) }
                            .foregroundStyle(Theme.muted).accessibilityLabel("Stop \(r.description)")
                    }
                    .neoPopCard(depth: 4, padding: 12)
                }
                NeoPopButton(title: "Add recurring bill", icon: "plus") { showNew = true }.padding(.top, 6)
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Recurring bills")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showNew, onDismiss: { Task { await load() } }) {
            ExpenseFormLoader(groupId: groupId, recurringOnly: true)
        }
    }

    private func schedule(_ r: Recurring) -> String {
        if r.frequency == "WEEKLY" {
            let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            return "every \(days[min(max(r.day, 0), 6)])"
        }
        let suffix = [1: "st", 2: "nd", 3: "rd", 21: "st", 22: "nd", 23: "rd"][r.day] ?? "th"
        return "monthly on the \(r.day)\(suffix)"
    }

    private func load() async {
        if let r: RecurringResponse = try? await APIClient.shared.request("GET", "/groups/\(groupId)/recurring") { items = r.recurring }
    }

    private func pause(_ r: Recurring) async {
        try? await APIClient.shared.raw("PATCH", "/recurring/\(r.id)", body: ["active": false])
        state.showToast("\(r.description) stopped")
        await load()
    }
}

// MARK: - Search

struct SearchView: View {
    let groupId: Int
    @State private var query = ""
    @State private var category: ExpenseCategory?
    @State private var month: Date?
    @State private var onlyMine = false
    @State private var result: SearchResponse?
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip(onlyMine ? "Involving me ✓" : "Involving me", on: onlyMine) { onlyMine.toggle() }
                        Menu {
                            Button("Any month") { month = nil }
                            ForEach(0..<6, id: \.self) { i in
                                let d = Calendar.current.date(byAdding: .month, value: -i, to: Date())!
                                Button(d.formatted(.dateTime.month(.wide).year())) { month = d }
                            }
                        } label: { chipLabel(month.map { $0.formatted(.dateTime.month(.abbreviated).year()) } ?? "Month", on: month != nil) }
                        ForEach(ExpenseCategory.allCases) { c in
                            filterChip(c.label, on: category == c) { category = category == c ? nil : c }
                        }
                    }
                }
                if let r = result {
                    Text("\(r.expenses.count) result\(r.expenses.count == 1 ? "" : "s") · \(Format.money(r.total, r.currency))")
                        .font(Theme.body(13, .semibold)).foregroundStyle(Theme.muted)
                    ForEach(r.expenses) { e in
                        NavigationLink(value: Route.expense(e.id)) { ExpenseRow(expense: e, me: state.user?.id ?? 0) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Description or comment")
        .task(id: "\(query)|\(category?.rawValue ?? "")|\(month?.monthKey ?? "")|\(onlyMine)") {
            try? await Task.sleep(for: .milliseconds(250))   // debounce typing
            await run()
        }
    }

    private func chipLabel(_ t: String, on: Bool) -> some View {
        Text(t).font(Theme.body(13, .semibold)).padding(.horizontal, 12).frame(minHeight: 36)
            .foregroundStyle(on ? Theme.bg : Theme.text).background(on ? Theme.text : Theme.surface).overlay(Rectangle().stroke(Theme.line))
    }

    private func filterChip(_ t: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(t, on: on) }
    }

    private func run() async {
        var q = ["q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"]
        if let category { q.append("category=\(category.rawValue)") }
        if let month { q.append("month=\(month.monthKey)") }
        if onlyMine, let me = state.user?.id { q.append("member=\(me)") }
        result = try? await APIClient.shared.request("GET", "/groups/\(groupId)/search?" + q.joined(separator: "&"))
    }
}

// MARK: - Flat chat

struct ExpenseFormLoader: View {
    let groupId: Int
    var editing: Expense? = nil
    var recurringOnly = false
    var onSaved: () -> Void = {}
    @State private var group: GroupDetail?

    var body: some View {
        Group {
            if let g = group {
                ExpenseForm(group: g, editing: editing, recurringOnly: recurringOnly, onSaved: onSaved)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .task { group = try? await APIClient.shared.request("GET", "/groups/\(groupId)", as: GroupDetail.self) }
    }
}
