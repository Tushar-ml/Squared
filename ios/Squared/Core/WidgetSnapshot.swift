import Foundation
import WidgetKit

/// What the home-screen widget shows. The app writes it after refreshing; the widget only reads.
struct WidgetSnapshot: Codable {
    var name: String
    var coins: Int?
    var youOwe: Int
    var youAreOwed: Int
    var currency: String
    var needsYou: Int
    var updated: Date

    static let appGroup = "group.app.squared.ios"
    static let key = "widgetSnapshot.v1"

    static func load() -> WidgetSnapshot? {
        guard let d = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.appGroup)?.set(d, forKey: Self.key)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func clear() {
        UserDefaults(suiteName: appGroup)?.removeObject(forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
