import Darwin
import Foundation
import XCTest
@testable import Statelet

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return storage }
    func update(_ body: (inout Value) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll(keepingCapacity: false)
        current.forEach { $0.resume() }
    }
}

final class CodexAppServerTitleResolverTests: XCTestCase {
    func testResolvedTitleStoreRejectsStaleThreadsAndLetsSidecarWin() {
        var store = SessionActivityResolvedTitleStore()
        store.adopt(
            ["activity": "Memory title"],
            expectedThreads: ["activity": "thread-1"],
            currentThreads: ["activity": "thread-1"]
        )
        XCTAssertEqual(store.combined(with: [:]), ["activity": "Memory title"])
        XCTAssertEqual(
            store.combined(with: ["activity": "Sidecar title"]),
            ["activity": "Sidecar title"]
        )

        store.retain(for: ["activity": "thread-2"])
        XCTAssertEqual(store.combined(with: [:]), [:])
        store.adopt(
            ["activity": "Stale title"],
            expectedThreads: ["activity": "thread-1"],
            currentThreads: ["activity": "thread-2"]
        )
        XCTAssertEqual(store.combined(with: [:]), [:])
        XCTAssertEqual(
            store.unresolvedTargets(
                activityThreads: ["activity": "thread-2"],
                suppliedTitles: [:]
            ),
            ["activity": "thread-2"]
        )
    }

    func testSanitizerNormalizesCollapsesAndBoundsTitles() {
        XCTAssertEqual(CodexAppServerTitleResolver.sanitize("  Cafe\u{301}\n\twork\u{200B}  "), "Café work")
        XCTAssertNil(CodexAppServerTitleResolver.sanitize("\n\t\u{200B}"))
        XCTAssertNotNil(CodexAppServerTitleResolver.sanitize(String(repeating: "a", count: 120)))
        XCTAssertNil(CodexAppServerTitleResolver.sanitize(String(repeating: "a", count: 121)))
        XCTAssertNotNil(CodexAppServerTitleResolver.sanitize(String(repeating: "é", count: 120)))
        XCTAssertNil(CodexAppServerTitleResolver.sanitize(String(repeating: "€", count: 100)))
    }

