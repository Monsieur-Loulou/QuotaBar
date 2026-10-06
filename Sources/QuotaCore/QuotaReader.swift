import Foundation
import ProcessSupport

private final class Cancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = qb_cancel_create() else { throw QuotaError.helperFailed }
        self.pointer = pointer
    }
    deinit { qb_cancel_destroy(pointer) }
    func cancel() { qb_cancel_signal(pointer) }
}

public struct ProcessResult: Sendable {
    public let data: Data
    public let exitStatus: Int32
}

public enum BoundedProcess {
    /// No shell, no stderr capture, bounded stdout, cancellable process group and a hard deadline.
    public static func run(path: String, arguments: [String], environment: [String: String],
                           timeout: TimeInterval = 45, capacity: Int = 262_144) async throws -> ProcessResult {
        guard timeout.isFinite, timeout > 0, timeout <= 60, capacity > 0, capacity <= 1_048_576 else {
            throw QuotaError.helperFailed
        }
        let cancellation = try Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let argv = ([path] + arguments).map { strdup($0) } + [nil]
                    let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
                    defer {
                        argv.forEach { free($0) }
                        envp.forEach { free($0) }
                    }
                    var bytes = [UInt8](repeating: 0, count: capacity)
                    var count = 0
                    var status: Int32 = -1
                    let result = qb_run(path, argv, envp, timeout, cancellation.pointer,
                                        &bytes, capacity, &count, &status)
                    switch result {
                    case 0: continuation.resume(returning: ProcessResult(data: Data(bytes.prefix(count)), exitStatus: status))
                    case 2: continuation.resume(throwing: QuotaError.timeout)
                    case 3: continuation.resume(throwing: QuotaError.cancelled)
                    case 4: continuation.resume(throwing: QuotaError.oversizedOutput)
                    default: continuation.resume(throwing: QuotaError.helperFailed)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

/// Reads quotas from the official sources only: `codex app-server` and Claude Code's own sign-in.
/// QuotaBar never stores, logs or renews a token; Codex and Claude Code keep owning their logins.
public struct QuotaReader: Sendable {
    public let codexPath: String?
    public init(codexPath: String? = QuotaReader.codexExecutable()) { self.codexPath = codexPath }

    public static func codexExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            home + "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func fetch(_ provider: Provider) async throws -> QuotaSnapshot {
        switch provider {
        case .codex:
            guard let codexPath else { throw QuotaError.codexMissing }
            let answers = try await CodexAppServer.request(path: codexPath)
            return try QuotaDecoder.codex(account: answers.account, limits: answers.limits)
        case .claude:
            return try await ClaudeUsage.fetch()
        }
    }
}

// Inherited API keys, tokens, proxy overrides and verbose logging are deliberately left out.
private func childEnvironment(adding folder: String? = nil) -> [String: String] {
    // Codex installed with npm is a `node` script, so its own folder and Homebrew's stay reachable.
    let path = ([folder].compactMap { $0 } + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    return [
        "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        "USER": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
        "PATH": path.joined(separator: ":"), "LANG": "en_US.UTF-8",
    ]
}

/// Talks JSON-RPC to `codex app-server` over stdio. Its stdin stays open until both answers arrive:
/// on end of input the server stops answering. Then stdin closes and the server exits by itself.
public enum CodexAppServer {
    public static func request(path: String, timeout: TimeInterval = 30) async throws -> (account: Data, limits: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        process.environment = childEnvironment(adding: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exchange = Exchange(process: process, input: input, output: output)
        let answers = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.start(continuation: continuation, timeout: timeout)
            }
        } onCancel: { exchange.finish(.failure(QuotaError.cancelled)) }
        // A failed request leaves its answer out; the decoder then tells signed out from unavailable.
        guard let account = answers[2] else { throw QuotaError.codexSignedOut }
        return (account, answers[3] ?? Data(#"{"rateLimits":null}"#.utf8))
    }

    /// Every step that touches the process or its pipes runs under `lock`, so a cancellation
    /// can never interleave with startup. `finished` is checked before each of those steps.
    private final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process, input: Pipe, output: Pipe
        private var continuation: CheckedContinuation<[Int: Data], Error>?
        private var buffer = Data(), answers: [Int: Data] = [:], answered = Set<Int>(), finished = false

        init(process: Process, input: Pipe, output: Pipe) {
            self.process = process; self.input = input; self.output = output
            // A server that exits early must not kill QuotaBar with SIGPIPE on the next write.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        func start(continuation: CheckedContinuation<[Int: Data], Error>, timeout: TimeInterval) {
            lock.lock()
            guard !finished else { lock.unlock(); continuation.resume(throwing: QuotaError.cancelled); return }
            self.continuation = continuation
            // Cleared in finish(), which breaks this cycle.
            output.fileHandleForReading.readabilityHandler = { handle in self.receive(handle.availableData) }
            let requests = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"quotabar","version":"1"}}}"#,
                #"{"jsonrpc":"2.0","method":"initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"account/read","params":{"refreshToken":false}}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read"}"#,
            ].joined(separator: "\n") + "\n"
            var failure: QuotaError?
            do {
                try process.run()
                // A few hundred bytes: the pipe buffer takes them without blocking.
                try input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))
            } catch { failure = .helperFailed }
            lock.unlock()
            if let failure { finish(.failure(failure)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(QuotaError.timeout))
            }
        }

        private func receive(_ data: Data) {
            guard !data.isEmpty else { finish(.failure(QuotaError.unavailable)); return } // server exited early
            lock.lock()
            guard !finished else { lock.unlock(); return }
            buffer.append(data)
            if buffer.count > 1_048_576 { lock.unlock(); finish(.failure(QuotaError.oversizedOutput)); return }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int, id == 2 || id == 3 else { continue }
                answered.insert(id)
                // An error, a null or a bare value is no answer; isValidJSONObject avoids an uncatchable exception.
                if let result = message["result"], JSONSerialization.isValidJSONObject(result),
                   let data = try? JSONSerialization.data(withJSONObject: result) {
                    answers[id] = data
                }
            }
            let complete = answered.count == 2 ? answers : nil
            lock.unlock()
            if let complete { finish(.success(complete)) }
        }

        func finish(_ result: Result<[Int: Data], Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation; self.continuation = nil
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            let running = process.isRunning
            lock.unlock()
            if running {
                let process = self.process
                if case .failure = result { process.terminate() }
                // A clean exit follows the closed stdin; anything still running after that is killed.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            continuation?.resume(with: result)
        }
    }
}

