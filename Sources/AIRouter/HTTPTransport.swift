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
        let (bytes, response) = try await session.bytes(for: request)
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
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIRouterError.noResponse
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
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
