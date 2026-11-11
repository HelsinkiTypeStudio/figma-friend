import Foundation
import Network

/// A small HTTP server on 127.0.0.1 for Figma plugins.
///
/// Plugin windows have a null origin, so every answer allows any origin. Any web page
/// could call localhost too, so everything except /ping and /pair needs the pairing key.
///
///   GET  /ping                 {"ok", "app", "version", "paired"}
///   POST /pair                 asks you in a dialog; on Allow answers {"key"}
///   GET  /fonts/files?family=&style=   the installed files for a font (for the report)
///   POST /fonts/prepare        body {"family", "style", "axes", "glyphs"}: the font check and
///                              subset font, see Resources/fontwork.py
///   POST /fonts/charset        body {"family", "style"}: every character the font maps, grouped
///                              for a glyph list, see Resources/fontwork.py
///   POST /save?name=           body: the file. Shows a save dialog; a PDF is made smaller meanwhile
///                              (menu setting). {"saved": path, "bytes", "sentBytes"} or {"cancelled": true}
final class Server {
    private var listener: NWListener?
    private(set) var status = "Starting…"
    var onStatus: ((String) -> Void)?

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback   // nothing on the network can connect
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Settings.port)!)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                self?.receive(conn, Data())
            }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.setStatus("Running on port \(Settings.port)")
                case .failed(let e): self?.failed(e)
                default: break
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            setStatus("Could not start: \(error). Trying again…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
        }
    }

    /// Port taken (often an older copy or a test helper still running): say so and try again shortly.
    private func failed(_ e: NWError) {
        listener?.cancel()
        listener = nil
        if case .posix(let code) = e, code == .EADDRINUSE {
            setStatus("Port \(Settings.port) is in use by another app. Trying again…")
        } else {
            setStatus("Could not start (\(e)). Trying again…")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
    }

    private func setStatus(_ s: String) {
        if s != status { Log.write(s) }   // don't fill the log while retrying
        status = s
        onStatus?(s)
    }

    // MARK: reading requests

    private let headerEnd = Data("\r\n\r\n".utf8)

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self = self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let r = buf.range(of: self.headerEnd) {
                let head = String(decoding: buf.subdata(in: buf.startIndex..<r.lowerBound), as: UTF8.self)
                var length = 0
                for l in head.components(separatedBy: "\r\n") where l.lowercased().hasPrefix("content-length:") {
                    length = Int(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                }
                let bodyStart = r.upperBound
                if buf.endIndex - bodyStart >= length {
                    let body = buf.subdata(in: bodyStart..<(bodyStart + length))
                    self.handle(conn, head, body)
                    return
                }
            }
            if done || err != nil || buf.count > 1_000_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buf)
            }
        }
    }

    // MARK: answering

    private func reply(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: X-Helper-Key, Content-Type\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func json(_ conn: NWConnection, _ obj: [String: Any], _ status: String = "200 OK") {
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        reply(conn, status, "application/json", body)
    }

    private func handle(_ conn: NWConnection, _ head: String, _ body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return json(conn, ["error": "bad request"], "400 Bad Request") }
        let method = String(parts[0])
        let comps = URLComponents(string: "http://localhost" + String(parts[1]))
        let path = comps?.path ?? ""
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }

        if method == "OPTIONS" { return reply(conn, "204 No Content", "text/plain", Data()) }
        let paired = headers["x-helper-key"] == Settings.pairingKey

        switch (method, path) {
        case ("GET", "/ping"):
            return json(conn, ["ok": true, "app": "Figma Friend", "version": Settings.version, "paired": paired])
        case ("POST", "/pair"):
            return pair(conn, body)
        default:
            break
        }

        guard paired else {
            Log.write("refused \(method) \(path): pairing key missing or wrong")
            return json(conn, ["error": "not paired"], "401 Unauthorized")
        }

        switch (method, path) {
        case ("GET", "/fonts/files"):
            let family = query["family"] ?? "", style = query["style"] ?? ""
            json(conn, ["family": family, "style": style, "files": FontLookup.candidates(family: family, style: style)])
        case ("POST", "/fonts/prepare"):
            prepare(conn, body)
        case ("POST", "/fonts/charset"):
            charset(conn, body)
        case ("POST", "/save"):
            save(conn, name: query["name"] ?? "Untitled.pdf", data: body)
        default:
            json(conn, ["error": "unknown path"], "404 Not Found")
        }
    }

    // MARK: pairing

    private var pairing = false

    private func pair(_ conn: NWConnection, _ body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let plugin = (obj?["plugin"] as? String) ?? "A Figma plugin"
        if pairing { return json(conn, ["error": "another request is waiting for an answer"], "409 Conflict") }
        pairing = true
        Dialogs.askToPair(plugin: plugin) { [weak self] allowed in
            self?.pairing = false
            if allowed {
                Log.write("paired: \(plugin)")
                self?.json(conn, ["key": Settings.pairingKey])
            } else {
                Log.write("pairing declined: \(plugin)")
                self?.json(conn, ["error": "declined"], "403 Forbidden")
            }
        }
    }

    // MARK: fonts

    private func prepare(_ conn: NWConnection, _ body: Data) {
        guard var req = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let family = req["family"] as? String, let style = req["style"] as? String,
              req["glyphs"] is [Any]
        else { return json(conn, ["error": "family, style and glyphs are required"], "400 Bad Request") }

        let started = Date()
        let files = FontLookup.candidates(family: family, style: style)
        if files.isEmpty {
            Log.write("not installed: \(family) \(style)")
            return json(conn, ["ok": false, "error": "not installed", "family": family, "style": style])
        }
        req["op"] = "prepare"
        req["candidates"] = files
        Worker.shared.ask(req) { [weak self] result in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch result {
            case .success(let data):
                Log.write("prepared \(family) \(style) in \(ms) ms")
                self?.reply(conn, "200 OK", "application/json", data)
            case .failure(let e):
                Log.write("could not prepare \(family) \(style): \(e)")
                self?.json(conn, ["ok": false, "error": "\(e)"], "500 Internal Server Error")
            }
        }
    }

    /// Every character the installed font maps, for a glyph list. Read fresh from the file.
    private func charset(_ conn: NWConnection, _ body: Data) {
        guard let req = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let family = req["family"] as? String, let style = req["style"] as? String
        else { return json(conn, ["error": "family and style are required"], "400 Bad Request") }

        let files = FontLookup.candidates(family: family, style: style)
        if files.isEmpty {
            Log.write("not installed: \(family) \(style)")
            return json(conn, ["ok": false, "error": "not installed", "family": family, "style": style])
        }
        Worker.shared.ask(["op": "charset", "candidates": files]) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    Log.write("listed the characters of \(family) \(style)")
                    self?.reply(conn, "200 OK", "application/json", data)
                case .failure(let e):
                    Log.write("could not list the characters of \(family) \(style): \(e)")
                    self?.json(conn, ["ok": false, "error": "\(e)"], "500 Internal Server Error")
                }
            }
        }
    }

    // MARK: saving

    /// Shows the save dialog at once. A PDF is made smaller meanwhile (unless turned off in the
    /// menu), with PDF Compressor's method; if that fails or saves nothing, the file is saved as sent.
    private func save(_ conn: NWConnection, name: String, data: Data) {
        let shrink = Settings.shrinkPDFs && name.lowercased().hasSuffix(".pdf")
        var ready: Data? = shrink ? nil : data
        var waiting: ((Data) -> Void)?
        if shrink {
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                var out = data
                do {
                    let (smaller, images) = try Compressor.compress(data: data)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    if smaller.count < data.count {
                        out = smaller
                        Log.write("made the PDF smaller: \(data.count) to \(smaller.count) bytes, \(images) images, \(ms) ms")
                    }
                } catch {
                    Log.write("kept the PDF as it was: \(error.localizedDescription)")
                }
                DispatchQueue.main.async {
                    ready = out
                    waiting?(out)
                }
            }
        }
        let original = data.count
        Dialogs.save(name: name, data: { done in
            if let d = ready { done(d) } else { waiting = done }
        }) { [weak self] result in
            var r = result
            r["sentBytes"] = original
            self?.json(conn, r)
        }
    }
}
