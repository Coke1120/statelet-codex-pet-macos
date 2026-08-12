from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PET_PLAYER = ROOT / "mac/CodexPetMac/Sources/CodexPetMac/PetPlayer.swift"


def source() -> str:
    return PET_PLAYER.read_text(encoding="utf-8")


class PetPlayerPlaybackSourceTests(unittest.TestCase):
    def test_looper_resume_is_deferred_until_current_item_arrives(self) -> None:
        text = source()

        self.assertIn("struct DeferredPlaybackResume", text)
        self.assertIn("currentItemAvailable: queuePlayer.currentItem != nil", text)
        self.assertIn("deferredPlaybackResume.consumeWhenCurrentItemBecomesAvailable()", text)
        self.assertNotIn("guard queuePlayer.currentItem != nil else { return }", text)

    def test_suspension_cancels_deferred_resume(self) -> None:
        text = source()
        pause_case = text.split("case .pause:", 1)[1].split("case let .resume(rate):", 1)[0]

        self.assertIn("deferredPlaybackResume.cancel()", pause_case)
        self.assertIn("queuePlayer.pause()", pause_case)

    def test_dialogue_message_overlay_is_presentational_and_blank_hides_it(self) -> None:
        text = source()

        self.assertIn("func showDialogueMessage(_ message: String?)", text)
        self.assertIn("trimmingCharacters(in: .whitespacesAndNewlines)", text)
        self.assertIn("dialogueBubble.isHidden = normalized.isEmpty", text)
        self.assertIn("quickControls.frame.minX - overlayGap", text)
        self.assertIn("occupiedFrames = [stateBadge, fpsBadge, quickControls]", text)

    def test_quick_controls_are_visible_regular_size_targets(self) -> None:
        text = source()

        self.assertIn("button.bezelStyle = .texturedRounded", text)
        self.assertIn("button.controlSize = .regular", text)
        self.assertIn("button.showsBorderOnlyWhileMouseInside = false", text)
        self.assertIn("button.widthAnchor.constraint(equalToConstant: 40)", text)
        self.assertIn("button.heightAnchor.constraint(equalToConstant: 40)", text)
        self.assertIn("button.convert(button.bounds, to: self)", text)
        self.assertIn("if target.contains(point) { return button }", text)
        self.assertLess(
            text.index("for button in [nextClipButton, temporaryStateButton]"),
            text.index("if quickControls.frame.contains(point)"),
        )


if __name__ == "__main__":
    unittest.main()
