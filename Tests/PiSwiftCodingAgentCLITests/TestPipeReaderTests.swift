import Foundation
import Testing

@Test(.timeLimit(.minutes(1)))
func testPipeReaderDrainsLargeOutputAndError() throws {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2"]
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    let outputReader = TestPipeReader(stdout)
    let errorReader = TestPipeReader(stderr)
    let output = outputReader.wait()
    let error = errorReader.wait()
    process.waitUntilExit()

    #expect(output.count == 1_048_576)
    #expect(error.count == 1_048_576)
    #expect(process.terminationStatus == 0)
}