    func testResolverDeduplicatesThreadRequestsAndMapsBackToEveryActivity() async {
        let calls = LockedValue<[[String]]>([])
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 10 },
            runner: { _, ids, timeout, limit in
                calls.update { $0.append(ids) }
                XCTAssertEqual(timeout, 1.5)
                XCTAssertEqual(limit, 1_048_576)
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("  Shared\n title ")) })
            }
        )
        let result = await resolver.resolve(activityThreads: ["a": "thread", "b": "thread"])
        XCTAssertEqual(result, ["a": "Shared title", "b": "Shared title"])
        XCTAssertEqual(calls.read(), [["thread"]])
    }

    func testSuccessAndNullResultsAreCachedForSixtySeconds() async {
        let now = LockedValue(0.0)
        let calls = LockedValue(0)
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { now.read() },
            runner: { _, ids, _, _ in
                calls.update { $0 += 1 }
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == "named" ? .title("Name") : .missing) })
            }
        )
        var result = await resolver.resolve(activityThreads: ["a": "named", "b": "null"])
        XCTAssertEqual(result, ["a": "Name"])
        now.update { $0 = 59 }
        result = await resolver.resolve(activityThreads: ["a": "named", "b": "null"])
        XCTAssertEqual(result, ["a": "Name"])
        XCTAssertEqual(calls.read(), 1)
        now.update { $0 = 61 }
        _ = await resolver.resolve(activityThreads: ["a": "named", "b": "null"])
        XCTAssertEqual(calls.read(), 2)
    }

    func testFailureDropsExpiredCacheAndBacksOffWithoutLeakingErrorDetails() async {
        let now = LockedValue(0.0)
        let calls = LockedValue(0)
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { now.read() },
            runner: { _, ids, _, _ in
                calls.update { $0 += 1 }
                if calls.read() > 1 { throw NSError(domain: "contains-private-id-and-title", code: 1) }
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("Cached")) })
            },
            cacheTTL: 1,
            failureBackoff: 60
        )
        var result = await resolver.resolve(activityThreads: ["a": "secret-thread"])
        XCTAssertEqual(result, ["a": "Cached"])
        now.update { $0 = 2 }
        result = await resolver.resolve(activityThreads: ["a": "secret-thread"])
        XCTAssertEqual(result, [:])
        now.update { $0 = 30 }
        result = await resolver.resolve(activityThreads: ["a": "secret-thread"])
        XCTAssertEqual(result, [:])
        XCTAssertEqual(calls.read(), 2)
    }

    func testConcurrentDuplicateResolutionCoalescesAndUsesCompletionTimeForCache() async {
        let now = LockedValue(0.0)
        let calls = LockedValue(0)
        let started = AsyncGate()
        let release = AsyncGate()
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { now.read() },
            runner: { _, ids, _, _ in
                calls.update { $0 += 1 }
                await started.open()
                await release.wait()
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("Fresh")) })
            },
            cacheTTL: 60
        )

        let first = Task { await resolver.resolve(activityThreads: ["a": "thread"]) }
        await started.wait()
        let secondInvoked = AsyncGate()
        let second = Task {
            await secondInvoked.open()
            return await resolver.resolve(activityThreads: ["b": "thread"])
        }
        await secondInvoked.wait()
        for _ in 0..<10 { await Task.yield() }
        now.update { $0 = 30 }
        await release.open()

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, ["a": "Fresh"])
        XCTAssertEqual(secondResult, ["b": "Fresh"])
        XCTAssertEqual(calls.read(), 1)
        now.update { $0 = 89 }
        let cachedResult = await resolver.resolve(activityThreads: ["c": "thread"])
        XCTAssertEqual(cachedResult, ["c": "Fresh"])
        XCTAssertEqual(calls.read(), 1)
    }

    func testCancellingSoleWaiterCancelsRunnerWithoutStartingFailureBackoff() async {
        let calls = LockedValue(0)
        let started = AsyncGate()
        let cancelled = AsyncGate()
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 10 },
            runner: { _, ids, _, _ in
                calls.update { $0 += 1 }
                if calls.read() == 1 {
                    await started.open()
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        await cancelled.open()
                        throw error
                    }
                }
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("Retried")) })
            },
            failureBackoff: 60
        )

        let first = Task { await resolver.resolve(activityThreads: ["a": "thread"]) }
        await started.wait()
        first.cancel()
        await cancelled.wait()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, [:])

        let retry = await resolver.resolve(activityThreads: ["a": "thread"])
        XCTAssertEqual(retry, ["a": "Retried"])
        XCTAssertEqual(calls.read(), 2)
    }

    func testCancellingOneOfTwoExactWaitersKeepsSharedRunnerAlive() async {
        let calls = LockedValue(0)
        let started = AsyncGate()
        let release = LockedValue(false)
        let runnerCancelled = LockedValue(false)
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 10 },
            runner: { _, ids, _, _ in
                calls.update { $0 += 1 }
                await started.open()
                do {
                    while !release.read() {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                } catch {
                    runnerCancelled.update { $0 = true }
                    throw error
                }
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("Shared")) })
            }
        )

        let first = Task { await resolver.resolve(activityThreads: ["a": "thread"]) }
        await started.wait()
        let second = Task { await resolver.resolve(activityThreads: ["b": "thread"]) }
        await waitForWaiterCounts(resolver, exact: 2, observers: 0)

        first.cancel()
        await waitForWaiterCounts(resolver, exact: 1, observers: 0)
        XCTAssertFalse(runnerCancelled.read())
        release.update { $0 = true }

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, [:])
        XCTAssertEqual(secondResult, ["b": "Shared"])
        XCTAssertFalse(runnerCancelled.read())
        XCTAssertEqual(calls.read(), 1)
    }

    func testDifferentTargetObserverDoesNotRetainCancelledStaleAttempt() async {
        let calls = LockedValue<[[String]]>([])
        let firstStarted = AsyncGate()
        let firstCancelled = AsyncGate()
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 10 },
            runner: { _, ids, _, _ in
                calls.update { $0.append(ids) }
                if ids == ["thread-a"] {
                    await firstStarted.open()
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        await firstCancelled.open()
                        throw error
                    }
                }
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("Fresh B")) })
            }
        )

        let stale = Task { await resolver.resolve(activityThreads: ["a": "thread-a"]) }
        await firstStarted.wait()
        let fresh = Task { await resolver.resolve(activityThreads: ["b": "thread-b"]) }
        await waitForWaiterCounts(resolver, exact: 1, observers: 1)

        stale.cancel()
        await firstCancelled.wait()
        let staleResult = await stale.value
        let freshResult = await fresh.value
        XCTAssertEqual(staleResult, [:])
        XCTAssertEqual(freshResult, ["b": "Fresh B"])
        XCTAssertEqual(calls.read(), [["thread-a"], ["thread-b"]])
    }

    func testCachePurgesExpiredEntriesAndBoundsUniqueThreadChurn() async {
        let now = LockedValue(0.0)
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { now.read() },
            runner: { _, ids, _, _ in
                Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("Title \($0)")) })
            },
            cacheTTL: 1,
            maximumCacheEntries: 8
        )
        for batch in 0..<3 {
            let values = Dictionary(uniqueKeysWithValues: (0..<6).map {
                ("activity-\(batch)-\($0)", "thread-\(batch)-\($0)")
            })
            _ = await resolver.resolve(activityThreads: values)
            now.update { $0 += 0.25 }
        }
        var count = await resolver.cachedEntryCountForTesting()
        XCTAssertEqual(count, 8)
        now.update { $0 = 2 }
        _ = await resolver.resolve(activityThreads: ["fresh": "fresh-thread"])
        count = await resolver.cachedEntryCountForTesting()
        XCTAssertEqual(count, 1)
    }

    func testMissingExecutableFailsSoftAndUsesBackoff() async {
        let now = LockedValue(0.0)
        let locatorCalls = LockedValue(0)
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { locatorCalls.update { $0 += 1 }; return nil },
            clock: { now.read() },
            runner: { _, _, _, _ in XCTFail("runner must not run"); return [:] }
        )
        var result = await resolver.resolve(activityThreads: ["a": "thread"])
        XCTAssertEqual(result, [:])
        now.update { $0 = 30 }
        result = await resolver.resolve(activityThreads: ["a": "thread"])
        XCTAssertEqual(result, [:])
        XCTAssertEqual(locatorCalls.read(), 1)
    }

    func testZeroDurationsCannotSpinTheResolutionLoop() async {
        let successCalls = LockedValue(0)
        let success = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 0 },
            runner: { _, ids, _, _ in
                successCalls.update { $0 += 1 }
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, .missing) })
            },
            cacheTTL: 0,
            failureBackoff: 0
        )
        let successResult = await success.resolve(activityThreads: ["a": "thread"])
        XCTAssertEqual(successResult, [:])
        XCTAssertEqual(successCalls.read(), 1)

        let failureCalls = LockedValue(0)
        let failure = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 0 },
            runner: { _, _, _, _ in
                failureCalls.update { $0 += 1 }
                throw CodexAppServerResolutionFailure.unavailable
            },
            cacheTTL: 0,
            failureBackoff: 0
        )
        let failureResult = await failure.resolve(activityThreads: ["a": "thread"])
        XCTAssertEqual(failureResult, [:])
        XCTAssertEqual(failureCalls.read(), 1)
    }

    func testMalformedRunnerResultAndUnsafeThreadIDFailClosed() async {
        let calls = LockedValue(0)
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 0 },
            runner: { _, _, _, _ in calls.update { $0 += 1 }; return ["different": .title("No")] }
        )
        let result = await resolver.resolve(activityThreads: ["a": "good", "b": "bad\nthread"])
        XCTAssertEqual(result, [:])
        XCTAssertEqual(calls.read(), 1)
        let tooMany = Dictionary(uniqueKeysWithValues: (0..<7).map {
            ("activity-\($0)", "thread-\($0)")
        })
        let tooManyResult = await resolver.resolve(activityThreads: tooMany)
        XCTAssertEqual(tooManyResult, [:])
        XCTAssertEqual(calls.read(), 1)
    }

    func testExecutableTrustRequiresRegularOwnedNonWritableExecutable() throws {
        let directory = try temporaryDirectory()
        let safe = directory.appendingPathComponent("safe")
        XCTAssertTrue(FileManager.default.createFile(atPath: safe.path, contents: Data("#!/bin/sh\n".utf8)))
        XCTAssertEqual(chmod(safe.path, 0o700), 0)
        XCTAssertFalse(CodexAppServerExecutableDiscovery.isTrustedExecutable(safe))
        XCTAssertTrue(CodexAppServerExecutableDiscovery.isTrustedExecutable(
            safe,
            policy: .testOnlyAllowUnsignedExecutable
        ))
        XCTAssertEqual(chmod(safe.path, 0o722), 0)
        XCTAssertFalse(CodexAppServerExecutableDiscovery.isTrustedExecutable(
            safe,
            policy: .testOnlyAllowUnsignedExecutable
        ))
        let folder = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertFalse(CodexAppServerExecutableDiscovery.isTrustedExecutable(folder))
    }

    func testProcessRunnerUsesExactWireAndExtractsNameOnly() async throws {
        let capture = try temporaryDirectory().appendingPathComponent("wire.jsonl")
        let script = try makePythonExecutable("""
        import json,sys
        cap=open(\(pythonLiteral(capture.path)),'w')
        init=json.loads(sys.stdin.readline()); cap.write(json.dumps(init,sort_keys=True)+'\\n'); cap.flush()
        print(json.dumps({'id':1,'result':{}}),flush=True)
        note=json.loads(sys.stdin.readline()); cap.write(json.dumps(note,sort_keys=True)+'\\n'); cap.flush()
        req=json.loads(sys.stdin.readline()); cap.write(json.dumps(req,sort_keys=True)+'\\n'); cap.flush()
        print(json.dumps({'id':2,'result':{'thread':{'id':req['params']['threadId'],'name':'Visible','preview':'SECRET','turns':[{'items':['SECRET']} ]}}}),flush=True)
        """)
        let result = try await CodexAppServerProcessRunner.run(
            executable: script,
            threadIDs: ["thread-1"],
            timeout: 1.5,
            maximumOutputBytes: 1_048_576,
            trustPolicy: .testOnlyAllowUnsignedExecutable
        )
        XCTAssertEqual(result, ["thread-1": .title("Visible")])
        let lines = try String(contentsOf: capture).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("\"method\": \"initialize\""))
        XCTAssertTrue(lines[1].contains("\"method\": \"initialized\""))
        XCTAssertTrue(lines[2].contains("\"includeTurns\": false"))
        XCTAssertTrue(lines[2].contains("\"method\": \"thread/read\""))
    }

    func testProcessRunnerRejectsExecutableReplacementAfterPreflightWithoutWritingProtocol() async throws {
        let directory = try temporaryDirectory()
        let executable = try makePythonExecutable("import sys; sys.stdin.read()", directory: directory)
        let pidURL = directory.appendingPathComponent("replacement-pid")
        let protocolURL = directory.appendingPathComponent("replacement-wire")
        let replacement = Data("""
        #!/bin/sh
        echo $$ > \(pidURL.path)
        if IFS= read -r line; then
          printf '%s\\n' "$line" > \(protocolURL.path)
        fi
        sleep 5
        """.utf8)
        let observedPID = LockedValue<Int32?>(nil)

        await XCTAssertThrowsAsync(.unavailable) {
            _ = try await CodexAppServerProcessRunner.run(
                executable: executable,
                threadIDs: ["private-thread-id"],
                timeout: 1,
                maximumOutputBytes: 1024,
                trustPolicy: .testOnlyAllowUnsignedExecutable,
                prelaunchHook: { resolvedExecutable in
                    try replacement.write(to: resolvedExecutable, options: .atomic)
                    guard chmod(resolvedExecutable.path, 0o700) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                },
                runningProcessValidator: { process, _ in
                    observedPID.update { $0 = process.processIdentifier }
                    for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidURL.path) {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    return false
                }
            )
        }

        guard let pid = observedPID.read() else {
            return XCTFail("running-process validator was not invoked")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: protocolURL.path))
        assertProcessDoesNotExist(pid)
    }

    func testProcessRunnerAcceptsNullNameAsMissing() async throws {
        let script = try makePythonExecutable("""
        import json,sys
        json.loads(sys.stdin.readline()); print(json.dumps({'id':1,'result':{}}),flush=True)
        json.loads(sys.stdin.readline()); req=json.loads(sys.stdin.readline())
        print(json.dumps({'id':2,'result':{'thread':{'id':req['params']['threadId'],'name':None}}}),flush=True)
        """)
        let result = try await CodexAppServerProcessRunner.run(
            executable: script,
            threadIDs: ["thread-1"],
            timeout: 1.5,
            maximumOutputBytes: 1_048_576,
            trustPolicy: .testOnlyAllowUnsignedExecutable
        )
        XCTAssertEqual(result, ["thread-1": .missing])
    }

    func testProcessRunnerAcceptsMissingNameAsMissing() async throws {
        let script = try makePythonExecutable("""
        import json,sys
        json.loads(sys.stdin.readline()); print(json.dumps({'id':1,'result':{}}),flush=True)
        json.loads(sys.stdin.readline()); req=json.loads(sys.stdin.readline())
        print(json.dumps({'id':2,'result':{'thread':{'id':req['params']['threadId']}}}),flush=True)
        """)
        let result = try await CodexAppServerProcessRunner.run(
            executable: script,
            threadIDs: ["thread-1"],
            timeout: 1,
            maximumOutputBytes: 1_048_576,
            trustPolicy: .testOnlyAllowUnsignedExecutable
        )
        XCTAssertEqual(result, ["thread-1": .missing])
    }

    func testProcessRunnerRejectsInvalidNameType() async throws {
        let script = try makePythonExecutable("""
        import json,sys
        json.loads(sys.stdin.readline()); print(json.dumps({'id':1,'result':{}}),flush=True)
        json.loads(sys.stdin.readline()); req=json.loads(sys.stdin.readline())
        print(json.dumps({'id':2,'result':{'thread':{'id':req['params']['threadId'],'name':False}}}),flush=True)
        """)
        await XCTAssertThrowsAsync(.protocolViolation) {
            _ = try await CodexAppServerProcessRunner.run(
                executable: script,
                threadIDs: ["thread-1"],
                timeout: 1,
                maximumOutputBytes: 1_048_576,
                trustPolicy: .testOnlyAllowUnsignedExecutable
            )
        }
    }

    func testProcessRunnerRequiresExactNumericResponseIDs() async throws {
        for invalidID in ["True", "1.5"] {
            let script = try makePythonExecutable("""
            import json,sys
            json.loads(sys.stdin.readline()); print(json.dumps({'id':\(invalidID),'result':{}}),flush=True)
            sys.stdin.read()
            """)
            await XCTAssertThrowsAsync(.protocolViolation) {
                _ = try await CodexAppServerProcessRunner.run(
                    executable: script,
                    threadIDs: ["thread-1"],
                    timeout: 1,
                    maximumOutputBytes: 1_048_576,
                    trustPolicy: .testOnlyAllowUnsignedExecutable
                )
            }
        }
    }

    func testProcessRunnerSurvivesChildClosingInputAfterInitializeResponse() async throws {
        let script = try makePythonExecutable("""
        import json,os,sys,time
        json.loads(sys.stdin.readline())
        os.close(0)
        print(json.dumps({'id':1,'result':{}}),flush=True)
        time.sleep(0.2)
        """)
        await XCTAssertThrowsAsync(.unavailable) {
            _ = try await CodexAppServerProcessRunner.run(
                executable: script,
                threadIDs: ["thread-1"],
                timeout: 1,
                maximumOutputBytes: 1_048_576,
                trustPolicy: .testOnlyAllowUnsignedExecutable
            )
        }
    }

    func testProcessRunnerRejectsMismatchedMalformedAndOversizedResponses() async throws {
        let mismatched = try makePythonExecutable("""
        import json,sys
        json.loads(sys.stdin.readline()); print(json.dumps({'id':1,'result':{}}),flush=True)
        json.loads(sys.stdin.readline()); req=json.loads(sys.stdin.readline())
        print(json.dumps({'id':2,'result':{'thread':{'id':'wrong','name':'No'}}}),flush=True)
        """)
        await XCTAssertThrowsAsync(.protocolViolation) {
            _ = try await CodexAppServerProcessRunner.run(executable: mismatched, threadIDs: ["expected"], timeout: 1, maximumOutputBytes: 1_048_576, trustPolicy: .testOnlyAllowUnsignedExecutable)
        }

        let malformed = try makePythonExecutable("import sys; print('{bad json',flush=True); sys.stdin.read()")
        await XCTAssertThrowsAsync(.protocolViolation) {
            _ = try await CodexAppServerProcessRunner.run(executable: malformed, threadIDs: ["x"], timeout: 1, maximumOutputBytes: 1_048_576, trustPolicy: .testOnlyAllowUnsignedExecutable)
        }

        let oversized = try makePythonExecutable("import sys; sys.stdout.write('x'*2048); sys.stdout.flush(); sys.stdin.read()")
        await XCTAssertThrowsAsync(.protocolViolation) {
            _ = try await CodexAppServerProcessRunner.run(executable: oversized, threadIDs: ["x"], timeout: 1, maximumOutputBytes: 1024, trustPolicy: .testOnlyAllowUnsignedExecutable)
        }
    }

    func testProcessRunnerDrainsLargeNotificationBeforeResponse() async throws {
        let script = try makePythonExecutable("""
        import json,sys
        json.loads(sys.stdin.readline())
        print(json.dumps({'method':'notice','params':{'preview':'x'*400000}}),flush=True)
        print(json.dumps({'id':1,'result':{}}),flush=True)
        json.loads(sys.stdin.readline()); req=json.loads(sys.stdin.readline())
        print(json.dumps({'id':2,'result':{'thread':{'id':req['params']['threadId'],'name':'Done'}}}),flush=True)
        """)
        let result = try await CodexAppServerProcessRunner.run(
            executable: script,
            threadIDs: ["x"],
            timeout: 5,
            maximumOutputBytes: 1_048_576,
            trustPolicy: .testOnlyAllowUnsignedExecutable
        )
        XCTAssertEqual(result, ["x": .title("Done")])
    }

    func testTimeoutAndCancellationTerminateAndReapProcess() async throws {
        let directory = try temporaryDirectory()
        let timeoutPIDURL = directory.appendingPathComponent("timeout-pid")
        let timeoutScript = try makePythonExecutable("""
        import os,time
        with open(\(pythonLiteral(timeoutPIDURL.path)),'w') as marker:
            marker.write(str(os.getpid())); marker.flush()
        while True: time.sleep(0.05)
        """, directory: directory)
        await XCTAssertThrowsAsync(.timeout) {
            _ = try await CodexAppServerProcessRunner.run(executable: timeoutScript, threadIDs: ["x"], timeout: 2, maximumOutputBytes: 1024, trustPolicy: .testOnlyAllowUnsignedExecutable)
        }
        let timeoutPID = try await waitForPID(timeoutPIDURL)
        assertProcessDoesNotExist(timeoutPID)

        let cancellationPIDURL = directory.appendingPathComponent("cancellation-pid")
        let cancellationScript = try makePythonExecutable("""
        import os,time
        with open(\(pythonLiteral(cancellationPIDURL.path)),'w') as marker:
            marker.write(str(os.getpid())); marker.flush()
        while True: time.sleep(0.05)
        """, directory: directory)
        let task = Task {
            try await CodexAppServerProcessRunner.run(executable: cancellationScript, threadIDs: ["x"], timeout: 5, maximumOutputBytes: 1024, trustPolicy: .testOnlyAllowUnsignedExecutable)
        }
        let cancellationPID = try await waitForPID(cancellationPIDURL)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let failure as CodexAppServerResolutionFailure {
            XCTAssertEqual(failure, .cancelled)
        } catch {
            XCTFail("unexpected error: \(type(of: error))")
        }
        assertProcessDoesNotExist(cancellationPID)
    }

    func testResolverShutdownWaitsForActiveRunnerToReapChildAndRejectsFutureWork() async throws {
        let directory = try temporaryDirectory()
        let pidURL = directory.appendingPathComponent("shutdown-pid")
        let script = try makePythonExecutable("""
        import os,time
        with open(\(pythonLiteral(pidURL.path)),'w') as marker:
            marker.write(str(os.getpid())); marker.flush()
        while True: time.sleep(0.05)
        """, directory: directory)
        let calls = LockedValue(0)
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { script },
            clock: { ProcessInfo.processInfo.systemUptime },
            runner: { executable, ids, timeout, maximumOutputBytes in
                calls.update { $0 += 1 }
                return try await CodexAppServerProcessRunner.run(
                    executable: executable,
                    threadIDs: ids,
                    timeout: timeout,
                    maximumOutputBytes: maximumOutputBytes,
                    trustPolicy: .testOnlyAllowUnsignedExecutable
                )
            },
            timeout: 5
        )

        let pending = Task {
            await resolver.resolve(activityThreads: ["activity": "private-thread-id"])
        }
        let pid = try await waitForPID(pidURL)

        await resolver.shutdown()

        assertProcessDoesNotExist(pid)
        let pendingResult = await pending.value
        XCTAssertEqual(pendingResult, [:])
        let afterShutdown = await resolver.resolve(activityThreads: ["later": "other-thread"])
        XCTAssertEqual(afterShutdown, [:])
        XCTAssertEqual(calls.read(), 1)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makePythonExecutable(_ body: String, directory suppliedDirectory: URL? = nil) throws -> URL {
        let directory: URL
        if let suppliedDirectory {
            directory = suppliedDirectory
        } else {
            directory = try temporaryDirectory()
        }
        let url = directory.appendingPathComponent("fake-codex-\(UUID().uuidString)")
        try ("#!/usr/bin/python3\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return url
    }

    private func pythonLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private func waitForPID(_ url: URL) async throws -> Int32 {
        for _ in 0..<500 {
            if let contents = try? String(contentsOf: url),
               let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "TestPIDTimeout", code: 1)
    }

    private func waitForWaiterCounts(
        _ resolver: CodexAppServerTitleResolver,
        exact: Int,
        observers: Int
    ) async {
        for _ in 0..<500 {
            let counts = await resolver.inFlightWaiterCountsForTesting()
            if counts.exact == exact, counts.observers == observers { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let counts = await resolver.inFlightWaiterCountsForTesting()
        XCTFail("waiter counts were exact=\(counts.exact), observers=\(counts.observers)")
    }

    private func assertProcessDoesNotExist(
        _ pid: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}

private extension XCTestCase {
    func XCTAssertThrowsAsync(
        _ expected: CodexAppServerResolutionFailure? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch let failure as CodexAppServerResolutionFailure {
            if let expected { XCTAssertEqual(failure, expected, file: file, line: line) }
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
        }
    }
}
