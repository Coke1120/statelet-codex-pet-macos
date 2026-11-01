#!/usr/bin/env python3
"""Installer voice migration using temporary homes and a simulated launchd only."""

import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import unittest
from pathlib import Path

import test_macos_pet_packaging as packaging


LABEL = "com.coke1120.statelet.gpt-sovits"
HELPER = packaging.PACKAGE / "scripts/gpt_sovits_launch_agent.py"
spec = importlib.util.spec_from_file_location("gpt_sovits_launch_agent", HELPER)
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class GPTSoVITSInstallerTests(unittest.TestCase):
    setUp = packaging.MacPetPackagingTests.setUp
    tearDown = packaging.MacPetPackagingTests.tearDown
    make_bundle = packaging.MacPetPackagingTests.make_bundle
    journal_command = packaging.MacPetPackagingTests.journal_command

    def voice_payload(self, *, marked=False, run_at_load=True):
        working = self.home / "GPT-SoVITS"
        support = self.home / "Library/Application Support/Statelet"
        payload = {
            "Label": LABEL,
            "ProgramArguments": [str(working / ".venv/bin/python"), str(working / "api_v2.py"),
                                 "-a", "127.0.0.1", "-p", "9880", "-c", str(working / "tts.yaml")],
            "WorkingDirectory": str(working),
            "EnvironmentVariables": {"HF_HUB_OFFLINE": "1", "PYTHONUNBUFFERED": "1",
                                     "TRANSFORMERS_OFFLINE": "1", "TLS_CONFIG": "private.pem"},
            "StandardOutPath": str(support / "voice/logs/gpt-sovits.out.log"),
            "StandardErrorPath": str(support / "voice/logs/gpt-sovits.err.log"),
            "RunAtLoad": run_at_load, "KeepAlive": False,
            "ThrottleInterval": 10, "Umask": 63, "ProcessType": "Background",
        }
        if marked:
            payload["StateletManaged"] = "statelet-v2"
        return payload

    def write_voice(self, payload):
        plist = self.home / "Library/LaunchAgents" / (LABEL + ".plist")
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_BINARY, sort_keys=False))
        plist.chmod(0o600)
        return plist

    def fake_launchctl(self, *, loaded=False, running=False):
        fake_bin = self.base / "fake-voice-bin"
        fake_bin.mkdir(exist_ok=True)
        state = fake_bin / "state.json"
        state.write_text(json.dumps({LABEL: {"running": running}} if loaded else {}))
        log = fake_bin / "log.jsonl"
        launchctl = fake_bin / "launchctl"
        launchctl.write_text("#!" + sys.executable + "\n" + '''
import json, os, plistlib, sys
from pathlib import Path
state_path = Path(os.environ["VOICE_FAKE_STATE"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
with open(os.environ["VOICE_FAKE_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
action = args[0]
label = Path(args[2]).stem if action == "bootstrap" else args[-1].rsplit("/", 1)[-1]
if action == os.environ.get("VOICE_FAKE_FAIL_ACTION") and label == os.environ.get("VOICE_FAKE_FAIL_LABEL"):
    sys.exit(64)
if action == "print":
    if label not in state:
        sys.exit(113)
    print(args[-1] + " = {")
    print("\\tpath = " + os.environ.get("VOICE_FAKE_LOADED_PATH", str(Path(os.environ["HOME"]) / "Library/LaunchAgents" / (label + ".plist"))))
    print("\\ttype = LaunchAgent")
    print("\\tstate = " + ("running" if state[label]["running"] else "not running"))
    if state[label]["running"]:
        print("\\tpid = 12345")
elif action == "bootstrap":
    if label in state:
        sys.exit(5)
    payload = plistlib.loads(Path(args[2]).read_bytes())
    state[label] = {"running": payload.get("RunAtLoad", False), "flags": {
        "RunAtLoad": payload.get("RunAtLoad"), "KeepAlive": payload.get("KeepAlive")}}
elif action == "bootout":
    if label not in state:
        sys.exit(113)
    del state[label]
    if label == os.environ.get("VOICE_FAKE_TAMPER_LABEL"):
        with open(os.environ["VOICE_FAKE_TAMPER_PATH"], "ab") as target:
            target.write(b"tampered")
elif action in ("kickstart", "kill"):
    if label not in state:
        sys.exit(113)
    state[label]["running"] = action == "kickstart"
else:
    sys.exit(2)
state_path.write_text(json.dumps(state))
''')
        launchctl.chmod(0o755)
        environment = os.environ.copy()
        environment.update(HOME=str(self.home), PATH=str(fake_bin) + ":" + environment["PATH"],
                           VOICE_FAKE_STATE=str(state), VOICE_FAKE_LOG=str(log))
        return environment, state, log

    def run_installer(self, environment, *options, player=False):
        bundle = self.make_bundle("VoiceMigration")
        return subprocess.run(["bash", str(packaging.INSTALL_SCRIPT), "--app-bundle", str(bundle),
                               *([] if player else ["--no-player-launch-agent"]), *options], cwd=packaging.ROOT,
                              env=environment, capture_output=True, text=True, timeout=120)

    def voice_commands(self, log):
        return [row for row in map(json.loads, log.read_text().splitlines())
                if any(LABEL in value for value in row)] if log.exists() else []

    def assert_on_demand(self, plist, original):
        migrated = plistlib.loads(plist.read_bytes())
        self.assertEqual(migrated, {**original, "StateletManaged": "statelet-v2",
                                    "RunAtLoad": False, "KeepAlive": False})
        self.assertEqual(plist.stat().st_mode & 0o777, 0o600)

    def test_unmarked_legacy_api_job_is_loaded_idle_and_private_assets_survive(self):
        original = self.voice_payload()
        plist = self.write_voice(original)
        assets = self.home / "Library/Application Support/Statelet/voice"
        assets.mkdir(parents=True)
        for name in ("tts.yaml", "gateway.py", "leaf.pem", "model.ckpt"):
            (assets / name).write_bytes(b"private fixture unchanged")
        provider = assets / "library.json"
        provider.write_text('{"activeProvider":"voxcpm2"}')
        profile = assets / "dialogue-voice.json"
        profile.write_text(json.dumps({"active_provider": "voxcpm2", "profile": {
            "api_base_url": "https://127.0.0.1:9881", "tls_leaf_certificate_sha256": "a" * 64}}))
        before_profile = profile.read_bytes()
        environment, state, log = self.fake_launchctl(loaded=True, running=True)

        result = self.run_installer(environment)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_on_demand(plist, {**original, "StateletVoiceEndpoint": "https://127.0.0.1:9881"})
        self.assertEqual(plistlib.loads(plist.read_bytes())["ProgramArguments"][5], "9880")
        self.assertEqual(profile.read_bytes(), before_profile)
        self.assertEqual(json.loads(state.read_text())[LABEL], {
            "running": False, "flags": {"RunAtLoad": False, "KeepAlive": False}})
        actions = [command[0] for command in self.voice_commands(log)]
        self.assertEqual(actions.count("bootout"), 1)
        self.assertEqual(actions.count("bootstrap"), 1)
        self.assertNotIn("kickstart", actions)
        for name in ("tts.yaml", "gateway.py", "leaf.pem", "model.ckpt"):
            self.assertEqual((assets / name).read_bytes(), b"private fixture unchanged")
        self.assertEqual(provider.read_text(), '{"activeProvider":"voxcpm2"}')

    def test_marked_custom_tls_gateway_remains_externally_managed(self):
        original = self.voice_payload(marked=True)
        original["ProgramArguments"] = ["/custom/python", "/custom/tls_gateway.py", "--config", "/private/config"]
        original["KeepAlive"] = True
        plist = self.write_voice(original)
        environment, state, log = self.fake_launchctl(loaded=True, running=True)
        result = self.run_installer(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads(plist.read_bytes()), original)
        self.assertTrue(json.loads(state.read_text())[LABEL]["running"])
        self.assertFalse(self.voice_commands(log))
        self.assertNotIn("bootout", [row[0] for row in self.voice_commands(log)])

    def test_absent_plist_does_not_create_or_manage_orphan_label(self):
        environment, state, log = self.fake_launchctl(loaded=True, running=True)
        result = self.run_installer(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / "Library/LaunchAgents" / (LABEL + ".plist")).exists())
        self.assertTrue(json.loads(state.read_text())[LABEL]["running"])
        self.assertEqual(self.voice_commands(log), [])

    def test_unknown_job_is_preserved_and_not_managed(self):
        original = self.voice_payload()
        original["ProgramArguments"] = ["/usr/bin/python3", "/external/server.py"]
        plist = self.write_voice(original)
        before = plist.read_bytes()
        environment, state, log = self.fake_launchctl(loaded=True, running=True)
        result = self.run_installer(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plist.read_bytes(), before)
        self.assertTrue(json.loads(state.read_text())[LABEL]["running"])
        self.assertEqual(self.voice_commands(log), [])

    def test_already_migrated_loaded_job_is_retained_without_restart(self):
        original = self.voice_payload(marked=True, run_at_load=False)
        plist = self.write_voice(original)
        before = plist.read_bytes()
        environment, state, log = self.fake_launchctl(loaded=True, running=True)
        result = self.run_installer(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plist.read_bytes(), before)
        self.assertTrue(json.loads(state.read_text())[LABEL]["running"])
        self.assertFalse(any(row[0] != "print" for row in self.voice_commands(log)))

    def test_already_migrated_unloaded_job_is_bootstrapped_without_starting(self):
        original = self.voice_payload(marked=True, run_at_load=False)
        plist = self.write_voice(original)
        environment, state, log = self.fake_launchctl()
        result = self.run_installer(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_on_demand(plist, original)
        self.assertFalse(json.loads(state.read_text())[LABEL]["running"])
        self.assertEqual([row[0] for row in self.voice_commands(log) if row[0] != "print"], ["bootstrap"])

    def test_skip_launchctl_migrates_only_files(self):
        original = self.voice_payload()
        plist = self.write_voice(original)
        environment, state, log = self.fake_launchctl(loaded=True, running=True)
        before = state.read_bytes()
        result = self.run_installer(environment, "--skip-launchctl")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_on_demand(plist, original)
        self.assertEqual(state.read_bytes(), before)
        self.assertFalse(log.exists())

    def test_precommit_failure_restores_original_plist_and_launch_state(self):
        for loaded, running, run_at_load in ((False, False, True), (True, True, True),
                                            (True, False, True), (True, True, False)):
            with self.subTest(loaded=loaded, running=running, run_at_load=run_at_load):
                self.home = self.base / f"home-{loaded}-{running}-{run_at_load}"
                self.home.mkdir()
                original = self.voice_payload(run_at_load=run_at_load)
                plist = self.write_voice(original)
                before = plist.read_bytes()
                environment, state, log = self.fake_launchctl(loaded=loaded, running=running)
                environment["STATELET_INSTALL_FAIL_AT"] = "after-support"
                result = self.run_installer(environment)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertEqual(plist.read_bytes(), before)
                jobs = json.loads(state.read_text())
                self.assertEqual(LABEL in jobs, loaded)
                if loaded:
                    self.assertEqual(jobs[LABEL]["running"], running)
                self.assertFalse((self.home / ".statelet-install-transaction").exists())
                self.assertEqual(any(row[0] == "kickstart" for row in self.voice_commands(log)),
                                 loaded and running and not run_at_load)
                log.unlink()

    def test_bootstrap_failure_retains_sealed_files_then_recovers_forward_idle(self):
        original = self.voice_payload()
        plist = self.write_voice(original)
        environment, state, log = self.fake_launchctl(loaded=True, running=True)
        environment.update(VOICE_FAKE_FAIL_ACTION="bootstrap", VOICE_FAKE_FAIL_LABEL=LABEL)
        failed = self.run_installer(environment)
        self.assertEqual(failed.returncode, 71, failed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "files-committed")
        self.assert_on_demand(plist, original)
        self.assertNotIn(LABEL, json.loads(state.read_text()))
        environment.pop("VOICE_FAKE_FAIL_ACTION")
        recovered = self.run_installer(environment)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertFalse(json.loads(state.read_text())[LABEL]["running"])
        self.assertFalse(transaction.exists())
        self.assertNotIn("kickstart", [row[0] for row in self.voice_commands(log)])

    def test_bootout_failure_keeps_original_running_job(self):
        plist = self.write_voice(self.voice_payload())
        before = plist.read_bytes()
        environment, state, log = self.fake_launchctl(loaded=True, running=True)
        environment.update(VOICE_FAKE_FAIL_ACTION="bootout", VOICE_FAKE_FAIL_LABEL=LABEL)
        result = self.run_installer(environment)
        self.assertEqual(result.returncode, 72, result.stderr)
        self.assertEqual(plist.read_bytes(), before)
        self.assertTrue(json.loads(state.read_text())[LABEL]["running"])
        self.assertNotIn("bootstrap", [row[0] for row in self.voice_commands(log)])

    def test_crash_after_files_commit_recovers_forward_without_starting_engine(self):
        original = self.voice_payload()
        plist = self.write_voice(original)
        environment, state, log = self.fake_launchctl(loaded=True, running=False)
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = self.run_installer(environment, player=True)
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        self.assert_on_demand(plist, original)
        self.assertNotIn(LABEL, json.loads(state.read_text()))
        environment.pop("STATELET_INSTALL_CRASH_AT")
        before = len(log.read_text().splitlines())
        recovered = self.run_installer(environment, player=True)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertFalse(json.loads(state.read_text())[LABEL]["running"])
        self.assertNotIn("kickstart", [row[0] for row in self.voice_commands(log)])
        self.assertFalse((self.home / ".statelet-install-transaction").exists())
        recovery = list(map(json.loads, log.read_text().splitlines()[before:]))
        bootstraps = [row[2] for row in recovery if row[0] == "bootstrap"]
        self.assertLess(next(i for i, path in enumerate(bootstraps) if LABEL in path),
                        next(i for i, path in enumerate(bootstraps) if "mac-player" in path))

    def test_loaded_job_from_an_unrelated_plist_is_not_stopped(self):
        plist = self.write_voice(self.voice_payload())
        original = plist.read_bytes()
        environment, state, log = self.fake_launchctl(loaded=True, running=True)
        environment["VOICE_FAKE_LOADED_PATH"] = "/external/unrelated.plist"
        result = self.run_installer(environment)
        self.assertEqual(result.returncode, 72, result.stderr)
        self.assertEqual(plist.read_bytes(), original)
        self.assertTrue(json.loads(state.read_text())[LABEL]["running"])
        self.assertFalse(any(row[0] != "print" for row in self.voice_commands(log)))

    def test_changed_original_after_bootout_fails_closed(self):
        plist = self.write_voice(self.voice_payload())
        environment, state, log = self.fake_launchctl(loaded=True, running=True)
        environment.update(VOICE_FAKE_TAMPER_LABEL=LABEL, VOICE_FAKE_TAMPER_PATH=str(plist))
        result = self.run_installer(environment)
        self.assertEqual(result.returncode, 74, result.stderr)
        self.assertTrue(plist.read_bytes().endswith(b"tampered"))
        self.assertNotIn("bootstrap", [row[0] for row in self.voice_commands(log)])

    def test_recognition_rejects_unknown_markers_triggers_and_external_lookalikes(self):
        payload = self.voice_payload()
        variants = ({"Label": "com.example.other"}, {"StateletManaged": "someone-else"},
                    {"StandardOutPath": "/tmp/gpt-sovits.log"}, {"KeepAlive": True},
                    {"ProgramArguments": ["/bin/sh", "-c", "external-server"]},
                    {"ProgramArguments": [*payload["ProgramArguments"][:3], "0.0.0.0", *payload["ProgramArguments"][4:]]})
        for updates in variants:
            with self.subTest(updates=updates):
                self.assertIsNone(migration.migrate_plist({**payload, **updates}, self.home))
        for trigger in migration.START_TRIGGERS:
            with self.subTest(trigger=trigger):
                self.assertIsNone(migration.migrate_plist({**payload, "StateletManaged": "statelet-v2",
                                                          trigger: {}}, self.home))

    def test_staging_ignores_symlinks_hardlinks_and_writable_or_malformed_jobs(self):
        for unsafe in ("symlink", "hardlink", "writable", "malformed"):
            with self.subTest(unsafe=unsafe):
                self.home = self.base / ("unsafe-" + unsafe)
                self.home.mkdir()
                plist = self.write_voice(self.voice_payload())
                if unsafe in {"symlink", "hardlink"}:
                    outside = self.base / (unsafe + ".plist")
                    plist.rename(outside)
                    if unsafe == "symlink":
                        plist.symlink_to(outside)
                    else:
                        os.link(outside, plist)
                elif unsafe == "writable":
                    plist.chmod(0o666)
                else:
                    plist.write_bytes(b"not a plist")
                before = plist.read_bytes()
                transaction = self.home / ".statelet-install-transaction"
                self.assertEqual(self.journal_command(transaction, "init").returncode, 0)
                result = self.journal_command(transaction, "gpt-stage", str(HELPER))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "absent")
                self.assertEqual(plist.read_bytes(), before)
                self.assertNotIn("gpt_sovits", json.loads((transaction / "journal.json").read_text()))

    def test_staging_endpoint_binding_requires_valid_profile_and_preserves_explicit_binding(self):
        valid = {"profile": {"api_base_url": "https://127.0.0.1:9881", "tls_leaf_certificate_sha256": "aB" * 32}}
        cases = ((valid, None, "https://127.0.0.1:9881"),
                 (valid, "https://127.0.0.1:9443", "https://127.0.0.1:9443"),
                 ({"profile": {**valid["profile"], "api_base_url": "http://127.0.0.1:9881"}}, None, None),
                 ({"profile": {**valid["profile"], "tls_leaf_certificate_sha256": "x" * 64}}, None, None),
                 ({"profile": {"api_base_url": "https://127.0.0.1:9881"}}, None, None),
                 ({"active_provider": "voxcpm2"}, None, None))
        for index, (document, explicit, expected) in enumerate(cases):
            with self.subTest(index=index):
                self.home = self.base / f"endpoint-{index}"
                self.home.mkdir()
                original = self.voice_payload()
                if explicit is not None:
                    original["StateletVoiceEndpoint"] = explicit
                plist = self.write_voice(original)
                profile = self.home / "Library/Application Support/Statelet/voice/dialogue-voice.json"
                profile.parent.mkdir(parents=True)
                profile.write_text(json.dumps(document))
                before = profile.read_bytes()
                transaction = self.home / ".statelet-install-transaction"
                self.assertEqual(self.journal_command(transaction, "init").returncode, 0)
                result = self.journal_command(transaction, "gpt-stage", str(HELPER))
                self.assertEqual(result.returncode, 0, result.stderr)
                stage = transaction / "stage" / (LABEL + ".plist")
                staged = plistlib.loads(stage.read_bytes())
                self.assertEqual(staged.get("StateletVoiceEndpoint"), expected)
                self.assertEqual(staged["ProgramArguments"], original["ProgramArguments"])
                self.assertEqual(profile.read_bytes(), before)
                self.assertEqual(plistlib.loads(plist.read_bytes()), original)

    def test_profile_endpoint_rejects_noncanonical_nonloopback_urls_and_invalid_pins(self):
        def profile(endpoint="https://127.0.0.1:9881", pin="a" * 64):
            return {"profile": {"api_base_url": endpoint, "tls_leaf_certificate_sha256": pin}}
        for endpoint in ("https://127.0.0.1:9881", "https://[::1]:9881", "https://127.0.0.2/", "https://127.0.0.1"):
            self.assertEqual(migration.profile_endpoint(profile(endpoint)), endpoint)
        for endpoint in ("http://127.0.0.1:9881", "https://localhost:9881", "https://0.0.0.0:9881",
                         "https://192.168.1.2:9881", "https://127.1:9881", "https://2130706433:9881",
                         "https://user@127.0.0.1:9881", "https://127.0.0.1:9881/tts",
                         "https://127.0.0.1:9881?x=1", "https://127.0.0.1:9881#fragment",
                         "https://127.0.0.1:0", "https://127.0.0.1:65536", "https://127.0.0.1:09881",
                         "https://[::1%lo0]:9881", "https://127.0.0.1:9881\n", None, 9881):
            with self.subTest(endpoint=endpoint):
                self.assertIsNone(migration.profile_endpoint(profile(endpoint)))
        for pin in (None, "a" * 63, "a" * 65, "g" * 64, " " + "a" * 64, 1234):
            with self.subTest(pin=pin):
                self.assertIsNone(migration.profile_endpoint(profile(pin=pin)))


if __name__ == "__main__":
    unittest.main()
