import Charts
import SwiftUI

/// Month navigation shared by both insights screens.
struct MonthSwitcher: View {
    @Binding var month: Date
    let label: String
    var body: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("Previous month")
            Spacer()
            Text(label).font(Theme.body(16, .heavy))
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(isCurrent).opacity(isCurrent ? 0.3 : 1)
                .accessibilityLabel("Next month")
        }
        .foregroundStyle(Theme.text)
        .background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
    }
    private var isCurrent: Bool { Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month) }
    private func shift(_ n: Int) { month = Calendar.current.date(byAdding: .month, value: n, to: month) ?? month }
}

extension Date {
    var monthKey: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.dateFormat = "yyyy-MM"
        return f.string(from: self)
    }
}

private let categoryColors: [String: Color] = [
    "rent": Color(hex: 0xF5F5F5), "utilities": Color(hex: 0x6FA8FF), "groceries": Color(hex: 0x06C270),
    "food": Color(hex: 0xFF9F5A), "help": Color(hex: 0xC792EA), "household": Color(hex: 0x8AD4D1),
    "transport": Color(hex: 0xFFD166), "entertainment": Color(hex: 0xFF7AA2), "travel": Color(hex: 0x5AC8FA), "stay": Color(hex: 0xB39DDB),
    "shopping": Color(hex: 0xF48FB1), "gifts": Color(hex: 0xE57373), "other": Color(hex: 0x8A8A8A),
]

struct CategoryBreakdown: View {
    let slices: [CategorySlice]
    let currency: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("By category")
            if slices.isEmpty {
                Text("No expenses this month.").font(Theme.body(14)).foregroundStyle(Theme.muted)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    Chart(slices) { s in
                        SectorMark(angle: .value("Amount", s.amount), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(categoryColors[s.category] ?? Theme.muted)
                    }
                    .frame(width: 120, height: 120)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(slices.prefix(6)) { s in
                            HStack(spacing: 8) {
                                Rectangle().fill(categoryColors[s.category] ?? Theme.muted).frame(width: 10, height: 10)
                                Text(s.label).font(Theme.body(13, .semibold))
                                Spacer()
                                Text("\(Int(s.pct.rounded()))%").font(Theme.body(12)).foregroundStyle(Theme.muted)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(s.label), \(Format.money(s.amount, currency)), \(Int(s.pct.rounded())) percent")
                        }
                    }
                }
            }
        }
        .neoPopCard(depth: 4, padding: 14)
    }
}

struct TrendChart: View {
    let points: [TrendPoint]
    let currency: String
    let showTotal: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Last 6 months")
            Chart {
                ForEach(points) { p in
                    // side by side, not stacked: your share is part of the group total
                    if showTotal, let t = p.total {
                        BarMark(x: .value("Month", p.label), y: .value("Amount", Double(t) / 100))
                            .foregroundStyle(by: .value("Series", "Whole group"))
                            .position(by: .value("Series", "Whole group"))
                    }
                    BarMark(x: .value("Month", p.label), y: .value("Amount", Double(p.myShare) / 100))
                        .foregroundStyle(by: .value("Series", "Your share"))
                        .position(by: .value("Series", "Your share"))
                }
            }
            .chartForegroundStyleScale(["Whole group": Color(hex: 0x4A4A4A), "Your share": Theme.coin])
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(compact(d)).font(.system(size: 10)).foregroundStyle(Theme.muted) } }
                }
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.muted) } }
            .frame(height: 160)
            HStack(spacing: 14) {
                if showTotal { legend(Color(hex: 0x4A4A4A), "Whole group") }
                legend(Theme.coin, "Your share")
            }
        }
        .neoPopCard(depth: 4, padding: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spending trend: " + points.map { "\($0.label) \(Format.money($0.myShare, currency))" }.joined(separator: ", "))
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) { Rectangle().fill(c).frame(width: 10, height: 10); Text(t).font(Theme.body(12)).foregroundStyle(Theme.muted) }
    }

    private func compact(_ v: Double) -> String {
        v >= 100_000 ? String(format: "%.1fL", v / 100_000) : v >= 1000 ? String(format: "%.0fk", v / 1000) : String(format: "%.0f", v)
    }
}

