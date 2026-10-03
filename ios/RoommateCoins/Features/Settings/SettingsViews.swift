import SwiftUI

/// S10 first-run intro: three skippable cards, never shown twice.
struct IntroView: View {
    @Environment(\.dismiss) private var dismiss
    let onFinish: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Spacer()
                Button("Skip") { finish(skipped: true) }.font(Theme.body(15, .semibold)).foregroundStyle(Theme.muted).frame(minHeight: 44)
            }
            TabView(selection: $page) {
                ForEach(Strings.intro.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 18) {
                        ZStack {
                            Rectangle().fill(Theme.surface).frame(height: 220).overlay(Rectangle().stroke(Theme.line))
                            illustration(i)
                        }
                        SectionLabel("\(i + 1) of 3", color: Theme.coin)
                        Text(Strings.intro[i].0).font(Theme.title(28)).fixedSize(horizontal: false, vertical: true)
                        Text(Strings.intro[i].1).font(Theme.body(16)).foregroundStyle(Theme.muted)
                        Spacer()
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            NeoPopFloatingButton(title: page < 2 ? "Next" : "Start earning") {
                if page < 2 { withAnimation { page += 1 } } else { finish(skipped: false) }
            }
        }
        .padding(24)
        .background(Theme.bg)
        .onAppear { APIClient.shared.track("intro_viewed") }
    }

    @ViewBuilder
    private func illustration(_ i: Int) -> some View {
        switch i {
        case 0: Image(systemName: "list.bullet.rectangle.portrait").font(.system(size: 70, weight: .light))
        case 1: HStack(spacing: -10) { Avatar(name: "A", tick: true, size: 64); Avatar(name: "P", tick: true, size: 64) }
        default: CoinGlyph(size: 90)
        }
    }

    private func finish(skipped: Bool) {
        if skipped { APIClient.shared.track("intro_skipped") }
        onFinish()
        dismiss()
    }
}

/// FR-15 preferences: hide coin UI and per-type notification toggles.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var prefs: [NotificationPref] = []
    @State private var hideCoins = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let u = state.user {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(u.name).font(Theme.title(24))
                            Text(u.phone).font(Theme.body(14)).foregroundStyle(Theme.muted)
                            if let upi = u.upiId { Text("UPI: \(upi)").font(Theme.body(13)).foregroundStyle(Theme.muted) }
                        }
                        NeoPopButton(title: "Edit profile", style: .stroke, height: 44) { state.needsProfile = true; dismiss() }
                    }
                    SectionLabel("Coins")
                    NeoPopToggle(label: "Hide coins", isOn: $hideCoins)
                    Text("Splitting, balances and settling work the same either way.").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    SectionLabel("Notifications")
                    ForEach($prefs) { $p in NeoPopToggle(label: p.label, isOn: $p.enabled) }
                    Text("We send at most 2 coin notifications a day and none between 10 pm and 8 am.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                    NeoPopButton(title: "Sign out", style: .flatStroke, height: 44) { state.signOut(); dismiss() }
                        .padding(.top, 12)
                    Text("Roommate Coins \(APIClient.appVersion) · \(APIClient.shared.baseURL.host() ?? "")")
                        .font(Theme.body(11)).foregroundStyle(Theme.muted)
                }
                .padding(24)
            }
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task { await load() }
        .onChange(of: hideCoins) { _, v in if loaded { Task { await setHide(v) } } }
        .onChange(of: prefs) { old, new in if loaded && !old.isEmpty { Task { await save(new) } } }
    }

    private func load() async {
        if let r: PrefsResponse = try? await APIClient.shared.request("GET", "/me/notification-prefs") {
            prefs = r.prefs
            hideCoins = r.hideCoins
        }
        try? await Task.sleep(for: .milliseconds(50))
        loaded = true
    }

    private func setHide(_ v: Bool) async {
        if let u: User = try? await APIClient.shared.request("PATCH", "/me", body: ["hide_coins": v]) {
            state.user = u
            state.refreshTick += 1
        }
    }

    private func save(_ p: [NotificationPref]) async {
        let dict = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0.enabled) })
        _ = try? await APIClient.shared.raw("PUT", "/me/notification-prefs", body: ["prefs": dict])
    }
}

/// In-app inbox: every coin notification, including ones held back by quiet hours or the daily cap.
struct NotificationsInboxView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AppNotification] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded && items.isEmpty {
                    Text("Nothing here yet.").foregroundStyle(Theme.muted).listRowBackground(Theme.bg)
                }
                ForEach(items) { n in
                    Button { open(n) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(n.title).font(Theme.body(15, .bold))
                                Spacer()
                                Text(Format.relative(n.createdAt)).font(Theme.body(11)).foregroundStyle(Theme.muted)
                            }
                            Text(n.body).font(Theme.body(14)).foregroundStyle(n.read ? Theme.muted : Theme.text)
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task {
            if let r: NotificationsResponse = try? await APIClient.shared.request("GET", "/me/notifications") { items = r.notifications }
            loaded = true
            _ = try? await APIClient.shared.raw("POST", "/me/notifications/read-all")
        }
    }

    private func open(_ n: AppNotification) {
        Task { _ = try? await APIClient.shared.raw("POST", "/me/notifications/\(n.id)/event", body: ["event": "opened"]) }
        dismiss()
        if let e = n.payload["expense_id"]?.intValue { state.open(.expense(e)) }
        else if n.payload["route"]?.stringValue == "wallet" { state.open(.wallet) }
        else if n.payload["route"]?.stringValue == "redeem" { state.open(.redeem) }
        else if let g = n.payload["group_id"]?.intValue {
            state.open(n.payload["route"]?.stringValue == "settle" ? .settle(g) : .group(g))
        }
    }
}
