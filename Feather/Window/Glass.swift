import AppKit
import SwiftUI

// Liquid Glass prototype (Settings → Appearance → Liquid Glass look). With it
// off, views keep Feather's usual soft fills; with it on, the same views become
// glass over a see-through window tinted with the space's color.

extension View {
    /// A control's background: a soft fill normally, glass in the prototype.
    @ViewBuilder
    func featherSurface<S: Shape>(_ shape: S, glass: Bool, fill: Double, tint: Color? = nil,
                                  interactive: Bool = false) -> some View {
        if glass {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(shape.fill(.primary.opacity(fill)))
        }
    }

    /// A floating panel's background (command bar, banners): material normally, glass in the prototype.
    @ViewBuilder
    func featherPanel<S: Shape>(_ shape: S, glass: Bool) -> some View {
        if glass {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
        }
    }
}

/// The window background in the prototype: the desktop shows through, tinted
/// with the space's hue, so the glass above it has something to bend.
final class GlassBackdropView: NSView {
    private let blur = NSVisualEffectView()
    private let tintView = GradientView()
    private var tint: CAGradientLayer { tintView.layer as! CAGradientLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blur.blendingMode = .behindWindow
        blur.material = .underWindowBackground
        blur.state = .followsWindowActiveState
        // A subview, not a sublayer, so AppKit keeps the tint above the blur.
        [blur, tintView].forEach(addSubview)
        tint.startPoint = CGPoint(x: 0, y: 1)
        tint.endPoint = CGPoint(x: 1, y: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(hue: Double, dark: Bool, site: NSColor? = nil) {
        if let site {
            let second = NSColor(hue: hue, saturation: dark ? 0.6 : 0.42, brightness: dark ? 0.22 : 0.9, alpha: 0.5)
            setColors([site.withAlphaComponent(dark ? 0.7 : 0.62), second])
            return
        }
        let colors: [NSColor] = dark
            ? [NSColor(hue: hue, saturation: 0.55, brightness: 0.32, alpha: 0.72),
               NSColor(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.22, alpha: 0.6)]
            : [NSColor(hue: hue, saturation: 0.32, brightness: 0.98, alpha: 0.62),
               NSColor(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.42, brightness: 0.9, alpha: 0.5)]
        setColors(colors)
    }

    private func setColors(_ colors: [NSColor]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.colors = colors.map(\.cgColor)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        tintView.frame = bounds
    }
}

private final class GradientView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
