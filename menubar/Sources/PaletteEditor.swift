import AppKit

/// The window where custom palettes are made: pick a background and four stroke
/// colours, name it, save it. Saved palettes join the built-ins in the Palette
/// menu and render by name exactly as those do.
///
/// A normal titled window rather than the HUD panel the preview uses — this one
/// is worked in, so it wants to take focus and carry a real colour picker.
final class PaletteEditorWindow: NSWindow {
    static let shared = PaletteEditorWindow()

    private let settings = Settings.shared
    private let list = NSPopUpButton()
    private let nameField = NSTextField()
    private let wells = (0..<5).map { _ in NSColorWell() }
    private let deleteButton = NSButton()

    /// The palette being edited, or nil for an unsaved new one. Held by name, not
    /// index, so a rename or a delete elsewhere can't point us at the wrong row.
    private var editing: String?

    /// Set by AppDelegate: save the current palette and render with it right
    /// away, so trying a palette out doesn't mean a trip to the Palette submenu.
    var onGenerate: ((String) -> Void)?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered,
                   defer: false)
        title = "Palette Editor"
        isReleasedWhenClosed = false
        buildContent()
        setFrameAutosaveName("AdvectPaletteEditor")
        center()
        reloadList()
        load(settings.customPalettes.first?.name)
    }

    func present() {
        // The app has no dock icon, so it isn't activated by a menu click alone;
        // without this the window opens behind whatever was in front.
        NSApp.activate(ignoringOtherApps: true)
        reloadList()
        makeKeyAndOrderFront(nil)
    }

    // MARK: - layout

    private func buildContent() {
        let content = NSView()

        list.target = self
        list.action = #selector(pickFromList)

        nameField.placeholderString = "Name"
        nameField.target = self
        nameField.action = #selector(save)

        let labels = ["Background", "Stroke 1", "Stroke 2", "Stroke 3", "Stroke 4"]
        var rows: [NSView] = []
        for (index, well) in wells.enumerated() {
            well.color = .black

            let label = NSTextField(labelWithString: labels[index])
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 84).isActive = true

            let row = NSStackView(views: [label, well])
            row.orientation = .horizontal
            row.spacing = 8
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            rows.append(row)
        }

        let buttons = NSStackView(views: [
            button("New", #selector(newPalette)),
            button("Duplicate", #selector(duplicate)),
            deleteButton,
            NSView(),
            button("Save", #selector(save)),
            button("Generate", #selector(generate)),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        deleteButton.title = "Delete"
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.target = self
        deleteButton.action = #selector(deletePalette)

        let stack = NSStackView(views: [list, nameField] + rows + [buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 380),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        contentView = content
        setContentSize(NSSize(width: 380, height: 300))
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    // MARK: - state

    private func reloadList() {
        list.removeAllItems()
        let names = settings.customPalettes.map(\.name)
        if names.isEmpty {
            list.addItem(withTitle: "No custom palettes")
            list.isEnabled = false
        } else {
            list.isEnabled = true
            list.addItems(withTitles: names)
            if let editing, names.contains(editing) { list.selectItem(withTitle: editing) }
        }
        deleteButton.isEnabled = editing != nil
    }

    /// Show a saved palette, or a fresh one when the name is unknown.
    private func load(_ name: String?) {
        let palette = name.flatMap { name in settings.customPalettes.first { $0.name == name } }
        editing = palette?.name
        nameField.stringValue = palette?.name ?? ""
        let spec = palette?.spec ?? PaletteSpec.named["moss"]!
        for (index, colour) in ([spec.background] + spec.strokes).enumerated() where index < wells.count {
            wells[index].color = NSColor(rgb: colour)
        }
        reloadList()
    }

    private var currentPalette: CustomPalette? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return CustomPalette(name: name,
                             background: wells[0].color.rgb,
                             strokes: wells.dropFirst().map(\.color.rgb))
    }

    // MARK: - actions

    @objc private func pickFromList() {
        guard let title = list.titleOfSelectedItem else { return }
        load(title)
    }

    @objc private func newPalette() {
        load(nil)
        nameField.stringValue = ""
        makeFirstResponder(nameField)
    }

    @objc private func duplicate() {
        editing = nil
        nameField.stringValue = uniqueName(from: nameField.stringValue.isEmpty ? "palette" : nameField.stringValue)
        reloadList()
    }

    @objc private func save() {
        _ = saveCurrent()
    }

    @objc private func generate() {
        guard let name = saveCurrent() else { return }
        onGenerate?(name)
    }

    /// Validates and persists the palette in the fields, returning its name on
    /// success. Shared by Save and Generate so trying a palette can't skip the
    /// same checks a plain save gets.
    @discardableResult
    private func saveCurrent() -> String? {
        guard let palette = currentPalette else {
            complain("Give the palette a name first.")
            return nil
        }
        // The name is both the menu label and part of the rendered file's name,
        // so it has to be unique against the built-ins and free of path bits.
        guard !PaletteSpec.named.keys.contains(palette.name),
              palette.name != Settings.randomPalette else {
            complain("“\(palette.name)” is a built-in palette. Pick another name.")
            return nil
        }
        guard !palette.name.contains("/"), !palette.name.contains(":") else {
            complain("Palette names can’t contain “/” or “:”.")
            return nil
        }
        var list = settings.customPalettes
        // Only a same-named save is an edit-in-place; a changed name means the
        // user is saving a new palette, not renaming the one they started from
        // — otherwise typing a fresh name over an old one silently replaces it.
        if editing == palette.name, let index = list.firstIndex(where: { $0.name == editing }) {
            list[index] = palette
        } else if list.contains(where: { $0.name == palette.name }) {
            complain("A palette named “\(palette.name)” already exists.")
            return nil
        } else {
            list.append(palette)
        }
        settings.customPalettes = list
        load(palette.name)
        return palette.name
    }

    @objc private func deletePalette() {
        guard let editing else { return }
        settings.customPalettes.removeAll { $0.name == editing }
        // Don't leave the menu pointing at a palette that no longer resolves.
        if settings.palette == editing { settings.palette = Settings.randomPalette }
        load(settings.customPalettes.first?.name)
    }

    private func uniqueName(from base: String) -> String {
        let taken = Set(settings.customPalettes.map(\.name)).union(PaletteSpec.named.keys)
        var candidate = base + " copy"
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) copy \(n)"
            n += 1
        }
        return candidate
    }

    private func complain(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: self)
    }
}

private extension NSColor {
    convenience init(rgb: [Int]) {
        let channel = { (i: Int) in CGFloat(rgb.indices.contains(i) ? rgb[i] : 0) / 255 }
        self.init(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: 1)
    }

    /// The renderer works in 0–255 sRGB; a well can hand back any colour space.
    var rgb: [Int] {
        let colour = usingColorSpace(.sRGB) ?? .black
        return [colour.redComponent, colour.greenComponent, colour.blueComponent]
            .map { Int(($0 * 255).rounded()) }
    }
}
