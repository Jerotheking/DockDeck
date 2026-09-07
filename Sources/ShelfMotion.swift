import AppKit
import QuartzCore

/// Spring physics for shelf movement.
///
/// Apple's motion does not read as "a timed slide"; it reads as mass on a
/// spring. The property that makes it feel alive is **interruptibility**: a new
/// target adopted mid-flight inherits the current velocity instead of restarting
/// from zero. A bezier `NSAnimationContext` cannot do that — retargeting snaps —
/// so this integrates the spring itself, per display frame.
///
/// Parameters follow SwiftUI's `response` / `dampingFraction` formulation, which
/// is the same model Apple's own components are tuned with:
///
///     stiffness = (2π / response)²
///     damping   = (4π · dampingFraction) / response
///
/// `dampingFraction` at 1.0 settles without overshoot; below 1.0 it overshoots
/// slightly, which is what makes a panel feel physical rather than mechanical.
/// The presets are tuned for *perceived latency*: a shelf following the Dock has
/// to feel welded to it (`.track`), while expansion may luxuriate (`.expand`).
struct SpringParameters {
    /// Roughly the time to approach the target, in seconds.
    var response: CGFloat
    /// 1.0 = critically damped. Below 1.0 overshoots.
    var dampingFraction: CGFloat

    /// Following the Dock's live geometry — magnification, divider drags. Fast
    /// enough to read as *attached* rather than chasing: visually caught up in
    /// under a tenth of a second, the interval the eye tolerates before two
    /// moving things stop reading as one object.
    static let track = SpringParameters(response: 0.13, dampingFraction: 0.95)
    /// Reveal: surfacing from off-screen or from the Dock's strip. A quick
    /// overshoot reads as eager, not sluggish.
    static let reveal = SpringParameters(response: 0.30, dampingFraction: 0.78)
    /// Expansion pours out of the Dock: the one gesture allowed to luxuriate.
    /// Bounciest of the set — the panel overshoots outward and settles back
    /// like liquid finding its level.
    static let expand = SpringParameters(response: 0.42, dampingFraction: 0.68)
    /// Collapsing back to the Dock strip: quicker than reveal, barely
    /// underdamped, so it reads as getting out of the way.
    static let collapse = SpringParameters(response: 0.24, dampingFraction: 0.85)
    /// A structural relocation — the Dock moved to another edge and the shelf
    /// travels with it. Decisive and quick, not the liquid reveal.
    static let slide = SpringParameters(response: 0.45, dampingFraction: 0.90)
    /// Notch open: decided, slightly eager — the silhouette grows into a
    /// panel with a hint of overshoot (brief §5). Between the genre's sobriety
    /// (boring) and jelly (NotchDrop's 0.5 s / 0.25 bounce).
    static let notchOpen = SpringParameters(response: 0.32, dampingFraction: 0.85)
    /// Notch close: quicker, almost no bounce — getting out of the way.
    static let notchClose = SpringParameters(response: 0.24, dampingFraction: 0.92)

    var stiffness: CGFloat { pow(2 * .pi / max(response, 0.01), 2) }
    var damping: CGFloat { (4 * .pi * dampingFraction) / max(response, 0.01) }
}

/// Drives an `NSWindow` frame with a spring, one component at a time.
///
/// Retargeting mid-flight keeps the current position *and velocity*, which is
/// what separates Apple-feeling motion from a restarted tween — and this class
/// now retargets *interactively*: `retarget(to:)` adopted a new destination so
/// cheaply that the watcher can feed it the Dock's geometry at event rate and
/// the motion stays one continuous gesture instead of a chain of animations.
final class SpringAnimator {
    /// The window's motion at the last integration step, published for the
    /// content's inertia: a surface whose contents ride rigidly reads as a
    /// rectangle with a decal, so the content needs to know how fast the
    /// surface is moving. Displacement is toward the target; velocity is the
    /// spring's own, in points per second.
    struct MotionSample: Equatable {
        static let zero = MotionSample(displacement: .zero, velocity: .zero)
        var displacement: CGSize
        var velocity: CGSize
        /// The larger axis speed — the scalar that drives how much inertia
        /// the content shows.
        var speed: CGFloat { max(abs(velocity.width), abs(velocity.height)) }
    }

    private weak var window: NSWindow?
    // Stored untyped: CADisplayLink is macOS 14+, and a typed stored property
    // would raise the whole class's availability past the deployment target.
    private var displayLinkStorage: AnyObject?
    private var fallbackTimer: Timer?
    private var lastTimestamp: CFTimeInterval = 0

