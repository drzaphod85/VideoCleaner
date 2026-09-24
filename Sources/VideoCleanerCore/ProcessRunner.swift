// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

/// Collects pipe output and optionally reports it line by line (splits on \n and \r).
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var all = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        all.append(data)
        if onLine != nil {
            buffer.append(data)
            while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = buffer[buffer.startIndex..<i]
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
                buffer.removeSubrange(buffer.startIndex...i)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func finish() -> String {
        lock.lock()
        let rest = buffer
        buffer = Data()
        let text = String(decoding: all, as: UTF8.self)
        lock.unlock()
        if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
        return text
    }
}

private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    let process: Process
    private var launched = false
    private var cancelled = false

    init(_ process: Process) { self.process = process }

    func launch() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        launched = true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = launched
        lock.unlock()
        if running && process.isRunning { process.terminate() }
    }

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public enum ProcessRunner {
    /// Runs an external tool. Cancelling the calling task terminates the process and throws `CancellationError`.
    public static func run(_ executable: URL, _ arguments: [String],
                           onStdoutLine: (@Sendable (String) -> Void)? = nil,
                           onStderrLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = LineCollector(onLine: onStdoutLine)
        let err = LineCollector(onLine: onStderrLine)
        let state = ProcessState(process)

        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    let result = CommandResult(status: p.terminationStatus, stdout: out.finish(), stderr: err.finish())
                    if state.wasCancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(returning: result)
                    }
                }
                do {
                    try state.launch()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Quotes a command line for display in logs (copy-pasteable into a shell).
    public static func shellLine(_ executable: URL, _ arguments: [String]) -> String {
        ([executable.lastPathComponent] + arguments).map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=,+%@")
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
