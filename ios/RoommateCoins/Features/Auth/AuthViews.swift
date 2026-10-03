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
                Text("ROOMMATE\nCOINS").font(.system(size: 22, weight: .black)).tracking(2).lineSpacing(-2)
            }
            .onLongPressGesture { showServer = true }
            Text(sent ? "Enter the code we sent to \(phone)" : "Keep your flat square.\nEarn together.")
                .font(Theme.title(30))
                .fixedSize(horizontal: false, vertical: true)
            if !sent {
                field("Phone number", text: $phone, keyboard: .phonePad, prefix: "+91")
            } else {
                field("6-digit code", text: $otp, keyboard: .numberPad, prefix: nil)
                    .textContentType(.oneTimeCode)
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
    @State private var name = ""
    @State private var email = ""
    @State private var upi = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer().frame(height: 20)
            SectionLabel("Almost there")
            Text("What do your roommates call you?").font(Theme.title(28))
            input("Your name", $name)
            input("Email (for voucher codes)", $email, keyboard: .emailAddress)
            input("UPI ID (so roommates can pay you)", $upi, keyboard: .emailAddress)
            if let error { Text(error).font(Theme.body(13)).foregroundStyle(Theme.owe) }
            Spacer()
            NeoPopFloatingButton(title: "Continue", enabled: !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                Task { await save() }
            }
        }
        .padding(24)
        .onAppear {
            name = state.user?.name ?? ""; email = state.user?.email ?? ""; upi = state.user?.upiId ?? ""
        }
    }

    private func input(_ p: String, _ t: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(p, text: t)
            .keyboardType(keyboard)
            .textInputAutocapitalization(keyboard == .default ? .words : .never)
            .autocorrectionDisabled()
            .font(Theme.body(17, .semibold))
            .padding(16)
            .background(Theme.surface)
            .overlay(Rectangle().stroke(Theme.line))
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let u: User = try await APIClient.shared.request("PATCH", "/me", body: [
                "name": name, "email": email.isEmpty ? nil : email, "upi_id": upi.isEmpty ? nil : upi])
            state.user = u
            state.needsProfile = false
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
