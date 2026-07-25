import Foundation

/// Eingabe-Validierung fuer Werte, die in URLs bzw. Requests interpoliert werden.
///
/// Sicherheits-Hintergrund: `vertexRegion` wird in den **Hostnamen** und
/// `vertexProject` sowie der Modellname in den **Pfad** des Vertex-Endpoints
/// interpoliert. Ohne strikte Allowlist koennte ein manipulierter Wert (z. B.
/// aus Remote-Config oder Nutzereingaben) den Request samt Bearer-Token auf
/// einen fremden Host umleiten oder Pfad-Segmente injizieren.
enum RouterValidation {
    private static let regionAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    private static let projectAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.:")
    private static let modelAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._@")

    /// GCP-Region: nur Kleinbuchstaben, Ziffern, Bindestrich (z. B. `us-central1`).
    static func isValidRegion(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { regionAllowed.contains($0) }
    }

    /// GCP-Projekt-ID inkl. Legacy-Format `example.com:project`.
    static func isValidProject(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { projectAllowed.contains($0) }
    }

    /// Vertex-Modellname (z. B. `gemini-2.5-flash`, `claude-3-5-sonnet@20240620`).
    /// Kein `/` erlaubt — verhindert Pfad-Injection trotz Percent-Encoding,
    /// da `.urlPathAllowed` den Schraegstrich unveraendert durchlaesst.
    static func isValidModelName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { modelAllowed.contains($0) }
    }

    /// Validiert eine Cloud-Provider-Basis-URL: nur `http`/`https` mit
    /// nicht-leerem Host; `http://` (Klartext) ist zusaetzlich nur fuer
    /// Loopback-/private Hosts erlaubt — API-Keys duerfen nicht unverschluesselt
    /// an entfernte Hosts gehen. `allowInsecureHTTP` hebt die Regel explizit auf
    /// (z. B. LAN-Hostname eines vLLM-Servers).
    static func validatedCloudBase(_ endpoint: String, allowInsecureHTTP: Bool = false) -> String? {
        guard let base = validatedLocalEndpoint(endpoint) else { return nil }
        if base.lowercased().hasPrefix("http:") {
            guard let url = URL(string: base), let host = url.host,
                  allowInsecureHTTP || isPrivateOrLoopbackHost(host) else {
                return nil
            }
        }
        return base
    }

    /// Loopback, `.local`-mDNS und private RFC-1918-Bereiche.
    static func isPrivateOrLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h.hasSuffix(".local") { return true }
        if h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    /// Validiert einen lokalen Inferenz-Endpoint: nur `http`/`https` mit
    /// nicht-leerem Host. Liefert die normalisierte Basis (ohne Trailing-Slash)
    /// oder `nil` bei ungueltiger Eingabe (z. B. `file://`, fehlendes Schema).
    static func validatedLocalEndpoint(_ endpoint: String) -> String? {
        var trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return trimmed
    }
}
