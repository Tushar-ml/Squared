import SwiftUI

struct ExpenseDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let expenseId: Int
    @State private var expense: Expense?
    @State private var error: String?
    @State private var showDispute = false
    @State private var showEdit = false
    @State private var reminded: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let e = expense {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e.description).font(Theme.title(28))
                        Text(Format.inr(paise: e.amountPaise)).font(Theme.number(36))
                        Text("\(e.paidByName ?? "") paid · added by \(e.createdByName ?? "") · \(Format.relative(e.createdAt))")
                            .font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                    if let c = e.confirmation { confirmationSection(e, c) }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Split")
                        ForEach(e.splits, id: \.userId) { s in
                            HStack {
                                Text(s.userId == state.user?.id ? "You" : (s.name ?? "")).font(Theme.body(15))
                                Spacer()
                                Text(Format.inr(paise: s.sharePaise)).font(Theme.body(15, .bold))
                            }
                            .padding(.vertical, 6)
                            Divider().overlay(Theme.line)
                        }
                    }
                    HStack(spacing: 12) {
                        NeoPopButton(title: "Edit", style: .stroke, icon: "pencil", height: 44) { showEdit = true }
                        NeoPopButton(title: "Delete", style: .flatStroke, icon: "trash", height: 44) { Task { await delete() } }
                    }
                } else if let error {
                    Text(error).foregroundStyle(Theme.muted)
                } else {
                    Skeleton(height: 120)
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: state.refreshTick) { Task { await load() } }
        .sheet(isPresented: $showDispute) { if let e = expense { NotRightSheet(expense: e) { Task { await load() } } } }
        .sheet(isPresented: $showEdit) { if let e = expense { EditExpenseSheet(expense: e) { Task { await load() } } } }
    }

    @ViewBuilder
    private func confirmationSection(_ e: Expense, _ c: Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ConfirmationChip(confirmation: c)
                ForEach(c.confirmedBy, id: \.userId) { p in
                    Text(Strings.confirmedBy(p.name ?? "")).font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
            }
            ForEach(c.disputedBy, id: \.userId) { d in
                Text("\(d.name ?? "") says it isn't right: \(reasonText(d.reason))\(d.note.map { ", \"\($0)\"" } ?? "")")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            if c.canConfirm {
                ConfirmBar(expense: e, source: "detail", onDone: { Task { await load() } }, onDispute: { showDispute = true })
            } else if e.createdBy == state.user?.id, !c.waitingOn.isEmpty {
                Text(Strings.waitingFor(Format.names(c.waitingOn.compactMap(\.name)))).font(Theme.body(15, .semibold))
                if !c.canRemind.isEmpty {
                    NeoPopButton(title: "Remind", style: .stroke, icon: "bell", height: 44, parent: Theme.UI.surface) {
                        Task { await remind() }
                    }
                } else {
                    Text(reminded.isEmpty ? "Reminded recently. You can nudge again tomorrow." : "Reminded \(Format.names(reminded))")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                if c.adderReward > 0 && c.status == "WAITING" {
                    Text("You earn \(c.adderReward) coins when \(Format.names(c.waitingOn.compactMap(\.name))) confirms.")
                        .font(Theme.body(12)).foregroundStyle(Theme.coin)
                }
            } else if c.status == "DISPUTED" && e.createdBy == state.user?.id {
                Text("Edit the amount, payer or split and your roommates can confirm again.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
        }
        .neoPopCard(depth: 5, padding: 16)
    }

    private func reasonText(_ r: String?) -> String {
        switch r { case "WRONG_AMOUNT": "wrong amount"; case "NOT_MINE": "not mine"; default: "other" }
    }

    private func load() async {
        do { expense = try await APIClient.shared.request("GET", "/expenses/\(expenseId)") }
        catch { self.error = error.localizedDescription }
    }

    private func remind() async {
        do {
            let r: RemindResponse = try await APIClient.shared.request("POST", "/expenses/\(expenseId)/remind")
            reminded = r.reminded.compactMap(\.name)
            state.showToast(reminded.isEmpty ? "Already reminded today" : "Reminded \(Format.names(reminded))")
            await load()
        } catch { state.showToast(error.localizedDescription) }
    }

    private func delete() async {
        do {
            try await APIClient.shared.raw("DELETE", "/expenses/\(expenseId)")
            state.refreshTick += 1
            dismiss()
        } catch { state.showToast(error.localizedDescription) }
    }
}