    private var current: CGRect = .zero
    private var target: CGRect = .zero
    private var velocity = (x: CGFloat(0), y: CGFloat(0), w: CGFloat(0), h: CGFloat(0))
    private var parameters = SpringParameters.track
    private var completion: (() -> Void)?

    /// Motion of the last integration step. Read by the panel's per-frame
    /// hook (`setFrame` fires once per spring step) to give the content its
    /// own inertia. Zero whenever the spring is idle or settled.
    private(set) var motion = MotionSample.zero

    /// Below this, the spring is close enough that another frame would not be
    /// visible: snap and stop rather than burn frames converging.
    private static let positionEpsilon: CGFloat = 0.5
    private static let velocityEpsilon: CGFloat = 0.5
    /// Small en route corrections — a follow-the-Dock retarget that barely
    /// differs from where the spring already is — snap instead of churning
    /// frames that no eye could tell apart.
    private static let snapEpsilon: CGFloat = 0.75

    init(window: NSWindow) {
        self.window = window
        current = window.frame
        target = window.frame
    }

    deinit { stop() }

    var isRunning: Bool { displayLinkStorage != nil || fallbackTimer != nil }

    /// Honours the system's Reduce Motion setting: when the user has asked for
    /// less animation, the frame is set directly.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func animate(to frame: CGRect, parameters: SpringParameters, completion: (() -> Void)? = nil) {
        guard let window else { return }
        self.parameters = parameters
        self.target = frame

        guard !reduceMotion else {
            stop()
            current = frame
            window.setFrame(frame, display: true)
            completion?()
            return
        }

        self.completion = completion
        if !isRunning {
            current = window.frame
            velocity = (0, 0, 0, 0)
            start()
        }
        // Already running: keep position and velocity, only the target changed.
    }

    /// Adopts a new destination while *already animating*, preserving position
    /// and velocity — the primitive that makes continuous Dock-following read
    /// as one gesture. When the animator is idle or the new target is within a
    /// hair of the current frame, it snaps instead of starting a spring that
    /// would run a dozen frames for a sub-pixel correction.
    func retarget(to frame: CGRect, parameters: SpringParameters) {
        guard isRunning, !reduceMotion, !frame.equalTo(current) else {
            set(frame)
            return
        }
        animate(to: frame, parameters: parameters)
    }

    /// Jump without animating — used on first presentation and on display
    /// reconfiguration, where a spring across a screen change looks like a bug.
    func set(_ frame: CGRect) {
        stop()
        current = frame
        target = frame
        velocity = (0, 0, 0, 0)
        window?.setFrame(frame, display: true)
    }

    private func start() {
        lastTimestamp = 0
        if #available(macOS 14.0, *), let window {
            let link = window.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLinkStorage = link
        } else {
            // 120 Hz keeps the integration stable on ProMotion displays too.
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.step(delta: 1.0 / 120.0) }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    func stop() {
        if #available(macOS 14.0, *) { (displayLinkStorage as? CADisplayLink)?.invalidate() }
        displayLinkStorage = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        lastTimestamp = 0
        motion = .zero
    }

    @available(macOS 14.0, *)
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let delta = lastTimestamp == 0 ? 1.0 / 60.0 : min(now - lastTimestamp, 1.0 / 30.0)
        lastTimestamp = now
        step(delta: delta)
    }

    /// Semi-implicit Euler. Stable at display rates for these stiffnesses, and
    /// the step is clamped above so a stalled frame cannot explode the spring.
    private func step(delta: CFTimeInterval) {
        guard let window else { stop(); return }
        let dt = CGFloat(delta)
        let k = parameters.stiffness
        let c = parameters.damping

        func integrate(_ position: CGFloat, _ goal: CGFloat, _ velocity: CGFloat) -> (CGFloat, CGFloat) {
            let acceleration = -k * (position - goal) - c * velocity
            let newVelocity = velocity + acceleration * dt
            return (position + newVelocity * dt, newVelocity)
        }

        let (x, vx) = integrate(current.origin.x, target.origin.x, velocity.x)
        let (y, vy) = integrate(current.origin.y, target.origin.y, velocity.y)
        let (w, vw) = integrate(current.size.width, target.size.width, velocity.w)
        let (h, vh) = integrate(current.size.height, target.size.height, velocity.h)

        current = CGRect(x: x, y: y, width: max(1, w), height: max(1, h))
        velocity = (vx, vy, vw, vh)
        motion = MotionSample(
            displacement: CGSize(width: target.origin.x - x, height: target.origin.y - y),
            velocity: CGSize(width: vx, height: vy))

        let settled = abs(x - target.minX) < Self.positionEpsilon
            && abs(y - target.minY) < Self.positionEpsilon
            && abs(w - target.width) < Self.positionEpsilon
            && abs(h - target.height) < Self.positionEpsilon
            && abs(vx) < Self.velocityEpsilon && abs(vy) < Self.velocityEpsilon
            && abs(vw) < Self.velocityEpsilon && abs(vh) < Self.velocityEpsilon

        if settled {
            current = target
            velocity = (0, 0, 0, 0)
            motion = .zero
            window.setFrame(target, display: true)
            stop()
            let done = completion
            completion = nil
            done?()
        } else {
            window.setFrame(current, display: false)
        }
    }
}

