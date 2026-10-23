import Darwin
import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import Testing

private enum T1PrintExitError: Error { case timeout }

@Suite("T1 print CLI exit", .timeLimit(.minutes(1)))
struct T1PrintExitTests {
    @Test(arguments: [false, true])
    func restoredTruncatedAnswerHasTheExpectedStatusAndOutput(_ json: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t1-print-exit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SessionManager.create(root.path, root.appendingPathComponent("sessions").path)
        manager.appendModelChange("anthropic", "claude-sonnet-4-5")
        manager.appendMessage(.assistant(AssistantMessage(
            content: [.text(TextContent(text: "Partial answer"))], api: .anthropicMessages,
            provider: "anthropic", model: "claude-sonnet-4-5",
            usage: Usage(input: 0, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 1), stopReason: .length)))
        let sessionFile = try #require(manager.getSessionFile())
        let binaryDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = try #require([
            binaryDirectory.appendingPathComponent("pi-coding-agent"),
            repo.appendingPathComponent(".build/debug/pi-coding-agent"),
            repo.appendingPathComponent(".build/out/Products/Debug/pi-coding-agent"),
        ].first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--session", sessionFile, "--continue", "--provider", "anthropic",
            "--model", "claude-sonnet-4-5", "--api-key", "fixture-key", "--offline",
            "--no-extensions", "--no-skills", "--no-prompt-templates", "--nc", "--print"]
            + (json ? ["--mode", "json"] : [])
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PI_CODING_AGENT_DIR": root.path,
                               "NO_COLOR": "1", "PI_HYPERLINKS": "0"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputReader = TestPipeReader(output)
        let errorReader = TestPipeReader(error)
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw T1PrintExitError.timeout
        }
        let stdout = String(decoding: outputReader.wait(), as: UTF8.self)
        let stderr = String(decoding: errorReader.wait(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == (json ? 0 : 1))
        if json {
            #expect(stdout.contains("\"type\":\"session\""))
            #expect(stderr == "")
        } else {
            #expect(stdout == "Partial answer\n")
            #expect(stderr == "Response was truncated: the model reached its output token limit.\n")
        }
    }
}
