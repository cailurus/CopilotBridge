import Foundation
import Network

/// A minimal HTTP/1.1 server on Network.framework (no third-party deps).
/// Supports request bodies, chunk-free responses, and streamed SSE responses.
final class HTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        /// Remote endpoint is loopback (127.0.0.1 / ::1).
        let isLoopback: Bool
    }

    /// A response the handler streams back. Either a full buffer or an async writer.
    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data?
        /// For streaming: called with a writer that appends chunks; return when done.
        var stream: (@Sendable (StreamWriter) async -> Void)?

        static func json(_ status: Int, _ obj: Any) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            return Response(status: status,
                            headers: ["Content-Type": "application/json"],
                            body: data, stream: nil)
        }

        static func text(_ status: Int, _ s: String, contentType: String = "text/plain") -> Response {
            Response(status: status, headers: ["Content-Type": contentType],
                     body: Data(s.utf8), stream: nil)
        }
    }

    /// Handle exposed to streaming handlers to push bytes to the client.
    final class StreamWriter: @unchecked Sendable {
        private let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }

        func write(_ s: String) async {
            await write(Data(s.utf8))
        }
        func write(_ data: Data) async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                connection.send(content: data, completion: .contentProcessed { _ in
                    cont.resume()
                })
            }
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "copilotbridge.http", attributes: .concurrent)
    private let handler: @Sendable (Request) async -> Response
    /// Called when the listener stops serving unexpectedly (bind failure, or it drops
    /// out of `.ready` while running). `stop()` detaches this first so a deliberate
    /// teardown's `.cancelled` transition stays silent.
    private let failureLock = NSLock()
    private var onFailure: (@Sendable (String) -> Void)?

    init(handler: @escaping @Sendable (Request) async -> Response) {
        self.handler = handler
    }

    /// Sets the callback fired when the listener enters `.failed`/`.waiting`.
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        failureLock.lock()
        onFailure = handler
        failureLock.unlock()
    }

    private func reportFailure(_ message: String) {
        failureLock.lock()
        let handler = onFailure
        failureLock.unlock()
        handler?(message)
    }

    func start(host: String, port: Int) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if host == "127.0.0.1" || host == "localhost" {
            params.requiredInterfaceType = .loopback
        }
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "HTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port) (must be 1–65535)"])
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let err):
                NSLog("HTTPServer listener failed: \(err)")
                self?.reportFailure(Self.describe(err))
            case .waiting(let err):
                // The listener could not acquire the port (e.g. already in use) and is
                // waiting to retry. Surface it as a failure so the UI stops claiming "Running".
                NSLog("HTTPServer listener waiting: \(err)")
                self?.reportFailure(Self.describe(err))
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        // Detach first so the listener's own `.cancelled` transition isn't reported
        // as a failure.
        failureLock.lock()
        onFailure = nil
        failureLock.unlock()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var acc = buffer
            if let data { acc.append(data) }
            if let parsed = self.tryParse(acc, conn: conn) {
                Task {
                    let response = await self.handler(parsed)
                    await self.send(response, on: conn)
                }
                return
            }
            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.receiveRequest(conn, buffer: acc)
        }
    }

    /// Attempts to parse a complete request (headers + full body if Content-Length present).
    private func tryParse(_ data: Data, conn: NWConnection) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = data.count - bodyStart
        if available < contentLength { return nil }   // wait for the rest of the body
        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + contentLength))
            : Data()

        var isLoopback = true
        if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
            switch host {
            case .ipv4(let a): isLoopback = a.isLoopback
            case .ipv6(let a): isLoopback = a.isLoopback
            default: isLoopback = false
            }
        }
        return Request(method: method, path: path, headers: headers, body: body, isLoopback: isLoopback)
    }

    private func send(_ response: Response, on conn: NWConnection) async {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        // For streamed responses we omit Content-Length and close the socket at the end
        // (HTTP/1.0-style delimitation), which SSE clients handle. Non-streamed responses
        // carry an explicit Content-Length.
        headers["Connection"] = "close"
        if response.stream == nil {
            headers["Content-Length"] = String(response.body?.count ?? 0)
        }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        let writer = StreamWriter(conn)
        await writer.write(head)
        if let stream = response.stream {
            await stream(writer)
        } else if let body = response.body {
            await writer.write(body)
        }
        conn.cancel()
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }

    /// Human-readable text for a listener failure, mapping the common POSIX cases.
    static func describe(_ error: NWError) -> String {
        if case let .posix(code) = error {
            switch code {
            case .EADDRINUSE: return "Port already in use"
            case .EACCES: return "Permission denied for this port"
            case .EADDRNOTAVAIL: return "Address not available"
            default: break
            }
        }
        return error.localizedDescription
    }
}
