import SwiftUI
import UIKit

/// NeoPOP-inspired tokens. Coins use one amber accent that never doubles as a money-direction colour.
enum Theme {
    static let bg = Color(hex: 0x0D0D0D)
    static let surface = Color(hex: 0x161616)
    static let surfaceHigh = Color(hex: 0x1F1F1F)
    static let line = Color(hex: 0x2A2A2A)
    static let text = Color.white
    static let muted = Color(hex: 0x8A8A8A)
    static let coin = Color(hex: 0xF5B301)        // rewards only
    static let owed = Color(hex: 0x06C270)        // "you are owed"
    static let owe = Color(hex: 0xFF8577)         // "you owe" (balances only, never in coin UI)
    static let chip = Color(hex: 0x2B2B2B)

    enum UI {
        static let bg = UIColor(hex: 0x0D0D0D)
        static let surface = UIColor(hex: 0x161616)
        static let white = UIColor.white
        static let black = UIColor(hex: 0x0D0D0D)
        static let coin = UIColor(hex: 0xF5B301)
        static let muted = UIColor(hex: 0x8A8A8A)
        static let line = UIColor(hex: 0x2A2A2A)
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
                    .foregroundStyle(Theme.bg)
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
