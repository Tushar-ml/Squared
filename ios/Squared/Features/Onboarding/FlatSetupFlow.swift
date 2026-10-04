import SwiftUI

/// Guided setup for a new user without a group: pick a kind, name it → invite → first expense.
/// Each step is skippable after the group exists; the Home checklist picks up wherever they left off.
struct FlatSetupFlow: View {
    enum Step: Int { case create, invite, expense }

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var step: Step = .create
    @State var groupId: Int?
    @State private var groupName = ""
    @State private var people = 3
    @State private var kind: GroupKind = .home
    @State private var busy = false
    @State private var personName = ""
    // invite
    @State private var members: [Member] = []
    // expense
    @State private var desc = ""
    @State private var amount = ""
    @Environment(\.openURL) private var openURL


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if step != .create {
                    Button { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .create } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back")
                }
                Spacer()
                Button(step == .create ? "Later" : "Skip") { skip() }
                    .font(Theme.body(15, .semibold)).foregroundStyle(Theme.muted).frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            PageBars(count: 3, current: step.rawValue).padding(.horizontal, 24).padding(.bottom, 20)
            ScrollView {
                Group {
                    switch step {
                    case .create: createStep
                    case .invite: inviteStep
                    case .expense: expenseStep
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 120)
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.bg)
        .overlay(alignment: .bottom) { cta.padding(.horizontal, 24).padding(.bottom, 8) }
        .onAppear { APIClient.shared.track("flat_setup_started", props: ["step": step.rawValue]) }
        .task(id: step) { if step == .invite { await loadMembers() } }
    }

    // MARK: steps

