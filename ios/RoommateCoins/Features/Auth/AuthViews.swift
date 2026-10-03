import SwiftUI

struct PhoneEntryView: View {
    @Environment(AppState.self) private var state
    @State private var phone = ""
    @State private var otp = ""
    @State private var sent = false
    @State private var busy = false
    @State private var error: String?
    @State private var showServer = false
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer().frame(height: 30)
            HStack(spacing: 10) {
                CoinGlyph(size: 34)
                Text("SQUARED").font(.system(size: 22, weight: .black)).tracking(2).lineSpacing(-2)
            }
            .onLongPressGesture { showServer = true }
            Text(sent ? "Enter the code we sent to +91 \(phone)" : "Split anything.\nKeep it square. Earn together.")
                .font(Theme.title(30))
                .fixedSize(horizontal: false, vertical: true)
            if !sent {
                field("Phone number", text: $phone, keyboard: .phonePad, prefix: "+91")
            } else {
                field("6-digit code", text: $otp, keyboard: .numberPad, prefix: nil)
                    .textContentType(.oneTimeCode)
                    .onChange(of: otp) { _, v in
                        if v.count == 6 && !busy { Task { await submit() } }   // no extra tap once the code is in
                    }
            }
            if let error { Text(error).font(Theme.body(13)).foregroundStyle(Theme.owe) }
            Spacer()
            NeoPopFloatingButton(title: sent ? "Verify" : "Send code", enabled: !busy && (sent ? otp.count >= 4 : phone.count >= 10)) {
                Task { await submit() }
            }
            if sent {
                Button("Change number") { sent = false; otp = "" }
                    .font(Theme.body(14, .semibold)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .onAppear {
            #if DEBUG
            if DebugAutomation.noFocus { return }
            #endif
            focus = true
        }
        .sheet(isPresented: $showServer) { ServerSettingsSheet() }
    }

    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType, prefix: String?) -> some View {
        HStack(spacing: 10) {
            if let prefix { Text(prefix).font(Theme.number(22)).foregroundStyle(Theme.muted) }
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .font(Theme.number(22))
                .focused($focus)
        }
        .padding(16)
        .background(Theme.surface)
        .overlay(Rectangle().stroke(Theme.line))
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if !sent {
                try await APIClient.shared.raw("POST", "/auth/otp/request", body: ["phone": phone])
                sent = true
            } else {
                let r: AuthResponse = try await APIClient.shared.request(
                    "POST", "/auth/otp/verify", body: ["phone": phone, "otp": otp, "device_id": APIClient.deviceId])
                await state.didSignIn(r)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProfileSetupView: View {
    @Environment(AppState.self) private var state
    @State private var step = 0
    @State private var name = ""
    @State private var email = ""
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
                Text("This is how you'll show up on expenses and confirmations.").font(Theme.body(13)).foregroundStyle(Theme.muted)
            } else {
                SectionLabel("Optional")
                Text("Make settling up painless").font(Theme.title(28))
                input("UPI ID, e.g. \(name.lowercased().filter(\.isLetter))@okbank", $upi, keyboard: .emailAddress)
                Text("Friends can pay you in one tap from their UPI app.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                input("Email", $email, keyboard: .emailAddress, content: .emailAddress)
                Text("We send voucher codes here when you redeem coins.").font(Theme.body(13)).foregroundStyle(Theme.muted)
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
            name = state.user?.name ?? ""; email = state.user?.email ?? ""; upi = state.user?.upiId ?? ""
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
                body["email"] = email.isEmpty ? nil : email
                body["upi_id"] = upi.isEmpty ? nil : upi
            }
            let u: User = try await APIClient.shared.request("PATCH", "/me", body: body)
            let wasNew = !editing
            state.user = u
            state.needsProfile = false
            if wasNew {
                APIClient.shared.track("profile_completed", props: ["upi": !upi.isEmpty && !skipDetails, "email": !email.isEmpty && !skipDetails])
                await state.routeAfterProfile()
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// Hidden dev setting (long-press the logo): point the app at another API host, e.g. a LAN IP for a real device.
struct ServerSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = APIClient.shared.baseURL.absoluteString

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("API server")
            TextField("http://localhost:8080", text: $url)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            NeoPopButton(title: "Save") {
                UserDefaults.standard.set(url, forKey: "apiBaseURL")
                dismiss()
            }
            Spacer()
        }
        .padding(24)
        .presentationDetents([.height(220)])
        .background(Theme.bg)
    }
}
