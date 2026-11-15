import Foundation
import OSLog

/// Debug-mode file logging.
///
/// OSLog debug-level messages are not persisted by `logd` — they are only
/// observable through a live `log stream`, which a user reporting a problem
/// can't run retroactively. Debug mode gives every installation an opt-in,
/// always-available record: while enabled (Settings → About → 诊断日志), key
/// diagnostics — panel lifecycle, file drag sessions, context-menu routing,
/// directory watchers — are mirrored to day-stamped files under
/// `~/Library/Logs/Tearoff/`.
///
/// Design notes:
/// - The enabled flag lives in UserDefaults (thread-safe) so any isolation
///   context can check it; `AppSettings.debugLoggingEnabled` is the UI-facing
///   mirror and calls `start()`/`stop()`.
/// - When disabled, `event` is a UserDefaults read plus a branch — cheap
///   enough to sprinkle at interaction-frequency call sites.
/// - All file I/O is confined to one serial utility queue; day rotation,
///   size capping (4 MB, one `.1` generation kept) and 7-day retention are
///   handled there.
final nonisolated class FileLog: @unchecked Sendable {
    static let shared = FileLog()

    /// Where log files live — also the folder the Settings "open log folder"
    /// button reveals. `~/Library/Logs/Tearoff/`.
    static let logDirectory: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return logs.appendingPathComponent("Logs/Tearoff", isDirectory: true)
    }()

    private static let enabledKey = "debugLoggingEnabled"
    private static let maxFileSize: UInt64 = 4 * 1024 * 1024
    private static let retentionDays = 7

    private let queue = DispatchQueue(label: "io.github.zcyisiee.Tearoff.filelog", qos: .utility)
    private var handle: FileHandle?
    private var currentDay = ""

    /// Queue-confined formatters (DateFormatting is not thread-safe; keeping
    /// them as queue-confined lets every line skip allocator churn).
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private init() {}

    // MARK: - Writing

    /// Appends one timestamped line if debug mode is on. `message` is only
    /// evaluated when enabled, so callers can pass interpolations freely.
    func event(_ category: String, _ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        let line = message()
        queue.async { [self] in
            append("\(category) \(line)")
        }
    }

    /// Called when debug mode is switched on: make sure the directory exists,
    /// prune stale files, and stamp a session header.
    func start() {
        queue.async { [self] in
            openFile(day: today())
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            append("── session start (v\(version) build \(build)) ──")
        }
    }

    /// Called when debug mode is switched off.
    func stop() {
        queue.async { [self] in
            append("── session end ──")
            closeFile()
        }
    }

    // MARK: - File management (serial queue only)

    private func today() -> String {
        dayFormatter.string(from: Date())
    }

    private func currentFileURL(day: String) -> URL {
        Self.logDirectory.appendingPathComponent("debug-\(day).log")
    }

    private func openFile(day: String) {
        guard handle == nil || day != currentDay else { return }
        closeFile()
        currentDay = day

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)

        // Retention: drop day-stamped logs older than a week (plus stray
        // rotated copies) so the folder never grows unbounded.
        if let contents = try? fm.contentsOfDirectory(
            at: Self.logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
        ) {
            let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86400)
            for url in contents where url.lastPathComponent.hasPrefix("debug-") {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date()
                if modified < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }

        let url = currentFileURL(day: day)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        if let newHandle = FileHandle(forWritingAtPath: url.path) {
            _ = try? newHandle.seekToEnd()
            handle = newHandle
        } else {
            Log.app.error("FileLog: cannot open \(url.path, privacy: .public)")
        }
    }

    private func append(_ line: String) {
        let day = today()
        openFile(day: day)

        // Size cap: rotate once per day file — `debug-<day>.log.1` replaces
        // any previous rotation, the fresh file continues recording.
        if let current = handle, let size = try? current.seekToEnd(), size > Self.maxFileSize {
            closeFile()
            let url = currentFileURL(day: day)
            let rotated = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
            openFile(day: day)
        }

        guard let handle else { return }
        let stamp = timeFormatter.string(from: Date())
        let data = Data("[\(stamp)] \(line)\n".utf8)
        try? handle.write(contentsOf: data)
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
    }
}
