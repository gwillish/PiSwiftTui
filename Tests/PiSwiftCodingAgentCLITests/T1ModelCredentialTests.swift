import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

private struct T1ModelFixture {
    let source = "t1-model-\(UUID().uuidString)"
    let auth = AuthStorage.inMemory()
    let registry: ModelRegistry

    init() {
        registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    }

    func add(_ provider: String, ids: [String], key: String? = nil) {
        registry.registerProvider(HookProviderConfig(
            provider: provider,
            api: .openAICompletions,
            baseUrl: "https://example.invalid",
            apiKey: key,
            models: ids.map { HookProviderModel(id: $0) }
        ), sourceId: source)
    }

    func close() {
        registry.unregisterProviders(sourceId: source)
    }
}

@Suite("T1 CLI model and credential selection")
struct T1ModelCredentialTests {
    @Test func inlineKeyAllowsSelectionBeforeKeyInstallation() async throws {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        let provider = fixture.source
        fixture.add(provider, ids: ["first-model"])
        var args = Args()
        args.provider = provider
        args.model = "first-model:high"
        args.apiKey = "inline-test-key"

        let result = await resolveStartupCliModel(args, fixture.registry)
        let model = try #require(result.model)
        #expect(result.error == nil)
        #expect(model.provider == provider)
        #expect(model.id == "first-model")
        #expect(result.thinkingLevel == .high)
        #expect(fixture.registry.hasConfiguredAuth(model) == false)
        #expect(await fixture.registry.isAvailable(model) == false)
        #expect(fixture.auth.listCredentials().isEmpty)

        fixture.auth.setRuntimeApiKey(provider, args.apiKey!)
        #expect(await fixture.registry.isAvailable(model))
    }

    @Test func selectionWithoutAnInlineKeyStillRequiresConfiguredAuth() async {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        fixture.add(fixture.source, ids: ["first-model"])
        var args = Args()
        args.provider = fixture.source
        args.model = "first-model"
        let result = await resolveStartupCliModel(args, fixture.registry)
        #expect(result.error == "Model \(fixture.source)/first-model is not available for the configured account.")
    }

    @Test func customFallbackKeepsTheReturnedModelAndThinking() async throws {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        fixture.add(fixture.source, ids: ["catalog-model"])
        var args = Args()
        args.provider = fixture.source
        args.model = "future-model:high"
        args.apiKey = "inline-test-key"
        let result = await resolveStartupCliModel(args, fixture.registry)
        let model = try #require(result.model)
        #expect(result.error == nil)
        #expect(model.id == "future-model")
        #expect(model.provider == fixture.source)
        #expect(model.api == .openAICompletions)
        #expect(model.baseUrl == "https://example.invalid")
        #expect(model.reasoning)
        #expect(result.thinkingLevel == .high)
        #expect(result.warning == "Model \"future-model\" not found for provider \"\(fixture.source)\". Using custom model id.")
        #expect(fixture.registry.find(fixture.source, model.id) == nil)
        #expect(fixture.auth.listCredentials().isEmpty)
    }

    @Test func explicitThinkingPreservesTheFallbackLiteralSuffix() async {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        fixture.add(fixture.source, ids: ["catalog-model"])
        var args = Args()
        args.provider = fixture.source
        args.model = "future-model:high"
        args.thinking = .medium
        args.apiKey = "inline-test-key"
        let result = await resolveStartupCliModel(args, fixture.registry)
        #expect(result.error == nil)
        #expect(result.model?.id == "future-model:high")
        #expect(result.model?.reasoning == true)
        #expect(result.thinkingLevel == nil)
    }

