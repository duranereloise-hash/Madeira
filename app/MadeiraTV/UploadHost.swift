import Foundation
import Network

/// In-process HTTP server that delivers games from a computer/phone to
/// the Apple TV — the same trick RetroArch uses on tvOS (content is
/// uploaded over the network because the tvOS sandbox has no user-facing
/// file browser).
///
/// Endpoints:
///   GET  /            — small HTML upload page
///   POST /upload?name=Game.exe  — raw body (Content-Length) → Documents/Games/
///   GET  /games       — JSON list of installed games
///
/// Runs on NWListener (Network.framework) — no third-party dependencies.
final class UploadHost: ObservableObject {

    static let shared = UploadHost()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16
    @Published private(set) var localIP: String?

    private var listener: NWListener?

    private static let defaultPort: UInt16 = 8080

    init() {
        let saved = UserDefaults.standard.integer(forKey: "madeira.hostPort")
        port = (saved > 0 && saved <= 65535) ? UInt16(saved) : Self.defaultPort
    }

    var displayURL: String {
        guard let ip = localIP else { return "http://<ip>:\(port)" }
        return "http://\(ip):\(port)"
    }

    func setPort(_ p: UInt16) {
        port = p
        UserDefaults.standard.set(Int(p), forKey: "madeira.hostPort")
        if isRunning { stop(); start() }
    }

    func start() {
        guard !isRunning else { return }
        localIP = Self.wifiIPv4()

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.isRunning = true
                } else if case .failed = state {
                    self?.isRunning = false
                }
            }
            listener?.start(queue: .global(qos: .utility))
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        receive(conn, accumulator: Data())
    }

    private func receive(_ conn: NWConnection, accumulator: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var acc = accumulator
            if let data, !data.isEmpty { acc.append(data) }
            if let error {
                if error == .posix(.ECONNRESET) || error == .connectionReset { return }
                conn.cancel(); return
            }
            // Try to parse a complete request (headers end with \r\n\r\n).
            if let headerEnd = self.headerEnd(in: acc) {
                self.route(conn, request: acc, headerEnd: headerEnd)
                return
            }
            if acc.count > 2 << 20 { conn.cancel(); return }  // too big, bail
            if isComplete {
                // Connection closed without a complete request — nothing to do.
                conn.cancel(); return
            }
            self.receive(conn, accumulator: acc)
        }
    }

    private func headerEnd(in data: Data) -> Int? {
        let sep = Data("\r\n\r\n".utf8)
        return data.range(of: sep)?.upperBound
    }

    private func route(_ conn: NWConnection, request: Data, headerEnd: Int) {
        guard let head = String(data: request[..<headerEnd], encoding: .utf8) else {
            respond(conn, status: 400, body: "Bad request")
            return
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { respond(conn, status: 400, body: "Bad request"); return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { respond(conn, status: 400, body: "Bad request"); return }
        let method = String(parts[0])
        let target = String(parts[1])

        // Content-Length for POST bodies
        var bodyLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                bodyLength = Int(kv[1]) ?? 0
            }
        }
        let body = request[headerEnd...]

        if method == "GET", target == "/" || target.isEmpty {
            respond(conn, status: 200, contentType: "text/html; charset=utf-8", body: Self.indexHTML)
        } else if method == "GET", target == "/games" {
            respond(conn, status: 200, contentType: "application/json", body: Self.gamesJSON())
        } else if method == "POST", target.hasPrefix("/upload") {
            handleUpload(conn, body: body, bodyLength: bodyLength, target: target)
        } else {
            respond(conn, status: 404, body: "Not found")
        }
    }

    private func handleUpload(_ conn: NWConnection, body: Data, bodyLength: Int, target: String) {
        // If the body hasn't fully arrived yet, keep receiving until Content-Length.
        guard body.count >= bodyLength else {
            receiveMoreForUpload(conn, body: body, bodyLength: bodyLength, target: target)
            return
        }
        saveUpload(body.prefix(bodyLength), target: target) { result in
            self.respond(conn, status: 200, contentType: "text/plain", body: result)
        }
    }

    private func receiveMoreForUpload(_ conn: NWConnection, body: Data, bodyLength: Int, target: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, error in
            guard let self else { return }
            var acc = body
            if let data, !data.isEmpty { acc.append(data) }
            if acc.count >= bodyLength {
                self.saveUpload(acc.prefix(bodyLength), target: target) { result in
                    self.respond(conn, status: 200, contentType: "text/plain", body: result)
                }
            } else if error != nil {
                conn.cancel()
            } else {
                self.receiveMoreForUpload(conn, body: acc, bodyLength: bodyLength, target: target)
            }
        }
    }

    private func saveUpload(_ data: Data, target: String, completion: @escaping (String) -> Void) {
        // Extract ?name=Game.exe from the target
        var name = "game.exe"
        if let q = target.split(separator: "?").last {
            let params = q.split(separator: "&")
            for p in params where p.hasPrefix("name=") {
                let v = String(p.dropFirst(5))
                // Sanitize: no path separators, no leading dots
                let cleaned = v.replacingOccurrences(of: "/", with: "")
                    .replacingOccurrences(of: "\\", with: "")
                if !cleaned.isEmpty {
                    name = cleaned.hasSuffix(".exe") ? cleaned : cleaned + ".exe"
                }
            }
        }
        let dir = GameLibrary.gamesDir
        let dest = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
            DispatchQueue.main.async { GameLibrary.shared.refresh() }
            completion("Saved \(name) (\(data.count) bytes)\n")
        } catch {
            completion("Failed to save \(name): \(error.localizedDescription)\n")
        }
    }

    // MARK: - HTTP responses

    private func respond(_ conn: NWConnection, status: Int, contentType: String = "text/plain; charset=utf-8", body: String) {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return "Error"
        }
    }

    private static var indexHTML: String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <title>Madeira TV — upload</title>
        <style>
          body{font-family:-apple-system,sans-serif;background:#111;color:#eee;
               display:flex;align-items:center;justify-content:center;min-height:90vh;margin:0}
          .card{max-width:620px;padding:40px;border-radius:18px;background:#1c1c1e}
          h1{margin-top:0} code{background:#000;padding:2px 6px;border-radius:4px}
          input[type=file]{margin:18px 0}
        </style></head><body>
        <div class="card">
          <h1>Madeira TV</h1>
          <p>Upload a Windows game (.exe plus its folder) to the Apple TV.
             To keep a game folder intact, zip it and upload the zip here —
             or use curl for a single file:</p>
          <p><code>curl -X POST --data-binary @Game.exe \\
             "http://<this-ip>/upload?name=Game.exe"</code></p>
          <form method="post" action="/upload" enctype="multipart/form-data">
            <input type="file" name="file" multiple>
            <button>Upload</button>
          </form>
          <p>Games land in <code>Documents/Games</code> and appear in the library.</p>
        </div></body></html>
        """
    }

    private static func gamesJSON() -> String {
        let games = GameLibrary.shared.games
        struct Item: Encodable { let name: String; let exe: String; let size: Int64 }
        let items = games.map { Item(name: $0.name, exe: $0.exeRelPath, size: $0.sizeBytes) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: enc.encode(items), encoding: .utf8)) ?? "[]"
    }

    // MARK: - Local IP

    /// Best-effort IPv4 of the active Wi-Fi/Ethernet interface (en0).
    private static func wifiIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var result: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee.ifa_addr
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" || name == "en2" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") { result = ip; break }
            }
        }
        return result
    }
}