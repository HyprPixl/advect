import AppKit

/// The floating window that shows the painting as it happens.
///
/// It's a non-activating HUD panel so watching a render never steals focus from
/// whatever you were doing, and it floats above ordinary windows across Spaces.
final class PreviewPanel: NSPanel {
    private let imageView = NSImageView()
    private let bar = NSProgressIndicator()
    private let caption = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()

    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                   styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        title = "Advect"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildContent()
        // Remember where it was left, but never the size — layout decides that,
        // and a stale saved frame would fight the width constraint.
        setFrameAutosaveName("AdvectPreviewPanel")
        setContentSize(NSSize(width: 420, height: 340))
    }

    private func buildContent() {
        let content = NSView()

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.controlSize = .small
        bar.style = .bar

        caption.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        caption.usesSingleLineMode = true
        // Without this the caption's intrinsic width sets the window's width, and
        // a long seed line stretches the panel instead of truncating.
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.setContentHuggingPriority(.defaultLow, for: .horizontal)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        for view in [imageView, bar, caption, cancelButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 420),

            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 0.625),

            bar.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),

            caption.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            caption.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),
            caption.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        contentView = content
    }

    @objc private func cancelPressed() { onCancel?() }

    // MARK: - state

    func begin(_ summary: String) {
        imageView.image = nil
        bar.doubleValue = 0
        cancelButton.isEnabled = true
        caption.stringValue = summary
        placeIfNeeded()
        orderFrontRegardless()
    }

    func update(progress: Double?, caption text: String) {
        if let progress { bar.doubleValue = min(max(progress, 0), 100) }
        caption.stringValue = text
    }

    func show(image: NSImage) {
        imageView.image = image
    }

    /// Leave the finished painting up for a moment so you can see what you got.
    func finish(caption text: String, lingering: TimeInterval) {
        bar.doubleValue = 100
        caption.stringValue = text
        cancelButton.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + lingering) { [weak self] in
            guard let self, self.cancelButton.isEnabled == false else { return }
            self.orderOut(nil)
        }
    }

    func dismiss() { orderOut(nil) }

    /// First run has no saved frame — tuck it into the bottom-right corner.
    private func placeIfNeeded() {
        guard let screen = NSScreen.main, frame.origin == .zero else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.minY + 24))
    }
}