    @Test func ambiguityReportsExactAuthenticationAndInlineKeyHints() async {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        let providers = [fixture.source + "-a", fixture.source + "-b"]
        for provider in providers { fixture.add(provider, ids: [fixture.source]) }
        var args = Args()
        args.model = fixture.source
        let prefix = "Model \"\(fixture.source)\" is ambiguous across providers: \(providers[0])/\(fixture.source), \(providers[1])/\(fixture.source). "
        let suffix = " Use --provider or provider/model."
        let unauthenticated = await resolveStartupCliModel(args, fixture.registry)
        #expect(unauthenticated.error == prefix + "No matching provider is authenticated." + suffix)

        fixture.auth.setRuntimeApiKey(providers[1], "stored-test-key")
        let selected = await resolveStartupCliModel(args, fixture.registry)
        #expect(selected.model?.provider == providers[1])
        args.apiKey = "inline-test-key"
        let inline = await resolveStartupCliModel(args, fixture.registry)
        #expect(inline.model == nil)
        #expect(inline.error == prefix + "--api-key does not choose a provider." + suffix)

        args.apiKey = nil
        fixture.auth.setRuntimeApiKey(providers[0], "other-stored-test-key")
        let multiple = await resolveStartupCliModel(args, fixture.registry)
        #expect(multiple.error == prefix + "More than one matching provider is authenticated." + suffix)
    }

