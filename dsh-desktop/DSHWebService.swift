import Combine
import Darwin
import Foundation

enum DSHWebState: Equatable {
    case starting
    case updating(DSHUpdateProgress)
    case running(URL)
    case failed(String)
}

struct DSHUpdateProgress: Equatable {
    let tag: String
    let command: String
    var output: String
}

struct DSHVersionTag: Equatable {
    let name: String
    let version: String
    let publishedAt: Date?
}

private enum DSHCommandError: LocalizedError {
    case executableNotFound(String)
    case commandFailed(String, Int32, String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "Unable to find \(name)."
        case .commandFailed(let command, let status, let details):
            let suffix = details.isEmpty ? "" : "\n\(details)"
            return "\(command) exited with status \(status).\(suffix)"
        case .invalidOutput(let message):
            return message
        }
    }
}

private struct DSHCommandResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

@MainActor
final class DSHWebService: ObservableObject {
    private static let webPort = 49258

    @Published private(set) var state: DSHWebState = .starting
    @Published private(set) var reloadID = 0

    private var process: Process?
    private var standardOutput = ""
    private var standardError = ""
    private var isStopping = false

    func start() {
        guard process == nil else { return }

        state = .starting
        isStopping = false
        standardOutput = ""
        standardError = ""

        switch clearExistingWebService() {
        case .cleared:
            launchProcess()
        case .blocked(let message):
            state = .failed(message)
        }
    }

