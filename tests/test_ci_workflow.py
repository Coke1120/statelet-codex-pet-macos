from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"


class CIWorkflowTests(unittest.TestCase):
    def test_ci_avoids_duplicate_branch_and_tag_runs(self) -> None:
        ci_triggers = CI_WORKFLOW.read_text(encoding="utf-8").split("permissions:", 1)[0]
        release_triggers = RELEASE_WORKFLOW.read_text(encoding="utf-8").split("permissions:", 1)[0]

        self.assertIn("push:\n    branches:\n      - main", ci_triggers)
        self.assertIn("pull_request:", ci_triggers)
        self.assertIn("workflow_dispatch:", ci_triggers)
        self.assertNotIn("tags:", ci_triggers)
        self.assertIn('tags:\n      - "v*"', release_triggers)

    def test_ci_runs_the_complete_opt_in_avplayer_integration_suite(self) -> None:
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("--skip PetPlayerPlaybackIntegrationTests", workflow)
        self.assertIn("--filter PetPlayerPlaybackIntegrationTests", workflow)
        self.assertNotIn(
            "--filter PetPlayerPlaybackIntegrationTests/testSameState",
            workflow,
        )


if __name__ == "__main__":
    unittest.main()
