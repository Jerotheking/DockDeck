import AppKit
import QuartzCore

/// The surface a shelf is drawn on, in three grades set by Preferences.
///
/// - **Liquid Glass** — macOS 26's `NSGlassEffectView`, the same dynamic
///   material the system chrome is made of. The glass, its backdrop sampling
///   and its light/dark adaptation are all Apple's own; this class only hosts
///   it and cuts its corners.
/// - **Frosted** — `NSVisualEffectView` with `.behindWindow` blending, the
///   classic translucent look. Available on every macOS and cheaper to
///   composite.
/// - **Opaque** — no translucency at all, for maximum contrast and minimum GPU.
///
/// Corners are cut by `maskImage` in every grade: the effect composites below
/// its own layer, so a layer `cornerRadius` would clip the content but leave
/// the material's square corners showing.
final class ShelfChromeView: NSView {
    struct Corners: OptionSet {
        let rawValue: Int
        static let topLeft = Corners(rawValue: 1 << 0)
        static let topRight = Corners(rawValue: 1 << 1)
        static let bottomLeft = Corners(rawValue: 1 << 2)
        static let bottomRight = Corners(rawValue: 1 << 3)
        static let all: Corners = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    /// Matches the Dock's own corner treatment closely enough that a shelf beside
    /// it reads as part of the same object.
    var cornerRadius: CGFloat = 12 { didSet { needsLayout = true } }
    var roundedCorners: Corners = .all { didSet { needsLayout = true } }
    /// Which surface grade to render. Set from `ShelfSettings` by the panel's
    /// owner; changing it swaps the effect in place without rebuilding the shelf.
    /// Named `surface` because `NSView` already owns `appearance`.
    var surface: ShelfAppearance = .liquidGlass {
        didSet {
            guard surface != oldValue else { return }
            applyAppearance()
        }
    }

    private let highlight = HairlineView()
    /// The translucent effect layer, liquid glass or frosted. Nil when opaque.
    private var effect: NSView?
    private var lastMaskedSize: NSSize = .zero
    private var lastMaskedCorners: Corners = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }
    required init?(coder: NSCoder) { return nil }

    private func configure() {
        wantsLayer = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyAppearance()
    }

