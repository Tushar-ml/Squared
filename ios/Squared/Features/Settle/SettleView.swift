import SwiftUI

/// S5: You owe Priya INR 450 → Pay (UPI deep link) → "Mark as paid" sheet on return → waiting for receipt.
struct SettleView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    let groupId: Int
    let creditorId: Int?
    var showsClose = true

    @State private var detail: GroupDetail?
    @State private var selected: Debt?
    @State private var amount = ""
    @State private var launchedUPI = false
    @State private var showMarkPaid = false
    @State private var recorded: Payment?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let recorded {
                    waiting(recorded)
                } else if let debt = selected {
                    payCard(debt)
                } else if let d = detail {
                    let mine = d.debts.filter(\.youOwe)
                    if mine.isEmpty {
                        Card { Text("You're all square in \(d.name).").font(Theme.body(16, .semibold)) }
                    }
                    ForEach(mine) { debt in
                        Button { select(debt) } label: {
                            HStack {
                                Text(Strings.youOwe(debt.creditorName ?? "", Format.inr(paise: debt.amountPaise))).font(Theme.body(16, .bold))
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .neoPopCard(depth: 4, padding: 14)
                        }.buttonStyle(.plain)
                    }
                } else {
                    Skeleton(height: 160)
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Settle up")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if showsClose { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } } }
        .task { await load() }
        .onChange(of: phase) { _, p in
            if p == .active && launchedUPI { launchedUPI = false; showMarkPaid = true }  // back from the UPI app
        }
        .sheet(isPresented: $showMarkPaid) {
            if let debt = selected { markPaidSheet(debt) }
        }
    }

    private func payCard(_ debt: Debt) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.youOwe(debt.creditorName ?? "", Format.inr(paise: debt.amountPaise))).font(Theme.title(26))
            if detail?.coinsEnabled == true, let hint = debt.payRewardHint {
                HStack(spacing: 6) { CoinGlyph(size: 16); Text(Strings.payToday(hint)).font(Theme.body(14, .bold)) }
                    .foregroundStyle(Theme.coin)
            }
            HStack {
                Text("INR").font(Theme.number(20)).foregroundStyle(Theme.muted)
                TextField("0", text: $amount).keyboardType(.decimalPad).font(Theme.number(30))
            }
            .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            if let upi = debt.creditorUpi {
                Text("Pays \(upi) in your UPI app").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            NeoPopFloatingButton(title: "Pay", enabled: Format.paise(from: amount) != nil) { pay(debt) }
            Button("I paid another way") { showMarkPaid = true }
                .font(Theme.body(14, .semibold)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).frame(minHeight: 44)
        }
    }

    private func markPaidSheet(_ debt: Debt) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Mark as paid")
            Text("Did you pay \(debt.creditorName ?? "") \(Format.inr(paise: Format.paise(from: amount) ?? debt.amountPaise))?")
                .font(Theme.title(22))
            Text("\(debt.creditorName ?? "They") will be asked to confirm they got it.").font(Theme.body(13)).foregroundStyle(Theme.muted)
            NeoPopButton(title: "Yes, mark as paid", enabled: !busy) { Task { await markPaid(debt) } }
            NeoPopButton(title: "Not yet", style: .stroke) { showMarkPaid = false }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.height(320)])
        .presentationBackground(Theme.bg)
    }

    private func waiting(_ p: Payment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "hourglass").font(.system(size: 26, weight: .bold)).frame(width: 56, height: 56).background(Theme.surfaceHigh)
            Text(Strings.waitingReceipt(p.receiverName ?? "")).font(Theme.title(24))
            Text("Paid \(Format.inr(paise: p.amountPaise)). Balances are already updated.").font(Theme.body(14)).foregroundStyle(Theme.muted)
            if OfflineQueue.shared.isPending("group:\(groupId):pay") { StatusChip(text: Strings.willSync) }
            NeoPopButton(title: "Done") { dismiss() }
        }
    }

    private func select(_ debt: Debt) {
        selected = debt
        amount = String(format: debt.amountPaise % 100 == 0 ? "%.0f" : "%.2f", Double(debt.amountPaise) / 100)
    }

    private func pay(_ debt: Debt) {
        guard let paise = Format.paise(from: amount) else { return }
        var comps = URLComponents()
        comps.scheme = "upi"; comps.host = "pay"
        comps.queryItems = [URLQueryItem(name: "pa", value: debt.creditorUpi ?? ""),
                            URLQueryItem(name: "pn", value: debt.creditorName ?? ""),
                            URLQueryItem(name: "am", value: String(format: "%.2f", Double(paise) / 100)),
                            URLQueryItem(name: "cu", value: "INR"),
                            URLQueryItem(name: "tn", value: "\(detail?.name ?? "Split") via Squared")]
        if let url = comps.url, debt.creditorUpi != nil, UIApplication.shared.canOpenURL(url) {
            launchedUPI = true
            openURL(url)
        } else {
            state.showToast(debt.creditorUpi == nil ? "\(debt.creditorName ?? "They") hasn't added a UPI ID" : "No UPI app found")
            showMarkPaid = true
        }
    }

    private func markPaid(_ debt: Debt) async {
        let paise = Format.paise(from: amount) ?? debt.amountPaise
        busy = true
        defer { busy = false }
        do {
            let p: Payment = try await APIClient.shared.request("POST", "/groups/\(groupId)/payments", body: [
                "receiver_id": debt.creditorId, "amount_paise": paise])
            recorded = p
            showMarkPaid = false
            state.refreshTick += 1
        } catch let e as APIError where e.isOffline {
            OfflineQueue.shared.enqueue(.init(method: "POST", path: "/groups/\(groupId)/payments", body: [:],
                                              intBody: ["receiver_id": debt.creditorId, "amount_paise": paise],
                                              tag: "group:\(groupId):pay"))
            recorded = Payment(id: -1, groupId: groupId, payerId: state.user?.id ?? 0, payerName: nil, receiverId: debt.creditorId,
                               receiverName: debt.creditorName, amountPaise: paise, note: nil, createdAt: "", confirmation: nil)
            showMarkPaid = false
        } catch {
            state.showToast(error.localizedDescription)
        }
    }

    private func load() async {
        guard let d: GroupDetail = try? await APIClient.shared.request("GET", "/groups/\(groupId)") else { return }
        detail = d
        if let creditorId, let debt = d.debts.first(where: { $0.youOwe && $0.creditorId == creditorId }) { select(debt) }
    }
}
