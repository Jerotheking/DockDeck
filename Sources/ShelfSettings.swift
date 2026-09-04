import AppKit
import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut, stored as the Carbon key code and modifier mask
/// that `RegisterEventHotKey` actually wants.
///
/// Deliberately not an `NSEvent.ModifierFlags`: those are Cocoa's masks, and
/// converting at registration time is where an off-by-one bit silently produces
/// a shortcut that never fires.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let showHide = Shortcut(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(optionKey | shiftKey))
    static let expandCollapse = Shortcut(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(optionKey | shiftKey))

    /// Human-readable form, in the order macOS renders modifiers.
    var displayName: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "?")
    }

    /// Only the keys worth binding a global shortcut to. Anything absent here is
    /// rejected by the recorder rather than stored as an unnameable code.
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_ANSI_Grave): "`", UInt32(kVK_ANSI_Backslash): "\\\\"
        ]
        for (index, code) in [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                              kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12].enumerated() {
            names[UInt32(code)] = "F\(index + 1)"
        }
        return names
    }()

    /// Carbon modifiers from a Cocoa event, and whether the combination is
    /// usable at all. A global shortcut with no modifier would swallow a plain
    /// keystroke from every other app.
    static func from(event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        guard carbon != 0 else { return nil }
        let code = UInt32(event.keyCode)
        guard keyNames[code] != nil else { return nil }
        return Shortcut(keyCode: code, carbonModifiers: carbon)
    }
}

/// How the shelves render their surface.
///
/// - **liquidGlass**: macOS 26's real Liquid Glass (`NSGlassEffectView`) — the
///   same dynamic material the system chrome uses. The default, because the
///   shelves are meant to read as part of the Dock, and this is what the Dock
///   is made of now.
/// - **frosted**: the classic translucent sidebar material
///   (`NSVisualEffectView`), the pre-26 look. Available everywhere and cheaper
///   to composite.
/// - **opaque**: no translucency at all, for maximum contrast and minimum GPU.
enum ShelfAppearance: String, Codable, CaseIterable {
    case liquidGlass
    case frosted
    case opaque

    var displayName: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .frosted: return "Frosted Glass"
        case .opaque: return "Opaque"
        }
    }
}

/// Persisted preferences.
///
/// Placement is deliberately absent: DockDeck flanks the Dock, so the Dock —
/// not a setting — decides which edge and which end each shelf occupies. What
/// remains configurable is how the shelves behave once placed.
struct ShelfSettings: Equatable {
    /// Expand when the pointer rests on a shelf. Dragging always expands,
    /// regardless of this, because you cannot drop into a strip too thin to aim at.
    var expandOnHover = true
    /// How far an expanded shelf reaches into the screen.
    var expandedDepth: CGFloat = ShelfGeometry.defaultDepth
    /// Hide alongside an auto-hiding Dock, the way Dockside does.
    var mirrorDockAutohide = true
    /// The files/notes/clipboard/links shelf, on the leading side of the Dock.
    var showLibraryShelf = true
    /// The screenshots/downloads shelf, on the trailing side of the Dock.
    var showRecentsShelf = true
    var monitorClipboard = true
    var monitorDownloads = true
    var monitorScreenshots = true
    var storeCopiedFiles = false
    var fileLimit = 200
    var noteLimit = 100
    var clipboardLimit = 50
    var smartLimit = 40
    var launchAtLogin = false
    /// Surface material of the shelves.
    var appearance: ShelfAppearance = .liquidGlass
    /// Shows and hides the shelves entirely.
    var showHideShortcut: Shortcut = .showHide
    /// Expands or collapses them without hiding them — the two are different
    /// intents, and Dockside binds them separately for the same reason.
    var expandCollapseShortcut: Shortcut = .expandCollapse
    static let defaults = ShelfSettings()

