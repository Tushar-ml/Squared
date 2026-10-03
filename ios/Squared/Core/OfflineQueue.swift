import Foundation
import Network
import Observation

/// Offline: confirm, not right and mark-as-paid queue locally with a "Will sync" label (PRD section 7).
@MainActor
@Observable
final class OfflineQueue {
    static let shared = OfflineQueue()

    struct Action: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        let method: String
        let path: String
        let body: [String: String]
        let intBody: [String: Int]
        let tag: String          // e.g. "expense:12", "payment:4", "group:3"
    }

    private(set) var actions: [Action] = []
    private let key = "offlineQueue.v1"
    private let monitor = NWPathMonitor()
    private var flushing = false

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let a = try? JSONDecoder().decode([Action].self, from: d) {
            actions = a
        }
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { @MainActor in self?.flush() } }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    func isPending(_ tag: String) -> Bool { actions.contains { $0.tag == tag } }

    func enqueue(_ a: Action) {
        actions.append(a)
        save()
    }

    func flush() {
        guard !flushing, !actions.isEmpty, APIClient.shared.token != nil else { return }
        flushing = true
        Task {
            defer { flushing = false }
            for a in actions {
                var body: [String: Any?] = a.body.mapValues { $0 }
                for (k, v) in a.intBody { body[k] = v }
                do {
                    try await APIClient.shared.raw(a.method, a.path, body: body, idempotencyKey: a.id)
                    remove(a)
                } catch let e as APIError where e.isOffline {
                    return
                } catch {
                    remove(a)  // server rejected (e.g. already confirmed): drop it, the UI re-syncs
                }
            }
            AppState.shared.refreshTick += 1
            AppState.shared.expectReward()
        }
    }

    private func remove(_ a: Action) {
        actions.removeAll { $0.id == a.id }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(actions) { UserDefaults.standard.set(d, forKey: key) }
    }
}
