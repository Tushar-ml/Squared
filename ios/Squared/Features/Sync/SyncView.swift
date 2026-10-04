import SwiftUI

/// Sync with phones nearby. Both people open this screen; one taps the other's name.
struct SyncView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var groupId: Int? = nil
    var groupName: String? = nil
    @State private var sync = NearbySync()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(groupName.map { "Share \($0)" } ?? "Sync nearby", color: Theme.coin)
                        Text(groupName == nil ? "Sync shared groups with friends nearby" : "Hand this group to a friend nearby")
                            .font(Theme.title(24)).fixedSize(horizontal: false, vertical: true)
                        Text("Both of you open Sync on the same Wi-Fi, or with Bluetooth on. Then tap their name. Everything travels phone to phone.")
                            .font(Theme.body(14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    SectionLabel("Phones nearby")
                    if sync.nearby.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking… ask them to open Sync too.").font(Theme.body(14)).foregroundStyle(Theme.muted)
                        }
                        .frame(minHeight: 44)
                    }
                    ForEach(sync.nearby) { n in
                        HStack(spacing: 12) {
                            Avatar(name: n.name, tick: sync.connected.contains(n.name), size: 40)
                            Text(n.name).font(Theme.body(16, .semibold))
                            Spacer()
                            if sync.connected.contains(n.name) {
                                StatusChip(text: "Connected", tint: Theme.owed)
                            } else {
                                NeoPopButton(title: "Sync", style: .stroke, height: 36) { sync.connect(n) }.frame(width: 96)
                            }
                        }
                    }
                    if !sync.log.isEmpty {
                        SectionLabel("What happened")
                        ForEach(Array(sync.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(Theme.body(13)).foregroundStyle(Theme.muted)
                        }
                    }
                    Text("Coins stay on each phone. Bill photos, recurring rules and budgets aren't shared.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted).padding(.top, 8)
                }
                .padding(24)
            }
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            sync.offerGroupId = groupId
            sync.onChange = { state.refreshTick += 1 }
            sync.start()
        }
        .onDisappear { sync.stop() }
        .sheet(item: $sync.pendingJoin) { p in JoinSharedGroupSheet(pending: p) { claim in sync.join(p, as: claim) } }
    }
}

/// First time a group arrives: which of its members is you?
struct JoinSharedGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pending: NearbySync.PendingJoin
    let onPick: (String) -> Void

    private var choices: [SyncEngine.PersonRec] {
        let b = pending.bundle
        return b.people.filter { b.group.members.contains($0.uid) && $0.uid != b.group.senderUid }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("From \(pending.from)", color: Theme.coin)
            Text("Join \(pending.bundle.group.name)?").font(Theme.title(26))
            Text("Which one is you? Expenses for that person will show as yours.").font(Theme.body(14)).foregroundStyle(Theme.muted)
            ForEach(choices, id: \.uid) { p in
                Button { onPick(p.uid); dismiss() } label: {
                    HStack(spacing: 12) {
                        Avatar(name: p.name, size: 40)
                        Text("I'm \(p.name)").font(Theme.body(17, .bold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                    }
                    .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                }
                .buttonStyle(.plain)
            }
            if choices.isEmpty {
                Text("\(pending.from) hasn't added you to this group yet. Ask them to add your name, then sync again.")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted)
            }
            Button("Not now") { dismiss() }.font(Theme.body(15, .semibold)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, minHeight: 44)
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }
}
