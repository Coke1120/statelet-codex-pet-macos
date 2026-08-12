import AppKit
import CodexPetCore
import XCTest
@testable import CodexPetMac

final class DialogueVoiceSettingsViewTests: XCTestCase {
    @MainActor
    func testConsecutiveAddsPreserveSubmittedStateAndLanguage() throws {
        let view = DialogueVoiceSettingsView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        var library = try DialogueVoiceLibrary()
        let draft = DialogueVoiceProfileDraft(
            name: "",
            apiBaseURL: "http://127.0.0.1:9880",
            promptLanguage: "japanese",
            defaultTextLanguage: "japanese",
            referenceText: ""
        )
        func snapshot() -> DialogueVoiceCoordinatorSnapshot {
            DialogueVoiceCoordinatorSnapshot(
                library: library,
                draft: draft,
                importedAssets: DialogueVoiceImportedAssets(),
                activityMessage: nil
            )
        }
        view.update(snapshot: snapshot())

        let textView = try XCTUnwrap(Self.descendants(of: view).compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Dialogue text" })
        let statePopup = try XCTUnwrap(Self.descendants(of: view).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Owning lifecycle state" })
        let languageField = try XCTUnwrap(Self.descendants(of: view).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Dialogue text language" })
        let addButton = try XCTUnwrap(Self.descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Add dialogue line" })

        statePopup.selectItem(at: PetState.allCases.firstIndex(of: .running)!)
        languageField.stringValue = "japanese"
        view.onAddLine = { text, language, state in
            do {
                try library.addLine(text: text, language: language, state: state)
            } catch {
                XCTFail("Failed to add dialogue line: \(error)")
                return
            }
            view.update(snapshot: snapshot())
        }

        for text in ["First running line", "Second running line"] {
            textView.string = text
            view.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
            XCTAssertTrue(addButton.isEnabled)
            addButton.performClick(nil)

            XCTAssertEqual(textView.string, "")
            XCTAssertEqual(statePopup.indexOfSelectedItem, PetState.allCases.firstIndex(of: .running))
            XCTAssertEqual(languageField.stringValue, "japanese")
        }

        XCTAssertEqual(library.lines.map(\.state), [.running, .running])
        XCTAssertEqual(library.lines.map(\.textLanguage), ["japanese", "japanese"])
    }

    private static func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
