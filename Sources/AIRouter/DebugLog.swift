import Foundation
import os

/// Leichtgewichtiges Logging fuer den AIRouter.
///
/// Schreibt sowohl in das Unified Logging System (`os.Logger`) als auch optional
/// in eine Datei. Standardmaessig ist nur das `os.Logger`-Backend aktiv; ein
/// Datei-Pfad kann ueber ``configure(filePath:)`` gesetzt werden.
///
/// Der Datei-Handle wird ausschliesslich auf `ioQueue` beruehrt (oeffnen,
/// schreiben, schliessen), wodurch Use-after-close-Races strukturell
/// ausgeschlossen sind.
public enum DebugLog {
    private static let logger = Logger(subsystem: "com.airouter", category: "debug")
    private static let ioQueue = DispatchQueue(label: "com.airouter.debuglog", qos: .utility)

    /// Nur auf `ioQueue` zugreifen.
    private static var handle: FileHandle?

    private static let lock = NSLock()
    private static var enabled = true

    /// Aktiviert das Schreiben in eine Logdatei am angegebenen Pfad.
    /// Uebergib `nil`, um das Datei-Logging zu deaktivieren.
    public static func configure(filePath: String?) {
        ioQueue.async {
            try? handle?.close()
            handle = nil
            guard let filePath else { return }
            // 0600: Logzeilen koennen Endpoints, Modellnamen und Fehler-Auszuege
            // enthalten — nur fuer den Besitzer lesbar anlegen.
            FileManager.default.createFile(
                atPath: filePath,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            handle = FileHandle(forWritingAtPath: filePath)
        }
    }

    /// Schaltet das Logging global an oder aus.
    public static func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    /// Ersetzt Steuerzeichen durch Leerzeichen. Teile der Nachrichten sind
    /// server-kontrolliert (Fehler-Body-Auszuege, entdeckte Modellnamen) —
    /// eingebettete Zeilenumbrueche koennten sonst Logzeilen faelschen und
    /// ANSI-Escapes beim Betrachten der Datei Terminal-Tricks ausfuehren.
    static func sanitized(_ msg: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in msg.unicodeScalars {
            view.append(scalar.value < 0x20 || scalar.value == 0x7F ? " " : scalar)
        }
        return String(view)
    }

    public static func write(_ msg: String) {
        lock.lock()
        let isEnabled = enabled
        lock.unlock()
        guard isEnabled else { return }

        let msg = sanitized(msg)

        // .private: Log-Inhalte (Endpoints, Fehler-Auszuege) erscheinen im
        // Unified Log nur geschwaerzt; Klartext gibt es gezielt via Datei-Log.
        logger.debug("\(msg, privacy: .private)")

        ioQueue.async {
            guard let handle else { return }
            let line = "\(Date()): \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            // Logging darf die App nie crashen (z. B. bei voller Platte).
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Fehler beim Datei-Log still verwerfen; os.Logger lief bereits.
            }
        }
    }
}
