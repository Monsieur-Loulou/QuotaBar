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
        guard timeout.isFinite, timeout > 0, timeout <= 120, capacity > 0, capacity <= 1_048_576 else {
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

public struct HelperReader: Sendable {
    public let path: String
    public let configPath: String
    public init(path: String, configPath: String) { self.path = path; self.configPath = configPath }

    public static func bundledHelper(in appURL: URL = Bundle.main.bundleURL) -> String? {
        guard appURL.pathExtension == "app" else { return nil }
        let root = appURL.resolvingSymlinksInPath()
        let helper = root.appendingPathComponent("Contents/Helpers/CodexBarCLI").resolvingSymlinksInPath()
        guard helper.path.hasPrefix(root.path + "/Contents/Helpers/"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        return helper.path
    }

    // Deliberately omit inherited API keys, tokens, proxy overrides and verbose logging.
    // The bundled signed helper owns authentication; QuotaBar never opens credential storage.
    private var environment: [String: String] {
        [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LANG": "en_US.UTF-8", "CODEXBAR_CONFIG": configPath,
        ]
    }

    /// `allowPrompt` is for an explicit user action only. If Claude fails, the reader may then show
    /// the macOS Keychain dialog for the browser's cookie key once, and the read is retried.
    public func fetch(_ provider: Provider, allowPrompt: Bool = false) async throws -> QuotaSnapshot {
        do { return try await read(provider) }
        catch QuotaError.unavailable where allowPrompt && provider == .claude {
            // Leaves time to type the Mac password; the reader never prints cookie values.
            _ = try await BoundedProcess.run(path: path, arguments: [
                "cookie", "refresh", "--provider", "claude", "--allow-keychain-prompt", "--format", "json", "--json-only",
            ], environment: environment, timeout: 120)
            return try await read(provider)
        }
    }

    private func read(_ provider: Provider) async throws -> QuotaSnapshot {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw QuotaError.helperMissing }
        let result = try await BoundedProcess.run(path: path, arguments: [
            "usage", "--provider", provider.rawValue, "--source", provider == .claude ? "web" : "oauth",
            "--format", "json", "--json-only", "--no-color",
        ], environment: environment)
        guard result.exitStatus == 0 else { throw QuotaError.unavailable }
        return try QuotaDecoder.decode(result.data, for: provider)
    }
}
