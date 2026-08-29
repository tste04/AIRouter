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
        // den Prozess nicht ueber den Speicher druecken.
        let limit = maxResponseBytes
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var totalBytes = 0
                do {
                    for try await line in bytes.lines {
                        totalBytes += line.utf8.count + 1
                        guard totalBytes <= limit else {
                            continuation.finish(throwing: AIRouterError.responseTooLarge(limitBytes: limit))
                            return
                        }
                        continuation.yield(line)
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
