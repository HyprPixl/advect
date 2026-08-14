import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private lazy var previewPanel: PreviewPanel = {
        let panel = PreviewPanel()
        panel.onCancel = { [weak self] in self?.cancelRender() }
        return panel
    }()

    private var job: RenderJob?
    private var rotateTimer: Timer?
    private var liveImage: NSImage?
    private var liveStatus = ""
    private var liveProgress: Double = 0
    private weak var liveItem: NSMenuItem?

    private let settings = Settings.shared

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "wind", accessibilityDescription: "Advect")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false        // enablement is decided when the menu is built
        statusItem.menu = menu

        scheduleRotation()
        // Waking from sleep can swallow a timer firing; catch up on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        job?.cancel()
    }

    /// `open advect://new` and `advect://daycycle` kick off a render from
    /// outside the app — a hotkey, a Shortcut, a macro pad, a script.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host?.lowercased() {
            case "new": renderStill()
            case "daycycle": renderDynamic()
            default: continue
            }
            return
        }
    }

    @objc private func didWake() { rotateIfDue() }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rendering = job != nil

        if rendering {
            let live = NSMenuItem(title: liveStatus, action: nil, keyEquivalent: "")
            live.image = liveImage.map { scaled($0, toWidth: 200) }
            live.isEnabled = false
            menu.addItem(live)
            liveItem = live
            menu.addItem(withTitle: "Cancel Render", action: #selector(cancelRender), keyEquivalent: ".")
                .target = self
            menu.addItem(.separator())
        }

        let new = menu.addItem(withTitle: "New Wallpaper", action: #selector(renderStill), keyEquivalent: "n")
        new.target = self
        new.isEnabled = !rendering

        let dynamic = menu.addItem(withTitle: "New Day Cycle", action: #selector(renderDynamic), keyEquivalent: "d")
        dynamic.target = self
        dynamic.isEnabled = !rendering
        dynamic.toolTip = "Render a Dynamic .heic whose colour drifts with the time of day"

        menu.addItem(.separator())
        menu.addItem(submenu: paletteMenu(), title: "Palette")
        menu.addItem(submenu: qualityMenu(), title: "Size")
        menu.addItem(submenu: framesMenu(), title: "Day Cycle Frames")
        menu.addItem(submenu: rotateMenu(), title: "Auto-Rotate")

        menu.addItem(.separator())
        menu.addItem(submenu: recentMenu(), title: "Recent")
        menu.addItem(withTitle: "Open Gallery Folder", action: #selector(openGallery), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())
        let preview = menu.addItem(withTitle: "Show Live Preview", action: #selector(togglePreview), keyEquivalent: "")
        preview.target = self
        preview.state = settings.showPreview ? .on : .off

        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(withTitle: "About Advect", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Advect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func paletteMenu() -> NSMenu {
        let sub = NSMenu()
        for palette in Palette.allCases {
            let item = sub.addItem(withTitle: palette.title, action: #selector(pickPalette(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = palette.rawValue
            item.state = settings.palette == palette ? .on : .off
            if palette == .random { sub.addItem(.separator()) }
        }
        return sub
    }

    private func qualityMenu() -> NSMenu {
        let sub = NSMenu()
        for quality in Quality.allCases {
            let size = quality.size
            let item = sub.addItem(withTitle: "\(quality.title) — \(size.w)×\(size.h)",
                                   action: #selector(pickQuality(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = quality.rawValue
            item.state = settings.quality == quality ? .on : .off
        }
        return sub
    }

    private func framesMenu() -> NSMenu {
        let sub = NSMenu()
        for count in [8, 16, 32, 64] {
            let item = sub.addItem(withTitle: "\(count) frames", action: #selector(pickFrames(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = count
            item.state = settings.frames == count ? .on : .off
        }
        return sub
    }

    private func rotateMenu() -> NSMenu {
        let sub = NSMenu()
        for interval in Rotate.allCases {
            let item = sub.addItem(withTitle: interval.title, action: #selector(pickRotate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval.rawValue
            item.state = settings.rotate == interval ? .on : .off
        }
        return sub
    }

    private func recentMenu() -> NSMenu {
        let sub = NSMenu()
        let files = Gallery.recent(limit: 12)
        if files.isEmpty {
            sub.addItem(withTitle: "Nothing rendered yet", action: nil, keyEquivalent: "").isEnabled = false
            return sub
        }
        for url in files {
            let item = sub.addItem(withTitle: url.lastPathComponent,
                                   action: #selector(setRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = Gallery.thumbnail(url, maxPixel: 128).map { scaled($0, toWidth: 64) }

            // Option-click reveals the file instead of setting it.
            let reveal = NSMenuItem(title: "Reveal “\(url.lastPathComponent)” in Finder",
                                    action: #selector(revealRecent(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = url
            reveal.isAlternate = true
            reveal.keyEquivalentModifierMask = .option
            sub.addItem(reveal)
        }
        return sub
    }

    /// Menu and panel images want a specific point size; the underlying bitmap is
    /// much larger, so set the represented size rather than resampling.
    private func scaled(_ image: NSImage, toWidth width: CGFloat) -> NSImage {
        let copy = image.copy() as! NSImage
        let ratio = image.size.height / max(image.size.width, 1)
        copy.size = NSSize(width: width, height: (width * ratio).rounded())
        return copy
    }

    // MARK: - settings actions

    @objc private func pickPalette(_ sender: NSMenuItem) {
        settings.palette = Palette(rawValue: sender.representedObject as? String ?? "") ?? .random
    }

    @objc private func pickQuality(_ sender: NSMenuItem) {
        settings.quality = Quality(rawValue: sender.representedObject as? String ?? "") ?? .native
    }

    @objc private func pickFrames(_ sender: NSMenuItem) {
        settings.frames = sender.representedObject as? Int ?? 32
    }

    @objc private func pickRotate(_ sender: NSMenuItem) {
        settings.rotate = Rotate(rawValue: sender.representedObject as? Int ?? 0) ?? .off
        settings.lastRotate = Date()
        scheduleRotation()
    }

    @objc private func togglePreview() {
        settings.showPreview.toggle()
        if !settings.showPreview { previewPanel.dismiss() }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            report(title: "Couldn’t change the login item", message: error.localizedDescription)
        }
    }

    @objc private func openGallery() {
        try? FileManager.default.createDirectory(at: Gallery.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Gallery.folder)
    }

    @objc private func setRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        applyWallpaper(url)
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Advect",
            .credits: NSAttributedString(
                string: "Generative flow-field wallpapers.\n\n"
                      + "Thousands of particles march through a layered noise field and "
                      + "leave glowing filaments behind them. Every render is unique.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }

    // MARK: - rendering

    @objc private func renderStill() { render(kind: .still, setWhenDone: true) }
    @objc private func renderDynamic() { render(kind: .dynamic, setWhenDone: true) }

    @objc private func cancelRender() {
        job?.cancel()
    }

    private func render(kind: RenderJob.Kind, setWhenDone: Bool) {
        guard job == nil else { return }
        let job = RenderJob(kind: kind)
        self.job = job

        liveImage = nil
        liveProgress = 0
        liveStatus = job.summary
        if settings.showPreview { previewPanel.begin(job.summary) }
        updateStatusButton()

        job.onProgress = { [weak self] percent, status in
            guard let self else { return }
            self.liveProgress = percent
            self.liveStatus = status
            self.previewPanel.update(progress: percent, caption: status)
            self.liveItem?.title = status
            self.updateStatusButton()
        }
        job.onPreview = { [weak self] image in
            guard let self else { return }
            self.liveImage = image
            self.previewPanel.show(image: image)
            self.liveItem?.image = self.scaled(image, toWidth: 200)
        }
        job.onFinish = { [weak self] result in
            guard let self else { return }
            self.job = nil
            self.updateStatusButton()
            switch result {
            case .success(let url):
                self.previewPanel.finish(caption: url.lastPathComponent, lingering: 2.5)
                if setWhenDone { self.applyWallpaper(url) }
            case .failure(let error):
                self.previewPanel.dismiss()
                if !job.isCancelled {
                    self.report(title: "Render failed", message: error.localizedDescription)
                }
            }
        }
        job.start()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = job == nil ? "" : " \(Int(liveProgress))%"
    }

    private func applyWallpaper(_ url: URL) {
        do {
            try Wallpaper.set(url)
        } catch {
            report(title: "Couldn’t set the wallpaper", message: error.localizedDescription)
        }
    }

    // MARK: - auto-rotate

    private func scheduleRotation() {
        rotateTimer?.invalidate()
        rotateTimer = nil
        let interval = settings.rotate
        guard interval != .off else { return }
        let seconds = TimeInterval(interval.rawValue)
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.rotateIfDue()
        }
        timer.tolerance = seconds * 0.1
        rotateTimer = timer
        rotateIfDue()
    }

    /// Rotation is driven by a stored timestamp rather than the timer alone, so a
    /// quit-and-relaunch (or a long sleep) doesn't reset the clock or double-fire.
    private func rotateIfDue() {
        let interval = settings.rotate
        guard interval != .off, job == nil else { return }
        guard Date().timeIntervalSince(settings.lastRotate) >= TimeInterval(interval.rawValue) else { return }
        settings.lastRotate = Date()
        render(kind: .still, setWhenDone: true)
    }

    // MARK: - helpers

    private func report(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private extension NSMenu {
    /// `addItem(withTitle:action:keyEquivalent:)` returns the item; this is the
    /// same convenience for an item that only exists to hold a submenu.
    @discardableResult
    func addItem(submenu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return item
    }
}
