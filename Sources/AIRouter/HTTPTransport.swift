import Foundation

/// Abstraktion ueber den HTTP-Transport, damit der ``AIRouter`` ohne echtes
/// Netzwerk getestet werden kann. Die Default-Implementierung nutzt `URLSession`.
public protocol HTTPTransport: Sendable {
    /// Fuehrt einen Request aus und liefert Body + HTTP-Response.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Fuehrt einen Streaming-Request aus und liefert einen zeilenweisen Stream
    /// (NDJSON) plus HTTP-Response.
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

/// Verweigert HTTP-Redirects. `URLSession` haengt die Original-Header sonst
/// auch an das Redirect-Ziel an — inklusive `Authorization` bzw. `x-api-key`,
/// und auch bei einem Hostwechsel. Ein kompromittiertes Backend koennte
/// Credentials so per `302 Location:` abgreifen. Keiner der angebundenen
/// API-Pfade braucht Redirects; die 3xx-Antwort wird stattdessen wie jeder
/// andere Nicht-2xx-Status an den Aufrufer durchgereicht.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectRefusingDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Zeilen-Puffer fuer den Streaming-Transport: zerlegt rohe Bytes an `\n`
/// (ein `\r` davor wird entfernt) und zaehlt JEDES empfangene Byte gegen das
/// Limit — auch Bytes, die nie eine Zeile abschliessen. `bytes.lines` wuerde
/// einen zeilenumbruchfreien Body unbegrenzt puffern, bevor das Limit greift.
struct ByteLineBuffer {
    private var buffer: [UInt8] = []
    private(set) var totalBytes = 0

    /// Nimmt ein Byte auf; liefert die Zeile, die dieses Byte abschliesst.
    mutating func append(_ byte: UInt8) -> String? {
        totalBytes += 1
        guard byte == 0x0A else {
            buffer.append(byte)
            return nil
        }
        return takeLine()
    }

    /// Restinhalt nach Stream-Ende (letzte Zeile ohne Zeilenumbruch).
    mutating func flush() -> String? {
        buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        var line = buffer
        buffer.removeAll(keepingCapacity: true)
        if line.last == 0x0D { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
    }
}

/// `URLSession`-basierte Standard-Implementierung von ``HTTPTransport``.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let maxResponseBytes: Int

    /// - Parameter maxResponseBytes: Obergrenze fuer Response-Bodies (Default
    ///   50 MB). Ein kompromittierter oder fehlerhafter Endpoint kann den
    ///   Prozess so nicht ueber unbegrenzte Antworten aus dem Speicher druecken.
    public init(session: URLSession = .shared, maxResponseBytes: Int = 50_000_000) {
        self.session = session
        self.maxResponseBytes = max(1024, maxResponseBytes)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectRefusingDelegate.shared)
        guard let http = response as? HTTPURLResponse else {
            throw AIRouterError.noResponse
        }
        if http.expectedContentLength > 0, http.expectedContentLength > Int64(maxResponseBytes) {
            throw AIRouterError.responseTooLarge(limitBytes: maxResponseBytes)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes {
                throw AIRouterError.responseTooLarge(limitBytes: maxResponseBytes)
            }
        }
        return (data, http)
    }

    public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectRefusingDelegate.shared)
        guard let http = response as? HTTPURLResponse else {
            throw AIRouterError.noResponse
        }
        // Groessenlimit gilt auch fuer Streams — ein endloser SSE-Strom darf
        // den Prozess nicht ueber den Speicher druecken. Byte-genau statt via
        // `bytes.lines`: dessen interner Puffer waechst bei einem Body ohne
        // Zeilenumbrueche unbegrenzt, bevor je eine Zeile beim Limit ankommt.
        let limit = maxResponseBytes
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var lineBuffer = ByteLineBuffer()
                do {
                    for try await byte in bytes {
                        if let line = lineBuffer.append(byte) {
                            continuation.yield(line)
                        }
                        guard lineBuffer.totalBytes <= limit else {
                            continuation.finish(throwing: AIRouterError.responseTooLarge(limitBytes: limit))
                            return
                        }
                    }
                    if let last = lineBuffer.flush() {
                        continuation.yield(last)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
}