    private var createStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel("Step 1 of 3", color: Theme.coin)
            Text("What are you splitting?").font(Theme.title(30))
            KindPicker(selected: $kind)
            TextField(kind.namePlaceholder, text: $groupName)
                .font(Theme.body(22, .bold)).textInputAutocapitalization(.words)
                .padding(16).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(kind.nameIdeas, id: \.self) { idea in chip(idea, selected: groupName == idea) { groupName = idea } }
                }
            }
            if kind.fixedSize == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("How many people, including you?").font(Theme.body(15, .semibold))
                HStack(spacing: 10) {
                    ForEach(2...6, id: \.self) { n in
                        Button { people = n } label: {
                            Text(n == 6 ? "6+" : "\(n)").font(.system(size: 18, weight: .heavy, design: .rounded))
                                .frame(width: 50, height: 50)
                                .foregroundStyle(people == n ? Theme.bg : Theme.text)
                                .background(people == n ? Theme.text : Theme.surface)
                                .overlay(Rectangle().stroke(Theme.line))
                        }
                        .accessibilityLabel("\(n) people")
                        .accessibilityAddTraits(people == n ? .isSelected : [])
                    }
                }
                Text("Next you'll add their names. Nobody needs the app.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            }
        }
    }

    private var inviteStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel("Step 2 of 3", color: Theme.coin)
            Text("Who's splitting with you?").font(Theme.title(30))
            HStack(spacing: 10) {
                TextField("Name", text: $personName)
                    .font(Theme.body(18, .bold)).textInputAutocapitalization(.words).submitLabel(.done)
                    .onSubmit { Task { await addPerson() } }
                    .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                NeoPopButton(title: "Add", enabled: !personName.trimmingCharacters(in: .whitespaces).isEmpty, height: 50) {
                    Task { await addPerson() }
                }
                .frame(width: 90)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("In \(groupName.isEmpty ? "your group" : groupName)")
                ForEach(members) { m in
                    HStack(spacing: 12) {
                        Avatar(name: m.isYou ? "You" : (m.name ?? "?"), size: 36)
                        Text(m.isYou ? "You" : (m.name ?? "")).font(Theme.body(15, .semibold))
                        Spacer()
                    }
                }
            }
            .padding(.top, 6)
            Text("Add UPI IDs later from the group's people list, for one-tap payments.")
                .font(Theme.body(13)).foregroundStyle(Theme.muted)
        }
    }

    private var expenseStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel("Step 3 of 3", color: Theme.coin)
            Text("Add your first shared expense").font(Theme.title(30))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(kind.expenseIdeas, id: \.0) { idea in
                    Button { desc = idea.0 } label: {
                        VStack(spacing: 6) {
                            Image(systemName: idea.1).font(.system(size: 18, weight: .semibold))
                            Text(idea.0).font(Theme.body(12, .semibold)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 66)
                        .foregroundStyle(desc == idea.0 ? Theme.bg : Theme.text)
                        .background(desc == idea.0 ? Theme.text : Theme.surface)
                        .overlay(Rectangle().stroke(Theme.line))
                    }
                    .accessibilityAddTraits(desc == idea.0 ? .isSelected : [])
                }
            }
            TextField("Or type what it was", text: $desc)
                .font(Theme.body(18, .bold))
                .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            HStack {
                Text("INR").font(Theme.number(22)).foregroundStyle(Theme.muted)
                TextField("0", text: $amount).keyboardType(.decimalPad).font(Theme.number(30))
            }
            .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            Group {
                if members.count >= 2 {
                    let share = (Format.paise(from: amount) ?? 0) / max(members.count, 1)
                    Text("You paid · split equally between \(members.count)" + (share > 0 ? ", \(Format.inr(paise: share)) each" : ""))
                } else {
                    Text("You paid · everyone sees their share as soon as they join")
                }
            }
            .font(Theme.body(13)).foregroundStyle(Theme.muted)
            if members.count >= 2 && state.coinsLive {
                HStack(spacing: 8) {
                    CoinGlyph(size: 16)
                    Text("When someone confirms it, you both earn coins. First one is +\(state.config?.earn.firstWin ?? 50).")
                        .font(Theme.body(13, .semibold))
                }
                .foregroundStyle(Theme.coin)
            }
        }
        .onAppear { APIClient.shared.track("first_expense_started", groupId: groupId) }
    }

    // MARK: CTA

    @ViewBuilder
    private var cta: some View {
        switch step {
        case .create:
            NeoPopFloatingButton(title: "Create group", enabled: !busy && !groupName.trimmingCharacters(in: .whitespaces).isEmpty) {
                Task { await create() }
            }
        case .invite:
            NeoPopFloatingButton(title: "Continue", shimmer: members.count >= 2, enabled: members.count >= 2) {
                withAnimation { step = .expense }
            }
        case .expense:
            NeoPopFloatingButton(title: "Add expense", enabled: !busy && !desc.isEmpty && Format.paise(from: amount) != nil) {
                Task { await addExpense() }
            }
        }
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Theme.body(14, .semibold)).padding(.horizontal, 14).frame(minHeight: 38)
                .foregroundStyle(selected ? Theme.bg : Theme.text)
                .background(selected ? Theme.text : Theme.surface)
                .overlay(Rectangle().stroke(Theme.line))
        }
    }

    // MARK: actions

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let g: GroupSummary = try await APIClient.shared.request("POST", "/groups", body: [
                "name": groupName, "group_type": kind.rawValue, "expected_members": kind.fixedSize ?? people])
            groupId = g.id
            APIClient.shared.track("flat_created", groupId: g.id, props: ["expected_members": kind.fixedSize ?? people, "group_type": kind.rawValue])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { step = .invite }
            state.refreshTick += 1
        } catch { state.showToast(error.localizedDescription) }
    }

    private func addPerson() async {
        let n = personName.trimmingCharacters(in: .whitespaces)
        guard let groupId, !n.isEmpty else { return }
        do {
            try await APIClient.shared.raw("POST", "/groups/\(groupId)/members", body: ["name": n])
            personName = ""
            await loadMembers()
        } catch { state.showToast(error.localizedDescription) }
    }

    private func loadMembers() async {
        guard let groupId, let d: GroupDetail = try? await APIClient.shared.request("GET", "/groups/\(groupId)") else { return }
        members = d.members
        groupName = d.name
    }

    private func addExpense() async {
        guard let groupId, let paise = Format.paise(from: amount) else { return }
        busy = true
        defer { busy = false }
        do {
            let _: Expense = try await APIClient.shared.request("POST", "/groups/\(groupId)/expenses", body: [
                "description": desc, "amount_paise": paise])
            finish()
        } catch { state.showToast(error.localizedDescription) }
    }

    private func skip() {
        if step == .create { dismiss(); return }
        if step == .invite { APIClient.shared.track("invite_step_skipped", groupId: groupId) }
        finish()
    }

    private func finish() {
        let gid = groupId
        dismiss()
        Task {
            await state.refreshActivation()
            state.refreshTick += 1
            if let gid { state.open(.group(gid)) }
        }
    }
}


/// Grid of group kinds (Home, Trip, Couple…) used when creating a group.
struct KindPicker: View {
    @Binding var selected: GroupKind
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(GroupKind.pickable) { k in
                Button { selected = k } label: {
                    VStack(spacing: 6) {
                        Image(systemName: k.icon).font(.system(size: 18, weight: .semibold))
                        Text(k.label).font(Theme.body(12, .semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .foregroundStyle(selected == k ? Theme.bg : Theme.text)
                    .background(selected == k ? Theme.text : Theme.surface)
                    .overlay(Rectangle().stroke(Theme.line))
                }
                .accessibilityLabel(k.label)
                .accessibilityAddTraits(selected == k ? .isSelected : [])
            }
        }
    }
}
