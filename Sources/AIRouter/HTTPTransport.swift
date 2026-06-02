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

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIRouterError.noResponse
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
