import Foundation
import os

/// Leichtgewichtiges Logging fuer den AIRouter.
///
/// Schreibt sowohl in das Unified Logging System (`os.Logger`) als auch optional
/// in eine Datei. Standardmaessig ist nur das `os.Logger`-Backend aktiv; ein
/// Datei-Pfad kann ueber ``configure(filePath:)`` gesetzt werden.
public enum DebugLog {
    private static let logger = Logger(subsystem: "com.airouter", category: "debug")
    private static let ioQueue = DispatchQueue(label: "com.airouter.debuglog", qos: .utility)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var enabled = true

    /// Aktiviert das Schreiben in eine Logdatei am angegebenen Pfad.
    /// Uebergib `nil`, um das Datei-Logging zu deaktivieren.
    public static func configure(filePath: String?) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        guard let filePath else { return }
        FileManager.default.createFile(atPath: filePath, contents: nil)
        handle = FileHandle(forWritingAtPath: filePath)
    }

    /// Schaltet das Logging global an oder aus.
    public static func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    public static func write(_ msg: String) {
        lock.lock()
        let isEnabled = enabled
        let fileHandle = handle
        lock.unlock()

        guard isEnabled else { return }
        logger.debug("\(msg, privacy: .public)")

        guard let fileHandle else { return }
        ioQueue.async {
            let line = "\(Date()): \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        }
    }
}
