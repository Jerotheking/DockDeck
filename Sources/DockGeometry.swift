import AppKit
import ApplicationServices

/// Where the macOS Dock actually is, in AppKit coordinates.
///
/// DockDeck flanks the Dock, so orientation alone is not enough: it needs the
/// Dock's real rectangle to know which strip of screen is left over. Two
/// sources, in order of accuracy:
///
/// 1. **Accessibility** — asks the Dock process for its item list's frame. Exact,
///    tracks magnification and item count live, needs the Accessibility grant.
/// 2. **Estimation** — derives thickness and length from `com.apple.dock`
///    preferences. No permission required, accurate to a few points, and wrong
///    whenever the Dock's own layout rules change.
///
/// The app works either way; `source` records which one produced a reading so
/// the UI can offer the grant instead of silently being approximate.
struct DockGeometry: Equatable {
    enum Orientation: String, CaseIterable { case left, right, bottom }
    enum Source: String { case accessibility, estimated }

    /// The Dock's rectangle in AppKit coordinates, always normalised to where
    /// the Dock sits when *revealed* — an auto-hidden Dock reports itself parked
    /// off-screen, which is not the rectangle the shelves must avoid.
    var frame: CGRect
    var orientation: Orientation
    var autohides: Bool
    var screen: CGRect
    var source: Source
    /// The Dock's configured tile size, straight from `com.apple.dock`.
    ///
    /// This is the key to telling a real resize apart from magnification.
    /// Magnification inflates the Dock's measured frame while the pointer is
    /// over it but never touches `tilesize`; dragging the Dock's divider changes
    /// `tilesize` and nothing else can. Without this, the two are
    /// indistinguishable from the frame alone.
    var tileSize: CGFloat = 48

    /// Thickness of the Dock strip (its short dimension).
    var thickness: CGFloat { orientation == .bottom ? frame.height : frame.width }

    /// The two leftover rectangles in the Dock's own strip, before and after it.
    /// For a bottom Dock these are left and right; for a side Dock, below and
    /// above. Either can be empty when the Dock fills its strip.
    var gaps: (leading: CGRect, trailing: CGRect) {
        let strip = dockStrip
        switch orientation {
        case .bottom:
            let leading = CGRect(x: strip.minX, y: strip.minY, width: max(0, frame.minX - strip.minX), height: strip.height)
            let trailing = CGRect(x: frame.maxX, y: strip.minY, width: max(0, strip.maxX - frame.maxX), height: strip.height)
            return (leading, trailing)
        case .left, .right:
            let leading = CGRect(x: strip.minX, y: strip.minY, width: strip.width, height: max(0, frame.minY - strip.minY))
            let trailing = CGRect(x: strip.minX, y: frame.maxY, width: strip.width, height: max(0, strip.maxY - frame.maxY))
            return (leading, trailing)
        }
    }