    private func launchProcess() {
        let process = Process()
        let processID = ObjectIdentifier(process)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let environment = processEnvironment()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "exec \"$DSH_EXECUTABLE\" web --no-open --port \(Self.webPort)"
        ]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            let output = String(decoding: data, as: UTF8.self)
            guard let self else { return }
            Task { @MainActor in
                self.consumeStandardOutput(output, from: processID)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            let output = String(decoding: data, as: UTF8.self)
            guard let self else { return }
            Task { @MainActor in
                self.consumeStandardError(output, from: processID)
            }
        }

        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            guard let self else { return }
            Task { @MainActor in
                self.processDidTerminate(process, status: status)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private nonisolated func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser

        var paths = [
            home.appendingPathComponent(".local/share/fnm/aliases/default/bin").path,
            home.appendingPathComponent(".local/state/fnm_multishells").path,
            home.appendingPathComponent(".volta/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        if let path = environment["PATH"] {
            paths.insert(contentsOf: path.split(separator: ":").map(String.init), at: 0)
        }

        var seen = Set<String>()
        environment["PATH"] = paths
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")

        if let dshExecutable = dshExecutable(in: paths) {
            environment["DSH_EXECUTABLE"] = dshExecutable.path
        } else {
            environment["DSH_EXECUTABLE"] = "dsh"
        }

        return environment
    }

    private nonisolated func dshExecutable(in paths: [String]) -> URL? {
        executable(named: "dsh", in: paths)
    }

    private nonisolated func executable(named name: String, in paths: [String]) -> URL? {
        let searchPaths = paths.flatMap { path -> [String] in
            guard path.hasSuffix("/fnm_multishells") else { return [path] }
            return (try? FileManager.default.contentsOfDirectory(atPath: path))?
                .map { (path as NSString).appendingPathComponent($0) } ?? [path]
        }

        return searchPaths
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated func availableVersionTags() async throws -> [DSHVersionTag] {
        let npm = try npmCommand()
        let result = try await Self.runCommand(
            executableURL: npm.executableURL,
            arguments: ["view", "@deepseek-ai/dsh", "time", "dist-tags", "--json"],
            environment: npm.environment
        )

        guard result.status == 0 else {
            throw DSHCommandError.commandFailed(
                "npm view",
                result.status,
                lastLines(of: result.standardError)
            )
        }

        guard let data = result.standardOutput.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTags = response["dist-tags"] as? [String: String]
        else {
            throw DSHCommandError.invalidOutput(
                "npm view returned an invalid time and dist-tags response."
            )
        }

        let rawTimes = response["time"] as? [String: String] ?? [:]
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return rawTags
            .map { name, version in
                DSHVersionTag(
                    name: name,
                    version: version,
                    publishedAt: rawTimes[version].flatMap(dateFormatter.date(from:))
                )
            }
            .sorted(by: versionTagSort)
    }

    func update(to tag: String) async throws {
        guard tag.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw DSHCommandError.invalidOutput("Invalid npm tag: \(tag)")
        }

        let command = "npm install --global @deepseek-ai/dsh@\(tag)"
        state = .updating(
            DSHUpdateProgress(
                tag: tag,
                command: command,
                output: "Stopping dsh web...\n"
            )
        )
        await stopForUpdate()

        do {
            let npm = try npmCommand()
            var environment = npm.environment
            environment["NO_COLOR"] = "1"

            let status = try await Self.runStreamingCommand(
                executableURL: npm.executableURL,
                arguments: ["install", "--global", "@deepseek-ai/dsh@\(tag)"],
                environment: environment
            ) { [weak self] output in
                guard let self else { return }
                Task { @MainActor in
                    self.appendUpdateOutput(output)
                }
            }

            guard status == 0 else {
                throw DSHCommandError.commandFailed(
                    command,
                    status,
                    lastLines(of: updateOutput())
                )
            }

            start()
        } catch {
            start()
            throw error
        }
    }

    private func appendUpdateOutput(_ output: String) {
        guard case .updating(var progress) = state else { return }
        progress.output += output
        state = .updating(progress)
    }

    private func updateOutput() -> String {
        guard case .updating(let progress) = state else { return "" }
        return progress.output
    }

    private nonisolated func npmCommand() throws -> (
        executableURL: URL,
        environment: [String: String]
    ) {
        let environment = processEnvironment()
        let paths = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        guard let executableURL = executable(named: "npm", in: paths) else {
            throw DSHCommandError.executableNotFound("npm")
        }

        return (executableURL, environment)
    }

    private nonisolated func versionTagSort(_ lhs: DSHVersionTag, _ rhs: DSHVersionTag) -> Bool {
        let rank = ["latest": 0, "alpha": 1]
        let lhsRank = rank[lhs.name] ?? 2
        let rhsRank = rank[rhs.name] ?? 2

        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private nonisolated func lastLines(of output: String) -> String {
        output
            .split(whereSeparator: \.isNewline)
            .suffix(8)
            .joined(separator: "\n")
    }

    private nonisolated static func runCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> DSHCommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()

            async let outputData = outputPipe.fileHandleForReading.readToEnd()
            async let errorData = errorPipe.fileHandleForReading.readToEnd()

            process.waitUntilExit()

            return DSHCommandResult(
                status: process.terminationStatus,
                standardOutput: String(
                    decoding: try await outputData ?? Data(),
                    as: UTF8.self
                ),
                standardError: String(
                    decoding: try await errorData ?? Data(),
                    as: UTF8.self
                )
            )
        }.value
    }

    private nonisolated static func runStreamingCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()

            async let outputReader = streamPipe(outputPipe, onOutput: onOutput)
            async let errorReader = streamPipe(errorPipe, onOutput: onOutput)

            process.waitUntilExit()
            try await outputReader
            try await errorReader

