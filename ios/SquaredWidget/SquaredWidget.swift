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

struct SquaredWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    private let amber = Color(red: 0.96, green: 0.70, blue: 0.0)

    var body: some View {
        if let s = entry.snap, family == .systemMedium {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.name.isEmpty ? "ROOMMATE COINS" : "HI \(s.name.uppercased())")
                        .font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    balance(s, size: 22)
                }
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                VStack(alignment: .leading, spacing: 10) {
                    if let c = s.coins {
                        HStack(spacing: 6) {
                            Circle().fill(amber).frame(width: 14, height: 14)
                            Text("\(c) coins").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(amber)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(s.needsYou > 0 ? "\(s.needsYou)" : "0").font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(s.needsYou > 0 ? amber : .secondary)
                    Text(s.needsYou == 1 ? "waiting for you" : (s.needsYou == 0 ? "nothing waiting" : "waiting for you"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .frame(width: 110, alignment: .leading)
            }
            .widgetURL(URL(string: "squared://open?route=home"))
        } else if let s = entry.snap {
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
                balance(s, size: 18)
                if s.needsYou > 0 {
                    Text("\(s.needsYou) waiting for you").font(.system(size: 11, weight: .semibold)).foregroundStyle(amber)
                }
            }
            .widgetURL(URL(string: "squared://open?route=home"))
        } else {
            VStack(alignment: .leading) {
                Circle().fill(amber).frame(width: 16, height: 16)
                Spacer()
                Text("Open Squared to sign in").font(.system(size: 13, weight: .semibold))
            }
        }
    }
}

extension SquaredWidgetView {
    @ViewBuilder
    func balance(_ s: WidgetSnapshot, size: CGFloat) -> some View {
        if s.youOwe > 0 {
            Text("YOU OWE").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            Text(money(s.youOwe, s.currency)).font(.system(size: size, weight: .heavy)).minimumScaleFactor(0.5).lineLimit(1)
        } else if s.youAreOwed > 0 {
            Text("YOU ARE OWED").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            Text(money(s.youAreOwed, s.currency)).font(.system(size: size, weight: .heavy)).minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle(Color(red: 0.02, green: 0.76, blue: 0.44))
        } else {
            Text("All square").font(.system(size: size, weight: .heavy))
        }
    }
}

@main
struct SquaredWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SquaredWidget", provider: Provider()) { entry in
            SquaredWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(red: 0.05, green: 0.05, blue: 0.05) }
                .environment(\.colorScheme, .dark)
        }
        .configurationDisplayName("Squared")
        .description("What you owe, what's waiting for you, and your coins.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