    /// The full band of screen the Dock lives in, spanning edge to edge.
    var dockStrip: CGRect {
        switch orientation {
        case .bottom: return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: thickness)
        case .left: return CGRect(x: screen.minX, y: screen.minY, width: thickness, height: screen.height)
        case .right: return CGRect(x: screen.maxX - thickness, y: screen.minY, width: thickness, height: screen.height)
        }
    }

    // MARK: - Reading the Dock

    static func current(preferring screen: NSScreen? = nil) -> DockGeometry {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        let orientation = Orientation(rawValue: defaults?.string(forKey: "orientation") ?? "bottom") ?? .bottom
        let autohides = defaults?.bool(forKey: "autohide") ?? false
        let target = screen ?? dockScreen(for: orientation) ?? NSScreen.main ?? NSScreen.screens.first
        let bounds = target?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = target?.visibleFrame ?? bounds

        if let measured = measureViaAccessibility(orientation: orientation, screen: bounds, visible: visible) {
            return measured
        }
        return estimate(orientation: orientation, autohides: autohides, screen: bounds, visible: visible, defaults: defaults)
    }

    /// The Dock lives on one screen only; pick the one whose edge it hugs.
    private static func dockScreen(for orientation: Orientation) -> NSScreen? {
        let screens = NSScreen.screens
        switch orientation {
        case .left: return screens.min { $0.frame.minX < $1.frame.minX }
        case .right: return screens.max { $0.frame.maxX < $1.frame.maxX }
        case .bottom: return screens.min { $0.frame.minY < $1.frame.minY }
        }
    }

    static var accessibilityAvailable: Bool { AXIsProcessTrusted() }

    /// macOS clamps the Dock's tile size to 16...128; anything outside that is a
    /// stale or absent preference, not a real setting.
    static func configuredTileSize(_ defaults: UserDefaults?) -> CGFloat {
        let raw = CGFloat(defaults?.double(forKey: "tilesize") ?? 0)
        return raw >= 16 && raw <= 128 ? raw : 48
    }

    private static func measureViaAccessibility(orientation: Orientation, screen: CGRect, visible: CGRect) -> DockGeometry? {
        guard AXIsProcessTrusted() else { return nil }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let application = AXUIElementCreateApplication(dock.processIdentifier)

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }

        // The item list is the only AXList the Dock exposes at the top level.
        guard let list = children.first(where: { element in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            return (role as? String) == "AXList"
        }) else { return nil }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &sizeValue) == .success else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // AXValue is a CoreFoundation type, so a conditional downcast always
        // succeeds and tells us nothing; the compiler itself points to comparing
        // CFTypeIDs instead. That check is the real guard, which is what makes
        // the forced casts below safe.
        guard let positionAX = positionValue, CFGetTypeID(positionAX) == AXValueGetTypeID(),
              let sizeAX = sizeValue, CFGetTypeID(sizeAX) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(positionAX as AnyObject, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeAX as AnyObject, to: AXValue.self), .cgSize, &size) else { return nil }
        guard size.width > 1, size.height > 1 else { return nil }

        let frame = normalise(axOrigin: origin, size: size, orientation: orientation, screen: screen)
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        let autohides = defaults?.bool(forKey: "autohide") ?? false
        return DockGeometry(frame: frame, orientation: orientation, autohides: autohides,
                            screen: visible, source: .accessibility, tileSize: configuredTileSize(defaults))
    }

    /// Converts an Accessibility rect (top-left origin, y down, global display
    /// space) into AppKit coordinates, then pins it to the revealed position:
    /// an auto-hidden Dock reports itself parked past the screen edge.
    private static func normalise(axOrigin: CGPoint, size: CGSize, orientation: Orientation, screen: CGRect) -> CGRect {
        let globalHeight = NSScreen.screens.first?.frame.maxY ?? screen.maxY
        var frame = CGRect(x: axOrigin.x, y: globalHeight - axOrigin.y - size.height, width: size.width, height: size.height)
        switch orientation {
        case .right: frame.origin.x = screen.maxX - frame.width
        case .left: frame.origin.x = screen.minX
        case .bottom: frame.origin.y = screen.minY
        }
        return frame
    }

    /// Fallback used without the Accessibility grant.
    ///
    /// Thickness is `tilesize` plus the Dock's fixed chrome; on the reference
    /// machine (tilesize 39) that predicts 53 points, which is what the
    /// Accessibility reading reports. Length is the tile pitch times the item
    /// count. Both are approximations and are marked as such via `source`.
    private static func estimate(orientation: Orientation, autohides: Bool, screen: CGRect, visible: CGRect, defaults: UserDefaults?) -> DockGeometry {
        let tileSize = CGFloat(defaults?.integer(forKey: "tilesize") ?? 0)
        let tile = tileSize > 8 ? tileSize : 48
        let chrome: CGFloat = 14
        var thickness = tile + chrome

        // When the Dock is pinned, the system already subtracts it from
        // visibleFrame — a measurement, so prefer it over the estimate.
        if !autohides {
            let measured: CGFloat
            switch orientation {
            case .bottom: measured = visible.minY - screen.minY
            case .left: measured = visible.minX - screen.minX
            case .right: measured = screen.maxX - visible.maxX
            }
            if measured > 8 { thickness = measured }
        }

        let persistentApps = (defaults?.array(forKey: "persistent-apps")?.count ?? 0)
        let persistentOthers = (defaults?.array(forKey: "persistent-others")?.count ?? 0)
        let recents = (defaults?.bool(forKey: "show-recents") ?? false) ? (defaults?.array(forKey: "recent-apps")?.count ?? 0) : 0
        // Finder and Trash are always present and are not in the preference lists.
        let tiles = max(1, persistentApps + persistentOthers + recents + 2)
        let pitch = tile + 2
        let length = min(CGFloat(tiles) * pitch + 12, orientation == .bottom ? screen.width : screen.height)

        let frame: CGRect
        switch orientation {
        case .bottom:
            frame = CGRect(x: screen.midX - length / 2, y: screen.minY, width: length, height: thickness)
        case .left:
            frame = CGRect(x: screen.minX, y: screen.midY - length / 2, width: thickness, height: length)
        case .right:
            frame = CGRect(x: screen.maxX - thickness, y: screen.midY - length / 2, width: thickness, height: length)
        }
        return DockGeometry(frame: frame, orientation: orientation, autohides: autohides,
                            screen: visible, source: .estimated, tileSize: tile)
    }
}
