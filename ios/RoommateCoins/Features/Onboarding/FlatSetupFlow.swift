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
    @State private var showPaste = false
    // invite
    @State private var invite: InviteLink?
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
        .sheet(isPresented: $showPaste) { PasteInviteSheet() }
        .onChange(of: state.pendingJoinToken) { _, t in if t != nil { dismiss() } }  // joining instead of creating
        .task(id: step) {
            if step == .invite { await loadInvite() }
            while step == .invite && !Task.isCancelled {   // live "who joined" list
                await loadMembers()
                try? await Task.sleep(for: .seconds(3))
            }
        }
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
                Text("We'll remind you to invite everyone. Coins start as soon as one person joins.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            }
            Divider().overlay(Theme.line).padding(.vertical, 4)
            Button { showPaste = true } label: {
                HStack {
                    Image(systemName: "envelope.open")
                    Text("Someone already invited me").font(Theme.body(15, .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(Theme.text).frame(minHeight: 44)
            }
        }
    }

    private var inviteStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel("Step 2 of 3", color: Theme.coin)
            Text("Bring in your \(kind.people)").font(Theme.title(30))
            Text("Expenses only need a tap from them to be confirmed. Each person who joins and gets a first expense confirmed earns you both +\(state.config?.earn.inviteEach ?? 50) coins.")
                .font(Theme.body(15)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let invite {
                NeoPopButton(title: "Invite on WhatsApp", icon: "message.fill") {
                    APIClient.shared.track("invite_shared", groupId: groupId, props: ["channel": "whatsapp", "surface": "setup"])
                    if let url = URL(string: invite.whatsappUrl), UIApplication.shared.canOpenURL(url) { openURL(url) }
                    else { state.showToast("WhatsApp isn't installed. Use Share instead.") }
                }
                HStack(spacing: 12) {
                    ShareLink(item: invite.message) {
                        Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 14, weight: .heavy))
                            .frame(maxWidth: .infinity, minHeight: 48).overlay(Rectangle().stroke(Theme.text))
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        APIClient.shared.track("invite_shared", groupId: groupId, props: ["channel": "share_sheet", "surface": "setup"])
                    })
                    Button { UIPasteboard.general.string = invite.link; state.showToast("Link copied") } label: {
                        Label("Copy link", systemImage: "link").font(.system(size: 14, weight: .heavy))
                            .frame(maxWidth: .infinity, minHeight: 48).overlay(Rectangle().stroke(Theme.text))
                    }
                }
                .foregroundStyle(Theme.text)
            } else {
                Skeleton(height: 50)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("In \(groupName.isEmpty ? "your group" : groupName)")
                ForEach(members) { m in
                    HStack(spacing: 12) {
                        Avatar(name: m.isYou ? "You" : (m.name ?? "?"), tick: !m.isYou, size: 36)
                        Text(m.isYou ? "You" : (m.name ?? "")).font(Theme.body(15, .semibold))
                        Spacer()
                        if !m.isYou { StatusChip(text: "Joined", tint: Theme.owed) }
                    }
                }
                ForEach(0..<max(0, (kind.fixedSize ?? people) - members.count), id: \.self) { _ in
                    HStack(spacing: 12) {
                        Rectangle().stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])).frame(width: 36, height: 36)
                        Text("Waiting for someone to join").font(Theme.body(14)).foregroundStyle(Theme.muted)
                        Spacer()
                    }
                }
            }
            .padding(.top, 6)
        }
        .onAppear { APIClient.shared.track("invite_step_viewed", groupId: groupId) }
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
            NeoPopFloatingButton(title: members.count >= 2 ? "Continue" : "Continue without them", shimmer: members.count >= 2) {
                if members.count < 2 { APIClient.shared.track("invite_step_skipped", groupId: groupId) }
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

    private func loadInvite() async {
        guard let groupId, invite == nil else { return }
        invite = try? await APIClient.shared.request("POST", "/invites", body: ["group_id": groupId])
    }

    private func loadMembers() async {
        guard let groupId, let d: GroupDetail = try? await APIClient.shared.request("GET", "/groups/\(groupId)") else { return }
        if d.members.count > members.count && !members.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            state.announce("\(d.members.last?.name ?? "Someone") joined")
        }
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