/// Uses the sign-in Claude Code keeps in the login Keychain, through Apple's `security` tool.
/// The token stays in memory for one request and is never renewed here, so Claude Code's login is untouched.
enum ClaudeUsage {
    static func fetch() async throws -> QuotaSnapshot {
        let result = try await BoundedProcess.run(path: "/usr/bin/security", arguments: [
            "find-generic-password", "-s", "Claude Code-credentials", "-w",
        ], environment: childEnvironment(), timeout: 20, capacity: 65_536)
        guard result.exitStatus == 0 else { throw QuotaError.claudeSignedOut }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: result.data), let login = stored.claudeAiOauth,
              let token = login.accessToken, !token.isEmpty else { throw QuotaError.claudeSignedOut }
        if let expiry = login.expiresAt, Date(timeIntervalSince1970: expiry / 1000 - 60) <= Date() {
            throw QuotaError.claudeExpired
        }
        async let usage = get("https://api.anthropic.com/api/oauth/usage", token: token)
        async let profile = try? get("https://api.anthropic.com/api/oauth/profile", token: token)
        return try QuotaDecoder.claude(usage: try await usage, profile: await profile)
    }

    private struct Stored: Decodable {
        let claudeAiOauth: Login?
        struct Login: Decodable { let accessToken: String?; let expiresAt: Double? }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    private static func get(_ address: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw QuotaError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw QuotaError.cancelled }
        catch { throw QuotaError.unavailable }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: guard data.count <= 1_048_576 else { throw QuotaError.oversizedOutput }; return data
        case 401: throw QuotaError.claudeExpired
        case 403: throw QuotaError.claudeSignedOut
        default: throw QuotaError.unavailable
        }
    }
}
