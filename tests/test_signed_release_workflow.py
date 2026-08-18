import base64
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
SIGNER = ROOT / "mac" / "CodexPetMac" / "scripts" / "sign_update_manifest.swift"


class SignedReleaseWorkflowTests(unittest.TestCase):
    def test_workflow_is_bound_to_protected_main_and_repository_identity(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("runs-on: macos-15", workflow)
        self.assertIn("git merge-base --is-ancestor", workflow)
        self.assertIn("refs/remotes/origin/main", workflow)
        self.assertIn('ACTUAL_REPOSITORY" == "Coke1120/statelet-codex-pet-macos', workflow)
        self.assertIn('ACTUAL_REPOSITORY_ID" == "1329561047', workflow)
        self.assertIn("refs/tags/$tag^{commit}", workflow)

    def test_workflow_uses_only_expected_signed_assets_and_secret(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Statelet-macos-$architecture.zip", workflow)
        self.assertIn("$asset_path.manifest.json", workflow)
        self.assertIn("$asset_path.manifest.sig", workflow)
        self.assertIn("secrets.STATELET_UPDATE_SIGNING_PRIVATE_KEY_B64", workflow)
        self.assertIn('expected_public_key="AXJpDm8ZsTUvMGS7dzbiNxBIGwehb+ern2ietCTAgIg="', workflow)
        self.assertIn('"$RUNNER_TEMP/sign-update-manifest" public-key', workflow)
        self.assertIn("gh release upload", workflow)
        self.assertIn('expected_title="Statelet $VERSION ($BUILD)"', workflow)
        self.assertIn("--json assets,isDraft,isPrerelease,name", workflow)
        self.assertIn('release["name"] != os.environ["EXPECTED_TITLE"]', workflow)
        self.assertIn('--title "$expected_title"', workflow)
        self.assertIn("unexpected = actual - allowed", workflow)
        self.assertIn("if unexpected:", workflow)
        self.assertIn('gh release view "$TAG" --json assets', workflow)
        self.assertIn("if actual != expected:", workflow)
        self.assertNotIn("gh release delete-asset", workflow)
        self.assertNotIn("Developer ID", workflow)
        self.assertNotIn("STATELET_UPDATE_SIGNING_TEAM_IDENTIFIER", workflow)
        self.assertNotRegex(workflow, r"uses:\s+[^\s]+release[^\s]+@")

    def test_manifest_generator_has_exact_v1_schema(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        expected = {
            "schema_version",
            "repository",
            "repository_id",
            "ref",
            "commit_sha",
            "version",
            "build",
            "asset_name",
            "asset_size",
            "asset_sha256",
        }
        generated_block = workflow.split("manifest = {", 1)[1].split("}", 1)[0]
        actual = {
            line.strip().split(":", 1)[0].strip('"')
            for line in generated_block.splitlines()
            if line.strip().startswith('"')
        }
        self.assertEqual(actual, expected)
        self.assertIn('sort_keys=True, separators=(",", ":")', workflow)

    @unittest.skipUnless(shutil.which("swift"), "Swift is unavailable")
    def test_signer_signs_canonical_manifest_and_private_writes_signature(self) -> None:
        manifest = {
            "schema_version": 1,
            "repository": "Coke1120/statelet-codex-pet-macos",
            "repository_id": 1329561047,
            "ref": "refs/tags/v1.8.4",
            "commit_sha": "a" * 40,
            "version": "1.8.4",
            "build": 18,
            "asset_name": "Statelet-macos-arm64.zip",
            "asset_size": 123,
            "asset_sha256": "b" * 64,
        }
        canonical = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
        private_key = bytes(range(32))

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest_path = directory / "update.manifest.json"
            signature_path = directory / "update.manifest.sig"
            manifest_path.write_bytes(canonical)
            public_key = subprocess.run(
                ["swift", str(SIGNER), "public-key"],
                input=base64.b64encode(private_key),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(public_key.returncode, 0, public_key.stderr.decode())
            self.assertEqual(len(base64.b64decode(public_key.stdout, validate=True)), 32)

            result = subprocess.run(
                ["swift", str(SIGNER), "sign", str(manifest_path), str(signature_path)],
                input=base64.b64encode(private_key),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(len(base64.b64decode(signature_path.read_bytes(), validate=True)), 64)
            self.assertEqual(signature_path.stat().st_mode & 0o777, 0o600)

            noncanonical = directory / "noncanonical.json"
            noncanonical.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
            rejected = subprocess.run(
                ["swift", str(SIGNER), "sign", str(noncanonical), str(signature_path)],
                input=base64.b64encode(private_key),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(rejected.returncode, 0)


if __name__ == "__main__":
    unittest.main()
