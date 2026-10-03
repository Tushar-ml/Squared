import SwiftUI

enum ExpenseCategory: String, CaseIterable, Identifiable {
    case rent, utilities, groceries, food, help, household, transport, entertainment, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rent: "Rent"; case .utilities: "Utilities"; case .groceries: "Groceries"; case .food: "Food"
        case .help: "House help"; case .household: "Household"; case .transport: "Transport"
        case .entertainment: "Fun"; case .other: "Other"
        }
    }
    var icon: String {
        switch self {
        case .rent: "house.fill"; case .utilities: "bolt.fill"; case .groceries: "cart.fill"; case .food: "fork.knife"
        case .help: "person.fill"; case .household: "sofa.fill"; case .transport: "car.fill"
        case .entertainment: "popcorn.fill"; case .other: "square.grid.2x2.fill"
        }
    }
}

/// Add or edit an expense: category, any currency (live conversion preview), and
/// equal / exact amounts / percent / shares splits. The server recomputes everything.
struct ExpenseForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    let group: GroupDetail
    var editing: Expense? = nil
    let onSaved: () -> Void

    @State private var desc = ""
    @State private var category: ExpenseCategory? = nil
    @State private var amount = ""
    @State private var currency = "INR"
    @State private var payer = 0
    @State private var mode: SplitMode = .equal
    @State private var included: Set<Int> = []
    @State private var inputs: [Int: String] = [:]     // per-person text for exact / percent
    @State private var weights: [Int: Double] = [:]    // per-person shares
    @State private var busy = false
    @State private var error: String?
    @State private var saved: Expense?
    @State private var showCurrency = false
    @FocusState private var focus: Int?

    private var groupCurrency: String { group.currency ?? "INR" }
    private var people: [Int] { group.members.map(\.id) }
    private var totalMinor: Int? { Format.minor(from: amount, currency: currency) }
    private var fx: FxStore { FxStore.shared }

    private var values: [Int: Double] {
        switch mode {
        case .exact: return inputs.compactMapValues { Format.minor(from: $0, currency: currency).map(Double.init) }
        case .percent: return inputs.compactMapValues { Double($0.replacingOccurrences(of: ",", with: ".")) }
        case .shares: return weights
        case .equal: return [:]
        }
    }

    private var preview: SplitMath.Result {
        SplitMath.compute(total: totalMinor ?? 0, mode: mode, people: people, included: included, values: values)
    }

    private var canSave: Bool {
        !desc.trimmingCharacters(in: .whitespaces).isEmpty && totalMinor != nil && preview.error == nil && !preview.shares.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let saved { successSheet(saved) } else { form }
            }
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(saved == nil ? "Cancel" : "Close") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focus = nil } }
            }
        }
        .onAppear(perform: prefill)
        .task { _ = await fx.rates(base: groupCurrency) }
        .sheet(isPresented: $showCurrency) {
            CurrencyPicker(selected: currency, reference: groupCurrency) { c in
                currency = c
                Task { _ = await fx.rates(base: c) }
            }
        }
    }

    // MARK: form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionLabel(editing == nil ? "Add expense · \(group.name)" : "Edit expense")
                TextField("What was it? e.g. Wifi bill", text: $desc)
                    .font(Theme.body(20, .bold)).focused($focus, equals: -1).submitLabel(.next)
                    .onSubmit { focus = -2 }
                    .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                categoryRow
                amountRow
                if currency != groupCurrency { conversionLine }
                SectionLabel("Paid by")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(group.members) { m in
                            pill(m.isYou ? "You" : (m.name ?? ""), selected: payer == m.id) { payer = m.id }
                        }
                    }
                }
                splitSection
                if let error { Text(error).font(Theme.body(13)).foregroundStyle(Theme.owe) }
                NeoPopButton(title: editing == nil ? "Save" : "Save changes", enabled: canSave && !busy, loading: busy) {
                    Task { await save() }
                }
                .padding(.top, 8)
                if editing?.confirmation?.status == "CONFIRMED" {
                    Text("Changing the amount, payer or split resets confirmations. Roommates confirm again and coins are re-earned.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ExpenseCategory.allCases) { c in
                    Button { category = (category == c ? nil : c) } label: {
                        Label(c.label, systemImage: c.icon).font(Theme.body(13, .semibold))
                            .padding(.horizontal, 12).frame(minHeight: 36)
                            .foregroundStyle(category == c ? Theme.bg : Theme.text)
                            .background(category == c ? Theme.text : Theme.surface)
                            .overlay(Rectangle().stroke(Theme.line))
                    }
                    .accessibilityAddTraits(category == c ? .isSelected : [])
                }
            }
        }
    }

    private var amountRow: some View {
        HStack(spacing: 12) {
            Button { showCurrency = true } label: {
                HStack(spacing: 4) {
                    Text(currency).font(Theme.number(20))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .black))
                }
                .foregroundStyle(currency == groupCurrency ? Theme.muted : Theme.coin)
                .frame(minWidth: 70, minHeight: 44)
            }
            .accessibilityLabel("Currency \(currency). Change")
            TextField("0", text: $amount).keyboardType(.decimalPad).font(Theme.number(30)).focused($focus, equals: -2)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
    }

    /// Editing in the same foreign currency keeps the locked-in rate (server does the same).
    private var effectiveRate: Double? {
        if let e = editing, e.originalCurrency == currency, let r = e.fxRate { return r }
        return fx.rate(currency, groupCurrency)
    }

    @ViewBuilder
    private var conversionLine: some View {
        if let r = effectiveRate {
            let converted = Int((Double(totalMinor ?? 0) / pow(10, Double(Format.digits(currency))) * r
                                 * pow(10, Double(Format.digits(groupCurrency)))).rounded())
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .bold))
                Text("≈ \(Format.money(converted, groupCurrency)) · 1 \(currency) = \(String(format: r >= 1 ? "%.2f" : "%.4f", r)) \(groupCurrency)")
                    .font(Theme.body(13, .semibold))
            }
            .foregroundStyle(Theme.muted)
            Text(editing?.originalCurrency == currency
                 ? "Keeps the rate it was entered with, so balances don't shift with the market."
                 : "Live rate. It's locked in when you save, so balances don't shift with the market.")
                .font(Theme.body(11)).foregroundStyle(Theme.muted)
            if groupCurrency == "INR" {
                Text("Expenses in other currencies don't earn coins.").font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
        } else {
            Text(fx.unavailable ? "Live rates unavailable. We'll convert when you save." : "Fetching live rate…")
                .font(Theme.body(12)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: split

    private var splitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Split")
            HStack(spacing: 0) {
                ForEach(SplitMode.allCases) { m in
                    Button {
                        withAnimation(.snappy) { switchMode(m) }
                    } label: {
                        Text(m.label).font(.system(size: 14, weight: .heavy))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .foregroundStyle(mode == m ? Theme.bg : Theme.text)
                            .background(mode == m ? Theme.text : Theme.surface)
                    }
                    .accessibilityAddTraits(mode == m ? .isSelected : [])
                    if m != SplitMode.allCases.last { Rectangle().fill(Theme.line).frame(width: 1, height: 42) }
                }
            }
            .overlay(Rectangle().stroke(Theme.line))

            ForEach(group.members) { m in personRow(m) }

            splitStatus
        }
    }

    @ViewBuilder
    private func personRow(_ m: Member) -> some View {
        let name = m.isYou ? "You" : (m.name ?? "")
        let share = preview.shares[m.id]
        switch mode {
        case .equal:
            NeoPopCheckRow(label: name, detail: share.map { Format.money($0, currency) },
                           isOn: Binding(get: { included.contains(m.id) },
                                         set: { on in if on { included.insert(m.id) } else { included.remove(m.id) } }))
        case .exact, .percent:
            HStack(spacing: 12) {
                Avatar(name: name, size: 32)
                Text(name).font(Theme.body(15, .semibold))
                Spacer()
                if mode == .percent, let share { Text(Format.money(share, currency)).font(Theme.body(12)).foregroundStyle(Theme.muted) }
                HStack(spacing: 4) {
                    if mode == .exact { Text(currency).font(Theme.body(12, .bold)).foregroundStyle(Theme.muted) }
                    TextField("0", text: Binding(get: { inputs[m.id] ?? "" }, set: { inputs[m.id] = $0 }))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .font(.system(size: 17, weight: .bold, design: .rounded)).frame(width: mode == .exact ? 90 : 56)
                        .focused($focus, equals: m.id)
                    if mode == .percent { Text("%").font(Theme.body(14, .bold)).foregroundStyle(Theme.muted).fixedSize() }
                }
                .padding(.horizontal, 10).frame(minHeight: 40).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            }
            .accessibilityElement(children: .contain)
        case .shares:
            HStack(spacing: 12) {
                Avatar(name: name, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.body(15, .semibold))
                    Text(share.map { Format.money($0, currency) } ?? "No share").font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                stepper(m.id)
            }
        }
    }

    private func stepper(_ id: Int) -> some View {
        let v = weights[id] ?? 0
        return HStack(spacing: 0) {
            Button { weights[id] = max(0, v - 1) } label: { Image(systemName: "minus").frame(width: 40, height: 40) }
                .accessibilityLabel("Fewer shares")
            Text(v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v))
                .font(.system(size: 17, weight: .heavy, design: .rounded)).frame(width: 34)
            Button { weights[id] = v + 1 } label: { Image(systemName: "plus").frame(width: 40, height: 40) }
                .accessibilityLabel("More shares")
        }
        .foregroundStyle(Theme.text)
        .overlay(Rectangle().stroke(Theme.line))
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(v)) shares")
    }

    @ViewBuilder
    private var splitStatus: some View {
        switch mode {
        case .exact:
            let rem = preview.remaining
            HStack {
                Text(rem == 0 ? "All assigned" : (rem > 0 ? "\(Format.money(rem, currency)) left to assign" : "Over by \(Format.money(-rem, currency))"))
                    .font(Theme.body(13, .semibold)).foregroundStyle(rem == 0 ? Theme.owed : Theme.muted)
                Spacer()
                if rem > 0, let empty = people.first(where: { (Format.minor(from: inputs[$0] ?? "", currency: currency) ?? 0) == 0 }) {
                    Button("Give rest to \(group.members.first { $0.id == empty }.map { $0.isYou ? "you" : ($0.name ?? "") } ?? "")") {
                        inputs[empty] = Format.majorString(rem, currency)
                    }
                    .font(Theme.body(12, .bold))
                }
            }
        case .percent:
            HStack {
                let t = preview.percentTotal
                Text("Total \(t.formatted(.number.precision(.fractionLength(0...2))))%")
                    .font(Theme.body(13, .semibold)).foregroundStyle(abs(t - 100) <= 0.01 ? Theme.owed : Theme.muted)
                Spacer()
                Button("Split evenly") { evenPercents() }.font(Theme.body(12, .bold))
            }
        default:
            EmptyView()
        }
    }

    private func pill(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Theme.body(14, .semibold)).padding(.horizontal, 14).frame(minHeight: 38)
                .foregroundStyle(selected ? Theme.bg : Theme.text)
                .background(selected ? Theme.text : Theme.surface)
                .overlay(Rectangle().stroke(Theme.line))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func switchMode(_ m: SplitMode) {
        guard m != mode else { return }
        mode = m
        inputs = [:]
        switch m {
        case .shares: weights = Dictionary(uniqueKeysWithValues: people.map { ($0, included.contains($0) ? 1 : 0) })
        case .percent: evenPercents()
        case .exact:
            if let t = totalMinor {   // start from the equal split so the user only adjusts
                let eq = SplitMath.compute(total: t, mode: .equal, people: people, included: included, values: [:]).shares
                inputs = eq.mapValues { Format.majorString($0, currency) }
            }
        case .equal: break
        }
    }

    private func evenPercents() {
        let ids = people.filter(included.contains)
        guard !ids.isEmpty else { return }
        let parts = SplitMath.allocate(10000, ids.map { _ in 1 })   // in basis points, sums to 100.00
        inputs = Dictionary(uniqueKeysWithValues: zip(ids, parts.map { p in
            p % 100 == 0 ? "\(p / 100)" : String(format: "%.2f", Double(p) / 100)
        }))
    }

    // MARK: data

    private func prefill() {
        payer = state.user?.id ?? 0
        currency = groupCurrency
        let ids = Set(people)
        if let e = editing {
            desc = e.description
            category = ExpenseCategory(rawValue: e.category ?? "other")
            currency = e.originalCurrency ?? e.currency
            let total = e.originalAmountMinor ?? e.amountPaise
            amount = Format.majorString(total, currency)
            payer = e.paidBy
            included = Set(e.splits.filter { $0.sharePaise > 0 }.map(\.userId))
            let meta = e.splitMeta
            switch e.splitType ?? "EQUAL" {
            case "EXACT":
                mode = .exact
                inputs = Dictionary(uniqueKeysWithValues: (meta?.exact ?? [:]).compactMap { k, v in Int(k).map { ($0, Format.majorString(v, currency)) } })
            case "PERCENT":
                mode = .percent
                inputs = Dictionary(uniqueKeysWithValues: (meta?.percents ?? [:]).compactMap { k, v in
                    Int(k).map { ($0, v == v.rounded() ? "\(Int(v))" : "\(v)") } })
            case "SHARES":
                mode = .shares
                weights = Dictionary(uniqueKeysWithValues: (meta?.shares ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } })
            default:
                mode = .equal
            }
        } else {
            let last = UserDefaults.standard.array(forKey: "lastSplit.\(group.id)") as? [Int]
            let remembered = Set(last ?? []).intersection(ids)
            included = remembered.isEmpty ? ids : remembered
            focus = -1
        }
    }

    private func requestBody(for total: Int) -> [String: Any?] {
        var b: [String: Any?] = ["description": desc, "amount_paise": total, "currency": currency, "paid_by": payer,
                                 "split_type": mode.rawValue, "category": category?.rawValue]
        func keyed<T>(_ d: [Int: T]) -> [String: T] { Dictionary(uniqueKeysWithValues: d.map { (String($0.key), $0.value) }) }
        switch mode {
        case .equal: b["participants"] = Array(included).sorted()
        case .exact: b["exact"] = keyed(values.mapValues { Int($0) })
        case .percent: b["percents"] = keyed(values)
        case .shares: b["shares"] = keyed(weights.filter { $0.value > 0 })
        }
        return b
    }

    private func save() async {
        guard let total = totalMinor else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if let e = editing {
                let _: Expense = try await APIClient.shared.request("PATCH", "/expenses/\(e.id)", body: requestBody(for: total))
                onSaved()
                state.refreshTick += 1
                dismiss()
            } else {
                let e: Expense = try await APIClient.shared.request("POST", "/groups/\(group.id)/expenses", body: requestBody(for: total))
                if mode == .equal { UserDefaults.standard.set(Array(included), forKey: "lastSplit.\(group.id)") }
                onSaved()
                if e.successHint != nil && group.coinsEnabled { withAnimation { saved = e } } else { dismiss() }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// S3 success sheet.
    private func successSheet(_ e: Expense) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer().frame(height: 10)
            Image(systemName: "checkmark").font(.system(size: 26, weight: .black)).foregroundStyle(Theme.bg)
                .frame(width: 56, height: 56).background(Theme.owed)
            let names = (e.successHint?.notified ?? []).compactMap { $0 }
            if let hint = e.successHint, hint.adderCoins > 0 {
                Text(Strings.addedSuccess(hint.adderCoins, Format.names(names))).font(Theme.title(24))
            } else {
                Text("Added.").font(Theme.title(24))
            }
            if !names.isEmpty {
                Text("Notified: \(names.joined(separator: ", "))").font(Theme.body(14)).foregroundStyle(Theme.muted)
            }
            Spacer()
            NeoPopButton(title: "Done") { dismiss() }
            NeoPopButton(title: "Remind", style: .stroke, icon: "bell") {
                Task {
                    if let r: RemindResponse = try? await APIClient.shared.request("POST", "/expenses/\(e.id)/remind") {
                        state.showToast(r.reminded.isEmpty ? "They were just notified" : "Reminded \(Format.names(r.reminded.compactMap(\.name)))")
                    }
                    dismiss()
                }
            }
        }
        .padding(24)
    }
}
