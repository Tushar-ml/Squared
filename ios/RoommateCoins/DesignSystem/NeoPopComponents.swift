import NeoPop
import SwiftUI
import UIKit

// SwiftUI bridges for CRED's NeoPOP iOS components (https://github.com/CRED-CLUB/neopop-ios).
// Every primary action, toggle and checkbox in the app goes through these.

enum NeoPopStyle {
    case elevated          // white face, 3D edges: primary actions
    case elevatedCoin      // amber face: coin actions (redeem, see coins)
    case flat              // white face sitting flush on its container
    case stroke            // black face, white border + edges: secondary actions
    case flatStroke        // outline only

    func model(parent: UIColor) -> PopButton.Model {
        switch self {
        case .elevated:
            return PopButton.Model(position: .bottomRight, backgroundColor: .white, superViewColor: parent)
        case .elevatedCoin:
            return PopButton.Model(position: .bottomRight, backgroundColor: Theme.UI.coin, superViewColor: parent)
        case .flat:
            return PopButton.Model(position: .bottomRight, backgroundColor: .white, superViewColor: .white)
        case .stroke:
            return PopButton.Model(position: .bottomRight, backgroundColor: parent, superViewColor: parent,
                                   buttonFaceBorderColor: EdgeColors(color: .white), borderWidth: 0.5, edgeLength: 2,
                                   customEdgeColor: EdgeColors(left: nil, right: PopHelper.horizontalEdgeColor(for: .white),
                                                               top: nil, bottom: PopHelper.verticalEdgeColor(for: .white)))
        case .flatStroke:
            return PopButton.Model(position: .bottomRight, backgroundColor: parent, superViewColor: parent,
                                   buttonFaceBorderColor: EdgeColors(color: Theme.UI.muted), borderWidth: 0.5, edgeLength: 0)
        }
    }

    var titleColor: UIColor {
        switch self {
        case .elevated, .flat, .elevatedCoin: return Theme.UI.black
        case .stroke, .flatStroke: return .white
        }
    }
}

/// NeoPOP `PopButton` as a SwiftUI view.
struct NeoPopButton: View {
    let title: String
    var style: NeoPopStyle = .elevated
    var icon: String? = nil
    var enabled = true
    var loading = false
    var height: CGFloat = 50
    var parent: UIColor = Theme.UI.bg
    let action: () -> Void

    var body: some View {
        PopButtonRepresentable(title: title, style: style, icon: icon, enabled: enabled, loading: loading,
                               parent: parent, action: action)
            .frame(height: height)
            .frame(minWidth: 44)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { action() } }
    }
}

private struct PopButtonRepresentable: UIViewRepresentable {
    let title: String
    let style: NeoPopStyle
    let icon: String?
    let enabled: Bool
    let loading: Bool
    let parent: UIColor
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PopButton {
        let b = PopButton()
        b.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        b.configurePopButton(withModel: style.model(parent: parent))
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(b, context: context, force: true)
        return b
    }

    func updateUIView(_ b: PopButton, context: Context) {
        apply(b, context: context, force: false)
    }

    private func apply(_ b: PopButton, context: Context, force: Bool) {
        context.coordinator.action = action
        let key = "\(title)|\(icon ?? "")|\(enabled)|\(loading)"
        guard force || key != context.coordinator.lastKey else { return }
        context.coordinator.lastKey = key
        let font = UIFont.systemFont(ofSize: 14, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.titleColor, .kern: 0.8]
        let text = loading ? "…" : title.uppercased()
        var image: UIImage?
        if let icon {
            image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .heavy))?
                .withTintColor(style.titleColor, renderingMode: .alwaysOriginal)
        }
        b.configureButtonContent(withModel: PopButtonContainerView.Model(
            attributedTitle: NSAttributedString(string: text, attributes: attrs),
            leftImage: image, leftImageTintColor: style.titleColor, leftImageScale: 1, contentLeftRightInset: 12))
        b.changeButtonState(newState: enabled && !loading ? .normal : .disabled(withOpacity: true))
    }

    final class Coordinator: NSObject {
        var action: () -> Void = {}
        var lastKey = ""
        @objc func tapped() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }
    }
}

/// NeoPOP `PopFloatingButton` with shimmer, for the screen's single hero CTA.
struct NeoPopFloatingButton: View {
    let title: String
    var color: UIColor = .white
    var shimmer = true
    var enabled = true
    let action: () -> Void

    var body: some View {
        FloatingRepresentable(title: title, color: color, shimmer: shimmer, enabled: enabled, action: action)
            .frame(height: 64)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { action() } }
    }
}

private struct FloatingRepresentable: UIViewRepresentable {
    let title: String
    let color: UIColor
    let shimmer: Bool
    let enabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SizedPopFloatingButton {
        let b = SizedPopFloatingButton()
        b.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        update(b, context: context)
        return b
    }

    func updateUIView(_ b: SizedPopFloatingButton, context: Context) { update(b, context: context) }

    private var animate: Bool { shimmer && !UIAccessibility.isReduceMotionEnabled }

