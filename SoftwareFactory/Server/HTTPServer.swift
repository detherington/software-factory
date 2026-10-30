import Foundation
import Network

struct HTTPRequest: Sendable {
    var method: String
    /// Percent-decoded, without the query.
    var path: String
    var query: [String: String]
    /// Lowercased names.
    var headers: [String: String]
    var body: Data
    /// Whether it came from this Mac.
    var isLoopback = true
    /// The other end's address: "192.168.1.20".
    var remoteAddress = "127.0.0.1"
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType = "application/json; charset=utf-8"
    var body: Data
    /// A response that comes later: the real one, which the request waits for. It's cancelled if
    /// the other end closes the connection first.
    var later: (@Sendable () async -> HTTPResponse)?

    static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: data + Data("\n".utf8))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        return json(body, status: status)
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }
}

/// A small HTTP/1.1 server: one request per connection, bodies by Content-Length, up to 4 MB. On the
/// loopback interface only, unless `acceptsOtherMacs`; the API then asks other Macs for the token.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum State: Sendable {
        case ready(UInt16)
        case failed(String)
    }

    let port: UInt16
    let acceptsOtherMacs: Bool
    private let handler: Handler
    private let onState: @Sendable (State) -> Void
    private let queue = DispatchQueue(label: "com.darrell.softwarefactory.http")
    private var listener: NWListener?

    init(port: UInt16, acceptsOtherMacs: Bool, onState: @escaping @Sendable (State) -> Void, handler: @escaping Handler) {
        self.port = port
        self.acceptsOtherMacs = acceptsOtherMacs
        self.onState = onState
        self.handler = handler
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            // Nothing off this Mac can reach it, unless other Macs are welcome.
            if !acceptsOtherMacs { parameters.requiredInterfaceType = .loopback }
            parameters.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.stateUpdateHandler = { [port, onState] state in
                switch state {
                case .ready: onState(.ready(port))
                case .failed(let error): onState(.failed(Self.describe(error, port: port)))
                case .waiting(let error): onState(.failed(Self.describe(error, port: port)))
                default: break
                }
            }
            listener.newConnectionHandler = { [handler, queue] connection in
                HTTPConnection(connection: connection, handler: handler).start(on: queue)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onState(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return String(localized: "Port \(port) is already in use. Is another copy of Software Factory running?")
        }
        return error.localizedDescription
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private static let maxSize = 4 * 1024 * 1024
    private let connection: NWConnection
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    private var sentContinue = false

    init(connection: NWConnection, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.handler = handler
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if buffer.count > Self.maxSize {
                send(.error(413, "Request too large."))
                return
            }
            switch parse() {
            case .complete(let request):
                let task = Task { [self] in send(await handler(request)) }
                watchForClose(task)
            case .invalid(let response):
                send(response)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }
    }

    /// A client that gives up on a response still being made (a hook whose prompt was answered
    /// elsewhere) closes the connection: stop making it.
    private func watchForClose(_ task: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] _, _, isComplete, error in
            if isComplete || error != nil { task.cancel() } else { watchForClose(task) }
        }
    }

    private enum Parse {
        case incomplete
        case complete(HTTPRequest)
        case invalid(HTTPResponse)
    }

    private func parse() -> Parse {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid(.error(400, "Malformed request.")) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid(.error(411, "Send a Content-Length; chunked bodies aren't supported."))
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        if buffer.count - bodyStart < length {
            // curl waits a second for this before sending a large body.
            if headers["expect"]?.lowercased() == "100-continue", !sentContinue {
                sentContinue = true
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
            return .incomplete
        }

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        let (isLoopback, address) = Self.peer(connection.endpoint)
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers,
                                     body: buffer.subdata(in: bodyStart..<(bodyStart + length)),
                                     isLoopback: isLoopback, remoteAddress: address))
    }

    /// Whether the other end is this Mac, and its address.
    private static func peer(_ endpoint: NWEndpoint) -> (Bool, String) {
        guard case .hostPort(let host, _) = endpoint else { return (false, "\(endpoint)") }
        switch host {
        case .ipv4(let address):
            return (address.isLoopback, "\(address)")
        case .ipv6(let address):
            let text = "\(address)"
            // IPv4 arrives mapped into IPv6 on a dual-stack listener: ::ffff:127.0.0.1.
            return (address.isLoopback || text.hasPrefix("::ffff:127."), text.replacingOccurrences(of: "::ffff:", with: ""))
        default:
            return (false, "\(host)")
        }
    }

    private func send(_ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        default: "Status"
        }
    }
}
