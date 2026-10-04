import SwiftUI

struct ProfileSetupView: View {
    @Environment(AppState.self) private var state
    @State private var step = 0
    @State private var name = ""
    @State private var upi = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var editing: Bool { !(state.user?.name.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !editing { PageBars(count: 2, current: step).padding(.top, 12) }
            if step == 0 {
                SectionLabel(editing ? "Your profile" : "Almost there")
                Text("What do your friends call you?").font(Theme.title(28))
                input("Your name", $name, content: .givenName)
                Text("Used on your expenses and in reminder messages. It stays on this phone.").font(Theme.body(13)).foregroundStyle(Theme.muted)
            } else {
                SectionLabel("Optional")
                Text("Make settling up painless").font(Theme.title(28))
                input("UPI ID, e.g. \(name.lowercased().filter(\.isLetter))@okbank", $upi, keyboard: .emailAddress)
                Text("Added to reminder messages you share, so people can pay you in one tap.").font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            if let error { Text(error).font(Theme.body(13)).foregroundStyle(Theme.owe) }
            Spacer()
            NeoPopFloatingButton(title: step == 0 && !editing ? "Next" : "Continue",
                                 enabled: !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                if step == 0 && !editing { withAnimation { step = 1 } } else { Task { await save() } }
            }
            if step == 1 && !editing {
                Button("Add these later") { Task { await save(skipDetails: true) } }
                    .font(Theme.body(14, .semibold)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).frame(minHeight: 44)
            }
        }
        .padding(24)
        .onAppear {
            name = state.user?.name ?? ""; upi = state.user?.upiId ?? ""
            if editing { step = 0 }
            #if DEBUG
            if DebugAutomation.noFocus { return }
            #endif
            focused = true
        }
    }

    private func input(_ p: String, _ t: Binding<String>, keyboard: UIKeyboardType = .default,
                       content: UITextContentType? = nil) -> some View {
        TextField(p, text: t)
            .keyboardType(keyboard)
            .textContentType(content)
            .textInputAutocapitalization(keyboard == .default ? .words : .never)
            .autocorrectionDisabled()
            .font(Theme.body(17, .semibold))
            .focused($focused)
            .padding(16)
            .background(Theme.surface)
            .overlay(Rectangle().stroke(Theme.line))
    }

    private func save(skipDetails: Bool = false) async {
        busy = true
        defer { busy = false }
        do {
            var body: [String: Any?] = ["name": name]
            if !skipDetails || editing {
                body["upi_id"] = upi.isEmpty ? nil : upi
            }
            let u: User = try await APIClient.shared.request("PATCH", "/me", body: body)
            let wasNew = !editing
            state.user = u
            state.needsProfile = false
            if wasNew {
                await state.routeAfterProfile()
            }
        } catch { self.error = error.localizedDescription }
    }
}
