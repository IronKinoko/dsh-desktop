import Combine
import Darwin
import Foundation

enum DSHWebState: Equatable {
    case starting
    case running(URL)
    case failed(String)
}

@MainActor
final class DSHWebService: ObservableObject {
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
        process.arguments = ["-c", "exec \"$DSH_EXECUTABLE\" web --no-open"]
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

    private func processEnvironment() -> [String: String] {
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

    private func dshExecutable(in paths: [String]) -> URL? {
        let searchPaths = paths.flatMap { path -> [String] in
            guard path.hasSuffix("/fnm_multishells") else { return [path] }
            return (try? FileManager.default.contentsOfDirectory(atPath: path))?
                .map { (path as NSString).appendingPathComponent($0) } ?? [path]
        }

        return searchPaths
            .map { URL(fileURLWithPath: $0).appendingPathComponent("dsh") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private enum PortClearResult {
        case cleared
        case blocked(String)
    }

    private func clearExistingWebService() -> PortClearResult {
        let listenerPIDs = listeningPIDs(onPort: 3080)
        guard !listenerPIDs.isEmpty else {
            return .cleared
        }

        guard listenerPIDs.allSatisfy(isDshWebProcess) else {
            return .blocked(
                "Port 3080 is already in use by another process. Close it and reopen the app."
            )
        }

        listenerPIDs.forEach { kill($0, SIGTERM) }

        for _ in 0..<20 where listenerPIDs.contains(where: processExists) {
            usleep(50_000)
        }

        for pid in listenerPIDs where processExists(pid) {
            kill(pid, SIGKILL)
        }

        for _ in 0..<20 where !listeningPIDs(onPort: 3080).isEmpty {
            usleep(50_000)
        }

        guard listeningPIDs(onPort: 3080).isEmpty else {
            return .blocked(
                "Unable to free port 3080 from the previous dsh web process."
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
        return command == "dsh web --no-open"
            || command.hasSuffix("/dsh web --no-open")
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