    /// Swaps the surface in place. The hairline stays on top throughout, so a
    /// settings change never flashes a bare view at the user.
    func applyAppearance() {
        effect?.removeFromSuperview()
        effect = nil

        let view: NSView?
        switch surface {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.cornerRadius = 0
                view = glass
            } else {
                // Below the OS that ships Liquid Glass, frosted is the ceiling.
                view = Self.makeBlurView()
            }
        case .frosted:
            view = Self.makeBlurView()
        case .opaque:
            view = nil
        }

        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view, positioned: .below, relativeTo: highlight)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            effect = view
        }

        lastMaskedSize = .zero
        needsLayout = true
    }

    private static func makeBlurView() -> NSVisualEffectView {
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        // .followsWindowActiveState would desaturate the shelf whenever another
        // app is frontmost — which for a non-activating panel is almost always.
        blur.state = .active
        blur.isEmphasized = false
        return blur
    }

    override func layout() {
        super.layout()
        highlight.cornerRadius = cornerRadius
        highlight.roundedCorners = roundedCorners

        if surface == .opaque {
            if let layer = layer {
                // A dynamic provider keeps the tint correct across light/dark
                // without a redraw pass per appearance change.
                layer.backgroundColor = NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        ? NSColor(calibratedWhite: 0.16, alpha: 1)
                        : NSColor(calibratedWhite: 0.94, alpha: 1)
                }.cgColor
                layer.cornerRadius = cornerRadius
                layer.cornerCurve = .continuous
                layer.maskedCorners = Self.layerCorners(roundedCorners)
            }
        } else if #available(macOS 26.0, *), let glass = effect as? NSGlassEffectView {
            // The glass cuts its own corners, all four — which matches the
            // Dock's own fully-rounded treatment.
            glass.cornerRadius = cornerRadius
        }

        // Regenerating the mask is not free; only do it when it would differ.
        // Only the frosted grade needs one: its blur is composited by the
        // window server below the layer tree, so a layer mask cannot clip it —
        // `maskImage` is the one hook it offers.
        guard bounds.size != lastMaskedSize || roundedCorners != lastMaskedCorners else { return }
        lastMaskedSize = bounds.size
        lastMaskedCorners = roundedCorners
        if let blur = effect as? NSVisualEffectView {
            blur.maskImage = Self.mask(size: blur.bounds.size, radius: cornerRadius, corners: roundedCorners)
        }
    }

    /// Maps AppKit corner names onto CALayer's, whose y axis runs the other way.
    private static func layerCorners(_ corners: Corners) -> CACornerMask {
        var mask: CACornerMask = []
        if corners.contains(.topLeft) { mask.insert(.layerMinXMaxYCorner) }
        if corners.contains(.topRight) { mask.insert(.layerMaxXMaxYCorner) }
        if corners.contains(.bottomLeft) { mask.insert(.layerMinXMinYCorner) }
        if corners.contains(.bottomRight) { mask.insert(.layerMaxXMinYCorner) }
        return mask
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight.needsDisplay = true
    }

    static func path(size: NSSize, radius: CGFloat, corners: Corners) -> NSBezierPath {
        let rect = NSRect(origin: .zero, size: size)
        let r = max(0, min(radius, min(size.width, size.height) / 2))
        guard r > 0, corners != [] else { return NSBezierPath(rect: rect) }

        let path = NSBezierPath()
        let bottomLeft = corners.contains(.bottomLeft) ? r : 0
        let bottomRight = corners.contains(.bottomRight) ? r : 0
        let topRight = corners.contains(.topRight) ? r : 0
        let topLeft = corners.contains(.topLeft) ? r : 0

        path.move(to: NSPoint(x: rect.minX + bottomLeft, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - bottomRight, y: rect.minY))
        if bottomRight > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.maxX - bottomRight, y: rect.minY + bottomRight),
                           radius: bottomRight, startAngle: -90, endAngle: 0)
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - topRight))
        if topRight > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.maxX - topRight, y: rect.maxY - topRight),
                           radius: topRight, startAngle: 0, endAngle: 90)
        }
        path.line(to: NSPoint(x: rect.minX + topLeft, y: rect.maxY))
        if topLeft > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.minX + topLeft, y: rect.maxY - topLeft),
                           radius: topLeft, startAngle: 90, endAngle: 180)
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + bottomLeft))
        if bottomLeft > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.minX + bottomLeft, y: rect.minY + bottomLeft),
                           radius: bottomLeft, startAngle: 180, endAngle: 270)
        }
        path.close()
        return path
    }

    private static func mask(size: NSSize, radius: CGFloat, corners: Corners) -> NSImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            path(size: size, radius: radius, corners: corners).fill()
            return true
        }
        image.resizingMode = .stretch
        return image
    }
}

/// The one-pixel specular edge that separates a glass surface from what is
/// behind it. Without it the material floats with no defined boundary; system
/// materials all carry some version of this.
private final class HairlineView: NSView {
    var cornerRadius: CGFloat = 12 { didSet { needsDisplay = true } }
    var roundedCorners: ShelfChromeView.Corners = .all { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let inset = NSRect(origin: .zero, size: bounds.size).insetBy(dx: 0.5, dy: 0.5)
        let path = ShelfChromeView.path(size: inset.size, radius: cornerRadius, corners: roundedCorners)
        let transform = AffineTransform(translationByX: 0.5, byY: 0.5)
        path.transform(using: transform)
        path.lineWidth = 1
        // Light content needs a darker separator; dark content needs a lighter
        // one. A single fixed colour disappears against one of the two.
        (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10)).setStroke()
        path.stroke()
    }
}