/// Material behaviors layered on top of the glass surface — the difference
/// between a window that moves and a shelf that *reacts*. Every effect honours
/// Reduce Motion by simply not being applied; the callers check once.
enum MaterialLayerStyles {
    /// A gentle perpetual drift — a point and a half of sway on two axes —
    /// so the glass catches its backdrop at subtly changing angles the way a
    /// real object at rest still moves with the light. The two periods are
    /// deliberately incommensurable (WS-7: a 5.3 s and a 7.1 s cycle meet
    /// again only every ~37.6 s, and with the ease curves no visible repeat),
    /// so the composite motion never resolves into a loop the eye can learn.
    /// Cheap: two infinite keyframe animations the compositor runs without
    /// the app's involvement.
    static func setFloatingMotion(on layer: CALayer) {
        let horizontal = CAKeyframeAnimation(keyPath: "transform.translation.x")
        horizontal.values = [0.0, 1.5, 0.0, -1.5, 0.0].map { NSNumber(value: Double($0)) }
        horizontal.duration = 5.3
        horizontal.repeatCount = .infinity
        horizontal.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let vertical = CAKeyframeAnimation(keyPath: "transform.translation.y")
        vertical.values = [0.0, -1.5, 0.0, 1.5, 0.0].map { NSNumber(value: Double($0)) }
        vertical.duration = 7.1
        vertical.repeatCount = .infinity
        vertical.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        layer.add(horizontal, forKey: "floatingDriftX")
        layer.add(vertical, forKey: "floatingDriftY")
    }

    /// The entrance for shelf *contents*: rows arrive with a short travel from
    /// the Dock-facing edge, a slight scale-up, and a fade — staggered by the
    /// caller — so the shelf appears to dispense its items outward.
    ///
    /// `offset` is the start position's displacement in AppKit points (the
    /// caller derives "from the Dock side" for its orientation); it is
    /// converted to layer space (y down) here.
    static func makeArrival(offset: CGSize, index: Int) -> CAAnimation {
        let spring = CASpringAnimation(keyPath: "transform")
        var from = CATransform3DMakeTranslation(offset.width, -offset.height, 0)
        from = CATransform3DScale(from, 0.94, 0.94, 1)
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = SpringParameters.expand.stiffness
        spring.damping = SpringParameters.expand.damping
        spring.duration = spring.settlingDuration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.14

        let group = CAAnimationGroup()
        group.animations = [spring, fade]
        group.duration = spring.duration
        group.beginTime = CACurrentMediaTime() + Double(index) * 0.045
        group.fillMode = .backwards
        return group
    }

    /// Press feedback for tiles and rows: a quick press *into* the glass and a
    /// spring back out, so every click lands with a physical thump.
    static func setPressed(_ layer: CALayer) {
        layer.removeAnimation(forKey: "press")
        let press = CASpringAnimation(keyPath: "transform.scale")
        press.fromValue = layer.value(forKeyPath: "transform.scale") ?? 1.0
        press.toValue = 0.92
        press.mass = 1
        press.stiffness = 900
        press.damping = 34
        press.duration = 0.18
        layer.add(press, forKey: "press")
        layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
    }

    /// The release half of `setPressed`: springs back past 1 and settles —
    /// the bounce that makes a press feel like it did something.
    static func releasePressed(_ layer: CALayer) {
        layer.removeAnimation(forKey: "press")
        let release = CASpringAnimation(keyPath: "transform.scale")
        release.fromValue = layer.value(forKeyPath: "transform.scale") ?? 1.0
        release.toValue = 1.0
        release.mass = 1
        release.stiffness = SpringParameters.reveal.stiffness
        release.damping = SpringParameters.reveal.damping
        release.duration = release.settlingDuration
        layer.add(release, forKey: "press")
        layer.transform = CATransform3DIdentity
    }

