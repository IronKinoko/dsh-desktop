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

        killProcessListeningOnPort3080()

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "exec dsh web --no-open"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
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
                self.consumeStandardOutput(output)
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
                self.consumeStandardError(output)
            }
        }

        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            guard let self else { return }
            Task { @MainActor in
                self.processDidTerminate(status: status)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func killProcessListeningOnPort3080() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            """
            kill -9 $(lsof -t -i :3080)
            """
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()
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

    private func consumeStandardOutput(_ output: String) {
        standardOutput += output

        while let newline = standardOutput.firstIndex(of: "\n") {
            let line = String(standardOutput[..<newline])
            standardOutput.removeSubrange(...newline)

            if let url = webURL(from: line) {
                state = .running(url)
            }
        }
    }

    private func consumeStandardError(_ output: String) {
        standardError += output
        if standardError.count > 4_000 {
            standardError = String(standardError.suffix(4_000))
        }
    }

    private func processDidTerminate(status: Int32) {
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
