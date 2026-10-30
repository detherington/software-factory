import Foundation
import SystemConfiguration

/// Runs the API for the app's lifetime, on the port from Settings (`FactoryPort`, 7720 unless changed).
@MainActor
final class ServerController {
    static let shared = ServerController()
    private var server: HTTPServer?

    static var configuredPort: UInt16 {
        let value = UserDefaults.standard.integer(forKey: "FactoryPort")
        return (1024...65_535).contains(value) ? UInt16(value) : API.defaultPort
    }

    func start(store: ProjectStore = .shared) {
        server?.stop()
        let port = Self.configuredPort
        store.port = port
        store.serverStatus = .starting
        // Hooks waiting on a permission prompt held the old server's connections: nothing waits now.
        store.dropStalePermissions()
        let server = HTTPServer(port: port, acceptsOtherMacs: store.acceptsOtherMacs) { state in
            Task { @MainActor in
                switch state {
                case .ready(let port): store.serverStatus = .listening(port)
                case .failed(let message): store.serverStatus = .failed(message)
                }
            }
        } handler: { request in
            let response = await MainActor.run { API.handle(request, store: .shared) }
            return await response.later?() ?? response
        }
        server.start()
        self.server = server
    }

    func restart() { start() }

    /// This Mac on the local network: "http://My-Mac.local:7720".
    static func networkURL(port: UInt16) -> String {
        let name = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ProcessInfo.processInfo.hostName
        return "http://\(name).local:\(port)"
    }

    /// What to paste into Terminal on another Mac: download `factory` from this board, then connect.
    static func setupCommand(port: UInt16, token: String) -> String {
        let url = networkURL(port: port)
        return "mkdir -p ~/.local/bin && curl -fsS -H 'Authorization: Bearer \(token)' \(url)/api/factory -o ~/.local/bin/factory "
            + "&& chmod +x ~/.local/bin/factory && ~/.local/bin/factory connect \(url) --token \(token)"
    }
}
