import Foundation

enum WorkerError: Error, CustomStringConvertible {
    case notFound(String)
    case stopped(String)

    var description: String {
        switch self {
        case .notFound(let s): return "font worker not found: \(s)"
        case .stopped(let s): return "font worker stopped: \(s)"
        }
    }
}

/// Runs the font work (fontwork.py, built into a standalone program inside the app) as a
/// long-lived child process. Requests are JSON lines in and JSON lines out, one at a time.
final class Worker {
    static let shared = Worker()

    private let queue = DispatchQueue(label: "font-worker")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 1

    /// The program to run: the bundled worker in the app, or, when run with `swift run`,
    /// Python with Resources/fontwork.py (set FONT_HELPER_PYTHON to pick a Python).
    private func command() throws -> (URL, [String]) {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("fontwork/fontwork")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return (bundled, []) }
        }
        let env = ProcessInfo.processInfo.environment
        let script = env["FONT_HELPER_WORKER"]
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/fontwork.py").path
        guard FileManager.default.fileExists(atPath: script) else { throw WorkerError.notFound(script) }
        let python = env["FONT_HELPER_PYTHON"] ?? "/usr/bin/python3"
        return (URL(fileURLWithPath: python), [script])
    }

    private func start() throws {
        let (exe, args) = try command()
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { Log.write("worker: " + String(decoding: d, as: UTF8.self).trimmingCharacters(in: .newlines)) }
        }
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        buffer = Data()
        Log.write("font worker started: \(exe.path) \(args.joined(separator: " "))")
    }

    private func readLine() throws -> Data {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<i)
                buffer = buffer.subdata(in: (i + 1)..<buffer.endIndex)
                return line
            }
            guard let chunk = output?.availableData, !chunk.isEmpty else {
                throw WorkerError.stopped("no answer")
            }
            buffer.append(chunk)
        }
    }

    private func send(_ request: [String: Any]) throws -> Data {
        if process == nil || process?.isRunning == false { try start() }
        var req = request
        req["id"] = nextID
        nextID += 1
        var line = try JSONSerialization.data(withJSONObject: req)
        line.append(0x0A)
        try input?.write(contentsOf: line)
        return try readLine()
    }

    /// Sends one request and returns the worker's JSON answer. Restarts the worker once if it died.
    func ask(_ request: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            do {
                completion(.success(try self.send(request)))
            } catch {
                Log.write("font worker problem: \(error); restarting it")
                self.process?.terminate()
                self.process = nil
                do {
                    completion(.success(try self.send(request)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    func stop() {
        queue.sync {
            process?.terminate()
            process = nil
        }
    }
}
