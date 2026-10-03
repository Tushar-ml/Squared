import SwiftUI

/// S9 invite sheet: prefilled WhatsApp message with a group deep link, plus invitee status rows.
struct InviteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL
    let groupId: Int
    let groupName: String
    let coinsEnabled: Bool
    @State private var invite: InviteLink?
    @State private var statuses: [InviteStatus] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel("Invite to \(groupName)")
                    Text(coinsEnabled ? "Bring your roommates in. When their first expense is confirmed, you both get +\(state.config?.earn.inviteEach ?? 50)."
                                      : "Bring your roommates in.")
                        .font(Theme.title(22))
                    if let invite {
                        Text(invite.message).font(Theme.body(14))
                            .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                        NeoPopButton(title: "Share on WhatsApp", icon: "message.fill") {
                            APIClient.shared.track("invite_shared", groupId: groupId, props: ["channel": "whatsapp"])
                            if let url = URL(string: invite.whatsappUrl), UIApplication.shared.canOpenURL(url) {
                                openURL(url)
                            } else {
                                state.showToast("WhatsApp isn't installed. Use Share instead.")
                            }
                        }
                        ShareLink(item: invite.message) {
                            Text("SHARE").font(.system(size: 14, weight: .heavy)).tracking(1.2)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .overlay(Rectangle().stroke(Theme.text, lineWidth: 1))
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            APIClient.shared.track("invite_shared", groupId: groupId, props: ["channel": "share_sheet"])
                        })
                        Button {
                            UIPasteboard.general.string = invite.link
                            state.showToast("Link copied")
                        } label: {
                            Label("Copy link", systemImage: "link").font(Theme.body(14, .semibold))
                        }
                        .frame(minHeight: 44)
                    } else if let error {
                        Text(error).foregroundStyle(Theme.muted)
                    } else {
                        Skeleton(height: 90)
                    }
                    if !statuses.isEmpty {
                        SectionLabel("Invites")
                        ForEach(statuses) { s in
                            HStack {
                                Text(s.inviteeName ?? "Invite sent").font(Theme.body(15, .semibold))
                                Spacer()
                                StatusChip(text: s.statusText, tint: s.status == "REWARDED" ? Theme.coin : Theme.muted)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(24)
            }
            .background(Theme.bg)
        }
        .task { await load() }
    }

    private func load() async {
        do {
            invite = try await APIClient.shared.request("POST", "/invites", body: ["group_id": groupId])
            let r: InvitesResponse = try await APIClient.shared.request("GET", "/invites?group_id=\(groupId)")
            statuses = r.invites.filter { $0.status != "INVITED" || $0.id == invite?.referralId }.filter { $0.status != "INVITED" }
        } catch { self.error = error.localizedDescription }
    }
}

/// Opened from a roommatecoins://join?token= deep link.
struct JoinGroupSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let token: String
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("You're invited")
            Text("Join your roommates' flat?").font(Theme.title(26))
            Text("You'll see shared expenses and can confirm them in one tap.").font(Theme.body(14)).foregroundStyle(Theme.muted)
            if let error { Text(error).font(Theme.body(13)).foregroundStyle(Theme.owe) }
            NeoPopButton(title: "Join flat", enabled: !busy) { Task { await join() } }
            NeoPopButton(title: "Not now", style: .stroke) { state.pendingJoinToken = nil; dismiss() }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationBackground(Theme.bg)
    }

    private func join() async {
        busy = true
        defer { busy = false }
        do {
            let r: AcceptResponse = try await APIClient.shared.request("POST", "/invites/accept", body: ["token": token])
            state.pendingJoinToken = nil
            dismiss()
            state.refreshTick += 1
            state.open(.group(r.groupId))
            if let name = r.groupName { state.showToast("Joined \(name)") }
        } catch { self.error = error.localizedDescription }
    }
}

/// Paste a link when the deep link can't open the app directly (e.g. a desktop browser).
struct PasteInviteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Join with a link")
            TextField("Paste the invite link", text: $text, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            NeoPopButton(title: "Continue", enabled: token != nil) {
                state.pendingJoinToken = token
                dismiss()
            }
            Spacer()
        }
        .padding(24)
        .presentationDetents([.height(260)])
        .presentationBackground(Theme.bg)
        .onAppear { if let s = UIPasteboard.general.string, s.contains("/j/") || s.contains("token=") { text = s } }
    }

    private var token: String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "/j/") { return String(t[r.upperBound...]).components(separatedBy: CharacterSet(charactersIn: "?# ")).first }
        if let r = t.range(of: "token=") { return String(t[r.upperBound...]).components(separatedBy: "&").first }
        return nil
    }
}

struct CreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    let onCreated: (Int) -> Void
    @State private var name = ""
    @State private var type = "HOME"
    @State private var people = 3
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("New group")
            TextField("Flat 4B", text: $name).font(Theme.body(22, .bold))
                .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            NeoPopRadioRow(label: "Home (flatmates)", selected: type == "HOME") { type = "HOME" }
            NeoPopRadioRow(label: "Trip", selected: type == "TRIP") { type = "TRIP" }
            NeoPopRadioRow(label: "Other", selected: type == "OTHER") { type = "OTHER" }
            if type == "HOME" {
                Stepper("People living here: \(people)", value: $people, in: 2...8).font(Theme.body(15, .semibold))
            }
            NeoPopButton(title: "Create", enabled: !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                Task { await create() }
            }
            Spacer()
        }
        .padding(24)
        .presentationDetents([.height(470)])
        .presentationBackground(Theme.bg)
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let g: GroupSummary = try await APIClient.shared.request("POST", "/groups", body: [
                "name": name, "group_type": type, "expected_members": type == "HOME" ? people : nil])
            dismiss()
            onCreated(g.id)
        } catch { state.showToast(error.localizedDescription) }
    }
}