    private func update(_ b: SizedPopFloatingButton, context: Context) {
        context.coordinator.action = action
        let key = "\(title)|\(enabled)"
        guard key != context.coordinator.lastKey else { return }
        context.coordinator.lastKey = key
        // Disabled = same component re-skinned grey; NeoPOP's alpha/disable path leaves edge artifacts on black.
        let face = enabled ? color : UIColor(hex: 0x3A3A3A)
        b.apply(PopFloatingButton.Model(
            backgroundColor: face, shadowColor: UIColor(white: 0, alpha: 0.6), edgeWidth: 9,
            shimmerModel: enabled && animate
                ? PopShimmerModel(spacing: 10, lineColor1: .white, lineColor2: .white, lineWidth1: 16, lineWidth2: 35,
                                  duration: 2, delay: 4) : nil))
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16, weight: .black),
                                                    .foregroundColor: enabled ? Theme.UI.black : UIColor(hex: 0x8A8A8A),
                                                    .kern: 1.6]
        b.configureButtonContent(withModel: PopButtonContainerView.Model(
            attributedTitle: NSAttributedString(string: title.uppercased(), attributes: attrs)))
        b.isEnabled = enabled
        if enabled && animate { b.startShimmerAnimation() }
    }

    final class Coordinator: NSObject {
        var action: () -> Void = {}
        var lastKey = ""
        @objc func tapped() {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }
    }
}

/// PopFloatingButton only redraws its faces from the `bounds` setter, which Auto Layout
/// frame updates never call. Re-apply the model whenever the laid-out size changes.
final class SizedPopFloatingButton: PopFloatingButton {
    private var model: PopFloatingButton.Model?
    private var drawnSize: CGSize = .zero

    func apply(_ model: PopFloatingButton.Model) {
        self.model = model
        configureFloatingButton(withModel: model)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let model, bounds.size != drawnSize, bounds.width > 0 else { return }
        drawnSize = bounds.size
        configureFloatingButton(withModel: model)
    }
}

/// NeoPOP `PopView` used as a 3D card background.
struct NeoPopSurface: UIViewRepresentable {
    var color: UIColor = Theme.UI.surface
    var edge: UIColor = UIColor(hex: 0x3A3A3A)
    var depth: CGFloat = 5

    func makeUIView(context: Context) -> PopView {
        let v = PopView(frame: .zero, model: model)
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: PopView, context: Context) { v.configurePopView(withModel: model) }

    private var model: PopView.Model {
        PopView.Model(popEdgeDirection: .bottomRight, edgeOffSet: depth, backgroundColor: color,
                      verticalEdgeColor: PopHelper.verticalEdgeColor(for: edge),
                      horizontalEdgeColor: PopHelper.horizontalEdgeColor(for: edge))
    }
}

extension View {
    /// Places content on a NeoPOP 3D surface.
    func neoPopCard(color: UIColor = Theme.UI.surface, edge: UIColor = UIColor(hex: 0x3A3A3A), depth: CGFloat = 5,
                    padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .padding(.trailing, depth).padding(.bottom, depth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NeoPopSurface(color: color, edge: edge, depth: depth))
    }
}

/// NeoPOP `PopSwitch`.
struct NeoPopToggle: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(label).font(Theme.body(15))
            Spacer()
            SwitchRepresentable(isOn: $isOn).frame(width: 52, height: 31)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isOn.toggle() }
    }
}

private struct SwitchRepresentable: UIViewRepresentable {
    @Binding var isOn: Bool
    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }
    func makeUIView(context: Context) -> PopSwitch {
        let s = PopSwitch()
        s.configureMode(.dark)
        s.setOn(isOn, animated: false)
        s.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return s
    }
    func updateUIView(_ s: PopSwitch, context: Context) {
        context.coordinator.isOn = $isOn
        if s.isOn != isOn { s.setOn(isOn, animated: true) }
    }
    final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        init(isOn: Binding<Bool>) { self.isOn = isOn }
        @objc func changed(_ s: PopSwitch) { isOn.wrappedValue = s.isOn }
    }
}

/// NeoPOP `PopCheckBox` with a label.
struct NeoPopCheckRow: View {
    let label: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 12) {
            CheckRepresentable(isOn: $isOn).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.body(15, .semibold))
                if let detail { Text(detail).font(Theme.body(12)).foregroundStyle(Theme.muted) }
            }
            Spacer()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isOn.toggle() }
    }
}

private struct CheckRepresentable: UIViewRepresentable {
    @Binding var isOn: Bool
    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }
    func makeUIView(context: Context) -> PopCheckBox {
        let c = PopCheckBox()
        c.configure(mode: .dark)
        c.setSelected(isOn)
        c.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return c
    }
    func updateUIView(_ c: PopCheckBox, context: Context) {
        context.coordinator.isOn = $isOn
        if c.isSelectedState != isOn { c.setSelected(isOn) }
    }
    final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        init(isOn: Binding<Bool>) { self.isOn = isOn }
        @objc func changed(_ c: PopCheckBox) { isOn.wrappedValue = c.isSelectedState }
    }
}

/// NeoPOP `PopRadioButton` with a label.
struct NeoPopRadioRow: View {
    let label: String
    let selected: Bool
    let onSelect: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            RadioRepresentable(selected: selected).frame(width: 22, height: 22).allowsHitTesting(false)
            Text(label).font(Theme.body(15, .semibold))
            Spacer()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
    }
}

private struct RadioRepresentable: UIViewRepresentable {
    let selected: Bool
    func makeUIView(context: Context) -> PopRadioButton {
        let r = PopRadioButton()
        r.configure(mode: .dark)
        r.setSelected(selected)
        return r
    }
    func updateUIView(_ r: PopRadioButton, context: Context) {
        if r.isSelectedState != selected { r.setSelected(selected) }
    }
}
