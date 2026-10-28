import SwiftUI

enum TourTarget: String {
    case address, newTab, favorite, spaces
}

/// Layout probes follow the actual SwiftUI controls, rather than guessing their
/// position from a sidebar width. They never intercept input or accessibility.
struct TourAnchor: NSViewRepresentable {
    let target: TourTarget
    init(_ target: TourTarget) { self.target = target }
    func makeNSView(context: Context) -> TourAnchorView { TourAnchorView(target) }
    func updateNSView(_ view: TourAnchorView, context: Context) {}
}

final class TourAnchorView: NSView {
    let target: TourTarget
    init(_ target: TourTarget) {
        self.target = target
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func find(_ target: TourTarget, in view: NSView) -> TourAnchorView? {
        if let probe = view as? TourAnchorView, probe.target == target { return probe }
        for child in view.subviews {
            if let probe = find(target, in: child) { return probe }
        }
        return nil
    }
}
