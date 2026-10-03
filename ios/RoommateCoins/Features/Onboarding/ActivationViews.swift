import SwiftUI

/// Home checklist that walks a new user to activation: flat → roommate → expense → confirmed.
/// Server-computed, so it's right on every device. Disappears once the first expense is confirmed.
struct ActivationChecklist: View {
    @Environment(AppState.self) private var state
    let activation: Activation
    let onInvite: (Int, String) -> Void
    @State private var reminded = false

    private var waitingNames: String { Format.names((activation.waitingOn ?? []).compactMap { $0 }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Get your flat started", color: Theme.coin)
                Spacer()
                Text("\(activation.doneCount) of \(activation.steps.count)").font(Theme.body(12, .bold)).foregroundStyle(Theme.muted)
            }
            PageBars(count: activation.steps.count, current: activation.doneCount - 1)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(activation.steps) { step in
                    let isNext = step.id == activation.nextStep
                    HStack(spacing: 12) {
                        Image(systemName: step.done ? "checkmark" : (isNext ? "arrow.right" : "circle"))
                            .font(.system(size: step.done || isNext ? 12 : 8, weight: .black))
                            .foregroundStyle(step.done ? Theme.bg : (isNext ? Theme.text : Theme.muted))
                            .frame(width: 24, height: 24)
                            .background(step.done ? Theme.owed : Color.clear)
                            .overlay(Rectangle().stroke(step.done ? Color.clear : Theme.line))
                        Text(title(step)).font(Theme.body(15, isNext ? .bold : .regular))
                            .foregroundStyle(step.done ? Theme.muted : Theme.text)
                            .strikethrough(step.done, color: Theme.muted)
                        Spacer()
                    }
                    .frame(minHeight: 34)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(step.done ? "Done" : (isNext ? "Next" : "To do"))
                }
            }
            if let next = activation.nextStep {
                Text(hint(next)).font(Theme.body(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                NeoPopButton(title: ctaTitle(next), style: next == "confirm" && activation.confirmExpenseId != nil ? .elevatedCoin : .elevated,
                             parent: UIColor(hex: 0x141414)) { act(next) }
            }
        }
        .neoPopCard(color: UIColor(hex: 0x141414), edge: Theme.UI.coin, depth: 6)
    }

    private func title(_ s: ActivationStep) -> String {
        if s.id == "flat", let g = activation.group { return "Set up \(g.name)" }
        return s.title
    }

    private func hint(_ next: String) -> String {
        let firstWin = activation.firstWinCoins ?? 50
        switch next {
        case "flat": return "Create your flat or join the one your roommates already use."
        case "roommates":
            let want = (activation.group?.expectedMembers ?? 2) - (activation.group?.memberCount ?? 1)
            return "Invite \(max(want, 1) == 1 ? "a roommate" : "\(max(want, 1)) roommates"). Coins start as soon as one joins."
        case "expense": return "Rent, wifi or groceries: anything you share. Takes 10 seconds."
        default:
            if activation.confirmExpenseId != nil { return "A roommate added an expense with you in it. Confirm it to earn your first \(firstWin) coins." }
            if reminded { return "Reminder sent to \(waitingNames). You'll both earn \(firstWin) coins the moment they confirm." }
            if activation.waitingExpenseId != nil, !waitingNames.isEmpty {
                return "Waiting for \(waitingNames) to confirm. A nudge usually does it. You'll both earn your first \(firstWin) coins."
            }
            return "Waiting for a roommate to confirm. You'll both earn your first \(firstWin) coins."
        }
    }

    private func ctaTitle(_ next: String) -> String {
        switch next {
        case "flat": return "Set up flat"
        case "roommates": return "Invite roommates"
        case "expense": return "Add an expense"
        default:
            if activation.confirmExpenseId != nil { return "Confirm +\(activation.firstWinCoins ?? 50)" }
            if activation.waitingExpenseId != nil && !reminded {
                let first = (activation.waitingOn ?? []).compactMap { $0 }
                return first.count == 1 ? "Remind \(first[0])" : "Send a reminder"
            }
            return "Open flat"
        }
    }

    private func act(_ next: String) {
        APIClient.shared.track("checklist_tapped", groupId: activation.group?.id, props: ["step": next])
        switch next {
        case "flat": state.showFlatSetup = true
        case "roommates": if let g = activation.group { onInvite(g.id, g.name) }
        case "expense": if let g = activation.group { state.open(.group(g.id)) }
        default:
            if let e = activation.confirmExpenseId { state.open(.expense(e)) }
            else if let e = activation.waitingExpenseId, !reminded {
                Task {
                    let r: RemindResponse? = try? await APIClient.shared.request("POST", "/expenses/\(e)/remind")
                    withAnimation { reminded = true }
                    state.showToast(r?.reminded.isEmpty == false ? "Reminder sent" : "They were notified recently")
                }
            }
            else if let g = activation.group { state.open(.group(g.id)) }
        }
    }
}

/// Shown on the group screen to a newcomer who has an expense waiting on them: the fastest first win.
struct WelcomeBanner: View {
    let groupName: String
    let expense: Expense
    let firstWin: Int

    var body: some View {
        NavigationLink(value: Route.expense(expense.id)) {
            HStack(alignment: .top, spacing: 12) {
                CoinGlyph(size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to \(groupName)").font(Theme.body(16, .heavy))
                    Text("\(expense.createdByName ?? "A roommate") added \(expense.description). Check your share and confirm to earn your first \(firstWin) coins.")
                        .font(Theme.body(13)).foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).padding(.top, 6)
            }
        }
        .buttonStyle(.plain)
        .neoPopCard(color: UIColor(hex: 0x1C1608), edge: Theme.UI.coin, depth: 5, padding: 14)
    }
}

/// Celebrates finishing the checklist once.
struct ActivatedCard: View {
    let onDismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .black)).foregroundStyle(Theme.bg)
                .frame(width: 32, height: 32).background(Theme.owed)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your flat is set up").font(Theme.body(15, .heavy))
                Text("Keep confirming and settling to hit this week's goal together.").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 44, height: 44) }
                .accessibilityLabel("Dismiss")
        }
        .neoPopCard(depth: 4, padding: 12)
    }
}
