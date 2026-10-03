import SwiftUI

/// S2 confirm bar: one tap, optimistic, with the reward second.
struct ConfirmBar: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let expense: Expense
    var source = "detail"
    var compact = false
    let onDone: () -> Void
    let onDispute: () -> Void

    @State private var done = false
    @State private var floatUp = false
    @State private var busy = false

    private var preview: RewardPreview? { expense.confirmation?.rewardPreview }
    private var coins: Int { preview?.coins ?? 0 }
    private var queued: Bool { OfflineQueue.shared.isPending("expense:\(expense.id)") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact { Text(Strings.looksRight).font(Theme.body(16, .bold)) }
            if done || queued {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .black)).foregroundStyle(Theme.onAccent)
                        .frame(width: 26, height: 26).background(Theme.owed)
                    Text(queued ? "Confirmed · \(Strings.willSync)" : "Confirmed").font(Theme.body(15, .bold))
                    Spacer()
                    if coins > 0, !queued {
                        Text("+\(coins)").font(.system(size: 16, weight: .black, design: .rounded)).foregroundStyle(Theme.coin)
                            .offset(y: floatUp ? -28 : 0).opacity(floatUp ? 0 : 1)
                    }
                }
                .frame(height: 44)
            } else {
                HStack(spacing: 12) {
                    NeoPopButton(title: coins > 0 ? "Confirm +\(coins)" : "Confirm", style: .elevated,
                                 enabled: !busy, height: compact ? 44 : 50, parent: Theme.UI.surface) { confirm() }
                    NeoPopButton(title: Strings.notRight, style: .stroke, enabled: !busy, height: compact ? 44 : 50,
                                 parent: Theme.UI.surface) { onDispute() }
                }
                if let reason = preview?.cappedReason, reason.hasPrefix("cap_") {
                    Text(reason == "cap_user_monthly" ? Strings.capMonthly : Strings.capDaily)
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                } else if let bonus = preview?.firstWinBonus, bonus > 0, coins > 0 {
                    Text("Your first confirmed expense also earns +\(bonus)").font(Theme.body(12)).foregroundStyle(Theme.coin)
                }
            }
        }
    }

    private func confirm() {
        APIClient.shared.track("expense_confirm_tapped", groupId: expense.groupId, props: ["expense_id": expense.id, "source": source])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        busy = true
        withAnimation(.spring(duration: 0.3)) { done = true }
        if !reduceMotion { withAnimation(.easeOut(duration: 0.6).delay(0.1)) { floatUp = true } }
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.raw("POST", "/expenses/\(expense.id)/confirmations",
                                               body: ["status": "CONFIRMED", "source": source],
                                               idempotencyKey: "confirm-\(expense.id)-\(expense.version)")
                if coins > 0 { state.announce("Confirmed. You earned \(coins) coins.") }
                state.expectReward()
                try? await Task.sleep(for: .milliseconds(700))
                onDone()
            } catch let e as APIError where e.isOffline {
                OfflineQueue.shared.enqueue(.init(method: "POST", path: "/expenses/\(expense.id)/confirmations",
                                                  body: ["status": "CONFIRMED", "source": source], intBody: [:],
                                                  tag: "expense:\(expense.id)"))
            } catch {
                withAnimation { done = false; floatUp = false }   // roll back with a neutral toast
                state.showToast(error.localizedDescription)
            }
        }
    }
}

/// N2 / S5 receiver bar: "Yes, got it" / "Not yet".
struct ReceiptBar: View {
    @Environment(AppState.self) private var state
    let payment: Payment
    let reward: Int
    let onDone: () -> Void
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        if let result {
            HStack(spacing: 8) {
                Image(systemName: result == "CONFIRMED" ? "checkmark" : "clock").font(.system(size: 13, weight: .black))
                Text(result == "CONFIRMED" ? "Got it" : "Marked not received yet").font(Theme.body(15, .bold))
            }
            .frame(height: 44)
        } else {
            HStack(spacing: 12) {
                NeoPopButton(title: reward > 0 ? "Got it +\(reward)" : "Yes, got it", enabled: !busy, height: 44,
                             parent: Theme.UI.surface) { send("CONFIRMED") }
                NeoPopButton(title: "Not yet", style: .stroke, enabled: !busy, height: 44, parent: Theme.UI.surface) { send("REJECTED") }
            }
        }
    }

    private func send(_ status: String) {
        busy = true
        withAnimation { result = status }
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.raw("POST", "/payments/\(payment.id)/confirmation", body: ["status": status])
                if status == "CONFIRMED" { state.expectReward() }
                try? await Task.sleep(for: .milliseconds(600))
                onDone()
            } catch let e as APIError where e.isOffline {
                OfflineQueue.shared.enqueue(.init(method: "POST", path: "/payments/\(payment.id)/confirmation",
                                                  body: ["status": status], intBody: [:], tag: "payment:\(payment.id)"))
            } catch {
                withAnimation { result = nil }
                state.showToast(error.localizedDescription)
            }
        }
    }
}

/// "Not right" bottom sheet: three reasons plus an optional note.
struct NotRightSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    let expense: Expense
    let onDone: () -> Void
    @State private var reason = "WRONG_AMOUNT"
    @State private var note = ""
    @State private var busy = false

    private let reasons = [("WRONG_AMOUNT", "Wrong amount"), ("NOT_MINE", "Not mine"), ("OTHER", "Something else")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Not right")
            Text("What's off with \(expense.description)?").font(Theme.title(22))
            Text("\(expense.createdByName ?? "They") will be asked to fix it. Nobody earns coins until it's sorted.")
                .font(Theme.body(13)).foregroundStyle(Theme.muted)
            ForEach(reasons, id: \.0) { r in
                NeoPopRadioRow(label: r.1, selected: reason == r.0) { reason = r.0 }
            }
            TextField("Add a note (optional)", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .padding(12).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            NeoPopButton(title: "Send", enabled: !busy) { Task { await send() } }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.height(500)])
        .presentationBackground(Theme.bg)
    }

    private func send() async {
        busy = true
        defer { busy = false }
        let body: [String: String] = ["status": "DISPUTED", "reason": reason, "note": note]
        do {
            try await APIClient.shared.raw("POST", "/expenses/\(expense.id)/confirmations", body: body.mapValues { $0 })
        } catch let e as APIError where e.isOffline {
            OfflineQueue.shared.enqueue(.init(method: "POST", path: "/expenses/\(expense.id)/confirmations", body: body,
                                              intBody: [:], tag: "expense:\(expense.id)"))
        } catch {
            state.showToast(error.localizedDescription)
            return
        }
        dismiss()
        onDone()
    }
}

/// Status chip for an expense row. Neutral colours only.
struct ConfirmationChip: View {
    let confirmation: Confirmation
    var body: some View {
        switch confirmation.status {
        case "CONFIRMED":
            StatusChip(text: "Confirmed", tint: Theme.text)
        case "DISPUTED":
            StatusChip(text: "Needs a look", tint: Theme.muted)
        case "UNCONFIRMED":
            StatusChip(text: "Unconfirmed", tint: Theme.muted)
        default:
            StatusChip(text: "Waiting", tint: Theme.muted)
        }
    }
}
