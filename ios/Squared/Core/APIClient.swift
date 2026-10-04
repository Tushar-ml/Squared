import Foundation
import UIKit

struct APIError: LocalizedError, Equatable {
    let status: Int
    let message: String
    let code: String?
    var errorDescription: String? { message }
    var isOffline: Bool { status == -1 }
    var isCoinsUnavailable: Bool { status == 503 }
}

/// The screens' data access. Everything is answered on the device by `LocalAPI`; there is no server.
final class APIClient {
    static let shared = APIClient()

    /// Kept so existing call sites compile; the offline app has no sessions.
    var token: String? = "local"

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static var deviceId: String { UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device" }
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }

    func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any?]? = nil,
                               idempotencyKey: String? = nil, as: T.Type = T.self) async throws -> T {
        let data = try await raw(method, path, body: body, idempotencyKey: idempotencyKey)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("Decode \(T.self) failed for \(path): \(error)")
            #endif
            throw APIError(status: 0, message: "Something went wrong.", code: "decode")
        }
    }

    @discardableResult
    func raw(_ method: String, _ path: String, body: [String: Any?]? = nil, idempotencyKey: String? = nil) async throws -> Data {
        do {
            return try await LocalAPI.shared.handle(method, path, body: body?.compactMapValues { $0 })
        } catch let e as LocalError {
            throw APIError(status: e.status, message: e.message, code: nil)
        }
    }

    /// Bill photos are saved next to the database.
    @discardableResult
    func upload(_ path: String, data: Data, contentType: String) async throws -> Data {
        do {
            return try await LocalAPI.shared.handle("POST", path, body: nil, data: data)
        } catch let e as LocalError {
            throw APIError(status: e.status, message: e.message, code: nil)
        }
    }

    /// No analytics in the offline app.
    func track(_ name: String, groupId: Int? = nil, props: [String: Any] = [:]) {}
    func flushQueuedEvents() {}
}

extension Notification.Name {
    static let sessionExpired = Notification.Name("sessionExpired")
    static let coinsChanged = Notification.Name("coinsChanged")
    static let openRoute = Notification.Name("openRoute")
}
