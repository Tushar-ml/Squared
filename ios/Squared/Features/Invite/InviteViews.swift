import SwiftUI

/// Add the people you split with. They're names on this device (with an optional UPI ID for one-tap pay);
/// nobody gets an invite or needs the app.
struct InviteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let groupId: Int
    let groupName: String
    var coinsEnabled = true
    @State private var members: [Member] = []
    @State private var name = ""
    @State private var upi = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionLabel("People in \(groupName)")
                    ForEach(members) { m in
                        HStack(spacing: 12) {
                            Avatar(name: m.isYou ? "You" : (m.name ?? "?"), size: 36)
                            Text(m.isYou ? "You" : (m.name ?? "")).font(Theme.body(16, .semibold))
                            Spacer()
                        }
                    }
                    SectionLabel("Add someone")
                    TextField("Name", text: $name)
                        .font(Theme.body(18, .bold)).textInputAutocapitalization(.words).focused($focused)
                        .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                        .submitLabel(.done).onSubmit { Task { await add() } }
                    TextField("UPI ID (optional, for one-tap pay)", text: $upi)
                        .font(Theme.body(15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                    NeoPopButton(title: "Add", enabled: !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty, loading: busy) {
                        Task { await add() }
                    }
                    Text("Only names live in Squared, on this phone. Nobody is contacted.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                .padding(24)
            }
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task { await load(); focused = true }
    }

    private func load() async {
        if let d: GroupDetail = try? await APIClient.shared.request("GET", "/groups/\(groupId)") { members = d.members }
    }

    private func add() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared.raw("POST", "/groups/\(groupId)/members", body: ["name": n, "upi_id": upi])
            name = ""; upi = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
            state.refreshTick += 1
        } catch { state.showToast(error.localizedDescription) }
    }
}

struct CreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    let onCreated: (Int) -> Void
    @State private var name = ""
    @State private var kind: GroupKind = .home
    @State private var people = 3
    @State private var busy = false
    @State private var currency = "INR"
    @State private var showCurrency = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("New group")
            KindPicker(selected: $kind)
            TextField(kind.namePlaceholder, text: $name).font(Theme.body(22, .bold))
                .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            if kind.fixedSize == nil {
                Stepper("People, including you: \(people)", value: $people, in: 2...20).font(Theme.body(15, .semibold))
            }
            Button { showCurrency = true } label: {
                HStack {
                    Text("Group currency").font(Theme.body(15, .semibold))
                    Spacer()
                    Text(currency).font(Theme.body(15, .heavy))
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                }
                .frame(minHeight: 44)
            }
            .foregroundStyle(Theme.text)
            NeoPopButton(title: "Create", enabled: !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                Task { await create() }
            }
            Spacer()
        }
        .padding(24)
        .presentationDetents([.height(560)])
        .presentationBackground(Theme.bg)
        .sheet(isPresented: $showCurrency) { CurrencyPicker(selected: currency, reference: "INR") { currency = $0 } }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let g: GroupSummary = try await APIClient.shared.request("POST", "/groups", body: [
                "name": name, "group_type": kind.rawValue, "expected_members": kind.fixedSize ?? people, "currency": currency])
            dismiss()
            onCreated(g.id)
        } catch { state.showToast(error.localizedDescription) }
    }
}
