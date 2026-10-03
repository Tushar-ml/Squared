import SwiftUI
import UIKit

/// NeoPOP-inspired tokens. Coins use one amber accent that never doubles as a money-direction colour.
enum Theme {
    // Dynamic tokens: NeoPOP dark by default, a CRED-style light mode (white canvas, black buttons).
    static let bg = Color(uiColor: UI.bg)
    static let surface = Color(uiColor: UI.surface)
    static let surfaceHigh = Color(uiColor: .dynamic(light: 0xEDEDED, dark: 0x1F1F1F))
    static let line = Color(uiColor: UI.line)
    static let text = Color(uiColor: UI.inverse)          // primary text; also the face of primary buttons
    static let muted = Color(uiColor: UI.muted)
    static let coin = Color(uiColor: .dynamic(light: 0xD99A00, dark: 0xF5B301))   // rewards only
    static let owed = Color(uiColor: .dynamic(light: 0x038A50, dark: 0x06C270))   // "you are owed"
    static let owe = Color(uiColor: .dynamic(light: 0xD64B3A, dark: 0xFF8577))    // "you owe" (balances only)
    static let chip = Color(uiColor: .dynamic(light: 0xEDEDED, dark: 0x2B2B2B))
    static let onAccent = Color(hex: 0x0D0D0D)            // text on amber / green fills, both themes

    enum UI {
        static let bg = UIColor.dynamic(light: 0xFFFFFF, dark: 0x0D0D0D)
        static let surface = UIColor.dynamic(light: 0xF6F6F6, dark: 0x161616)
        static let inverse = UIColor.dynamic(light: 0x0D0D0D, dark: 0xFFFFFF)      // button face
        static let onInverse = UIColor.dynamic(light: 0xFFFFFF, dark: 0x0D0D0D)    // text on button face
        static let white = UIColor.white
        static let black = UIColor(hex: 0x0D0D0D)
        static let coin = UIColor(hex: 0xF5B301)
        static let muted = UIColor.dynamic(light: 0x6B6B6B, dark: 0x8A8A8A)
        static let line = UIColor.dynamic(light: 0xDDDDDD, dark: 0x2A2A2A)
        static let edge = UIColor.dynamic(light: 0xC9C9C9, dark: 0x3A3A3A)
        static let disabled = UIColor.dynamic(light: 0xD5D5D5, dark: 0x3A3A3A)
    }

    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .heavy, design: .default) }
    static func body(_ size: CGFloat = 15, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func number(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .heavy, design: .rounded).monospacedDigit() }
    static let label = Font.system(size: 11, weight: .bold).width(.expanded)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension UIColor {
    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark) }
    }

    /// NeoPOP draws with CGColors at configure time, so resolve dynamic colours for the current scheme.
    func resolved(_ scheme: ColorScheme) -> UIColor {
        resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .light ? .light : .dark))
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Uppercase, tracked section label in the NeoPOP style.
struct SectionLabel: View {
    let text: String
    var color: Color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(1.6)
            .foregroundStyle(color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Neutral status chip. Never red (PRD S2).
struct StatusChip: View {
    let text: String
    var tint: Color = Theme.muted
    var filled = false
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(filled ? Theme.bg : tint)
            .background(filled ? tint : Theme.chip)
            .overlay(Rectangle().stroke(filled ? .clear : Theme.line, lineWidth: 1))
    }
}

/// Amber coin badge used wherever a balance appears.
struct CoinChip: View {
    let coins: Int
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            CoinGlyph(size: compact ? 14 : 16)
            Text("\(coins)").font(.system(size: compact ? 13 : 15, weight: .heavy, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(Theme.coin)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.coin.opacity(0.12))
        .overlay(Rectangle().stroke(Theme.coin.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(coins) coins")
    }
}

struct CoinGlyph: View {
    var size: CGFloat = 16
    var body: some View {
        ZStack {
            Circle().fill(Theme.coin)
            Circle().stroke(Color(hex: 0xB07F00), lineWidth: size * 0.12).padding(size * 0.14)
            Text("C").font(.system(size: size * 0.5, weight: .black, design: .rounded)).foregroundStyle(Color(hex: 0x6B4A00))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct Avatar: View {
    let name: String
    var tick = false
    var size: CGFloat = 36
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .heavy))
                .frame(width: size, height: size)
                .background(Theme.surfaceHigh)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            if tick {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.26, weight: .black))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Theme.owed)
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tick ? "\(name), confirmed this week" : name)
    }
}

/// Flat surface card with a hairline border (used inside lists).
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }
}

struct Skeleton: View {
    var height: CGFloat = 16
    @State private var phase = false
    var body: some View {
        Rectangle()
            .fill(Theme.surfaceHigh)
            .frame(height: height)
            .opacity(phase ? 0.45 : 0.9)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { phase = true } }
            .accessibilityLabel("Loading")
    }
}

/// Neutral state shown when the reward service can't be reached (FR-14).
struct CoinsUnavailable: View {
    var body: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "circle.dashed").foregroundStyle(Theme.muted)
                Text(Strings.coinsUnavailable).font(Theme.body(14)).foregroundStyle(Theme.muted)
            }
        }
    }
}
