import CoreServices

/// One FSEvents event's effect: a relist, or a rebuild only a lost stream position forces.
enum FileIndexEventPolicy {
    enum Action: Equatable {
        case rebuild
        case relist(path: String, recursive: Bool)
    }

    /// `nil` for `HistoryDone`, which only marks the end of the replayed backlog.
    static func action(path rawPath: String, flags: FSEventStreamEventFlags) -> Action? {
        guard !has(flags, kFSEventStreamEventFlagHistoryDone) else { return nil }
        if has(flags, kFSEventStreamEventFlagRootChanged)
            || has(flags, kFSEventStreamEventFlagEventIdsWrapped)
        {
            return .rebuild
        }
        var path = rawPath
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return .relist(
            path: path, recursive: has(flags, kFSEventStreamEventFlagMustScanSubDirs))
    }

    private static func has(_ flags: FSEventStreamEventFlags, _ flag: Int) -> Bool {
        flags & FSEventStreamEventFlags(flag) != 0
    }
}
