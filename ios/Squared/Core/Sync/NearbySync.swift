import Foundation
import MultipeerConnectivity
import Observation
import UIKit

/// Phone-to-phone sync over Wi-Fi / Bluetooth (Apple's MultipeerConnectivity): no internet, no server.
/// Runs only while the Sync screen is open. Traffic is encrypted; a phone accepts connections only
/// while its own Sync screen is open too.
@MainActor
@Observable
final class NearbySync: NSObject {
    struct Nearby: Identifiable, Hashable { let id: String; let name: String; let peer: MCPeerID }
    struct PendingJoin: Identifiable { let id = UUID(); let bundle: SyncEngine.Bundle; let from: String }

    private(set) var nearby: [Nearby] = []
    private(set) var connected: Set<String> = []
    private(set) var log: [String] = []
    var pendingJoin: PendingJoin?
    private(set) var running = false

    /// Group to hand over when connecting (opened from a group's Sync button). nil = sync shared groups only.
    var offerGroupId: Int?

    private static let service = "sqd-sync"           // ≤ 15 chars; matches NSBonjourServices in Info.plist
    private let db: LocalDB
    private var peer: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    var onChange: (() -> Void)?

    init(db: LocalDB = .shared) { self.db = db }

    private enum Message: Codable {
        case hello(shared: [String], offered: String?)
        case bundle(SyncEngine.Bundle)
    }

    func start() {
        guard !running else { return }
        let name = db.read { $0.me?.name ?? "" }.isEmpty ? UIDevice.current.name : db.read { $0.me!.name }
        let p = MCPeerID(displayName: String(name.prefix(40)))
        let s = MCSession(peer: p, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        let a = MCNearbyServiceAdvertiser(peer: p, discoveryInfo: nil, serviceType: Self.service)
        a.delegate = self
        let b = MCNearbyServiceBrowser(peer: p, serviceType: Self.service)
        b.delegate = self
        peer = p; session = s; advertiser = a; browser = b
        a.startAdvertisingPeer(); b.startBrowsingForPeers()
        running = true
        note("Looking for phones nearby…")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers(); session?.disconnect()
        advertiser = nil; browser = nil; session = nil; peer = nil
        nearby = []; connected = []; running = false
    }

    func connect(_ n: Nearby) {
        guard let browser, let session else { return }
        note("Connecting to \(n.name)…")
        browser.invitePeer(n.peer, to: session, withContext: nil, timeout: 20)
    }

    /// The person picked which member they are; merge the group and send ours back.
    func join(_ p: PendingJoin, as claim: String) {
        apply(p.bundle, claim: claim, from: p.from)
        pendingJoin = nil
        sendShared()
    }

    // MARK: - internals

    private func note(_ s: String) { log.insert(s, at: 0); if log.count > 30 { log.removeLast() } }

    private func sharedUids() -> [String] { db.read { $0.groups.filter { $0.shared == true && !$0.archived }.compactMap(\.uid) } }

    private func send(_ m: Message, to peers: [MCPeerID]? = nil) {
        guard let session, let data = try? JSONEncoder().encode(m) else { return }
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
    }

    private func hello(to p: MCPeerID) {
        let offered = offerGroupId.flatMap { gid in db.read { $0.group(gid)?.uid } }
        send(.hello(shared: sharedUids(), offered: offered), to: [p])
    }

    private func sendShared(to p: MCPeerID? = nil) {
        for uid in sharedUids() { sendGroup(uid, to: p) }
    }

    private func sendGroup(_ uid: String, to p: MCPeerID?) {
        guard let gid = db.read({ $0.groups.first { $0.uid == uid && !$0.archived }?.id }),
              let b = db.read({ SyncEngine.bundle($0, groupId: gid) }) else { return }
        try? db.write { s in if let i = s.groups.firstIndex(where: { $0.id == gid }) { s.groups[i].shared = true } }
        send(.bundle(b), to: p.map { [$0] })
        note("Sent \(b.group.name)")
    }

    private func received(_ m: Message, from p: MCPeerID) {
        switch m {
        case .hello(let theirs, let offered):
            // send what we both share, plus what either side is handing over
            var mine = Set(sharedUids()).intersection(theirs)
            if let me = offerGroupId.flatMap({ gid in db.read { $0.group(gid)?.uid } }) { mine.insert(me) }
            if let offered, db.read({ $0.groups.contains { $0.uid == offered && !$0.archived } }) { mine.insert(offered) }
            for uid in mine { sendGroup(uid, to: p) }
            if mine.isEmpty && offered == nil { note("Nothing shared with \(p.displayName) yet. Open a group's Sync to share it.") }
        case .bundle(let b):
            if db.read({ SyncEngine.knows($0, b) }) { apply(b, claim: nil, from: p.displayName) }
            else { pendingJoin = PendingJoin(bundle: b, from: p.displayName) }
        }
    }

    private func apply(_ b: SyncEngine.Bundle, claim: String?, from: String) {
        do {
            let r = try db.write { try SyncEngine.merge(&$0, b, claim: claim) }
            let parts = [r.newExpenses > 0 ? "\(r.newExpenses) new expense\(r.newExpenses == 1 ? "" : "s")" : nil,
                         r.updatedExpenses > 0 ? "\(r.updatedExpenses) updated" : nil,
                         r.newPayments > 0 ? "\(r.newPayments) payment\(r.newPayments == 1 ? "" : "s")" : nil].compactMap { $0 }
            note("\(b.group.name) from \(from): " + (parts.isEmpty ? "already up to date" : parts.joined(separator: ", ")))
            onChange?()
        } catch { note("Couldn't merge \(b.group.name): \(error.localizedDescription)") }
    }
}

extension NearbySync: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                connected.insert(peerID.displayName)
                note("Connected to \(peerID.displayName)")
                hello(to: peerID)
            case .notConnected:
                if connected.remove(peerID.displayName) != nil { note("\(peerID.displayName) disconnected") }
            default: break
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let m = try? JSONDecoder().decode(Message.self, from: data) else { return }
        Task { @MainActor in received(m, from: peerID) }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension NearbySync: MCNearbyServiceAdvertiserDelegate {
    /// Accept while this phone's Sync screen is open (that's the only time we advertise).
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(running, session) }
    }
}

extension NearbySync: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            let key = "\(peerID.displayName)#\(peerID.hash)"
            if !nearby.contains(where: { $0.id == key }) { nearby.append(.init(id: key, name: peerID.displayName, peer: peerID)) }
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in nearby.removeAll { $0.peer == peerID } }
    }
}
