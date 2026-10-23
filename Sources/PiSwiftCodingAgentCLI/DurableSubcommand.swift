import ArgumentParser
import Foundation
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftCodingAgentTui
import PiSwiftDurable

struct DurableSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "durable",
        abstract: "Start a durable coding session",
        shouldDisplay: false
    )

    @Flag(name: [.customShort("c"), .customLong("continue")], help: "Continue the previous durable session")
    var continueSession = false

    static func checkTerminalResult(_ result: SessionCloseResult,
                                    report: (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }) throws {
        if case .failed(let error) = result {
            let cause = (error as? SessionFailed)?.cause ?? error
            report((cause as? any LocalizedError)?.errorDescription ?? String(describing: cause))
            throw ExitCode.failure
        }
    }

    mutating func run() async throws {
        markCodingAgentEnvironment()
        time("start")
        let durable = try await openDurable(OpenDurableOptions(continueSession: continueSession))
        initializeStartupTheme(durable.settings, enableWatcher: true)
        try Self.checkTerminalResult(await runDurableTui(durable))
    }
}
