import AppKit
import Foundation

/// Headless regression suite for everything in DockDeck that can be exercised
/// without a window server: the store, settings normalisation, placement
/// geometry, rename validation, and archive preconditions.
///
/// Runtime behaviour that genuinely needs a live app (first-launch visibility,
/// status item, duplicate launch, shutdown) is covered by verify-app.sh.
enum ModelSelfTest {
    private struct Failure: Error { let message: String }
    private static var checks = 0
    private static var failures: [String] = []

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !condition() { failures.append(description) }
    }

    static func run() throws {
        checks = 0
        failures = []

        try storeInvariants()
        try persistenceAndRecovery()
        try settingsNormalisation()
        placementGeometry()
        springParameters()
        dockReadingStability()
        decisionCore()
        transientGeometry()
        renameValidation()
        try archivePreconditions()
        try safeRemoval()

        guard failures.isEmpty else {
            failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
            throw Failure(message: "\(failures.count) of \(checks) checks failed")
        }
        print("DockDeck model self-test: PASS (\(checks) checks — store, persistence, settings, migration, dock geometry, promotion core, springs, rename, archive, safe removal)")
    }

    // MARK: - Store

    private static func storeInvariants() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ShelfStore(fileURL: url, loadImmediately: false)
        store.limitPerKind = [.file: 2, .note: 2, .clipboard: 2, .bookmark: 2]

        let old = ShelfItem(kind: .file, title: "old", path: "/tmp/dockdeck/../dockdeck/old")
        let fresh = ShelfItem(kind: .file, title: "fresh", path: "/tmp/dockdeck/fresh")
        expect(store.add(old), "adds a file item")
        expect(store.add(fresh), "adds a second file item")
        expect(!store.add(ShelfItem(kind: .file, title: "duplicate", path: "/tmp/dockdeck/./fresh")), "rejects a path duplicate after normalisation")
        expect(!store.add(ShelfItem(kind: .file, title: "   ", path: "/tmp/invalid")), "rejects a blank title")

        expect(store.displayOrder(kind: .file, query: "FRESH").count == 1, "search is case-insensitive")
        store.togglePin(id: old.id)
        expect(store.displayOrder(kind: .file, query: "").first?.id == old.id, "pinned items sort first")

        let note = ShelfItem(kind: .note, title: "wrong", text: "Hello\nsecond line")
        expect(store.add(note), "adds a note")
        store.setText(id: note.id, text: "Updated title")
        expect(store.item(id: note.id)?.title == "Updated title", "note title follows its first line")
        expect(ShelfStore.title(forText: String(repeating: "x", count: 100)).count == 60, "long titles are truncated to 60")
        expect(ShelfStore.title(forText: "   \n  ") == "Empty note", "blank text falls back to a placeholder title")

        for index in 0..<4 { _ = store.add(ShelfItem(kind: .clipboard, title: "clip \(index)", text: "clip \(index)")) }
        expect(store.displayOrder(kind: .clipboard, query: "").count == 2, "per-kind limits are enforced")

        let bookmark = ShelfItem(kind: .bookmark, title: "Example", urlString: "https://example.com/docs?a=1")
        expect(store.add(bookmark), "adds a bookmark")
        expect(!store.add(ShelfItem(kind: .bookmark, title: "Other", urlString: "https://example.com/docs?a=1")), "rejects a duplicate URL")
        store.touch(id: bookmark.id, action: .opened)
        expect(store.history.first?.action == .opened, "history records the latest action first")
        expect(store.searchAll("example").contains { $0.id == bookmark.id }, "cross-kind search finds the bookmark")

        let revisionBefore = store.revision
        store.togglePin(id: bookmark.id)
        expect(store.revision != revisionBefore, "mutations bump the revision the view layer diffs on")

        store.historyLimit = 1
        store.record(itemID: bookmark.id, action: .copied)
        store.record(itemID: bookmark.id, action: .opened)
        expect(store.history.count == 1, "history is trimmed to its limit")

        store.limitPerKind[.clipboard] = 0
        _ = store.add(ShelfItem(kind: .clipboard, title: "discard", text: "discard"))
        expect(store.displayOrder(kind: .clipboard, query: "").isEmpty, "a zero limit discards unpinned items")
        // `bookmark` was pinned two checks ago, so this also asserts the more
        // important half of the rule: a limit never evicts a pinned item.
        let disposable = ShelfItem(kind: .bookmark, title: "disposable", urlString: "https://disposable.example")
        store.limitPerKind[.bookmark] = 10
        _ = store.add(disposable)
        store.limitPerKind[.bookmark] = -1
        store.housekeeping()
        expect(!store.items.contains { $0.id == disposable.id }, "a negative limit is treated as zero for unpinned items")
        expect(store.items.contains { $0.id == bookmark.id }, "a limit never evicts a pinned item")

        store.clear(kind: .file, keepPinned: true)
        expect(store.items.contains { $0.id == old.id }, "clear keeps pinned items")
        expect(!store.items.contains { $0.id == fresh.id }, "clear removes unpinned items")

        expect(MarkdownExport.markdown(for: old).contains("[old](file://"), "file items export as Markdown links")
        expect(MarkdownExport.markdown(for: bookmark).contains("https://example.com"), "bookmarks export with their URL")

        // Items whose file has vanished must survive: the shelf is a reference
        // list, and silently dropping rows would look like data loss.
        let missing = ShelfItem(kind: .file, title: "gone", path: "/tmp/dockdeck-does-not-exist-\(UUID().uuidString)")
        store.limitPerKind[.file] = 10
        expect(store.add(missing), "accepts a reference to a file that is not there")
        expect(store.item(id: missing.id) != nil, "a missing file keeps its shelf entry")

        let brokenBookmark = ShelfItem(kind: .bookmark, title: "broken", urlString: "not a url at all")
        store.limitPerKind[.bookmark] = 10
        expect(store.add(brokenBookmark), "stores a malformed bookmark rather than crashing")
        expect(store.item(id: brokenBookmark.id)?.urlString == "not a url at all", "a malformed bookmark round-trips unchanged")
    }

    // MARK: - Persistence

    private static func persistenceAndRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-persist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ShelfStore(fileURL: url, loadImmediately: false)
        _ = store.add(ShelfItem(kind: .note, title: "kept", text: "kept"), action: .opened)
        expect(store.save(), "saves to a new location, creating the directory")

        let reloaded = ShelfStore(fileURL: url)
        expect(reloaded.items.count == store.items.count, "items survive a save/load round trip")
        expect(reloaded.history.count == store.history.count, "history survives a save/load round trip")

        let corruptURL = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        try Data("not-json".utf8).write(to: corruptURL)
        let corrupt = ShelfStore(fileURL: corruptURL)
        expect(corrupt.items.isEmpty, "a corrupt store loads empty instead of crashing")
        expect(!corrupt.load(), "loading a corrupt store reports failure")

        let legacyURL = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([ShelfItem(kind: .note, title: "legacy", text: "legacy")]).write(to: legacyURL)
        let legacy = ShelfStore(fileURL: legacyURL)
        expect(legacy.items.count == 1, "a legacy bare-array store still loads")

        let missing = ShelfStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-absent-\(UUID().uuidString).json"))
        expect(missing.items.isEmpty, "an absent store starts empty")

        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        try Data("{}".utf8).write(to: projectRoot.appendingPathComponent("package.json"))
        expect(ProjectContextStore.discover(from: projectRoot)?.standardizedFileURL.path == projectRoot.standardizedFileURL.path,
               "project discovery finds a package.json root")
    }

    // MARK: - Settings

    private static func settingsNormalisation() throws {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: absent) }
        let fresh = SettingsStore(url: absent)
        expect(fresh.isFirstRun, "a missing settings file is a first run")
        expect(fresh.settings.showLibraryShelf && fresh.settings.showRecentsShelf, "both shelves are on by default")
        expect(fresh.settings.expandOnHover, "hover-to-expand is on by default")
        expect(fresh.settings.mirrorDockAutohide, "mirroring the Dock's auto-hide is on by default")

        fresh.update { $0.expandedDepth = -20; $0.fileLimit = -4 }
        expect(fresh.settings.expandedDepth == ShelfGeometry.minimumDepth, "expanded depth clamps up to the minimum")
        expect(fresh.settings.fileLimit == 0, "a negative limit clamps to zero")

        fresh.update { $0.expandedDepth = 99999 }
        expect(fresh.settings.expandedDepth == ShelfGeometry.maximumDepth, "expanded depth clamps down to the maximum")

        fresh.update { $0.expandedDepth = .nan }
        expect(fresh.settings.expandedDepth == ShelfGeometry.defaultDepth, "a NaN depth falls back to the default")

        let reopened = SettingsStore(url: absent)
        expect(!reopened.isFirstRun, "an existing settings file is not a first run")
        expect(reopened.settings.expandedDepth == ShelfGeometry.defaultDepth, "settings persist across launches")

        let corruptURL = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-settings-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        try Data("{ this is not json".utf8).write(to: corruptURL)
        let corrupt = SettingsStore(url: corruptURL)
        expect(corrupt.settings == ShelfSettings.defaults, "corrupt settings fall back to defaults")
        expect(corrupt.isFirstRun, "corrupt settings are treated as a first run so the user gets guidance")

        let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-settings-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        try Data().write(to: emptyURL)
        expect(SettingsStore(url: emptyURL).settings == ShelfSettings.defaults, "an empty settings file falls back to defaults")

        // Forward migration: a file written by an older version carries none of
        // the newer keys. Every one of those preferences must survive the load.
        let oldURL = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-settings-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: oldURL) }
        let oldFile = """
        {"expandOnHover":false,"expandedDepth":321,"monitorClipboard":false,"fileLimit":7}
        """
        try Data(oldFile.utf8).write(to: oldURL)
        let migrated = SettingsStore(url: oldURL)
        expect(!migrated.isFirstRun, "a settings file from an older version is not a first run")
        expect(migrated.settings.showHideShortcut == Shortcut.showHide, "a missing shortcut key falls back to its default binding")
        expect(migrated.settings.appearance == ShelfAppearance.liquidGlass, "a missing appearance key falls back to the default surface")
        expect(migrated.settings.expandOnHover == false, "an older file keeps its hover preference")
        expect(migrated.settings.expandedDepth == 321, "an older file keeps its expanded depth")
        expect(migrated.settings.monitorClipboard == false, "an older file keeps its clipboard preference")
        expect(migrated.settings.fileLimit == 7, "an older file keeps its file limit")

        // Re-saving writes a complete archive, so the next version can migrate
        // from it the same way.
        _ = migrated.save()
        let roundTrip = SettingsStore(url: oldURL)
        expect(roundTrip.settings == migrated.settings, "re-saving an older archive produces a complete current archive")
    }

    // MARK: - Geometry

    /// The reference Dock: the machine this was developed against — 3440x1410
    /// usable, Dock on the right edge, auto-hiding, 53 pt thick, 1131 pt long.
    /// Measured via Accessibility, not invented.
    private static func referenceDock() -> DockGeometry {
        DockGeometry(frame: CGRect(x: 3387, y: 140, width: 53, height: 1131),
                     orientation: .right,
                     autohides: true,
                     screen: CGRect(x: 0, y: 0, width: 3440, height: 1410),
                     source: .accessibility)
    }

    private static func placementGeometry() {
        let dock = referenceDock()
        let screens = [dock.screen]

        // Gaps must be the leftover strip either side of the Dock, and nothing else.
        let gaps = dock.gaps
        expect(gaps.leading == CGRect(x: 3387, y: 0, width: 53, height: 140), "leading gap is the strip below the Dock")
        expect(gaps.trailing == CGRect(x: 3387, y: 1271, width: 53, height: 139), "trailing gap is the strip above the Dock")
        expect(dock.thickness == 53, "thickness is the Dock's short dimension")
        expect(dock.dockStrip == CGRect(x: 3387, y: 0, width: 53, height: 1410), "the strip spans the full screen edge")

        for slot in ShelfGeometry.Slot.allCases {
            let layout = ShelfGeometry.layout(slot: slot, dock: dock)
            expect(layout.isViable, "\(slot.rawValue) shelf is viable on the reference Dock")
            expect(layout.mode == .inGap, "\(slot.rawValue) shelf uses the Dock's own gap when there is one")
            expect(ShelfGeometry.isUsable(layout.collapsed, onAnyOf: screens), "\(slot.rawValue) collapsed frame is usable")
            expect(ShelfGeometry.isUsable(layout.expanded, onAnyOf: screens), "\(slot.rawValue) expanded frame is usable")
            expect(dock.screen.contains(layout.collapsed), "\(slot.rawValue) collapsed frame stays on screen")
            expect(dock.screen.contains(layout.expanded), "\(slot.rawValue) expanded frame stays on screen")

            // The whole premise: a shelf must sit in the Dock's own strip, not
            // somewhere else on screen.
            expect(layout.collapsed.maxX == dock.frame.maxX, "\(slot.rawValue) collapsed shelf shares the Dock's outer edge")
            expect(layout.collapsed.width == dock.thickness, "\(slot.rawValue) collapsed shelf is as thick as the Dock")

            // And it must touch the Dock, not float away from it.
            let touching = abs(layout.collapsed.maxY - dock.frame.minY) < 1 || abs(layout.collapsed.minY - dock.frame.maxY) < 1
            expect(touching, "\(slot.rawValue) collapsed shelf is adjacent to the Dock")

            // Expanding must not overlap the Dock's own length.
            expect(layout.expanded.width > layout.collapsed.width, "\(slot.rawValue) expands into the screen")
            expect(layout.expanded.maxX == dock.frame.maxX, "\(slot.rawValue) stays anchored to the screen edge while expanding")
        }

        // A 140 pt gap is shorter than one useful row list, so expansion also
        // lengthens along the strip — away from the outer screen edge.
        let leading = ShelfGeometry.layout(slot: .leading, dock: dock)
        expect(leading.expanded.height >= ShelfGeometry.minimumUsefulLength, "a short gap is lengthened when expanded")
        expect(leading.expanded.minY == dock.screen.minY, "the leading shelf stays anchored to the bottom edge")
        let trailing = ShelfGeometry.layout(slot: .trailing, dock: dock)
        expect(trailing.expanded.maxY == dock.screen.maxY, "the trailing shelf stays anchored to the top edge")

        // Depth is honoured and clamped.
        let deep = ShelfGeometry.layout(slot: .leading, dock: dock, depth: 480)
        expect(deep.expanded.width == 480, "a requested depth is used")
        let absurd = ShelfGeometry.layout(slot: .leading, dock: dock, depth: 99999)
        expect(absurd.expanded.width == ShelfGeometry.maximumDepth, "an absurd depth is clamped")
        let nanDepth = ShelfGeometry.layout(slot: .leading, dock: dock, depth: .nan)
        expect(nanDepth.expanded.width == ShelfGeometry.defaultDepth, "a NaN depth falls back to the default")

        // A bottom Dock: gaps run left and right instead.
        let bottom = DockGeometry(frame: CGRect(x: 1200, y: 0, width: 1040, height: 70),
                                  orientation: .bottom, autohides: false,
                                  screen: CGRect(x: 0, y: 0, width: 3440, height: 1410),
                                  source: .accessibility)
        let bottomGaps = bottom.gaps
        expect(bottomGaps.leading == CGRect(x: 0, y: 0, width: 1200, height: 70), "a bottom Dock leaves a gap on its left")
        expect(bottomGaps.trailing == CGRect(x: 2240, y: 0, width: 1200, height: 70), "a bottom Dock leaves a gap on its right")
        let bottomLeading = ShelfGeometry.layout(slot: .leading, dock: bottom)
        expect(bottomLeading.isViable, "a bottom Dock yields a viable leading shelf")
        expect(bottomLeading.collapsed.height == 70, "a bottom shelf is as thick as the Dock")
        expect(abs(bottomLeading.collapsed.maxX - bottom.frame.minX) < 1, "a bottom shelf butts up against the Dock")
        expect(bottomLeading.expanded.minY == bottom.screen.minY, "a bottom shelf grows upward from the bottom edge")
        expect(bottomLeading.expanded.height > bottomLeading.collapsed.height, "a bottom shelf expands into the screen")

        // A left Dock mirrors the right one.
        let left = DockGeometry(frame: CGRect(x: 0, y: 75, width: 60, height: 700),
                                orientation: .left, autohides: false,
                                screen: CGRect(x: 0, y: 0, width: 1440, height: 850),
                                source: .estimated)
        let leftLayout = ShelfGeometry.layout(slot: .trailing, dock: left)
        expect(leftLayout.isViable, "a left Dock yields a viable shelf")
        expect(leftLayout.collapsed.minX == 0, "a left shelf hugs the left screen edge")
        expect(leftLayout.expanded.minX == 0, "a left shelf expands rightward from the edge")

        // A Dock reported partly off its screen — seen when a display is
        // disconnected between the measurement and its use. Refusing is correct;
        // deriving a frame from an impossible rectangle is not.
        let inconsistent = DockGeometry(frame: CGRect(x: 0, y: 300, width: 60, height: 700),
                                        orientation: .left, autohides: false,
                                        screen: CGRect(x: 0, y: 0, width: 1440, height: 850),
                                        source: .estimated)
        expect(ShelfGeometry.layout(slot: .trailing, dock: inconsistent).mode == .sidecar,
               "a Dock hanging off its screen falls back to a sidecar on the overflowing side")
        expect(ShelfGeometry.layout(slot: .leading, dock: inconsistent).isViable,
               "the side that still has room is unaffected")

        // A Dock that fills its strip leaves no gap. The shelf must NOT vanish —
        // it falls back to the lane immediately inboard of the Dock. Vanishing
        // was the original bug and is never an acceptable answer.
        let full = DockGeometry(frame: CGRect(x: 3387, y: 0, width: 53, height: 1410),
                                orientation: .right, autohides: false,
                                screen: CGRect(x: 0, y: 0, width: 3440, height: 1410),
                                source: .accessibility)
        for slot in ShelfGeometry.Slot.allCases {
            let layout = ShelfGeometry.layout(slot: slot, dock: full)
            expect(layout.isViable, "\(slot.rawValue): a Dock filling its strip still yields a shelf")
            expect(layout.mode == .sidecar, "\(slot.rawValue): that shelf is placed as a sidecar")
            expect(ShelfGeometry.isUsable(layout.collapsed, onAnyOf: [full.screen]),
                   "\(slot.rawValue): the sidecar frame is usable")
            expect(full.screen.contains(layout.collapsed), "\(slot.rawValue): the sidecar stays on screen")
            // Inboard of the Dock and touching it.
            expect(abs(layout.collapsed.maxX - full.dockStrip.minX) < 1,
                   "\(slot.rawValue): the sidecar is pressed against the Dock's inboard edge")
            expect(layout.collapsed.width == full.thickness,
                   "\(slot.rawValue): the sidecar keeps the Dock's thickness")
        }
        // The two sidecars go to opposite ends and must not overlap each other.
        let sideLeading = ShelfGeometry.layout(slot: .leading, dock: full).collapsed
        let sideTrailing = ShelfGeometry.layout(slot: .trailing, dock: full).collapsed
        expect(sideLeading.minY < sideTrailing.minY, "the leading sidecar sits below the trailing one")
        expect(sideLeading.intersection(sideTrailing).isNull || sideLeading.intersection(sideTrailing).height < 1,
               "the two sidecars do not overlap")

        // Same for a bottom Dock that spans the screen.
        let fullBottom = DockGeometry(frame: CGRect(x: 0, y: 0, width: 3440, height: 90),
                                      orientation: .bottom, autohides: false,
                                      screen: CGRect(x: 0, y: 0, width: 3440, height: 1410),
                                      source: .accessibility)
        let bottomSide = ShelfGeometry.layout(slot: .leading, dock: fullBottom)
        expect(bottomSide.isViable, "a full-width bottom Dock still yields a shelf")
        expect(bottomSide.mode == .sidecar, "it is placed as a sidecar")
        expect(abs(bottomSide.collapsed.minY - fullBottom.dockStrip.maxY) < 1,
               "the bottom sidecar sits directly above the Dock")

        // A gap too small to aim at falls back rather than being refused.
        let almostFull = DockGeometry(frame: CGRect(x: 3387, y: 20, width: 53, height: 1370),
                                      orientation: .right, autohides: false,
                                      screen: CGRect(x: 0, y: 0, width: 3440, height: 1410),
                                      source: .accessibility)
        let tiny = ShelfGeometry.layout(slot: .leading, dock: almostFull)
        expect(tiny.isViable, "a 20 pt gap falls back to a sidecar instead of vanishing")
        expect(tiny.mode == .sidecar, "the 20 pt gap is refused as a gap")

        // A screen too small for both Dock and shelf is the only case that fails.
        let cramped = DockGeometry(frame: CGRect(x: 0, y: 0, width: 60, height: 100),
                                   orientation: .right, autohides: false,
                                   screen: CGRect(x: 0, y: 0, width: 70, height: 100),
                                   source: .estimated)
        expect(!ShelfGeometry.layout(slot: .leading, dock: cramped).isViable,
               "a screen with no room for both is the one case that yields nothing")

        // Negative-origin display, as reported by a screen placed above-left.
        let secondary = DockGeometry(frame: CGRect(x: 886, y: -1169, width: 1000, height: 70),
                                     orientation: .bottom, autohides: false,
                                     screen: CGRect(x: 886, y: -1169, width: 1800, height: 1130),
                                     source: .accessibility)
        let secondaryLayout = ShelfGeometry.layout(slot: .trailing, dock: secondary)
        expect(secondaryLayout.isViable, "a negative-origin display still places a shelf")
        expect(ShelfGeometry.isUsable(secondaryLayout.collapsed, onAnyOf: [secondary.screen]), "the shelf is usable on a negative-origin display")

        // Hiding always leaves a reachable sliver on screen.
        for slot in ShelfGeometry.Slot.allCases {
            let layout = ShelfGeometry.layout(slot: slot, dock: dock)
            let hidden = ShelfGeometry.hiddenFrame(from: layout.collapsed, dock: dock)
            let overlap = dock.screen.intersection(hidden)
            expect(!overlap.isNull && overlap.width > 0 && overlap.height > 0, "\(slot.rawValue) keeps a sliver on screen when hidden")
        }

        // isUsable must actually reject things.
        expect(!ShelfGeometry.isUsable(CGRect(x: 99999, y: 99999, width: 320, height: 800), onAnyOf: screens), "a fully off-screen frame is rejected")
        expect(!ShelfGeometry.isUsable(.zero, onAnyOf: screens), "a zero frame is rejected")
        expect(!ShelfGeometry.isUsable(CGRect(x: 0, y: 0, width: 320, height: 2), onAnyOf: screens), "a collapsed frame is rejected")

        // Clamping keeps a frame inside its bounds.
        let clamped = ShelfGeometry.clamp(CGRect(x: -500, y: -500, width: 320, height: 800), to: dock.screen)
        expect(dock.screen.contains(clamped), "clamp pulls a frame back inside the screen")
    }

    /// Dock magnification must not make the shelves disappear.
    private static func springParameters() {
        let reveal = SpringParameters.reveal
        expect(reveal.response > 0, "reveal spring has a positive response")
        expect(reveal.dampingFraction > 0 && reveal.dampingFraction < 1.2,
               "reveal spring damping is in a sensible range")
        expect(SpringParameters.collapse.response <= reveal.response,
               "collapse is the snappier motion")
        contentMotionMapping()
    }

    /// WS-1: the content-motion mapping's boundaries — the taste limits that
    /// keep inertia felt but never jelly. Pure: no window, no runloop.
    private static func contentMotionMapping() {
        // Identity when there is no motion.
        expect(ContentMotion.resolve(sample: .zero, strip: .vertical, depth: .horizontal).isIdentity,
               "a motionless spring yields an identity content transform")

        // Shear: signed, proportional, and hard-clamped at maxSkew. Depth is
        // horizontal here, so depth velocity rides the width component.
        let slow = ContentMotion.resolve(sample: .init(displacement: .zero, velocity: CGSize(width: 350, height: 0)),
                                         strip: .vertical, depth: .horizontal)
        expect(slow.shear > 0 && slow.shear < ContentMotion.maxSkew,
               "a quarter-speed depth velocity produces a proportional shear below the clamp")
        let fast = ContentMotion.resolve(sample: .init(displacement: .zero, velocity: CGSize(width: 4000, height: 0)),
                                         strip: .vertical, depth: .horizontal)
        expect(fast.shear == ContentMotion.maxSkew,
               "an extreme velocity clamps the shear at the taste ceiling")
        let reversed = ContentMotion.resolve(sample: .init(displacement: .zero, velocity: CGSize(width: -700, height: 0)),
                                             strip: .vertical, depth: .horizontal)
        expect(reversed.shear < 0,
               "the shear is signed: travel the other way, lean the other way")

        // Squash: only while moving outward on the depth axis, bounded.
        let outward = ContentMotion.resolve(sample: .init(displacement: .zero, velocity: CGSize(width: 3000, height: 0)),
                                            strip: .vertical, depth: .horizontal)
        expect(outward.depthScale == 1 - ContentMotion.maxSquash,
               "full outbound depth velocity squashes by exactly the ceiling")
        let inward = ContentMotion.resolve(sample: .init(displacement: .zero, velocity: CGSize(width: -3000, height: 0)),
                                           strip: .vertical, depth: .horizontal)
        expect(inward.depthScale == 1,
               "inbound depth velocity never stretches the depth axis")

        // Parallax: content trails the window by exactly one third. Tolerance,
        // not equality: the ratio is 1/3, which binary floats only approximate.
        let drifting = ContentMotion.resolve(sample: .init(displacement: CGSize(width: 0, height: 30), velocity: .zero),
                                             strip: .vertical, depth: .horizontal)
        expect(abs(drifting.offset.height + 10) < 0.0001,
               "content trails the frame's displacement by exactly the parallax ratio")
        expect(drifting.shear == 0 && drifting.depthScale == 1,
               "pure displacement produces no shear and no squash")

        // The transform is built in the documented order: translation, then
        // shear (m21), then depth scale (m22).
        let m = ContentMotion.makeTransform(.init(shear: 0.02, depthScale: 0.98, offset: CGSize(width: -3, height: 2)))
        expect(m.m21 == 0.02 && m.m22 == 0.98 && m.m41 == -3 && m.m42 == 2,
               "the content transform composes translation, shear, and squash in that order")

        // Boundaries are sane constants.
        expect(ContentMotion.maxSkew < 0.05, "the skew ceiling stays under 3 degrees")
        expect(ContentMotion.maxSquash <= 0.06, "the squash ceiling stays subtle")
        expect(ContentMotion.parallax < 1, "content trails by less than the window moves")
    }

    private static func dockReadingStability() {
        let resting = referenceDock()
        // The same Dock while magnified: taller, so both gaps fall below the
        // viable minimum. Observed on the reference machine as 1384 pt.
        let magnified = DockGeometry(frame: CGRect(x: 3387, y: 13, width: 53, height: 1384),
                                     orientation: .right, autohides: true,
                                     screen: resting.screen, source: .accessibility)

        // A magnified Dock leaves no gap: full re-placement would jump to
        // sidecar and back — the flicker the transient path exists to avoid.
        expect(ShelfGeometry.layout(slot: .leading, dock: magnified).mode == .sidecar,
               "a magnified Dock would force sidecar placement on a resting re-layout")
        expect(ShelfGeometry.layout(slot: .leading, dock: resting).mode == .inGap,
               "the resting Dock places in its own gap")

        // The transient path compresses into the room that actually exists,
        // hugging the Dock's edge, and yields nothing (zero) when there is none.
        let partial = DockGeometry(frame: CGRect(x: 3387, y: 263, width: 53, height: 884),
                                   orientation: .right, autohides: true,
                                   screen: resting.screen, source: .accessibility)
        let compressedLeading = ShelfGeometry.compressIntoGap(slot: .leading, dock: partial)
        let compressedTrailing = ShelfGeometry.compressIntoGap(slot: .trailing, dock: partial)
        expect(compressedLeading.height == partial.gaps.leading.height && compressedLeading.maxY == partial.frame.minY,
               "a compressed leading shelf hugs the Dock's edge in the room left")
        expect(compressedTrailing.height == partial.gaps.trailing.height && compressedTrailing.minY == partial.frame.maxY,
               "a compressed trailing shelf hugs the Dock's other edge")
        expect(ShelfGeometry.compressIntoGap(slot: .leading, dock: magnified) == .zero,
               "a Dock that fills its strip compresses the shelf to nothing")
        expect(ShelfGeometry.compressIntoGap(slot: .leading, dock: resting).height == ShelfGeometry.layout(slot: .leading, dock: resting).collapsed.height,
               "a resting Dock's compressed frame is its normal gap frame")

        // Classification: size-only is transient, anything else is structural.
        expect(!DockWatcher.isStructural(magnified, comparedTo: resting),
               "a magnification frame differs only in size, so it is transient")
        let midUnwind = DockGeometry(frame: CGRect(x: 3387, y: 200, width: 53, height: 1000),
                                     orientation: .right, autohides: true,
                                     screen: resting.screen, source: .accessibility)
        expect(!DockWatcher.isStructural(midUnwind, comparedTo: resting),
               "an unwind frame is also size-only")
        let toggledAutohide = DockGeometry(frame: resting.frame, orientation: .right, autohides: false,
                                           screen: resting.screen, source: .accessibility)
        expect(DockWatcher.isStructural(toggledAutohide, comparedTo: resting),
               "an auto-hide change is structural")
        let movedEdge = DockGeometry(frame: CGRect(x: 0, y: 140, width: 53, height: 1131),
                                     orientation: .left, autohides: true,
                                     screen: resting.screen, source: .accessibility)
        expect(DockWatcher.isStructural(movedEdge, comparedTo: resting),
               "an edge change is structural")
        expect(DockWatcher.isStructural(movedEdge, comparedTo: movedEdge) == false,
               "an identical reading is never structural")
        let resizedTile = DockGeometry(frame: CGRect(x: 3387, y: 140, width: 70, height: 1131),
                                       orientation: .right, autohides: true,
                                       screen: resting.screen, source: .accessibility, tileSize: 64)
        expect(DockWatcher.isStructural(resizedTile, comparedTo: resting),
               "a tile-size change is structural (the divider drag's signature)")

        // Resizing via the divider changes tilesize, so it is structural even
        // with the pointer on the Dock.
        let resized = DockGeometry(frame: CGRect(x: 3387, y: 410, width: 40, height: 1000),
                                   orientation: .right, autohides: true,
                                   screen: resting.screen, source: .accessibility, tileSize: 26)
        expect(DockWatcher.isStructural(resized, comparedTo: resting),
               "a divider-drag resize is structural and re-places immediately")
        expect(ShelfGeometry.layout(slot: .leading, dock: resized).collapsed.width == resized.thickness,
               "the shelf follows the Dock's new thickness")
        expect(ShelfGeometry.layout(slot: .leading, dock: resized).collapsed.height
               > ShelfGeometry.layout(slot: .leading, dock: resting).collapsed.height,
               "a smaller Dock yields a taller gap and shelf")
    }

    /// The promotion decision core: pure, driven here without a runloop.
    /// This is the WS-0 contract from DESIGN_THINKING.md: at most one report
    /// per evaluation, promotion by repetition instead of timer cascades, and
    /// pointer-off size-only readings adopted instantly.
    private static func decisionCore() {
        let resting = referenceDock()
        // Magnified frame: same everything, larger height (size-only change).
        let magnified = DockGeometry(frame: CGRect(x: 3387, y: 13, width: 53, height: 1384),
                                     orientation: .right, autohides: true,
                                     screen: resting.screen, source: .accessibility)
        let half = DockGeometry(frame: CGRect(x: 3387, y: 200, width: 53, height: 1000),
                                orientation: .right, autohides: true,
                                screen: resting.screen, source: .accessibility)

        // Identical reading → idle, and clears any pending candidate.
        var state = DockWatcher.PromotionState(accepted: resting)
        state.candidate = half
        expect(DockWatcher.fold(&state, reading: resting, pointerOnDock: true) == .idle,
               "a reading equal to the accepted geometry decides nothing")
        expect(state.candidate == nil,
               "returning to the accepted geometry clears a stale candidate")

        // Structural → adopt immediately, candidate and count reset.
        let toggled = DockGeometry(frame: resting.frame, orientation: .right, autohides: false,
                                   screen: resting.screen, source: .accessibility)
        state = DockWatcher.PromotionState(accepted: resting)
        state.candidate = magnified
        state.repeatedReadings = 1
        if case .adopt = DockWatcher.fold(&state, reading: toggled, pointerOnDock: true) {} else {
            expect(false, "an auto-hide change adopts immediately without confirmation")
        }
        expect(state.candidate == nil && state.repeatedReadings == 0,
               "adoption clears the candidate and the repetition count")

        // Size-only under the pointer: transient until the reading repeats.
        state = DockWatcher.PromotionState(accepted: resting)
        if case .offerTransient(let d) = DockWatcher.fold(&state, reading: magnified, pointerOnDock: true) {
            expect(d == magnified, "the transient offer carries the reading being held")
        } else {
            expect(false, "a first size-only reading under the pointer is transient, not adopted")
        }
        expect(state.candidate == magnified && state.repeatedReadings == 1,
               "the first size-only reading becomes the promotion candidate")

        // The animation breathing through a different frame does not adopt:
        // each new shape restarts the count at one.
        if case .offerTransient = DockWatcher.fold(&state, reading: half, pointerOnDock: true) {} else {
            expect(false, "a new size-only shape is also transient")
        }
        expect(state.candidate == half && state.repeatedReadings == 1,
               "a different size-only shape restarts the count at one")

        // Magnification unwinding returns to the accepted geometry: idle, and
        // the stale candidate is gone.
        expect(DockWatcher.fold(&state, reading: resting, pointerOnDock: true) == .idle,
               "the unwound animation is idle")
        expect(state.candidate == nil, "the unwind clears the held candidate")

        // Repetition promotes: the Dock stopped breathing.
        state = DockWatcher.PromotionState(accepted: resting)
        if case .offerTransient = DockWatcher.fold(&state, reading: magnified, pointerOnDock: true) {} else {
            expect(false, "the pre-quorum reading is transient")
        }
        if case .adopt(let adopted) = DockWatcher.fold(&state, reading: magnified, pointerOnDock: true) {
            expect(adopted == magnified, "the repeated reading is adopted as resting geometry")
        } else {
            expect(false, "a repeated size-only reading promotes at quorum")
        }
        expect(state.accepted == magnified && state.candidate == nil && state.repeatedReadings == 0,
               "promotion rewrites the accepted geometry and clears the model")

        // Size-only with the pointer elsewhere: a real resize, adopted at once
        // (magnification happens only under the pointer).
        state = DockWatcher.PromotionState(accepted: resting)
        if case .adopt = DockWatcher.fold(&state, reading: magnified, pointerOnDock: false) {} else {
            expect(false, "a size-only reading without the pointer on the Dock is a real resize")
        }

        // Promotion quorum is exactly two.
        expect(DockWatcher.promotionQuorum == 2, "promotion needs the reading twice, not more")
    }

    /// The liquid-follow geometry: content scaling for transient readings, and
    /// an expanded shelf riding a magnifying Dock instead of snapping shut.
    private static func transientGeometry() {
        let resting = referenceDock()
        // Right Dock, gap bigger than the thickness: content sits at natural size.
        expect(ShelfGeometry.contentScale(slot: .leading, dock: resting) == 1,
               "a roomy gap leaves the content unscaled")
        // A gap narrower than the Dock's thickness forces the content down.
        let cramped = DockGeometry(frame: CGRect(x: 3387, y: 30, width: 53, height: 1400),
                                   orientation: .right, autohides: true,
                                   screen: resting.screen, source: .accessibility)
        expect(abs(ShelfGeometry.contentScale(slot: .leading, dock: cramped) - 30.0 / 53.0) < 0.001,
               "content scales to the gap/thickness ratio when the gap is tight")
        expect(ShelfGeometry.contentScale(slot: .trailing, dock: cramped) == 1,
               "an empty gap means no room to show anything, so no scaling either")
        // Bottom Dock: the gap's *width* is the room that matters.
        let bottom = DockGeometry(frame: CGRect(x: 700, y: 0, width: 400, height: 60),
                                  orientation: .bottom, autohides: false,
                                  screen: CGRect(x: 0, y: 0, width: 1440, height: 900), source: .accessibility)
        expect(abs(ShelfGeometry.contentScale(slot: .leading, dock: bottom) - 700.0 / 60.0) > 1,
               "a wide gap clamps to natural size on a bottom Dock")
        let tightBottom = DockGeometry(frame: CGRect(x: 50, y: 0, width: 1360, height: 60),
                                       orientation: .bottom, autohides: false,
                                       screen: bottom.screen, source: .accessibility)
        expect(abs(ShelfGeometry.contentScale(slot: .leading, dock: tightBottom) - 50.0 / 60.0) < 0.001,
               "a tight gap scales content by width/thickness on a bottom Dock")

        // An expanded shelf re-welds to the strip's face when the Dock's
        // thickness changes, keeping the depth and length the user sees.
        let grownRight = DockGeometry(frame: CGRect(x: 3360, y: 140, width: 80, height: 1131),
                                      orientation: .right, autohides: true,
                                      screen: resting.screen, source: .accessibility)
        let trailingExpanded = CGRect(x: 3067, y: 1010, width: 320, height: 400)
        let reWelded = ShelfGeometry.expandedTransient(from: trailingExpanded, dock: grownRight)
        expect(reWelded.maxX == grownRight.frame.minX,
               "an expanded shelf's inner face re-welds to the grown Dock's face")
        expect(reWelded.height == trailingExpanded.height && reWelded.width == trailingExpanded.width,
               "transient handling preserves the depth and length the user sees")
        expect(reWelded.minY == trailingExpanded.minY,
               "an expanded shelf's length axis does not chase the Dock's end")
        // Depth clamps to the room on the shelf's side of the strip.
        let shallowBottom = DockGeometry(frame: CGRect(x: 550, y: 0, width: 300, height: 60),
                                         orientation: .bottom, autohides: false,
                                         screen: CGRect(x: 0, y: 0, width: 1440, height: 200), source: .accessibility)
        let clamped = ShelfGeometry.expandedTransient(from: CGRect(x: 360, y: 60, width: 240, height: 400),
                                                      dock: shallowBottom)
        expect(clamped.height == 140 && clamped.minY == 60,
               "an expanded shelf's depth clamps to the room above the strip")
        // A bottom Dock's thickness change lifts the shelf's floor without
        // touching its length.
        let grownBottom = DockGeometry(frame: CGRect(x: 550, y: 0, width: 300, height: 90),
                                       orientation: .bottom, autohides: false,
                                       screen: bottom.screen, source: .accessibility)
        let lifted = ShelfGeometry.expandedTransient(from: CGRect(x: 360, y: 300, width: 240, height: 320),
                                                     dock: grownBottom)
        expect(lifted.minY == grownBottom.dockStrip.maxY && lifted.height == 320 && lifted.minX == 360,
               "an expanded shelf rides the strip's face and keeps its length on a bottom Dock")
    }

    // MARK: - Rename

    private static func renameValidation() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-rename-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("original.txt")
        try? Data("x".utf8).write(to: source)
        let occupied = base.appendingPathComponent("taken.txt")
        try? Data("y".utf8).write(to: occupied)

        func rejects(_ name: String, _ description: String) {
            if case .success = FinderActions.validateRename(name, of: source.path) { failures.append(description) }
            checks += 1
        }
        rejects("", "an empty name is rejected")
        rejects("   ", "a whitespace-only name is rejected")
        rejects("a/b.txt", "a name with a slash is rejected")
        rejects("a:b.txt", "a name with a colon is rejected")
        rejects("..", "a parent-directory name is rejected")
        rejects(".", "a current-directory name is rejected")
        rejects("taken.txt", "a name that already exists is rejected")
        rejects("original.txt", "renaming to the current name is rejected")

        if case .success(let destination) = FinderActions.validateRename("  renamed.txt  ", of: source.path) {
            expect(destination.lastPathComponent == "renamed.txt", "a valid name is trimmed and accepted")
            expect(destination.deletingLastPathComponent().path == base.path, "the rename stays in the same folder")
        } else {
            failures.append("a valid name is accepted")
            checks += 1
        }
    }

    // MARK: - Archive

    private static func archivePreconditions() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let absent = ShelfItem(kind: .file, title: "absent", path: base.appendingPathComponent("absent.txt").path)
        var absentResult: Bool?
        expect(FinderActions.compress(absent, completion: { absentResult = $0 }) == nil, "compressing a missing file starts no process")
        expect(absentResult == false, "compressing a missing file reports failure")

        let real = base.appendingPathComponent("real.txt")
        try Data("payload".utf8).write(to: real)
        try Data("existing".utf8).write(to: base.appendingPathComponent("real.txt.zip"))
        let occupied = ShelfItem(kind: .file, title: "real", path: real.path)
        var occupiedResult: Bool?
        expect(FinderActions.compress(occupied, completion: { occupiedResult = $0 }) == nil, "compressing over an existing archive starts no process")
        expect(occupiedResult == false, "compressing over an existing archive reports failure")

        let pathless = ShelfItem(kind: .note, title: "note", text: "note")
        expect(FinderActions.compress(pathless) == nil, "compressing an item with no path starts no process")
    }

    // MARK: - Safe removal

    private static func safeRemoval() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dockdeck-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("keepme.txt")
        try Data("precious".utf8).write(to: file)

        let storeURL = base.appendingPathComponent("shelf.json")
        let store = ShelfStore(fileURL: storeURL, loadImmediately: false)
        let item = ShelfItem(kind: .file, title: "keepme.txt", path: file.path)
        expect(store.add(item), "adds the referenced file")
        store.remove(id: item.id)
        expect(store.item(id: item.id) == nil, "removing drops the shelf entry")
        expect(FileManager.default.fileExists(atPath: file.path), "removing from the shelf never deletes the file on disk")

        // Shutdown persistence: whatever is in memory at quit must reach disk.
        _ = store.add(ShelfItem(kind: .note, title: "final", text: "final"))
        expect(store.save(), "the shutdown save succeeds")
        expect(ShelfStore(fileURL: storeURL).items.contains { $0.title == "final" }, "state written at shutdown is readable again")
    }
}

#if DOCKDECK_SELFTEST
@main
struct ModelSelfTestMain {
    static func main() {
        do { try ModelSelfTest.run() }
        catch { FileHandle.standardError.write(Data("DockDeck model self-test: FAIL — \(error)\n".utf8)); exit(1) }
    }
}
#endif