    /// Growth on the Dock-facing face, seen at expansion frame one: the
    /// sheet's long edges bulge outward with the growing window, as if the
    /// glass were stretching over more of the screen (WS-2, principle 1).
    /// `verticalLongAxis` is true when the shelf's length runs vertically
    /// (a side Dock). Set without implicit actions — the spring drives the
    /// frame per tick; this rides on it. Removed when the growth ends.
    static func setFaceGrowth(_ layer: CALayer, fraction: CGFloat, verticalLongAxis: Bool) {
        let f = max(0, min(1, fraction))
        let bulge = 1.0 + 0.045 * f
        var t = CATransform3DIdentity
        if verticalLongAxis { t.m22 = bulge } else { t.m11 = bulge }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = t
        CATransaction.commit()
    }

    static func removeFaceGrowth(_ layer: CALayer) {
        guard !CATransform3DEqualToTransform(layer.transform, CATransform3DIdentity) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}

/// How the shelf's *content* inherits the surface's motion (WS-1: principle 2 —
/// the content rides the material, it is not taped to it).
///
/// A spring-animated window and its rigid content read as "a rectangle with a
/// decal". The fix that survives taste: publish the spring's own velocity and
/// displacement once per frame, and let the content shear and squash against
/// it by small, bounded amounts — mass, not jelly. The mapping is pure so the
/// headless suite pins every boundary that keeps this tasteful:
/// - skew is a shear proportional to depth-axis velocity, hard-clamped to
///   `maxSkew` (≈ 2.5° — felt, never wobbly);
/// - the depth axis compresses a touch while the sheet is pouring out
///   (depth velocity outward > 0), bounded by `maxSquash`;
/// - parallax is one third of the frame's displacement, always — a
///   sub-lead-of-the-window drift that never desyncs from the glass.
/// The panel applies the result as **one GPU transform per frame** on the
/// existing content host — no relayout, no view churn — and zeroes it under
/// Reduce Motion.
enum ContentMotion {
    /// Velocity (points/s) at which the shear reaches its clamp. Between the
    /// `.track` and `.expand` peaks, so every preset gets a visible amount.
    static let referenceVelocity: CGFloat = 1400
    /// The taste ceiling on skew, in radians (~2.5°).
    static let maxSkew: CGFloat = 0.045
    /// The taste ceiling on depth squash (5% at full outbound speed).
    static let maxSquash: CGFloat = 0.05
    /// How much of the frame's displacement the content trails (parallax).
    static let parallax: CGFloat = 1.0 / 3.0

    struct Transform: Equatable {
        /// Shear factor along the strip axis, already clamped.
        var shear: CGFloat = 0
        /// Depth-axis scale adjustment (1 − squash..1+stretch).
        var depthScale: CGFloat = 1
        /// Content displacement opposite the frame's motion, in points.
        var offset: CGSize = .zero

        static let identity = Transform()
        var isIdentity: Bool { self == .identity }
    }

    /// Maps one spring sample to a content transform, for a shelf whose
    /// content runs along `strip` (the Dock's axis) and grows along `depth`.
    static func resolve(sample: SpringAnimator.MotionSample,
                        strip: Axis, depth: Axis) -> Transform {
        guard sample != .zero else { return .identity }
        let (dv, _) = Self.components(velocity: sample.velocity, strip: strip, depth: depth)
        var t = Transform()
        t.shear = min(max(dv / referenceVelocity, -1), 1) * maxSkew
        let outbound = max(0, dv) / referenceVelocity
        t.depthScale = 1 - min(outbound, 1) * maxSquash
        // Parallax needs no axis decomposition: the content simply moves at
        // two thirds of the window's speed, in whatever direction it travels.
        t.offset = CGSize(width: -sample.displacement.width * parallax,
                          height: -sample.displacement.height * parallax)
        return t
    }

    /// Projects a motion vector onto the shelf's axes. Strip runs along the
    /// Dock; depth runs into the screen. For a bottom Dock the strip is
    /// horizontal and depth vertical; for a side Dock it is the reverse.
    enum Axis { case horizontal, vertical }

    private static func components(velocity v: CGSize, strip: Axis, depth: Axis) -> (depth: CGFloat, strip: CGFloat) {
        let depthComponent: CGFloat
        let stripComponent: CGFloat
        switch (strip, depth) {
        case (.horizontal, .vertical): depthComponent = v.height; stripComponent = v.width
        case (.vertical, .horizontal): depthComponent = v.width; stripComponent = v.height
        default: depthComponent = 0; stripComponent = 0
        }
        return (depthComponent, stripComponent)
    }

    /// Builds the layer transform: translation (parallax), then shear (m21,
    /// layer space), then depth squash — applied in that order so the shear
    /// leans the material and the squash compresses it, never the reverse.
    static func makeTransform(_ t: Transform) -> CATransform3D {
        var m = CATransform3DMakeTranslation(t.offset.width, t.offset.height, 0)
        m.m21 = t.shear
        m.m22 = t.depthScale
        return m
    }
}
