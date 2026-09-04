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
        fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in DispatchQueue.main.async { self?.onChange() } }
            self?.debounceWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.setCancelHandler { [fd] in if fd >= 0 { close(fd) } }
        source.resume(); self.source = source
    }

    func stop() { debounceWork?.cancel(); debounceWork = nil; source?.cancel(); source = nil; fd = -1 }
    deinit { stop() }
}