            return process.terminationStatus
        }.value
    }

    private nonisolated static func streamPipe(
        _ pipe: Pipe,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData

                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.resume()
                    return
                }

                onOutput(String(decoding: data, as: UTF8.self))
            }
        }
    }

    private func stopForUpdate() async {
        guard let process else { return }

        isStopping = true
        let processIdentifier = process.processIdentifier
        process.terminate()

        let exited = await Self.waitForProcessToExit(
            processIdentifier,
            timeout: 2
        )

        if !exited {
            kill(processIdentifier, SIGKILL)
            _ = await Self.waitForProcessToExit(processIdentifier, timeout: 2)
        }

        self.process = nil
    }

    private nonisolated static func waitForProcessToExit(
        _ processIdentifier: pid_t,
        timeout: TimeInterval
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(timeout)

            while Date() < deadline {
                if kill(processIdentifier, 0) != 0 {
                    return true
                }
                usleep(50_000)
            }

            return kill(processIdentifier, 0) != 0
        }.value
    }

    private enum PortClearResult {
        case cleared
        case blocked(String)
    }

    private func clearExistingWebService() -> PortClearResult {
        let listenerPIDs = listeningPIDs(onPort: Self.webPort)
        guard !listenerPIDs.isEmpty else {
            return .cleared
        }

        guard listenerPIDs.allSatisfy(isDshWebProcess) else {
            return .blocked(
                "Port \(Self.webPort) is already in use by another process. Close it and reopen the app."
            )
        }

        listenerPIDs.forEach { kill($0, SIGTERM) }

        for _ in 0..<20 where listenerPIDs.contains(where: processExists) {
            usleep(50_000)
        }

        for pid in listenerPIDs where processExists(pid) {
            kill(pid, SIGKILL)
        }

        for _ in 0..<20 where !listeningPIDs(onPort: Self.webPort).isEmpty {
            usleep(50_000)
        }

        guard listeningPIDs(onPort: Self.webPort).isEmpty else {
            return .blocked(
                "Unable to free port \(Self.webPort) from the previous dsh web process."
            )
        }

        return .cleared
    }

    private func listeningPIDs(onPort port: Int) -> [pid_t] {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
    }

    private func processCommand(_ pid: pid_t) -> String {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-o", "command=", "-p", String(pid)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isDshWebProcess(_ pid: pid_t) -> Bool {
        let command = processCommand(pid)
        let expectedArguments = "web --no-open --port \(Self.webPort)"
        return command == "dsh \(expectedArguments)"
            || command.hasSuffix("/dsh \(expectedArguments)")
    }

    private func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    func stop() {
        guard let process else { return }

        isStopping = true
        let processIdentifier = process.processIdentifier

        process.terminate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard process.isRunning else { return }
            kill(processIdentifier, SIGKILL)
        }
    }

    func restart() {
        state = .starting
        standardOutput = ""
        standardError = ""

        if let process {
            isStopping = true
            let processIdentifier = process.processIdentifier
            process.terminate()

            for _ in 0..<40 where processExists(processIdentifier) {
                usleep(50_000)
            }

            if processExists(processIdentifier) {
                kill(processIdentifier, SIGKILL)
            }

            self.process = nil
        }

        start()
    }

    private func consumeStandardOutput(
        _ output: String,
        from processID: ObjectIdentifier
    ) {
        guard process.map(ObjectIdentifier.init) == processID else { return }

        standardOutput += output

        while let newline = standardOutput.firstIndex(of: "\n") {
            let line = String(standardOutput[..<newline])
            standardOutput.removeSubrange(...newline)

            if let url = webURL(from: line) {
                reloadID += 1
                state = .running(url)
            }
        }
    }

    private func consumeStandardError(
        _ output: String,
        from processID: ObjectIdentifier
    ) {
        guard process.map(ObjectIdentifier.init) == processID else { return }

        standardError += output
        if standardError.count > 4_000 {
            standardError = String(standardError.suffix(4_000))
        }
    }

    private func processDidTerminate(_ terminatedProcess: Process, status: Int32) {
        guard terminatedProcess === process else { return }
        process = nil

        guard !isStopping, case .starting = state else { return }

        let details = standardError
            .split(whereSeparator: \.isNewline)
            .suffix(6)
            .joined(separator: "\n")
        state = .failed(
            details.isEmpty
                ? "dsh web exited with status \(status)."
                : details
        )
    }

    private func webURL(from line: String) -> URL? {
        guard let range = line.range(of: #"https?://\S+"#, options: .regularExpression) else {
            return nil
        }

        let value = String(line[range])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;)]}"))
        return URL(string: value)
    }
}
