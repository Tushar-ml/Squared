import SwiftUI

struct Friend: Codable, Identifiable, Hashable {
    let groupId: Int
    let userId: Int
    let name: String?
    var currency: String? = "INR"
    let myNetPaise: Int
    let coinsEnabled: Bool
    var id: Int { groupId }
}
struct FriendsResponse: Codable { let friends: [Friend] }
struct FriendInvite: Codable { let groupId: Int; let link: String; let message: String; let whatsappUrl: String }

/// 1:1 splits on Home. Each friend is a hidden two-person group, so balances, reminders and coins work as in any group.
struct FriendsSection: View {
    @Environment(AppState.self) private var state
    let friends: [Friend]
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Friends")
                Spacer()
                Button(action: onAdd) {
                    Label("Add friend", systemImage: "person.badge.plus").font(Theme.body(13, .semibold))
                }
                .foregroundStyle(Theme.muted)
            }
            if friends.isEmpty {
                Button(action: onAdd) {
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2.fill").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44)
                                .background(Theme.surfaceHigh)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Split with one person").font(Theme.body(16, .bold))
                                Text("No group needed. Dinner, a cab, a gift: add it and sync when you meet.")
                                    .font(Theme.body(12)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(friends) { f in
                Button { state.open(.group(f.groupId)) } label: {
                    HStack(spacing: 14) {
                        Avatar(name: f.name ?? "?", size: 44)
                        Text(f.name ?? "").font(Theme.body(17, .bold))
                        Spacer()
                        BalanceText(net: f.myNetPaise, currency: f.currency)
                    }
                    .neoPopCard(depth: 4, padding: 14)
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Add someone by phone if they're on Squared; otherwise send them a link that pairs them with you.
struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL
    let onAdded: (Int) -> Void
    @State private var phone = ""
    @State private var busy = false
    @State private var notOnApp = false
    @State private var invite: FriendInvite?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Add a friend")
            Text("Split with one person").font(Theme.title(26))
            HStack(spacing: 10) {
                Text("+91").font(Theme.body(20, .bold)).foregroundStyle(Theme.muted)
                TextField("Their phone number", text: $phone).keyboardType(.phonePad).font(Theme.body(20, .bold))
                    .onChange(of: phone) { notOnApp = false }
            }
            .padding(14).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
            if notOnApp {
                Text("They're not on Squared yet. Send them a link and you'll be paired as soon as they join.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            NeoPopButton(title: "Add friend", enabled: !busy && phone.filter(\.isNumber).count >= 10, loading: busy) {
                Task { await add() }
            }
            Divider().overlay(Theme.line).padding(.vertical, 4)
            if let invite {
                NeoPopButton(title: "Invite on WhatsApp", style: .stroke, icon: "message.fill") {
                    if let url = URL(string: invite.whatsappUrl), UIApplication.shared.canOpenURL(url) { openURL(url) }
                    else { state.showToast("WhatsApp isn't installed. Use Share instead.") }
                }
                ShareLink(item: invite.message) {
                    Label("Share invite link", systemImage: "square.and.arrow.up").font(.system(size: 14, weight: .heavy))
                        .frame(maxWidth: .infinity, minHeight: 48).overlay(Rectangle().stroke(Theme.text))
                }
                .foregroundStyle(Theme.text)
            } else {
                Button { Task { await makeInvite() } } label: {
                    HStack {
                        Image(systemName: "link")
                        Text("Not on Squared? Send an invite link").font(Theme.body(15, .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(Theme.text).frame(minHeight: 44)
                }
            }
            Spacer()
        }
        .padding(24)
        .presentationDetents([.height(460)])
        .presentationBackground(Theme.bg)
    }

    private func add() async {
        busy = true
        defer { busy = false }
        do {
            let f: Friend = try await APIClient.shared.request("POST", "/friends", body: ["phone": phone.filter(\.isNumber)])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            onAdded(f.groupId)
        } catch let e as APIError where e.status == 404 {
            notOnApp = true
            await makeInvite()
        } catch { state.showToast(error.localizedDescription) }
    }

    private func makeInvite() async {
        guard invite == nil else { return }
        invite = try? await APIClient.shared.request("POST", "/friends/invite")
    }
}
