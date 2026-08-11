import AppKit

struct CharacterProfileSummary: Equatable {
    let id: String
    let name: String
    let clipCount: Int
}

struct CharacterProfileDeletionRequest: Equatable {
    let profileID: String
    let profileName: String

    init?(
        requestedProfileID: String,
        profiles: [CharacterProfileSummary],
        activeProfileID: String,
        busy: Bool
    ) {
        guard !busy,
              profiles.count > 1,
              requestedProfileID == activeProfileID,
              let profile = profiles.first(where: { $0.id == requestedProfileID }) else { return nil }
        profileID = profile.id
        profileName = profile.name
    }

    func confirmedProfileID(
        response: NSApplication.ModalResponse,
        profiles: [CharacterProfileSummary],
        activeProfileID: String,
        busy: Bool
    ) -> String? {
        guard response == .alertFirstButtonReturn,
              !busy,
              profiles.count > 1,
              activeProfileID == profileID,
              profiles.contains(where: { $0.id == profileID }) else { return nil }
        return profileID
    }
}

final class CharacterProfileSelectorView: NSView {
    var onSelectProfile: ((String) -> Void)?
    var onNewCharacter: (() -> Void)?
    var onRenameActive: (() -> Void)?
    var onDuplicateActive: (() -> Void)?
    var onDeleteActive: ((String) -> Void)?
    var onImportBundle: (() -> Void)?
    var onExportActive: (() -> Void)?

    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let actionsButton = NSButton()
    private let deleteProfileButton = NSButton(title: "Delete Profile…", target: nil, action: nil)
    private let actionsMenu = NSMenu(title: "Character actions")
    private var profiles: [CharacterProfileSummary] = []
    private var activeID: String?
    private var busy = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        update(profiles: [], activeID: nil, busy: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(profiles: [CharacterProfileSummary], activeID: String?, busy: Bool) {
        self.profiles = profiles
        self.activeID = profiles.contains(where: { $0.id == activeID }) ? activeID : profiles.first?.id
        self.busy = busy
        rebuildProfileMenu()
        rebuildActionsMenu()
        profilePopup.isEnabled = !busy
        actionsButton.isEnabled = !busy && self.activeID != nil
        deleteProfileButton.isEnabled = !busy && self.activeID != nil && profiles.count > 1
        deleteProfileButton.toolTip = profiles.count <= 1
            ? "The last character cannot be deleted."
            : "Delete the active character profile."
    }

    private func build() {
        profilePopup.controlSize = .small
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        profilePopup.cell?.lineBreakMode = .byTruncatingTail
        profilePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        profilePopup.setAccessibilityLabel("Active character")
        profilePopup.setAccessibilityHelp("Choose the active character, create a character, or import a character bundle.")

        actionsButton.bezelStyle = .texturedRounded
        actionsButton.controlSize = .small
        actionsButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        actionsButton.imagePosition = .imageOnly
        actionsButton.target = self
        actionsButton.action = #selector(showActions(_:))
        actionsButton.translatesAutoresizingMaskIntoConstraints = false
        actionsButton.setAccessibilityLabel("Active character actions")
        actionsButton.setAccessibilityHelp("Rename, duplicate, export, or delete the active character.")
        actionsButton.toolTip = "Active character actions"
        actionsButton.menu = actionsMenu

        deleteProfileButton.bezelStyle = .rounded
        deleteProfileButton.controlSize = .small
        deleteProfileButton.target = self
        deleteProfileButton.action = #selector(deleteActive)
        deleteProfileButton.translatesAutoresizingMaskIntoConstraints = false
        deleteProfileButton.setAccessibilityLabel("Delete active character profile")
        deleteProfileButton.setAccessibilityHelp("Delete the active character profile after confirmation. The last profile cannot be deleted.")

        addSubview(profilePopup)
        addSubview(actionsButton)
        addSubview(deleteProfileButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            profilePopup.leadingAnchor.constraint(equalTo: leadingAnchor),
            profilePopup.topAnchor.constraint(equalTo: topAnchor),
            profilePopup.bottomAnchor.constraint(equalTo: bottomAnchor),
            profilePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            profilePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            actionsButton.leadingAnchor.constraint(equalTo: profilePopup.trailingAnchor, constant: 6),
            actionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionsButton.widthAnchor.constraint(equalToConstant: 28),
            actionsButton.heightAnchor.constraint(equalToConstant: 28),
            deleteProfileButton.leadingAnchor.constraint(equalTo: actionsButton.trailingAnchor, constant: 6),
            deleteProfileButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            deleteProfileButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func rebuildProfileMenu() {
        profilePopup.removeAllItems()
        if profiles.isEmpty {
            profilePopup.addItem(withTitle: "No Characters")
            profilePopup.lastItem?.isEnabled = false
        } else {
            for profile in profiles {
                let noun = profile.clipCount == 1 ? "clip" : "clips"
                let item = NSMenuItem(
                    title: "\(profile.name) — \(profile.clipCount) \(noun)",
                    action: #selector(selectProfile(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = profile.id
                profilePopup.menu?.addItem(item)
            }
        }
        profilePopup.menu?.addItem(.separator())
        addProfileMenuItem(title: "New Character…", action: #selector(createCharacter))
        addProfileMenuItem(title: "Import Bundle…", action: #selector(importBundle))
        restoreActiveSelection()
    }

    private func addProfileMenuItem(title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        profilePopup.menu?.addItem(item)
    }

    private func rebuildActionsMenu() {
        actionsMenu.removeAllItems()
        actionsMenu.autoenablesItems = false
        addActionMenuItem(title: "Rename…", action: #selector(renameActive))
        addActionMenuItem(title: "Duplicate…", action: #selector(duplicateActive))
        addActionMenuItem(title: "Export…", action: #selector(exportActive))
        actionsMenu.addItem(.separator())
        let deleteItem = addActionMenuItem(title: "Delete…", action: #selector(deleteActive))
        let hasActiveProfile = activeID != nil
        for item in actionsMenu.items where !item.isSeparatorItem {
            item.isEnabled = hasActiveProfile && !busy
        }
        deleteItem.isEnabled = hasActiveProfile && profiles.count > 1 && !busy
        deleteItem.toolTip = profiles.count <= 1
            ? "The last character cannot be deleted."
            : "Delete the active character."
    }

    @discardableResult
    private func addActionMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        actionsMenu.addItem(item)
        return item
    }

    private func restoreActiveSelection() {
        guard
            let activeID,
            let index = profiles.firstIndex(where: { $0.id == activeID })
        else {
            profilePopup.selectItem(at: 0)
            return
        }
        profilePopup.selectItem(at: index)
        let profile = profiles[index]
        profilePopup.setAccessibilityValue(profile.name)
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        activeID = id
        restoreActiveSelection()
        onSelectProfile?(id)
    }

    @objc private func createCharacter() {
        restoreActiveSelection()
        onNewCharacter?()
    }

    @objc private func importBundle() {
        restoreActiveSelection()
        onImportBundle?()
    }

    @objc private func showActions(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        actionsMenu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - 4),
            in: sender
        )
    }

    @objc private func renameActive() { onRenameActive?() }
    @objc private func duplicateActive() { onDuplicateActive?() }
    @objc private func exportActive() { onExportActive?() }
    @objc private func deleteActive() {
        guard !busy,
              profiles.count > 1,
              let activeID,
              profiles.contains(where: { $0.id == activeID }) else { return }
        onDeleteActive?(activeID)
    }
}
