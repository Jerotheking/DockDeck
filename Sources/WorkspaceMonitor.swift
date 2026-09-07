import AppKit
import Darwin

final class WorkspaceMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounceWork: DispatchWorkItem?
    private(set) var projectURL: URL?
    var onChange: () -> Void = {}

    func start(projectURL: URL? = nil) {
        stop(); self.projectURL = projectURL
        let folder = projectURL ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        // A VFS-wedged folder (stuck file-provider operation, hung security
        // scan) makes open() block *forever* — it froze the whole app's launch
        // when Downloads wedged. open() therefore runs off the main thread
        // under a 2 s watchdog: on timeout the monitor reports unavailable and
        // the app launches without Downloads watching, instead of not
        // launching at all. A late-arriving descriptor is adopted.
        let box = WatchdogOpenBox()
        let sem = DispatchSemaphore(value: 0)
        box.onAbandonedFd = { [weak self] lateFd in self?.adopt(fd: lateFd, folder: folder) }
        DispatchQueue.global(qos: .utility).async {
            box.complete(open(folder.path, O_EVTONLY))
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 2) == .success else {
            // Exactly-once resolution lives inside the box: whichever of
            // {abandon(), complete()} runs second routes the descriptor to
            // `adopt`. Either way the main thread moves on now.
            box.abandon()
            return
        }
        let result = box.fd
        guard result >= 0 else { return }
        install(fd: result, folder: folder)
    }

    /// Installs the dispatch source for a successfully opened descriptor.
    private func install(fd newFd: Int32, folder: URL) {
        fd = newFd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: newFd, eventMask: [.write, .rename, .delete, .extend], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in DispatchQueue.main.async { self?.onChange() } }
            self?.debounceWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.setCancelHandler { [fd] in if fd >= 0 { close(fd) } }
        source.resume(); self.source = source
    }

    /// A late-arriving descriptor from an orphaned watchdog open: adopt it if
    /// the monitor has none yet (the folder unwedged after launch).
    private func adopt(fd lateFd: Int32, folder: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fd < 0 else { close(lateFd); return }
            self.install(fd: lateFd, folder: folder)
        }
    }

    func stop() { debounceWork?.cancel(); debounceWork = nil; source?.cancel(); source = nil; fd = -1 }
    deinit { stop() }
}

/// Hand-off box for the watchdog open. The background thread completes the
/// descriptor under the lock; the main thread either reads it on time or
/// calls `abandon()` — exactly one of the two paths ends up owning the
/// descriptor, so nothing leaks and nothing is adopted twice.
final class WatchdogOpenBox {
    private let lock = NSLock()
    private var storedFd: Int32 = -1
    private var abandoned = false
    var onAbandonedFd: ((Int32) -> Void)?

    func complete(_ fd: Int32) {
        lock.lock()
        let wasAbandoned = abandoned
        storedFd = fd
        lock.unlock()
        if wasAbandoned, fd >= 0 { onAbandonedFd?(fd) }
    }

    func abandon() {
        lock.lock()
        abandoned = true
        let fd = storedFd
        lock.unlock()
        if fd >= 0 { onAbandonedFd?(fd) }
    }

    var fd: Int32 {
        lock.lock(); defer { lock.unlock() }; return storedFd
    }
}
