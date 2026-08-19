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

final class CodexAppServerTitleResolverTests: XCTestCase {
    func testSanitizerNormalizesCollapsesAndBoundsTitles() {
        XCTAssertEqual(CodexAppServerTitleResolver.sanitize("  Cafe\u{301}\n\twork\u{200B}  "), "Café work")
        XCTAssertEqual(CodexAppServerTitleResolver.sanitize("A\u{200B}\u{030A}"), "Å")
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

    func testCacheRetainsOnlyCurrentlyRequestedThreadsAndClearsWhenEmpty() async {
        let calls = LockedValue(0)
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 0 },
            runner: { _, ids, _, _ in
                calls.update { $0 += 1 }
                let call = calls.read()
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("Call \(call)")) })
            }
        )

        var result = await resolver.resolve(activityThreads: ["a": "thread-a"])
        XCTAssertEqual(result, ["a": "Call 1"])
        result = await resolver.resolve(activityThreads: ["b": "thread-b"])
        XCTAssertEqual(result, ["b": "Call 2"])
        result = await resolver.resolve(activityThreads: ["a": "thread-a"])
        XCTAssertEqual(result, ["a": "Call 3"])
        result = await resolver.resolve(activityThreads: [:])
        XCTAssertEqual(result, [:])
        result = await resolver.resolve(activityThreads: ["a": "thread-a"])
        XCTAssertEqual(result, ["a": "Call 4"])
    }

    func testFailureUsesStaleCacheAndBacksOffWithoutLeakingErrorDetails() async {
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
        XCTAssertEqual(result, ["a": "Cached"])
        now.update { $0 = 30 }
        result = await resolver.resolve(activityThreads: ["a": "secret-thread"])
        XCTAssertEqual(result, ["a": "Cached"])
        XCTAssertEqual(calls.read(), 2)
    }

    func testCancellationDoesNotBackOffImmediateReplacementResolution() async {
        let calls = LockedValue(0)
        let health = LockedValue<[CodexAppServerTitleHealth]>([])
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 10 },
            runner: { _, ids, _, _ in
                calls.update { $0 += 1 }
                if calls.read() == 1 {
                    throw CodexAppServerResolutionFailure.cancelled
                }
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("Recovered")) })
            },
            failureBackoff: 60,
            healthReporter: { status in health.update { $0.append(status) } }
        )

        var result = await resolver.resolve(activityThreads: ["a": "thread"])
        XCTAssertEqual(result, [:])
        result = await resolver.resolve(activityThreads: ["a": "thread"])
        XCTAssertEqual(result, ["a": "Recovered"])
        XCTAssertEqual(calls.read(), 2)
        XCTAssertEqual(health.read(), [.healthy])
    }

    func testMissingExecutableFailsSoftAndUsesBackoff() async {
        let now = LockedValue(0.0)
        let locatorCalls = LockedValue(0)
        let health = LockedValue<[CodexAppServerTitleHealth]>([])
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { locatorCalls.update { $0 += 1 }; return nil },
            clock: { now.read() },
            runner: { _, _, _, _ in XCTFail("runner must not run"); return [:] },
            healthReporter: { status in health.update { $0.append(status) } }
        )
        var result = await resolver.resolve(activityThreads: ["a": "thread"])
        XCTAssertEqual(result, [:])
        now.update { $0 = 30 }
        result = await resolver.resolve(activityThreads: ["a": "thread"])
        XCTAssertEqual(result, [:])
        XCTAssertEqual(locatorCalls.read(), 1)
        XCTAssertEqual(health.read(), [.unavailable])
    }

    func testHealthReportsCategoricalFailuresOnceAndRecoveryWithoutPrivateInput() async {
        let now = LockedValue(0.0)
        let calls = LockedValue(0)
        let health = LockedValue<[CodexAppServerTitleHealth]>([])
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { now.read() },
            runner: { _, ids, _, _ in
                calls.update { $0 += 1 }
                switch calls.read() {
                case 1:
                    throw CodexAppServerResolutionFailure.timeout
                case 2:
                    throw NSError(domain: "private-thread private-title /private/path", code: 1)
                default:
                    return Dictionary(uniqueKeysWithValues: ids.map { ($0, .title("Recovered")) })
                }
            },
            failureBackoff: 60,
            healthReporter: { status in health.update { $0.append(status) } }
        )

        var result = await resolver.resolve(activityThreads: ["a": "private-thread"])
        XCTAssertEqual(result, [:])
        now.update { $0 = 30 }
        result = await resolver.resolve(activityThreads: ["a": "private-thread"])
        XCTAssertEqual(result, [:])
        now.update { $0 = 61 }
        result = await resolver.resolve(activityThreads: ["a": "private-thread"])
        XCTAssertEqual(result, [:])
        now.update { $0 = 122 }
        result = await resolver.resolve(activityThreads: ["a": "private-thread"])
        XCTAssertEqual(result, ["a": "Recovered"])

        XCTAssertEqual(health.read(), [.timeout, .protocolViolation, .healthy])
        XCTAssertEqual(calls.read(), 3)
        let evidence = health.read().map(\.rawValue).joined(separator: ",")
        XCTAssertFalse(evidence.contains("private-thread"))
        XCTAssertFalse(evidence.contains("private-title"))
        XCTAssertFalse(evidence.contains("/private/path"))
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
    }

    func testResolverRejectsMoreThanBoundedActivityCountWithoutLaunching() async {
        let resolver = CodexAppServerTitleResolver(
            executableLocator: { URL(fileURLWithPath: "/trusted/codex") },
            clock: { 0 },
            runner: { _, _, _, _ in
                XCTFail("runner must not run for an oversized activity set")
                return [:]
            }
        )
        let activities = Dictionary(uniqueKeysWithValues: (0...CodexAppServerTitleResolver.maximumActivityCount).map {
            ("activity-\($0)", "thread-\($0)")
        })
        let result = await resolver.resolve(activityThreads: activities)
        XCTAssertEqual(result, [:])
    }

    func testExecutableTrustRequiresRegularOwnedNonWritableExecutable() throws {
        let directory = try temporaryDirectory()
        let safe = directory.appendingPathComponent("safe")
        XCTAssertTrue(FileManager.default.createFile(atPath: safe.path, contents: Data("#!/bin/sh\n".utf8)))
        XCTAssertEqual(chmod(safe.path, 0o700), 0)
        XCTAssertTrue(CodexAppServerExecutableDiscovery.isTrustedExecutable(safe))
        XCTAssertEqual(chmod(safe.path, 0o722), 0)
        XCTAssertFalse(CodexAppServerExecutableDiscovery.isTrustedExecutable(safe))
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
            executable: script, threadIDs: ["thread-1"], timeout: 1.5, maximumOutputBytes: 1_048_576
        )
        XCTAssertEqual(result, ["thread-1": .title("Visible")])
        let lines = try String(contentsOf: capture).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("\"method\": \"initialize\""))
        XCTAssertTrue(lines[1].contains("\"method\": \"initialized\""))
        XCTAssertTrue(lines[2].contains("\"includeTurns\": false"))
        XCTAssertTrue(lines[2].contains("\"method\": \"thread/read\""))
    }

    func testProcessRunnerTreatsExplicitNullNameAsMissing() async throws {
        let script = try makePythonExecutable("""
        import json,sys
        json.loads(sys.stdin.readline()); print(json.dumps({'id':1,'result':{}}),flush=True)
        json.loads(sys.stdin.readline()); req=json.loads(sys.stdin.readline())
        print(json.dumps({'id':2,'result':{'thread':{'id':req['params']['threadId'],'name':None}}}),flush=True)
        """)
        let result = try await CodexAppServerProcessRunner.run(
            executable: script, threadIDs: ["thread-null"], timeout: 1.5, maximumOutputBytes: 1_048_576
        )
        XCTAssertEqual(result, ["thread-null": .missing])
    }

    func testProcessRunnerTreatsExactThreadNotLoadedErrorAsMissingAndContinuesBatch() async throws {
        let script = try makePythonExecutable("""
        import json,sys
        json.loads(sys.stdin.readline()); print(json.dumps({'id':1,'result':{}}),flush=True)
        json.loads(sys.stdin.readline()); first=json.loads(sys.stdin.readline())
        print(json.dumps({'id':2,'error':{'code':-32600,'message':'thread not loaded: '+first['params']['threadId']}}),flush=True)
        second=json.loads(sys.stdin.readline())
        print(json.dumps({'id':3,'result':{'thread':{'id':second['params']['threadId'],'name':'Loaded title'}}}),flush=True)
        """)
        let result = try await CodexAppServerProcessRunner.run(
            executable: script,
            threadIDs: ["stale-thread", "loaded-thread"],
            timeout: 1.5,
            maximumOutputBytes: 1_048_576
        )
        XCTAssertEqual(result, [
            "stale-thread": .missing,
            "loaded-thread": .title("Loaded title"),
        ])
    }

    func testProcessRunnerRejectsNearMatchThreadNotLoadedErrorsAndMismatchedResponseID() async throws {
        let invalidResponses = [
            "{'id':2,'error':{'code':-32601,'message':'thread not loaded: expected'}}",
            "{'id':2,'error':{'code':-32600.5,'message':'thread not loaded: expected'}}",
            "{'id':2,'error':{'code':-32600,'message':'thread not loaded: different'}}",
            "{'id':2,'error':{'code':-32600,'message':'thread not loaded: expected','detail':'extra'}}",
            "{'id':2,'error':{'code':-32600,'message':'thread not loaded: expected'},'result':{}}",
            "{'id':2.5,'error':{'code':-32600,'message':'thread not loaded: expected'}}",
            "{'id':999,'error':{'code':-32600,'message':'thread not loaded: expected'}}",
        ]

        for invalidResponse in invalidResponses {
            let script = try makePythonExecutable("""
            import json,sys
            json.loads(sys.stdin.readline()); print(json.dumps({'id':1,'result':{}}),flush=True)
            json.loads(sys.stdin.readline()); json.loads(sys.stdin.readline())
            print(json.dumps(\(invalidResponse)),flush=True)
            """)
            do {
                _ = try await CodexAppServerProcessRunner.run(
                    executable: script,
                    threadIDs: ["expected"],
                    timeout: 1,
                    maximumOutputBytes: 1_048_576
                )
                XCTFail("expected protocol violation for \(invalidResponse)")
            } catch CodexAppServerResolutionFailure.protocolViolation {
                // Expected: only the exact stale-thread error is recoverable.
            } catch {
                XCTFail("expected protocol violation, got \(error)")
            }
        }

        let booleanInitializeID = try makePythonExecutable("""
        import json,sys
        json.loads(sys.stdin.readline()); print(json.dumps({'id':True,'result':{}}),flush=True)
        """)
        do {
            _ = try await CodexAppServerProcessRunner.run(
                executable: booleanInitializeID,
                threadIDs: ["expected"],
                timeout: 1,
                maximumOutputBytes: 1_048_576
            )
            XCTFail("expected protocol violation for a Boolean response ID")
        } catch CodexAppServerResolutionFailure.protocolViolation {
            // Expected: JSON-RPC identifiers must be exact non-Boolean numbers.
        } catch {
            XCTFail("expected protocol violation, got \(error)")
        }
    }

    func testProcessRunnerRejectsMismatchedMalformedAndOversizedResponses() async throws {
        let mismatched = try makePythonExecutable("""
        import json,sys
        json.loads(sys.stdin.readline()); print(json.dumps({'id':1,'result':{}}),flush=True)
        json.loads(sys.stdin.readline()); req=json.loads(sys.stdin.readline())
        print(json.dumps({'id':2,'result':{'thread':{'id':'wrong','name':'No'}}}),flush=True)
        """)
        await XCTAssertThrowsAsync {
            _ = try await CodexAppServerProcessRunner.run(executable: mismatched, threadIDs: ["expected"], timeout: 1, maximumOutputBytes: 1_048_576)
        }

        let malformed = try makePythonExecutable("import sys; print('{bad json',flush=True); sys.stdin.read()")
        await XCTAssertThrowsAsync {
            _ = try await CodexAppServerProcessRunner.run(executable: malformed, threadIDs: ["x"], timeout: 1, maximumOutputBytes: 1_048_576)
        }

        let oversized = try makePythonExecutable("import sys; sys.stdout.write('x'*2048); sys.stdout.flush(); sys.stdin.read()")
        await XCTAssertThrowsAsync {
            _ = try await CodexAppServerProcessRunner.run(executable: oversized, threadIDs: ["x"], timeout: 1, maximumOutputBytes: 1024)
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
            executable: script, threadIDs: ["x"], timeout: 1.5, maximumOutputBytes: 1_048_576
        )
        XCTAssertEqual(result, ["x": .title("Done")])
    }

    func testTimeoutAndCancellationTerminateAndReapProcess() async throws {
        let directory = try temporaryDirectory()
        let marker = directory.appendingPathComponent("term")
        let ready = directory.appendingPathComponent("ready")
        let pidFile = directory.appendingPathComponent("pid")
        let script = directory.appendingPathComponent("fake-codex-term")
        try """
        #!/bin/sh
        trap 'echo term > "\(marker.path)"; exit 0' TERM
        echo $$ > "\(pidFile.path)"
        echo ready > "\(ready.path)"
        while :; do sleep 0.05; done
        """.write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(script.path, 0o700), 0)

        let timeoutTask = Task {
            try await CodexAppServerProcessRunner.run(
                executable: script,
                threadIDs: ["x"],
                timeout: 2,
                maximumOutputBytes: 1024
            )
        }
        let timeoutReady = try await waitForFile(ready, timeout: 1)
        XCTAssertTrue(timeoutReady)
        await XCTAssertThrowsAsync {
            _ = try await timeoutTask.value
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(try processFromFileIsRunning(pidFile))

        try FileManager.default.removeItem(at: marker)
        try FileManager.default.removeItem(at: ready)
        try FileManager.default.removeItem(at: pidFile)

        let task = Task {
            try await CodexAppServerProcessRunner.run(executable: script, threadIDs: ["x"], timeout: 5, maximumOutputBytes: 1024)
        }
        let cancellationReady = try await waitForFile(ready, timeout: 1)
        XCTAssertTrue(cancellationReady)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(try processFromFileIsRunning(pidFile))
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func processFromFileIsRunning(_ url: URL) throws -> Bool {
        let rawPID = try String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(rawPID) else {
            XCTFail("helper did not publish a valid process identifier")
            return true
        }
        errno = 0
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
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
}

private extension XCTestCase {
    func XCTAssertThrowsAsync(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {}
    }
}