    /// Clamped to the bounds `ShelfGeometry` enforces, so a hand-edited or
    /// corrupt file cannot produce an unreachable shelf.
    mutating func normalize() {
        expandedDepth = expandedDepth.isFinite
            ? min(max(expandedDepth, ShelfGeometry.minimumDepth), ShelfGeometry.maximumDepth)
            : ShelfGeometry.defaultDepth
        fileLimit = min(max(fileLimit, 0), 5000)
        noteLimit = min(max(noteLimit, 0), 2000)
        clipboardLimit = min(max(clipboardLimit, 0), 500)
        smartLimit = min(max(smartLimit, 1), 500)
        // A shortcut with no modifiers would intercept a bare keystroke system
        // wide; a hand-edited file must not be able to ask for that.
        if showHideShortcut.carbonModifiers == 0 { showHideShortcut = .showHide }
        if expandCollapseShortcut.carbonModifiers == 0 { expandCollapseShortcut = .expandCollapse }
        // Two identical bindings mean the second silently never fires.
        if showHideShortcut == expandCollapseShortcut { expandCollapseShortcut = .expandCollapse }
    }
}

extension ShelfSettings: Codable {
    /// Hand-written decoding with a fallback for every key.
    ///
    /// Synthesised `Codable` is a trap for a settings file: one missing or
    /// mistyped key — the normal situation whenever a new setting ships and the
    /// user already has a settings file on disk — fails the whole decode, and
    /// `SettingsStore` then treats the user's real preferences as a corrupt
    /// first run and resets everything. Decoding key-by-key means files written
    /// by any earlier version keep every preference they did carry.
    ///
    /// Encoding stays synthesised: the archive is always complete.
    private enum Keys: String, CodingKey {
        case expandOnHover, expandedDepth, mirrorDockAutohide
        case showLibraryShelf, showRecentsShelf
        case monitorClipboard, monitorDownloads, monitorScreenshots
        case storeCopiedFiles, fileLimit, noteLimit, clipboardLimit, smartLimit
        case launchAtLogin, appearance, showHideShortcut, expandCollapseShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init()
        expandOnHover = try container.decodeIfPresent(Bool.self, forKey: .expandOnHover) ?? expandOnHover
        expandedDepth = try container.decodeIfPresent(CGFloat.self, forKey: .expandedDepth) ?? expandedDepth
        mirrorDockAutohide = try container.decodeIfPresent(Bool.self, forKey: .mirrorDockAutohide) ?? mirrorDockAutohide
        showLibraryShelf = try container.decodeIfPresent(Bool.self, forKey: .showLibraryShelf) ?? showLibraryShelf
        showRecentsShelf = try container.decodeIfPresent(Bool.self, forKey: .showRecentsShelf) ?? showRecentsShelf
        monitorClipboard = try container.decodeIfPresent(Bool.self, forKey: .monitorClipboard) ?? monitorClipboard
        monitorDownloads = try container.decodeIfPresent(Bool.self, forKey: .monitorDownloads) ?? monitorDownloads
        monitorScreenshots = try container.decodeIfPresent(Bool.self, forKey: .monitorScreenshots) ?? monitorScreenshots
        storeCopiedFiles = try container.decodeIfPresent(Bool.self, forKey: .storeCopiedFiles) ?? storeCopiedFiles
        fileLimit = try container.decodeIfPresent(Int.self, forKey: .fileLimit) ?? fileLimit
        noteLimit = try container.decodeIfPresent(Int.self, forKey: .noteLimit) ?? noteLimit
        clipboardLimit = try container.decodeIfPresent(Int.self, forKey: .clipboardLimit) ?? clipboardLimit
        smartLimit = try container.decodeIfPresent(Int.self, forKey: .smartLimit) ?? smartLimit
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        appearance = try container.decodeIfPresent(ShelfAppearance.self, forKey: .appearance) ?? appearance
        showHideShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .showHideShortcut) ?? showHideShortcut
        expandCollapseShortcut = try container.decodeIfPresent(Shortcut.self, forKey: .expandCollapseShortcut) ?? expandCollapseShortcut
    }
}

final class SettingsStore {
    let url: URL
    private(set) var settings: ShelfSettings
    /// True when no readable settings file existed at launch. Drives the
    /// first-run experience; a corrupt file counts as a first run so the user
    /// gets guidance instead of silence.
    let isFirstRun: Bool

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(ShelfSettings.self, from: data) {
            settings = decoded
            isFirstRun = false
        } else {
            settings = .defaults
            isFirstRun = true
        }
        settings.normalize()
    }

    @discardableResult
    func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("DockDeck: could not save settings to %@ — %@", url.path, String(describing: error))
            return false
        }
    }

    func update(_ change: (inout ShelfSettings) -> Void) {
        change(&settings)
        settings.normalize()
        _ = save()
    }
}
