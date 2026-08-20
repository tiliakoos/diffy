import CoreServices
import Foundation

final class RepositoryWatcher {
    private let paths: [String]
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?

    init(repositoryPath: String, gitdirPath: String? = nil, onChange: @escaping () -> Void) {
        let resolvedGitdir = gitdirPath ?? URL(fileURLWithPath: repositoryPath).appendingPathComponent(".git").path
        self.paths = [repositoryPath, resolvedGitdir]
        self.onChange = onChange
    }

    func start() -> Bool {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleRefresh()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            return false
        }

        stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, DispatchQueue.main)
        return FSEventStreamStart(createdStream)
    }

    func stop() {
        debounceWorkItem?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleRefresh() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}
