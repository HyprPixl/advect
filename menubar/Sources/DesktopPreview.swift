import AppKit
import Foundation
import QuartzCore

/// Shows in-progress frames on the desktop, so the wallpaper appears to draw
/// itself.
///
/// This used to be done by *actually setting the wallpaper* ten times a second
/// with short-lived temp files. That was the wrong surface. macOS records the
/// desktop picture as a file path, per Space and per display, in a store that a
/// separate agent reads asynchronously and caches — so driving it at 10 Hz meant
/// hundreds of writes to durable system state per render, and a permanent race
/// between retiring a frame file and the agent getting round to reading it. Lose
/// that race and the agent finds nothing there and falls back to the stock
/// system wallpaper: a very visible flash. The old code fought this with grace
/// windows (sixty frames on disk, a five second delay before purging) that made
/// it rarer without making it correct, and left the wallpaper store littered
/// with references to deleted files that resurfaced later as a stock wallpaper
/// on a newly attached display.
///
/// So: draw the frames ourselves instead. One borderless window per screen at
/// the desktop window level — above the real wallpaper, below the desktop icons
/// — with the frame as its layer's contents. Nothing is written to disk, nothing
/// touches the wallpaper system until the render is finished and the real image
/// is set, once. The flash isn't unlikely any more; there is no longer a
/// mechanism for it.
///
/// It is also strictly cheaper than what it replaces: no JPEG encode (6 ms a
/// frame), no file writes, no IPC with the wallpaper agent.
final class DesktopPreview {
    private var windows: [NSWindow] = []
    /// Per window, the part of the frame it shows: nil for all of it, or that
    /// screen's tile when the render spans the displays.
    private var crops: [CGRect?] = []
    private let span: SpanLayout?
    private let interval: TimeInterval
    private var lastPaint = Date.distantPast
    private let width: Int
    private var latest: CGImage?
    private var dismissed = false

    /// - Parameter interval: minimum seconds between frames. The work per frame
    ///   is now a downscale and a layer assignment, so this is a much cheaper
    ///   10/s than the old one.
    init(interval: TimeInterval = 0.1, span: SpanLayout? = nil) {
        self.interval = interval
        self.span = span
        // Half the display's pixel width — or the whole arrangement's, when
        // spanning. The layer scales it up to fill, and the cost of the
        // downscale is quadratic in the dimension.
        let screen = NSScreen.main
        width = span.map { max(640, $0.width / 2) } ?? max(640, Int((screen?.frame.width ?? 1920)
            * (screen?.backingScaleFactor ?? 2)) / 2)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Show this frame, unless one went up too recently.
    ///
    /// Called from the render thread. Only the downscale runs here, and it has
    /// to: the buffer it reads keeps being painted into, so the copy must be
    /// taken synchronously. Handing the full buffer to the main thread instead
    /// would be worse than it looks — the array would no longer be uniquely
    /// referenced, so the next `withUnsafeMutableBufferPointer` in the march
    /// would deep-copy 23 MB. Downscaling first hands over a small, already
    /// detached copy.
    func paint(_ buffer: [UInt8], width w: Int, height h: Int) {
        guard Date().timeIntervalSince(lastPaint) >= interval else { return }
        lastPaint = Date()

        let (small, sw, sh) = Self.downscale(buffer, width: w, height: h, maxWidth: width)
        guard let image = ImageWriter.makeImage(small, width: sw, height: sh) else { return }

        DispatchQueue.main.async { [self] in
            guard !dismissed else { return }
            latest = image
            if windows.isEmpty { build() }
            applyAll(image)
        }
    }

    /// Take the preview down, once the real wallpaper has had a moment to land.
    ///
    /// The delay is not politeness: `setDesktopImageURL` returns before the
    /// wallpaper agent has finished reading the file it was handed. Uncovering
    /// the desktop too early shows the *previous* wallpaper for a beat. Fading
    /// rather than cutting also hides the seam between our frame and the real
    /// image, which are the same picture at different scales.
    func dismiss(after delay: TimeInterval = 0.5, fade: TimeInterval = 0.35) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard !dismissed else { return }
            dismissed = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fade
                for window in windows { window.animator().alphaValue = 0 }
            } completionHandler: { [self] in
                for window in windows { window.orderOut(nil) }
                windows.removeAll()
                crops.removeAll()
                latest = nil
            }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - windows

    /// One window per screen. Borderless and at the desktop window level, which
    /// sits above the wallpaper and below `kCGDesktopIconWindowLevel`, so the
    /// desktop icons stay visible on top of the render.
    private func build() {
        crops = NSScreen.screens.map { span?.unitRect(for: $0) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false, screen: screen)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.setFrame(screen.frame, display: false)

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contentsGravity = .resizeAspectFill
            window.contentView = view

            window.orderFrontRegardless()
            return window
        }
    }

    /// Rebuild for the new screen arrangement. A display attached mid-render
    /// should join in rather than sit on the old wallpaper until the render ends.
    @objc private func screensChanged() {
        guard !dismissed, !windows.isEmpty else { return }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        build()
        if let latest { applyAll(latest) }
    }

    /// Cropping a CGImage shares its pixels rather than copying them, so a tile
    /// per screen costs next to nothing over the one shared frame.
    private func applyAll(_ image: CGImage) {
        for (window, crop) in zip(windows, crops) {
            Self.apply(crop.flatMap { image.cropping(unit: $0) } ?? image, to: window)
        }
    }

    /// Assign without an implicit animation: the default would cross-fade every
    /// frame into the next and turn the march into mush.
    private static func apply(_ image: CGImage, to window: NSWindow) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.contentView?.layer?.contents = image
        CATransaction.commit()
    }

    // MARK: - pixels

    private static func downscale(_ buffer: [UInt8], width w: Int, height h: Int,
                                  maxWidth: Int) -> ([UInt8], Int, Int) {
        let dw = min(w, maxWidth), dh = max(1, h * dw / w)
        var out = [UInt8](repeating: 0, count: dw * dh * 3)
        let xs = (0..<dw).map { ($0 * w / dw) * 3 }
        for y in 0..<dh {
            let src = (y * h / dh) * w * 3, dst = y * dw * 3
            for x in 0..<dw {
                let s = src + xs[x], d = dst + x * 3
                out[d] = buffer[s]; out[d + 1] = buffer[s + 1]; out[d + 2] = buffer[s + 2]
            }
        }
        return (out, dw, dh)
    }
}
