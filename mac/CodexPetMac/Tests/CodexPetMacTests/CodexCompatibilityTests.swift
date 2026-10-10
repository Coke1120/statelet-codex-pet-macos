import Darwin
import Foundation
import XCTest
@testable import Statelet

final class CodexCompatibilityTests: XCTestCase {
    func testVersionsAreBoundedAndNeverEchoUnrecognizedText() {
        XCTAssertEqual(CodexCLIVersion.parse("codex-cli 0.159.2\n")?.label, "0.159.2")
        XCTAssertTrue(CodexCLIVersion.parse("codex-cli 0.159.1")! < .validatedBaseline)
        XCTAssertTrue(CodexCLIVersion.validatedBaseline < CodexCLIVersion.parse("codex-cli 1.0.0")!)
        for value in ["private prompt", "codex-cli 0.159.2 /private/account", "codex-cli 999999.1.2", "codex-cli 0.159.2-beta", "0.159.2"] {
            XCTAssertNil(CodexCLIVersion.parse(value))
        }
    }

    func testHookMetadataDistinguishesReadyReviewModifiedAndDisabled() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for (trust, enabled, expected) in [
            ("trusted", true, CodexHookSummary.Status.ready),
            ("managed", true, .ready), ("untrusted", true, .needsReview),
            ("modified", true, .modified), ("trusted", false, .disabled),
        ] {
            let result = fixture.hooks(trust: trust, enabled: enabled)
            let summary = fixture.evaluate(result)
            XCTAssertEqual(summary.status, expected)
            XCTAssertEqual(summary.registered, 12)
        }
    }

    func testMissingIncompleteAndMisleadingDefinitionsAreNotReady() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(fixture.evaluate(fixture.hooks(entries: [])).status, .missing)
        var entries = fixture.entries()
        entries.removeLast()
        XCTAssertEqual(fixture.evaluate(fixture.hooks(entries: entries)).status, .incomplete)
        entries = fixture.entries()
        entries[0]["command"] = "echo \(fixture.command)"
        XCTAssertEqual(fixture.evaluate(fixture.hooks(entries: entries)).status, .incomplete)
        entries = fixture.entries()
        entries[0]["matcher"] = "resume"
        XCTAssertEqual(fixture.evaluate(fixture.hooks(entries: entries)).status, .incomplete)
        entries = fixture.entries()
        entries[1]["sourcePath"] = "/private/other/hooks.json"
        XCTAssertEqual(fixture.evaluate(fixture.hooks(entries: entries)).status, .incomplete)
    }

    func testMalformedOrWarnedMetadataAndMissingRuntimeRemainUnverified() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(fixture.evaluate([:]).status, .unverified)
        XCTAssertEqual(fixture.evaluate(["data": []]).status, .unverified)
        XCTAssertEqual(fixture.evaluate(fixture.hooks(warnings: ["private warning"])).status, .unverified)
        var entries = fixture.entries()
        entries[0]["enabled"] = 1
        XCTAssertEqual(fixture.evaluate(fixture.hooks(entries: entries)).status, .unverified)
        entries = fixture.entries()
        entries[0]["trustStatus"] = "private status"
        XCTAssertEqual(fixture.evaluate(fixture.hooks(entries: entries)).status, .unverified)
        try FileManager.default.removeItem(at: fixture.hook)
        XCTAssertEqual(fixture.evaluate(fixture.hooks()).status, .runtimeUnavailable)
    }

    func testDuplicateUntrustedDefinitionDoesNotHideHealthyRegistration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var entries = fixture.entries()
        var duplicate = entries[0]; duplicate["trustStatus"] = "untrusted"
        entries.append(duplicate)
        let summary = fixture.evaluate(fixture.hooks(entries: entries))
        XCTAssertEqual(summary.status, .needsReview)
        XCTAssertEqual(summary.needsReview, 1)
    }

    func testSyntheticCompatibleCLIProbesOnlyOfflineAndReadOnlyMethods() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.cli()
        let report = fixture.service(executable).check(control: CodexAppServerProcessControl())
        XCTAssertEqual(report.installation, .signed)
        XCTAssertEqual(report.version, .validatedBaseline)
        XCTAssertEqual(report.flags, .compatible)
        XCTAssertEqual(report.features, .compatible)
        XCTAssertEqual(report.hooks.status, .ready)
        let calls = try String(contentsOf: fixture.calls)
        XCTAssertTrue(calls.contains("hooks/list"))
        XCTAssertFalse(calls.contains("thread/"))
        XCTAssertFalse(calls.contains("/write"))
        XCTAssertFalse(calls.contains("bypass"))
        XCTAssertFalse(calls.contains("private-draft"))
        XCTAssertFalse(report.diagnosticLines.joined().contains(fixture.home.path))
    }

    func testOldFlagsMissingFeaturesAndDisabledHooksHaveDifferentActions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = fixture.service(try fixture.cli(version: "0.100.0", rejectHelp: true))
            .check(control: CodexAppServerProcessControl())
        XCTAssertEqual(old.flags, .incompatible)
        XCTAssertTrue(old.diagnosticLines.joined().contains("older-than-validated"))
        let missingFeature = fixture.service(try fixture.cli(missingFeature: "view_image"))
            .check(control: CodexAppServerProcessControl())
        XCTAssertEqual(missingFeature.features, .incompatible)
        let disabled = fixture.service(try fixture.cli(hooksEnabled: false))
            .check(control: CodexAppServerProcessControl())
        XCTAssertEqual(disabled.hooks.status, .featureDisabled)
        XCTAssertFalse(try String(contentsOf: fixture.calls).contains("hooks/list"))
    }

    func testMissingUnsignedCancelledAndBoundedFailureNeverLeakRawOutput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.service(fixture.home.appendingPathComponent("absent"))
            .check(control: CodexAppServerProcessControl())
        XCTAssertEqual(missing.installation, .missing)
        let executable = try fixture.cli()
        var unsigned = fixture.service(executable)
        unsigned.trustPolicy = .openAISigned
        XCTAssertEqual(unsigned.check(control: CodexAppServerProcessControl()).installation, .unverified)
        let cancelled = CodexAppServerProcessControl(); cancelled.cancel()
        XCTAssertEqual(fixture.service(executable).check(control: cancelled).flags, .unverified)
        for mode in ["timeout", "overflow", "error"] {
            let started = Date()
            let failed = fixture.service(try fixture.cli(failure: mode), timeout: 0.35)
                .check(control: CodexAppServerProcessControl())
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            XCTAssertEqual(failed.flags, .unverified)
            let text = failed.diagnosticLines.joined(separator: "\n")
            for sentinel in ["private-draft", "credential-secret", "/private/account", "raw error"] {
                XCTAssertFalse(text.contains(sentinel))
            }
        }
    }

    func testCancellingAnActiveProbeStopsAndCleansUpWithoutReportingHealth() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service(try fixture.cli(failure: "timeout"))
        let control = CodexAppServerProcessControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { control.cancel() }
        let started = Date()
        let snapshot = service.check(control: control)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(snapshot.flags, .unverified)
        XCTAssertEqual(snapshot.hooks.status, .unverified)
    }

    private struct Fixture {
        let home: URL
        var hook: URL { home.appendingPathComponent("Library/Application Support/Statelet/python/statelet_hook.py") }
        var codexHome: URL { home.appendingPathComponent(".codex") }
        var calls: URL { home.appendingPathComponent("calls") }
        var command: String { "/usr/bin/python3 '\(hook.path)' >/dev/null 2>&1 || :" }

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("statelet-compat-test-\(UUID())")
            try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# synthetic hook".utf8).write(to: hook)
        }
        func remove() { try? FileManager.default.removeItem(at: home) }
        func entries(trust: String = "trusted", enabled: Bool = true) -> [[String: Any]] {
            CodexHookSummary.requiredEvents.sorted().map { event in
                var entry: [String: Any] = ["handlerType": "command", "command": command,
                    "eventName": event, "source": "user", "sourcePath": codexHome.appendingPathComponent("hooks.json").path,
                    "enabled": enabled, "trustStatus": trust,
                    "statusMessage": "private-draft credential-secret", "key": "/private/account",
                    "currentHash": "private hash"]
                if event == "sessionStart" { entry["matcher"] = "startup|resume|clear|compact" }
                return entry
            }
        }
        func hooks(trust: String = "trusted", enabled: Bool = true,
                   entries: [[String: Any]]? = nil, warnings: [String] = []) -> [String: Any] {
            ["data": [["cwd": "/private/account", "hooks": entries ?? self.entries(trust: trust, enabled: enabled),
                       "warnings": warnings, "errors": []]]]
        }
        func evaluate(_ result: [String: Any]) -> CodexHookSummary {
            CodexHookSummary.evaluate(result, expectedHook: hook, codexHome: codexHome)
        }
        func service(_ executable: URL, timeout: TimeInterval = 5) -> CodexCompatibilityService {
            CodexCompatibilityService(candidates: { [executable] }, trustPolicy: .testOnlyAllowUnsignedExecutable,
                homeURL: home, codexHomeURL: codexHome, timeout: timeout)
        }
        func cli(version: String = "0.159.2", rejectHelp: Bool = false,
                 missingFeature: String = "", hooksEnabled: Bool = true, failure: String = "") throws -> URL {
            let resultJSON = String(decoding: try JSONSerialization.data(withJSONObject: hooks()), as: UTF8.self)
            let disabled = CompanionChatPolicy.disabledFeatures
            let featuresJSON = String(decoding: try JSONSerialization.data(withJSONObject: disabled), as: UTF8.self)
            let executable = home.appendingPathComponent("cli")
            let source = """
            #!/usr/bin/python3
            import json, os, sys, time
            args = sys.argv[1:]
            calls = \(String(reflecting: calls.path))
            with open(calls, 'a') as f: f.write(json.dumps(args) + '\\n')
            if \(String(reflecting: failure)) == 'timeout': time.sleep(5)
            if \(String(reflecting: failure)) == 'overflow': print('private-draft' * 200000); sys.exit(0)
            if \(String(reflecting: failure)) == 'error': print('credential-secret /private/account raw error', file=sys.stderr); sys.exit(1)
            if args == ['--version']: print('codex-cli \(version)'); sys.exit(0)
            if '--help' in args:
                if \(rejectHelp ? "True" : "False"): sys.exit(2)
                print('Usage: codex exec [OPTIONS] [PROMPT]')
                sys.exit(0)
            if 'features' in args:
                for feature in json.loads(\(String(reflecting: featuresJSON))):
                    if feature == \(String(reflecting: missingFeature)): continue
                    value = '\(hooksEnabled ? "true" : "false")' if feature == 'hooks' and '--disable' not in args else 'false'
                    print(feature + '\\texperimental\\t' + value)
                sys.exit(0)
            if 'app-server' not in args: sys.exit(2)
            for line in sys.stdin:
                message = json.loads(line)
                with open(calls, 'a') as f: f.write(message['method'] + '\\n')
                if message['method'] == 'initialize': result = {}
                elif message['method'] == 'initialized': continue
                elif message['method'] == 'hooks/list': result = json.loads(\(String(reflecting: resultJSON)))
                else: sys.exit(3)
                print(json.dumps({'id': message['id'], 'result': result}), flush=True)
            """
            try source.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try? FileManager.default.removeItem(at: calls)
            return executable
        }
    }
}