    @Test func scopeDiagnosticsKeepExactWarningsAndEveryAmbiguousMatch() async {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        let providers = [fixture.source + "-a", fixture.source + "-b"]
        for provider in providers { fixture.add(provider, ids: [fixture.source], key: "test-key") }
        let invalid = "\(providers[0])/\(fixture.source):invalid"
        let missing = fixture.source + "-missing"
        let scope = await resolveModelScopeWithDiagnostics([fixture.source, invalid, missing], fixture.registry)
        #expect(scope.scopedModels.map(\.model.provider).sorted() == providers)
        #expect(modelScopeWarningLines(scope.diagnostics) == [
            "Warning: Pattern \"\(fixture.source)\" matches several providers: \(providers.joined(separator: ", ")). Use provider/id to choose one.",
            "Warning: Invalid thinking level \"invalid\" in pattern \"\(invalid)\". Using default instead.",
            "Warning: No models match pattern \"\(missing)\"",
        ])
    }

    // pi-mono v1.3.0 credential-print.test.ts:27.
    @Test func modelOnlyCredentialPrintUsesCatalogModelsOfConfiguredProviders() async {
        let auth = AuthStorage.inMemory([
            "openai": .apiKey(ApiKeyCredential(key: "openai-test-key")),
            "anthropic": .apiKey(ApiKeyCredential(key: "anthropic-test-key")),
        ])
        let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let result = await runCredentialPrint(kind: .apiKey, provider: nil, model: "gpt-5.5",
                                             registry: registry, authStorage: auth)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "openai-test-key")
        #expect(result.stderr == nil)
    }

    @Test func modelOnlyCredentialPrintRejectsCustomIdsButExplicitProviderAllowsThem() async {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        fixture.add(fixture.source, ids: ["catalog-model"])
        fixture.auth.set(fixture.source, credential: .apiKey(ApiKeyCredential(key: "test-key")))
        let model = "\(fixture.source)/future-model:high"
        let strict = await runCredentialPrint(kind: .apiKey, provider: nil, model: model,
                                             registry: fixture.registry, authStorage: fixture.auth)
        #expect(strict.exitCode == 1)
        #expect(strict.stdout == nil)
        #expect(strict.stderr == "Model \"\(model)\" not found. Use --list-models to see available models.")
        let explicit = await runCredentialPrint(kind: .apiKey, provider: fixture.source, model: "future-model:high",
                                               registry: fixture.registry, authStorage: fixture.auth)
        #expect(explicit.exitCode == 0)
        #expect(explicit.stdout == "test-key")
        #expect(explicit.stderr == nil)
        let check = await runAuthCheck(provider: fixture.source, model: "future-model:high", showCredential: false,
                                       registry: fixture.registry, authStorage: fixture.auth)
        #expect(check.exitCode == 0)
    }

    @Test func modelOnlyCredentialPrintEvaluatesEveryUsableProvider() async {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        let providers = [fixture.source + "-a", fixture.source + "-b"]
        for provider in providers { fixture.add(provider, ids: [fixture.source]) }
        fixture.auth.set(providers[0], credential: .apiKey(ApiKeyCredential(key: " ")))
        fixture.auth.set(providers[1], credential: .apiKey(ApiKeyCredential(key: "second-test-key")))
        let single = await runCredentialPrint(kind: .apiKey, provider: nil, model: fixture.source,
                                             registry: fixture.registry, authStorage: fixture.auth)
        #expect(single.exitCode == 0)
        #expect(single.stdout == "second-test-key")
        fixture.auth.set(providers[0], credential: .apiKey(ApiKeyCredential(key: "first-test-key")))
        let multiple = await runCredentialPrint(kind: .apiKey, provider: nil, model: fixture.source,
                                               registry: fixture.registry, authStorage: fixture.auth)
        #expect(multiple.exitCode == 1)
        #expect(multiple.stdout == nil)
        #expect(multiple.stderr == "Multiple configured providers matched (\(providers.joined(separator: ", "))). Specify --provider.")
    }

    @Test func modelOnlyCredentialPrintSkipsWrongCredentialTypesAndRejectsInvalidSuffixes() async {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        let providers = [fixture.source + "-a", fixture.source + "-b"]
        for provider in providers { fixture.add(provider, ids: [fixture.source]) }
        fixture.auth.set(providers[0], credential: .oauth(OAuthCredential(
            access: "must-not-print", refresh: "unused", expires: Date().timeIntervalSince1970 * 1000 + 3_600_000)))
        fixture.auth.set(providers[1], credential: .apiKey(ApiKeyCredential(key: "api-test-key")))
        let single = await runCredentialPrint(kind: .apiKey, provider: nil, model: fixture.source + ":high",
                                             registry: fixture.registry, authStorage: fixture.auth)
        #expect(single.exitCode == 0)
        #expect(single.stdout == "api-test-key")
        let invalidModel = fixture.source + ":invalid"
        let invalid = await runCredentialPrint(kind: .apiKey, provider: nil, model: invalidModel,
                                              registry: fixture.registry, authStorage: fixture.auth)
        #expect(invalid.exitCode == 1)
        #expect(invalid.stderr == "Model \"\(invalidModel)\" not found. Use --list-models to see available models.")
        fixture.auth.remove(providers[1])
        let unusable = await runCredentialPrint(kind: .apiKey, provider: nil, model: fixture.source,
                                               registry: fixture.registry, authStorage: fixture.auth)
        #expect(unusable.exitCode == 1)
        #expect(unusable.stdout == nil)
        #expect(unusable.stderr == "No usable API key is configured")
    }

    @Test func modelOnlyCredentialSubcommandKeepsStdoutPipeable() throws {
        let root = try t1ModelProcessDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = [
            "openai": ["type": "api_key", "key": "process-openai-key"],
            "anthropic": ["type": "api_key", "key": "process-anthropic-key"],
        ]
        try JSONSerialization.data(withJSONObject: auth).write(to: root.appendingPathComponent("auth.json"))
        let result = try t1RunModelCLI(["auth", "print-api-key", "--model", "gpt-5.5"], root: root)
        #expect(result.code == 0)
        #expect(result.output == "process-openai-key\n")
        #expect(result.error.isEmpty)
    }

    @Test func modelOnlyBearerPrintEvaluatesValidityForEveryProvider() async {
        let fixture = T1ModelFixture()
        defer { fixture.close() }
        let providers = [fixture.source + "-a", fixture.source + "-b"]
        let now = Date().timeIntervalSince1970 * 1000
        for provider in providers { fixture.add(provider, ids: [fixture.source]) }
        fixture.auth.set(providers[0], credential: .oauth(OAuthCredential(
            access: "too-short", refresh: nil, expires: now + 1000)))
        fixture.auth.set(providers[1], credential: .oauth(OAuthCredential(
            access: "usable-token", refresh: nil, expires: now + 3_600_000)))
        let single = await runCredentialPrint(kind: .bearerToken, provider: nil, model: fixture.source,
                                             minimumOAuthValidityMs: 1_800_000,
                                             registry: fixture.registry, authStorage: fixture.auth)
        #expect(single.exitCode == 0)
        #expect(single.stdout == "usable-token")
        fixture.auth.set(providers[0], credential: .oauth(OAuthCredential(
            access: "other-usable-token", refresh: nil, expires: now + 3_600_000)))
        let multiple = await runCredentialPrint(kind: .bearerToken, provider: nil, model: fixture.source,
                                               minimumOAuthValidityMs: 1_800_000,
                                               registry: fixture.registry, authStorage: fixture.auth)
        #expect(multiple.exitCode == 1)
        #expect(multiple.stdout == nil)
        #expect(multiple.stderr == "Multiple configured providers matched (\(providers.joined(separator: ", "))). Specify --provider.")
        fixture.auth.remove(providers[0])
        fixture.auth.set(providers[1], credential: .apiKey(ApiKeyCredential(key: "wrong-type")))
        let unavailable = await runCredentialPrint(kind: .bearerToken, provider: nil, model: fixture.source,
                                                  registry: fixture.registry, authStorage: fixture.auth)
        #expect(unavailable.exitCode == 1)
        #expect(unavailable.stderr == "No usable OAuth bearer token is configured")
    }

    @Test func cliPrintsScopeWarningsAndRejectsInlineKeyProviderAmbiguity() throws {
        let root = try t1ModelProcessDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let providers = ["t1-process-a", "t1-process-b"]
        let shared = "t1-process-shared"
        var definitions: [String: Any] = [:]
        for provider in providers {
            definitions[provider] = [
                "api": "openai-completions", "baseUrl": "https://example.invalid",
                "apiKey": "configured-test-key", "models": [["id": shared]],
            ]
        }
        try JSONSerialization.data(withJSONObject: ["providers": definitions])
            .write(to: root.appendingPathComponent("models.json"))
        let result = try t1RunModelCLI([
            "--print", "--no-session", "--no-extensions", "--no-approve", "--offline",
            "--models", shared + ":invalid,t1-process-missing", "--model", shared,
            "--api-key", "inline-test-key",
        ], root: root)
        #expect(result.code == 1)
        #expect(result.output.isEmpty)
        #expect(result.error.contains("Warning: Invalid thinking level \"invalid\" in pattern \"\(shared):invalid\". Using default instead.\n"))
        #expect(result.error.contains("Warning: Pattern \"\(shared):invalid\" matches several providers: t1-process-a, t1-process-b. Use provider/id to choose one.\n"))
        #expect(result.error.contains("Warning: No models match pattern \"t1-process-missing\"\n"))
        #expect(result.error.contains("Model \"\(shared)\" is ambiguous across providers: t1-process-a/\(shared), t1-process-b/\(shared). --api-key does not choose a provider. Use --provider or provider/model.\n"))
    }
}

private func t1ModelProcessDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t1-model-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func t1RunModelCLI(_ arguments: [String], root: URL) throws -> (code: Int32, output: String, error: String) {
    let binaryDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [binaryDirectory.appendingPathComponent("pi-coding-agent"),
                      repo.appendingPathComponent(".build/debug/pi-coding-agent"),
                      repo.appendingPathComponent(".build/out/Products/Debug/pi-coding-agent")]
    let process = Process()
    process.executableURL = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    process.arguments = arguments
    process.currentDirectoryURL = root
    var environment = ProcessInfo.processInfo.environment
    environment[ENV_AGENT_DIR] = root.path
    environment["NO_COLOR"] = "1"
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let outputReader = TestPipeReader(output)
    let errorReader = TestPipeReader(error)
    let outputData = outputReader.wait()
    let errorData = errorReader.wait()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: outputData, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
}
