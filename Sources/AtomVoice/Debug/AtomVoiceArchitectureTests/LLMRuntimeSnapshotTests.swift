import Foundation
@testable import AtomVoiceCore

enum LLMRuntimeSnapshotTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("LLM runtime snapshots skip credentials for disabled or inapplicable refinement") {
            try await skipsCredentials()
        }
        await runner.run("LLM runtime snapshot returns unavailable once for absent empty or failed credentials") {
            try await unavailableCredentials()
        }
        await runner.run("LLM runtime snapshot submission and metadata remain responsive during a blocked credential read") {
            try await responsiveSubmission()
        }
        await runner.run("LLM runtime snapshot waits for an in-flight connection save and reads one complete new connection") {
            try await saveBeforeRead()
        }
        await runner.run("LLM runtime read freezes one connection before a later save and the next read sees the save") {
            try await readBeforeSave()
        }
        await runner.run("LLM failed connection save leaves the runtime snapshot on the complete previous connection") {
            try await failedSave()
        }
    }

    @MainActor
    private static func skipsCredentials() async throws {
        for (enabled, engine, url) in [(false, "openai", "https://api.openai.com/v1"),
                                      (true, "apple", "https://api.openai.com/v1"),
                                      (true, "doubao", "https://api.openai.com/v1"),
                                      (true, "sherpaOnnx", "https://api.openai.com/v1"),
                                      (true, "openai", "https://fixture.invalid/v1")] {
            let store = RuntimeSnapshotKeyStore()
            let settings = fixture(store)
            settings.enabled = enabled
            settings.apiBaseURL = url
            let result = try await snapshot(settings, engine: engine)
            if case .disabled = result {} else { try expect(false, "Expected disabled snapshot") }
            try expect(store.readCount == 0)
        }
    }

    @MainActor
    private static func unavailableCredentials() async throws {
        for read in [KeychainStringReadResult.notFound, .failure(-1), .value("  \n")] {
            let store = RuntimeSnapshotKeyStore()
            store.readOverride = read
            let settings = fixture(store)
            let result = try await snapshot(settings)
            if case .unavailable = result {} else { try expect(false, "Expected unavailable snapshot") }
            try expect(store.readCount == 1 && store.writeCount == 0 && store.deleteCount == 0)
            try expect(settings.apiBaseURL == oldConnection.baseURL && settings.model == oldConnection.model)
        }
    }

    @MainActor
    private static func responsiveSubmission() async throws {
        let gate = RuntimeSnapshotGate()
        defer { gate.release() }
        let store = RuntimeSnapshotKeyStore()
        store.readGate = gate
        let settings = fixture(store)
        var result: LLMRuntimeSnapshotResult?
        var callbacks = 0
        var callbackOnMain = false
        settings.readRuntimeSnapshotAsync(forRecognitionEngine: "openai") {
            callbacks += 1
            callbackOnMain = Thread.isMainThread
            result = $0
        }
        try await waitUntil { gate.entered }
        try expect(result == nil && !gate.timedOut, "Submission must return while the read is still blocked")
        // 普通设置不取得慢凭据锁；本轮 metadata 已经在后台读取钥匙串前冻结。
        settings.systemPrompt = "later-fixture-prompt"
        settings.model = "later-fixture-model"
        settings.enabled = false
        try expect(settings.systemPrompt == "later-fixture-prompt" && !settings.enabled && !gate.timedOut)
        gate.release()
        try await waitUntil { result != nil }
        let value = try ready(result!)
        try expect(matches(value.connection, oldConnection) && value.systemPrompt == "original-fixture-prompt")
        try expect(callbacks == 1 && callbackOnMain && store.readCount == 1)
    }

    @MainActor
    private static func saveBeforeRead() async throws {
        let gate = RuntimeSnapshotGate()
        defer { gate.release() }
        let store = RuntimeSnapshotKeyStore()
        store.writeGate = gate
        let settings = fixture(store)
        let saved = RuntimeSnapshotValue<Bool>()
        DispatchQueue.global(qos: .userInitiated).async {
            saved.set(settings.saveConnection(newConnection, previousKeyRead: .value(oldConnection.apiKey)))
        }
        try await waitUntil { gate.entered }
        var result: LLMRuntimeSnapshotResult?
        settings.readRuntimeSnapshotAsync(forRecognitionEngine: "openai") { result = $0 }
        try expect(result == nil && !gate.timedOut)
        gate.release()
        try await waitUntil { saved.value != nil && result != nil }
        try expect(saved.value == true)
        try expect(matches(tryReadyConnection(result!), newConnection))
        try expect(store.readCount == 1 && store.writeCount == 1)
    }

    @MainActor
    private static func readBeforeSave() async throws {
        let gate = RuntimeSnapshotGate()
        defer { gate.release() }
        let store = RuntimeSnapshotKeyStore()
        store.readGate = gate
        let settings = fixture(store)
        var result: LLMRuntimeSnapshotResult?
        settings.readRuntimeSnapshotAsync(forRecognitionEngine: "openai") { result = $0 }
        try await waitUntil { gate.entered }
        let saved = RuntimeSnapshotValue<Bool>()
        DispatchQueue.global(qos: .userInitiated).async {
            saved.set(settings.saveConnection(newConnection, previousKeyRead: .value(oldConnection.apiKey)))
        }
        gate.release()
        try await waitUntil { result != nil && saved.value != nil }
        try expect(matches(tryReadyConnection(result!), oldConnection) && saved.value == true)
        store.readGate = nil
        let next = try await snapshot(settings)
        try expect(matches(tryReadyConnection(next), newConnection) && store.readCount == 2)
    }

    @MainActor
    private static func failedSave() async throws {
        let store = RuntimeSnapshotKeyStore()
        store.writeSucceeds = false
        let settings = fixture(store)
        let saved: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: settings.saveConnection(newConnection, previousKeyRead: .value(oldConnection.apiKey)))
            }
        }
        let result = try await snapshot(settings)
        try expect(!saved && matches(tryReadyConnection(result), oldConnection))
        try expect(store.readCount == 1 && store.writeCount == 1 && store.deleteCount == 0)
    }

    private static let oldConnection = LLMConnectionSettings(baseURL: "https://api.openai.com/v1", apiKey: "old-fixture", model: "old-fixture-model")
    private static let newConnection = LLMConnectionSettings(baseURL: "https://api.openai.com/v1/chat/completions", apiKey: "new-fixture", model: "new-fixture-model")

    private static func fixture(_ store: RuntimeSnapshotKeyStore) -> LLMSettings {
        let settings = LLMSettings(backend: InMemorySettingsBackend(), apiKeyStore: store)
        settings.apiBaseURL = oldConnection.baseURL
        settings.model = oldConnection.model
        settings.systemPrompt = "original-fixture-prompt"
        settings.enabled = true
        return settings
    }

    @MainActor
    private static func snapshot(_ settings: LLMSettings, engine: String = "openai") async throws -> LLMRuntimeSnapshotResult {
        var result: LLMRuntimeSnapshotResult?
        settings.readRuntimeSnapshotAsync(forRecognitionEngine: engine) { result = $0 }
        try await waitUntil { result != nil }
        return try require(result)
    }

    private static func ready(_ result: LLMRuntimeSnapshotResult) throws -> LLMRuntimeSnapshot {
        if case .ready(let snapshot) = result { return snapshot }
        throw TestFailure(file: #filePath, line: #line, message: "Expected ready runtime snapshot")
    }

    private static func matches(_ value: LLMConnectionSettings?, _ expected: LLMConnectionSettings) -> Bool {
        guard let value else { return false }
        return value.baseURL == expected.baseURL && value.apiKey == expected.apiKey && value.model == expected.model
    }

    // 比较不在失败信息里输出密钥。
    private static func tryReadyConnection(_ result: LLMRuntimeSnapshotResult) -> LLMConnectionSettings? {
        if case .ready(let snapshot) = result { return snapshot.connection }
        return nil
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw TestFailure(file: #filePath, line: #line, message: "Runtime snapshot operation timed out")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class RuntimeSnapshotValue<Value> {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
}

private final class RuntimeSnapshotGate {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false
    private var didTimeOut = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeOut }
    func wait() {
        lock.lock(); didEnter = true; lock.unlock()
        // 保持长于调用方的 4 秒等待上限，避免繁忙 CI 提前放行测试屏障。
        let timeout = semaphore.wait(timeout: .now() + 10) == .timedOut
        lock.lock(); didTimeOut = timeout; lock.unlock()
    }
    func release() { semaphore.signal() }
}

private final class RuntimeSnapshotKeyStore: LLMAPIKeyStoring {
    private let lock = NSLock()
    private var stored = "old-fixture"
    private var reads = 0
    private var writes = 0
    private var deletes = 0
    // 测试在启动操作前配置，或等待前一操作全部完成后替换。
    var readGate: RuntimeSnapshotGate?
    var writeGate: RuntimeSnapshotGate?
    var readOverride: KeychainStringReadResult?
    var writeSucceeds = true
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    var deleteCount: Int { lock.lock(); defer { lock.unlock() }; return deletes }
    func readResult() -> KeychainStringReadResult {
        lock.lock(); reads += 1; lock.unlock()
        readGate?.wait()
        lock.lock(); defer { lock.unlock() }
        return readOverride ?? .value(stored)
    }
    func write(_ value: String) -> Bool {
        lock.lock(); writes += 1; lock.unlock()
        writeGate?.wait()
        lock.lock(); defer { lock.unlock() }
        guard writeSucceeds else { return false }
        stored = value
        return true
    }
    func delete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        deletes += 1
        stored = ""
        return true
    }
}
