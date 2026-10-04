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

/// Your profile and the app's settings. Everything here lives on this device.
struct SettingsView: View {
    var showsDone = true
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var faceID = false
    @State private var hideCoins = false
    @State private var loaded = false
    @State private var confirmErase = false
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var confirmImport: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let u = state.user {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(u.name).font(Theme.title(24))
                            if let upi = u.upiId { Text("UPI: \(upi)").font(Theme.body(13)).foregroundStyle(Theme.muted) }
                        }
                        NeoPopButton(title: "Edit profile", style: .stroke, height: 44) { state.needsProfile = true; if showsDone { dismiss() } }
                    }
                    SectionLabel("Appearance")
                    HStack(spacing: 0) {
                        ForEach(Appearance.allCases) { a in
                            Button { state.appearance = a } label: {
                                Text(a.label).font(.system(size: 14, weight: .heavy)).frame(maxWidth: .infinity, minHeight: 42)
                                    .foregroundStyle(state.appearance == a ? Theme.bg : Theme.text)
                                    .background(state.appearance == a ? Theme.text : Theme.surface)
                            }
                            .accessibilityAddTraits(state.appearance == a ? .isSelected : [])
                        }
                    }
                    .overlay(Rectangle().stroke(Theme.line))
                    Button("App language: change in iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(Theme.body(13, .semibold)).foregroundStyle(Theme.muted)
                    SectionLabel("Security")
                    NeoPopToggle(label: "Lock with Face ID", isOn: $faceID)
                    SectionLabel("Coins")
                    NeoPopToggle(label: "Hide coins", isOn: $hideCoins)
                    Text("Splitting, balances and settling work the same either way.").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    SectionLabel("Your data")
                    Text("Everything is stored only on this device. Export a backup now and then; iCloud device backups include it too.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                    HStack(spacing: 12) {
                        NeoPopButton(title: "Export backup", style: .stroke, icon: "square.and.arrow.up", height: 44) { exportBackup() }
                        NeoPopButton(title: "Import", style: .stroke, icon: "square.and.arrow.down", height: 44) { importing = true }
                    }
                    Text("Backups contain groups, people, expenses, payments and coins. Bill photos stay on the device.")
                        .font(Theme.body(11)).foregroundStyle(Theme.muted)
                    Button(role: .destructive) { confirmErase = true } label: {
                        Text("Erase all data").font(Theme.body(15, .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .foregroundStyle(Theme.owe)
                    .padding(.top, 8)
                    Text("Squared \(APIClient.appVersion) · offline").font(Theme.body(11)).foregroundStyle(Theme.muted)
                }
                .padding(24)
            }
            .background(Theme.bg)
            .navigationTitle(showsDone ? "" : "Account")
            .toolbar { if showsDone { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } } }
        }
        .task {
            faceID = state.faceIDEnabled
            hideCoins = state.user?.hideCoins ?? false
            try? await Task.sleep(for: .milliseconds(50))
            loaded = true
        }
        .onChange(of: faceID) { _, v in
            guard v != state.faceIDEnabled else { return }
            if v {
                Task {
                    if await AppLock.authenticate(reason: "Turn on Face ID lock") { state.faceIDEnabled = true }
                    else { faceID = false }
                }
            } else { state.faceIDEnabled = false }
        }
        .onChange(of: hideCoins) { _, v in if loaded { Task { await setHide(v) } } }
        .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { confirmImport = url }
        }
        .alert("Replace everything with this backup?", isPresented: Binding(get: { confirmImport != nil }, set: { if !$0 { confirmImport = nil } })) {
            Button("Replace", role: .destructive) { if let u = confirmImport { importBackup(u) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your current groups and expenses on this device are replaced by the backup.") }
        .alert("Erase all data?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every group, person, expense, photo and coin on this device is deleted. Export a backup first if you might want it back.") }
    }

    private func exportBackup() {
        do {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Squared-backup-\(f.string(from: Date())).json")
            try LocalDB.shared.exportData().write(to: url, options: .atomic)
            exportURL = url
        } catch { state.showToast("Couldn't create the backup") }
    }

    private func importBackup(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            try LocalDB.shared.importData(try Data(contentsOf: url))
            Task { await state.startLocal(); state.refreshTick += 1 }
            state.showToast("Backup restored")
        } catch { state.showToast("That file isn't a Squared backup") }
    }

    private func erase() {
        try? LocalDB.shared.eraseEverything()
        if showsDone { dismiss() }
        state.resetAfterErase()
    }

    private func setHide(_ v: Bool) async {
        if let u: User = try? await APIClient.shared.request("PATCH", "/me", body: ["hide_coins": v]) {
            state.user = u
            state.refreshTick += 1
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