/// Per-group spend analytics: who paid, who consumed, categories, trend, top expenses, report export.
struct GroupInsightsView: View {
    let groupId: Int
    @State private var month = Date()
    @State private var data: GroupInsights?
    @State private var error: String?
    @State private var reportURL: URL?
    @State private var pdfURL: URL?
    @State private var exporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MonthSwitcher(month: $month, label: data?.monthLabel ?? " ")
                if let d = data {
                    summary(d)
                    membersCard(d)
                    BudgetsCard(groupId: groupId, currency: d.currency)
                    CategoryBreakdown(slices: d.categories, currency: d.currency)
                    TrendChart(points: d.trend, currency: d.currency, showTotal: true)
                    if !d.topExpenses.isEmpty { topCard(d) }
                    exportCard(d)
                } else if let error {
                    Card { Text(error).foregroundStyle(Theme.muted) }
                } else {
                    ForEach(0..<3, id: \.self) { _ in Skeleton(height: 120) }
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: month.monthKey) { await load() }
    }

    private func summary(_ d: GroupInsights) -> some View {
        HStack(spacing: 12) {
            stat("Group spent", Format.money(d.totalSpend, d.currency), "\(d.expenseCount) expenses")
            stat("Your share", Format.money(d.you?.share ?? 0, d.currency), "\(Int((d.you?.sharePct ?? 0).rounded()))% of total")
        }
    }

    private func stat(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            Text(value).font(Theme.body(20, .heavy)).minimumScaleFactor(0.6).lineLimit(1)
            Text(sub).font(Theme.body(12)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoPopCard(depth: 4, padding: 14)
    }

    private func membersCard(_ d: GroupInsights) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Paid vs share")
            Chart {
                ForEach(d.members) { m in
                    BarMark(x: .value("Amount", Double(m.paid) / 100), y: .value("Person", m.isYou ? "You" : (m.name ?? "")))
                        .foregroundStyle(by: .value("Kind", "Paid"))
                        .position(by: .value("Kind", "Paid"))
                    BarMark(x: .value("Amount", Double(m.share) / 100), y: .value("Person", m.isYou ? "You" : (m.name ?? "")))
                        .foregroundStyle(by: .value("Kind", "Share"))
                        .position(by: .value("Kind", "Share"))
                }
            }
            .chartForegroundStyleScale(["Paid": Theme.text, "Share": Theme.coin])
            .chartLegend(position: .bottom)
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(1, d.members.count)) * 54 + 30)
            .accessibilityHidden(true)
            ForEach(d.members) { m in
                HStack {
                    Text(m.isYou ? "You" : (m.name ?? "")).font(Theme.body(14, .semibold))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("paid \(Format.money(m.paid, d.currency)) · share \(Format.money(m.share, d.currency))")
                            .font(Theme.body(12)).foregroundStyle(Theme.muted)
                        // neutral wording and colour: insights describe, they don't judge ("square, not shame")
                        Text(m.net == 0 ? "even this month" : (m.net > 0 ? "paid \(Format.money(m.net, d.currency)) more than their share"
                                                                       : "share is \(Format.money(-m.net, d.currency)) more than paid"))
                            .font(Theme.body(12, .semibold)).foregroundStyle(Theme.text.opacity(0.75))
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("Daily average \(Format.money(d.dailyAverage, d.currency)) for the group").font(Theme.body(12)).foregroundStyle(Theme.muted)
        }
        .neoPopCard(depth: 4, padding: 14)
    }

    private func topCard(_ d: GroupInsights) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Biggest expenses")
            ForEach(d.topExpenses) { e in
                NavigationLink(value: Route.expense(e.id)) {
                    HStack {
                        Image(systemName: ExpenseCategory(rawValue: e.category)?.icon ?? "square.grid.2x2.fill")
                            .frame(width: 30, height: 30).background(Theme.surfaceHigh)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.description).font(Theme.body(14, .semibold))
                            Text("\(e.paidByName ?? "") · \(Format.shortDate(e.createdAt))").font(Theme.body(11)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text(Format.money(e.amount, d.currency)).font(Theme.body(14, .heavy))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .neoPopCard(depth: 4, padding: 14)
    }

    private func exportCard(_ d: GroupInsights) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Monthly report")
            Text("Every expense with each person's share, payments, totals and what's still owed. Opens in Numbers, Excel or Sheets.")
                .font(Theme.body(13)).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                exportButton("CSV", url: reportURL) { Task { await export(d, format: "csv") } }
                exportButton("PDF", url: pdfURL) { Task { await export(d, format: "pdf") } }
            }
        }
        .neoPopCard(depth: 4, padding: 14)
    }

    @ViewBuilder
    private func exportButton(_ kind: String, url: URL?, make: @escaping () -> Void) -> some View {
        if let url {
            ShareLink(item: url) {
                Label("Share \(kind)", systemImage: "square.and.arrow.up").font(.system(size: 14, weight: .heavy))
                    .frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(Theme.bg).background(Theme.text)
            }
        } else {
            NeoPopButton(title: exporting ? "…" : "Export \(kind)", style: .stroke, icon: kind == "PDF" ? "doc.richtext" : "tablecells",
                         enabled: !exporting, parent: Theme.UI.surface, action: make)
        }
    }

    private func load() async {
        reportURL = nil
        pdfURL = nil
        do {
            data = try await APIClient.shared.request("GET", "/groups/\(groupId)/insights?month=\(month.monthKey)")
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func export(_ d: GroupInsights, format: String) async {
        exporting = true
        defer { exporting = false }
        do {
            let data = try await APIClient.shared.raw("GET", "/groups/\(groupId)/report?month=\(d.month)&format=\(format)")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(d.groupName.replacingOccurrences(of: " ", with: "_"))_\(d.month).\(format)")
            try data.write(to: url)
            if format == "pdf" { pdfURL = url } else { reportURL = url }
        } catch { self.error = error.localizedDescription }
    }
}

/// My spending across every group, in one display currency at live rates.
struct MyInsightsView: View {
    @State private var month = Date()
    @State private var currency = UserDefaults.standard.string(forKey: "displayCurrency") ?? "INR"
    @State private var data: MyInsights?
    @State private var error: String?
    @State private var showCurrency = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MonthSwitcher(month: $month, label: data?.monthLabel ?? " ")
                HStack {
                    Text("Show in").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    Button { showCurrency = true } label: {
                        HStack(spacing: 4) { Text(currency).font(Theme.body(14, .heavy)); Image(systemName: "chevron.down").font(.system(size: 10, weight: .black)) }
                            .padding(.horizontal, 10).frame(minHeight: 34).overlay(Rectangle().stroke(Theme.line))
                    }
                    .foregroundStyle(Theme.text)
                    Spacer()
                    Text("live rates").font(Theme.body(11)).foregroundStyle(Theme.muted)
                }
                if let d = data {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Your share this month")
                        Text(Format.money(d.totalShare, d.currency)).font(Theme.number(34))
                        Text("You paid \(Format.money(d.totalPaid, d.currency)) up front").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                    .neoPopCard(depth: 5)
                    if !d.byGroup.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("By group")
                            ForEach(d.byGroup) { g in
                                HStack {
                                    Text(g.groupName).font(Theme.body(14, .semibold))
                                    if g.groupCurrency != d.currency {
                                        Text(Format.money(g.shareInGroupCurrency, g.groupCurrency)).font(Theme.body(11)).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Text(Format.money(g.share, d.currency)).font(Theme.body(14, .heavy))
                                }
                            }
                        }
                        .neoPopCard(depth: 4, padding: 14)
                    }
                    CategoryBreakdown(slices: d.categories, currency: d.currency)
                    TrendChart(points: d.trend, currency: d.currency, showTotal: false)
                } else if let error {
                    Card { Text(error).foregroundStyle(Theme.muted) }
                } else {
                    ForEach(0..<3, id: \.self) { _ in Skeleton(height: 120) }
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("My spending")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(month.monthKey)-\(currency)") { await load() }
        .sheet(isPresented: $showCurrency) {
            CurrencyPicker(selected: currency, reference: currency) { c in
                currency = c
                UserDefaults.standard.set(c, forKey: "displayCurrency")
            }
        }
    }

    private func load() async {
        do {
            data = try await APIClient.shared.request("GET", "/me/insights?month=\(month.monthKey)&currency=\(currency)")
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}


/// Monthly category budgets with progress and an editor; the server alerts everyone at 80% and 100%.
struct BudgetsCard: View {
    let groupId: Int
    let currency: String
    @State private var budgets: [Budget] = []
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Budgets this month")
                Spacer()
                Button(budgets.isEmpty ? "Set budgets" : "Edit") { editing = true }.font(Theme.body(13, .bold)).foregroundStyle(Theme.text)
            }
            if budgets.isEmpty {
                Text("Set a monthly limit for groceries, food or anything else. Everyone gets a heads-up at 80%.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            ForEach(budgets) { b in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(b.label).font(Theme.body(14, .semibold))
                        Spacer()
                        Text("\(Format.money(b.spent, currency)) of \(Format.money(b.limit, currency))").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.line)
                            Rectangle().fill(b.pct >= 100 ? Theme.owe : (b.pct >= 80 ? Theme.coin : Theme.text))
                                .frame(width: g.size.width * min(1, b.pct / 100))
                        }
                    }
                    .frame(height: 6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(b.label): \(Int(b.pct)) percent of budget used")
            }
        }
        .neoPopCard(depth: 4, padding: 14)
        .task { await load() }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            BudgetEditor(groupId: groupId, currency: currency, existing: budgets)
        }
    }

    private func load() async {
        if let r: BudgetsResponse = try? await APIClient.shared.request("GET", "/groups/\(groupId)/budgets") { budgets = r.budgets }
    }
}

private struct BudgetEditor: View {
    @Environment(\.dismiss) private var dismiss
    let groupId: Int
    let currency: String
    let existing: [Budget]
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Leave empty for no budget.")) {
                    ForEach(ExpenseCategory.allCases) { c in
                        HStack {
                            Label(c.label, systemImage: c.icon)
                            Spacer()
                            Text(currency).foregroundStyle(Theme.muted)
                            TextField("0", text: Binding(get: { values[c.rawValue] ?? "" }, set: { values[c.rawValue] = $0 }))
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Monthly budgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Save") { Task { await save() } }.bold() }
            }
        }
        .onAppear {
            for b in existing { values[b.category] = Format.majorString(b.limit, currency) }
        }
    }

    private func save() async {
        var body: [String: Int] = [:]
        for c in ExpenseCategory.allCases {
            body[c.rawValue] = Format.minor(from: values[c.rawValue] ?? "", currency: currency) ?? 0
        }
        _ = try? await APIClient.shared.raw("PUT", "/groups/\(groupId)/budgets", body: ["budgets": body])
        dismiss()
    }
}
