import CoreServices
import Foundation

/// Watches a repository working tree via FSEvents and fires a debounced
/// callback when files change — external edits (editor, checkouts, tools)
/// then auto-refresh the diff.
///
/// Call `invalidate()` before releasing; the FSEvents stream holds an
/// unmanaged reference to its context and cannot be cleaned up safely from
/// a nonisolated deinit under Swift 6.
@MainActor
final class WorkspaceWatcher {

    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var debounceTimer: Timer?

    init?(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            // Ignore events entirely inside .git (index updates, locks…)
            // so our own diff commands don't retrigger refreshes.
            let pathList = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let interesting = pathList.contains { path in
                !path.contains("/.git/") && !path.hasSuffix("/.git")
            }
            guard interesting || count == 0 else { return }

            let watcher = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                watcher.scheduleChange()
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func scheduleChange() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onChange()
            }
        }
    }

    func invalidate() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }
}
