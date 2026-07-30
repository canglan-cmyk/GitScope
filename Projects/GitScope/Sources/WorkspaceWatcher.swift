import Foundation
import CoreServices

/// Watches a repository working tree with FSEvents and fires a debounced
/// callback when files change — used to auto-refresh the diff after the AI
/// (or anything else) edits the workspace.
@MainActor
final class WorkspaceWatcher {

    private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private let onChange: () -> Void

    init?(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            // Ignore changes inside .git (index churn from our own git calls).
            let paths = Unmanaged<NSArray>.fromOpaque(
                UnsafeRawPointer(OpaquePointer(eventPaths))
            ).takeUnretainedValue() as? [String] ?? []
            let relevant = paths.contains { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }
            guard relevant else { return }

            let watcher = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                watcher.scheduleChange()
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func scheduleChange() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    /// Stops watching. Must be called before the watcher is released
    /// (the FSEvents stream holds an unretained pointer to `self`).
    func invalidate() {
        debounceTask?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
