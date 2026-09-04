import AppKit
import QuartzCore

/// The shelf's glass reacts to the pointer. This is the layer that makes the
/// surface feel *alive* rather than merely animated:
///
/// - a **specular glow** gathers in the glass beneath the pointer and follows
///   it, biased toward the Dock-facing edge — the way Liquid Glass catches
///   light from the content behind it;
/// - a perpetual **one-and-a-half-point float** keeps the surface from sitting
///   dead still, the way a real physical object still moves with the light;
/// - everything fades in over a beat on pointer enter and dissolves on exit,
///   so the reaction reads as the glass noticing you, not an effect switching
///   on.
///
/// All of it is GPU-side: one sublayer with two infinite animations the
/// compositor runs without this process's involvement. The interactor itself
/// uses only long-available CALayer APIs; the caller gates *creation* on the
/// Liquid Glass OS and on Reduce Motion, so this class carries no availability
/// annotation of its own.
final class GlassInteractor {
    private weak var panel: ShelfPanel?
    private let glow = CAGradientLayer()
    private let glowSize: CGFloat = 320
    private var lastPointer: NSPoint?
    /// The glow's *presented* position, which approaches the pointer
    /// exponentially (WS-7: light has inertia — it gathers, it never
    /// teleports). Nil until first placed.
    private var smoothed: NSPoint?
    /// Exponential time-constant for the approach: fast enough to feel welded
    /// to the pointer on slow moves, slow enough that a fast sweep visibly
    /// drags the light through the glass.
    private static let followTau: CFTimeInterval = 0.07
    /// Within this distance the glow snaps the rest of the way — the tail of
    /// an exponential approach would otherwise be visible as a permanent
    /// few-point offset after a sweep stops.
    private static let snapDistance: CGFloat = 4
    private var appeared = false

    init(panel: ShelfPanel) {
        self.panel = panel
        glow.type = .radial
        glow.colors = [
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor
        ]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.bounds = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
        glow.isOpaque = false
        glow.opacity = 0
        // The gradient axis leans toward the Dock's edge, so the bloom is
        // pulled toward where the shelf meets the Dock — light pooling at the
        // seam rather than centred on the pointer.
        glow.endPoint = Self.interior(panel: panel)
        // A slow breath so even a stationary pointer reads as awake.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.55
        pulse.toValue = 1.0
        pulse.duration = 1.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(pulse, forKey: "glowPulse")
    }

    /// Unit vector pointing from the Dock-facing edge *into* the shelf, in
    /// layer space (y runs down). The glow's gradient axis leans this way.
    private static func interior(panel: ShelfPanel) -> CGPoint {
        switch panel.dock.orientation {
        case .bottom: return CGPoint(x: 0.0, y: 1.0)
        case .left:   return CGPoint(x: -1.0, y: 0.0)
        case .right:  return CGPoint(x: 1.0, y: 0.0)
        }
    }

    func appear() {
        appeared = true
        guard let panel, let hostLayer = panel.contentScaleHost.layer else { return }
        if glow.superlayer == nil {
            hostLayer.insertSublayer(glow, at: 0)
        }
        if let chromeLayer = panel.chrome.layer,
           chromeLayer.animation(forKey: "floatingDriftX") == nil,
           chromeLayer.animation(forKey: "floatingDriftY") == nil {
            MaterialLayerStyles.setFloatingMotion(on: chromeLayer)
        }
        // Fade the glow in over a beat — the glass noticing the pointer.
        glow.removeAnimation(forKey: "glowFade")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.28
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        glow.add(fade, forKey: "glowFade")
        glow.opacity = 1
        // Re-entering resumes from the light's last spot — never a teleport.
        smoothed = lastPointer
        if let smoothed { moveGlow(to: smoothed) }
    }

    func disappear() {
        appeared = false
        panel?.chrome.layer?.removeAnimation(forKey: "floatingDriftX")
        panel?.chrome.layer?.removeAnimation(forKey: "floatingDriftY")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = glow.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.45
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(fade, forKey: "glowFade")
        glow.opacity = 0
    }

    /// The glow's placement uses the presented position, which is driven by
    /// `update`; `moveGlow` itself stays immediate so the window-frame hook
    /// can re-map it during springs without double-easing.

    /// The pointer moved: the glow follows it inside the glass.
    func update(point: NSPoint) {
        lastPointer = point
        guard appeared else { return }
        // Exponential approach from wherever the light is now to where the
        // pointer is — using the wall clock, so a burst of mouse-moved events
        // and one event after a pause advance the light by the same amount.
        let now = CACurrentMediaTime()
        if let current = smoothed {
            let dx = point.x - current.x
            let dy = point.y - current.y
            let distance = CGFloat(sqrt(dx * dx + dy * dy))
            if distance < Self.snapDistance {
                smoothed = point
            } else {
                let lag = lastMotionLag(to: now)
                let fraction = CGFloat(1 - exp(-lag / Self.followTau))
                smoothed = NSPoint(x: current.x + dx * fraction, y: current.y + dy * fraction)
            }
        } else {
            smoothed = point
        }
        lastMotionTime = now
        if let smoothed { moveGlow(to: smoothed) }
    }

    private var lastMotionTime: CFTimeInterval = 0
    private func lastMotionLag(to now: CFTimeInterval) -> CFTimeInterval {
        lastMotionTime == 0 ? Self.followTau : max(0, now - lastMotionTime)
    }

    /// The window's frame changed (spring, compression, expansion): keep the
    /// glow mapped to the same on-screen spot in the new bounds.
    func viewportChanged() {
        if let smoothed {
            moveGlow(to: smoothed)
        } else if let lastPointer {
            moveGlow(to: lastPointer)
        }
    }

    /// Tears the effects down for good — the panel is going away. Not the
    /// same as `disappear()`, which keeps the layer for the next appearance.
    func stop() {
        appeared = false
        glow.removeAnimation(forKey: "glowFade")
        glow.removeAnimation(forKey: "glowPulse")
        glow.removeFromSuperlayer()
        panel?.chrome.layer?.removeAnimation(forKey: "floatingDriftX")
        panel?.chrome.layer?.removeAnimation(forKey: "floatingDriftY")
    }

    private func moveGlow(to point: NSPoint) {
        guard let panel else { return }
        let bounds = panel.chrome.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        // Clamp so the bloom never leaves the surface entirely.
        let x = min(max(point.x, 24), bounds.width - 24)
        let y = min(max(point.y, 24), bounds.height - 24)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.position = CGPoint(x: x, y: bounds.height - y)
        CATransaction.commit()
    }
}
