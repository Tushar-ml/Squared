import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snap: WidgetSnapshot(name: "Aman", coins: 340, youOwe: 45000, youAreOwed: 0, currency: "INR", needsYou: 2, updated: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snap: WidgetSnapshot.load() ?? placeholder(in: context).snap))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, snap: WidgetSnapshot.load())],
                            policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

private func money(_ minor: Int, _ cur: String) -> String {
    let d = ["JPY", "KRW", "IDR"].contains(cur) ? 0 : 2
    let v = Double(minor) / pow(10, Double(d))
    let f = NumberFormatter()
    f.locale = Locale(identifier: cur == "INR" ? "en_IN" : "en_US")
    f.numberStyle = .decimal
    f.maximumFractionDigits = minor % 100 == 0 ? 0 : d
    return "\(cur) " + (f.string(from: NSNumber(value: v)) ?? "\(v)")
}

struct RoommateCoinsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    private let amber = Color(red: 0.96, green: 0.70, blue: 0.0)

    var body: some View {
        if let s = entry.snap {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(amber).frame(width: 14, height: 14)
                    if let c = s.coins { Text("\(c)").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(amber) }
                    Spacer()
                    if s.needsYou > 0 {
                        Text("\(s.needsYou)").font(.system(size: 11, weight: .black)).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(amber)
                    }
                }
                Spacer(minLength: 0)
                if s.youOwe > 0 {
                    Text("YOU OWE").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                    Text(money(s.youOwe, s.currency)).font(.system(size: family == .systemSmall ? 18 : 22, weight: .heavy)).minimumScaleFactor(0.6)
                } else if s.youAreOwed > 0 {
                    Text("YOU ARE OWED").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                    Text(money(s.youAreOwed, s.currency)).font(.system(size: family == .systemSmall ? 18 : 22, weight: .heavy))
                        .foregroundStyle(Color(red: 0.02, green: 0.76, blue: 0.44)).minimumScaleFactor(0.6)
                } else {
                    Text("All square").font(.system(size: 18, weight: .heavy))
                }
                if s.needsYou > 0 {
                    Text("\(s.needsYou) waiting for you").font(.system(size: 11, weight: .semibold)).foregroundStyle(amber)
                }
            }
            .widgetURL(URL(string: "roommatecoins://open?route=home"))
        } else {
            VStack(alignment: .leading) {
                Circle().fill(amber).frame(width: 16, height: 16)
                Spacer()
                Text("Open Roommate Coins to sign in").font(.system(size: 13, weight: .semibold))
            }
        }
    }
}

@main
struct RoommateCoinsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RoommateCoinsWidget", provider: Provider()) { entry in
            RoommateCoinsWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(red: 0.05, green: 0.05, blue: 0.05) }
                .environment(\.colorScheme, .dark)
        }
        .configurationDisplayName("Roommate Coins")
        .description("What you owe, what's waiting for you, and your coins.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
