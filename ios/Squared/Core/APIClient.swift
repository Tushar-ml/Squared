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

/// Thin async client for the Squared API. Coin amounts are never sent (I-2).
final class APIClient {
    static let shared = APIClient()

    var token: String?
    var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "apiBaseURL"), let u = URL(string: s) { return u }
        let plist = Bundle.main.object(forInfoDictionaryKey: "RCAPIBaseURL") as? String ?? "http://localhost:8080"
        return URL(string: plist)!
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData  // balances and coins must never come from cache
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

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
            throw APIError(status: 0, message: "Something went wrong. Pull to refresh.", code: "decode")
        }
    }

    @discardableResult
    func raw(_ method: String, _ path: String, body: [String: Any?]? = nil, idempotencyKey: String? = nil) async throws -> Data {
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        guard let url = URL(string: base + "/api/v1" + path) else {
            throw APIError(status: 0, message: "Bad server address", code: "url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ios/\(Self.appVersion)", forHTTPHeaderField: "X-Client")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let idempotencyKey { req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError(status: -1, message: "You're offline. We'll sync when you're back.", code: "offline")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var message = "Something went wrong. Try again."
            var code: String?
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let d = obj["detail"] as? String { message = d }
                if let d = obj["detail"] as? [String: Any] {
                    message = d["message"] as? String ?? message
                    code = d["code"] as? String
                }
            }
            if status == 401 && token != nil { NotificationCenter.default.post(name: .sessionExpired, object: nil) }
            throw APIError(status: status, message: message, code: code)
        }
        return data
    }

    /// Funnel events from before sign-in (walkthrough) wait here and are sent once there is a session.
    private var queuedEvents: [(String, Int?, [String: Any])] = []
    private let queueLock = NSLock()

    func flushQueuedEvents() {
        queueLock.lock(); let events = queuedEvents; queuedEvents = []; queueLock.unlock()
        for e in events { track(e.0, groupId: e.1, props: e.2) }
    }

    /// Binary upload (receipts).
    @discardableResult
    func upload(_ path: String, data: Data, contentType: String) async throws -> Data {
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        guard let url = URL(string: base + "/api/v1" + path) else { throw APIError(status: 0, message: "Bad URL", code: nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (out, resp) = try await session.upload(for: req, from: data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: out) as? [String: Any])?["detail"] as? String
            throw APIError(status: status, message: msg ?? "Upload failed", code: nil)
        }
        return out
    }

    func track(_ name: String, groupId: Int? = nil, props: [String: Any] = [:]) {
        guard token != nil else {
            queueLock.lock(); queuedEvents.append((name, groupId, props)); queueLock.unlock()
            return
        }
        Task {
            try? await raw("POST", "/analytics/events", body: ["name": name, "group_id": groupId, "props": props,
                                                               "app_version": Self.appVersion])
        }
    }
}

extension Notification.Name {
    static let sessionExpired = Notification.Name("sessionExpired")
    static let coinsChanged = Notification.Name("coinsChanged")
    static let openRoute = Notification.Name("openRoute")
}