/// Add expense: no coin fields added to the form (design theme "tiny steps").
struct AddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    let group: GroupDetail
    let onSaved: () -> Void

    @State private var desc = ""
    @State private var amount = ""
    @State private var payer: Int = 0
    @State private var included: Set<Int> = []
    @State private var busy = false
    @State private var error: String?
    @State private var saved: Expense?
    @FocusState private var focus: Field?
    enum Field { case desc, amount }

    var body: some View {
        NavigationStack {
            Group {
                if let saved { successSheet(saved) } else { form }
            }
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(saved == nil ? "Cancel" : "Close") { dismiss() } }
            }
        }
        .onAppear {
            payer = state.user?.id ?? 0
            let lastSplit = UserDefaults.standard.array(forKey: "lastSplit.\(group.id)") as? [Int]
            let ids = Set(group.members.map(\.id))
            included = Set(lastSplit ?? []).intersection(ids).isEmpty ? ids : Set(lastSplit!).intersection(ids)
            focus = .desc
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionLabel("Add expense · \(group.name)")
                TextField("What was it? e.g. Wifi bill", text: $desc)
                    .font(Theme.body(20, .bold)).focused($focus, equals: .desc).submitLabel(.next)
                    .onSubmit { focus = .amount }
                    .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                HStack {
                    Text("INR").font(Theme.number(22)).foregroundStyle(Theme.muted)
                    TextField("0", text: $amount).keyboardType(.decimalPad).font(Theme.number(30)).focused($focus, equals: .amount)
                }
                .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                SectionLabel("Paid by")
                ForEach(group.members) { m in
                    NeoPopRadioRow(label: m.isYou ? "You" : (m.name ?? ""), selected: payer == m.id) { payer = m.id }
                }
                SectionLabel("Split equally between")
                ForEach(group.members) { m in
                    NeoPopCheckRow(label: m.isYou ? "You" : (m.name ?? ""), detail: shareText(for: m.id),
                                   isOn: Binding(get: { included.contains(m.id) },
                                                 set: { on in if on { included.insert(m.id) } else { included.remove(m.id) } }))
                }
                if let error { Text(error).font(Theme.body(13)).foregroundStyle(Theme.owe) }
                NeoPopButton(title: "Save", enabled: canSave && !busy, loading: busy) { Task { await save() } }
                    .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private var canSave: Bool { !desc.trimmingCharacters(in: .whitespaces).isEmpty && Format.paise(from: amount) != nil && !included.isEmpty }

    private func shareText(for id: Int) -> String? {
        guard included.contains(id), let p = Format.paise(from: amount), !included.isEmpty else { return nil }
        return Format.inr(paise: p / included.count)
    }

    private func save() async {
        guard let paise = Format.paise(from: amount) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let e: Expense = try await APIClient.shared.request("POST", "/groups/\(group.id)/expenses", body: [
                "description": desc, "amount_paise": paise, "paid_by": payer, "participants": Array(included)])
            UserDefaults.standard.set(Array(included), forKey: "lastSplit.\(group.id)")
            onSaved()
            if e.successHint != nil && group.coinsEnabled { withAnimation { saved = e } } else { dismiss() }
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

struct EditExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    let expense: Expense
    let onSaved: () -> Void
    @State private var desc = ""
    @State private var amount = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Edit expense")
            TextField("Description", text: $desc).font(Theme.body(18, .bold))
                .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            HStack {
                Text("INR").font(Theme.number(20)).foregroundStyle(Theme.muted)
                TextField("0", text: $amount).keyboardType(.decimalPad).font(Theme.number(26))
            }
            .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            if expense.confirmation?.status == "CONFIRMED" {
                Text("Changing the amount resets confirmations. Roommates confirm again and coins are re-earned.")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            NeoPopButton(title: "Save", enabled: !busy && Format.paise(from: amount) != nil) { Task { await save() } }
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationBackground(Theme.bg)
        .onAppear {
            desc = expense.description
            amount = String(format: expense.amountPaise % 100 == 0 ? "%.0f" : "%.2f", Double(expense.amountPaise) / 100)
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared.raw("PATCH", "/expenses/\(expense.id)", body: [
                "description": desc, "amount_paise": Format.paise(from: amount)])
            onSaved()
            state.refreshTick += 1
            dismiss()
        } catch { state.showToast(error.localizedDescription) }
    }
}
