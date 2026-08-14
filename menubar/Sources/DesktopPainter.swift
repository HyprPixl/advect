import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Paints in-progress frames straight onto the desktop, so the wallpaper appears
/// to draw itself.
///
/// Three measurements shaped this. PNG encoding a native-resolution frame takes
/// 239 ms, which rules it out entirely; JPEG at half resolution takes 6 ms and
/// macOS scales it up to fill anyway. `setDesktopImageURL` is only ~0.8 ms, far
/// cheaper than expected.
///
/// Consecutive frames always go to *different* paths, because re-setting the
/// same path with changed contents is exactly the case a wallpaper cache is
/// entitled to ignore. They cycle through a fixed ring of slots rather than
/// each taking a fresh name — see `slotCount`.
///
/// Whatever was on the desktop before is remembered, so a cancelled render puts
/// it back rather than leaving a half-painted picture up.
final class DesktopPainter {
    private let directory: URL
    private let restoreURL: URL?
    private let width: Int
    private let interval: TimeInterval
    private var lastPaint = Date.distantPast
    private var counter = 0
    private let queue = DispatchQueue(label: "advect.desktop-painter")
    private let inFlight = NSLock.Flag()

    /// - Parameter interval: minimum seconds between desktop updates. At ~9 ms a
    ///   frame, 0.1 costs about 9% of a render.
    init?(interval: TimeInterval = 0.1) {
        guard let screen = NSScreen.main else { return nil }
        restoreURL = NSWorkspace.shared.desktopImageURL(for: screen)
        // Half the display's pixel width: macOS scales it to fill, and the cost
        // of encoding is quadratic in the dimension.
        width = max(640, Int(screen.frame.width * screen.backingScaleFactor) / 2)
        self.interval = interval
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("advect-live", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Show this frame, unless one went up too recently. Called from the render
    /// thread, and deliberately does as little there as possible.
    ///
    /// Only the downscale runs inline — 1.6 ms, and it has to, because the
    /// buffer it reads keeps being painted into. Encoding and the wallpaper call
    /// are the expensive 7 ms, and they go to a background queue.
    ///
    /// That helps less than it looks like it should: end to end, painting the
    /// desktop still costs about 7% of a render (median 3.48s against 3.24s at
    /// native size). Moving work to another thread doesn't make it free when
    /// the machine is doing the same total work — it only wins where a core is
    /// genuinely idle. Kept anyway because the queue also decouples the render
    /// from any hitch in the wallpaper call.
    ///
    /// Handing the full buffer to another thread instead would be worse than it
    /// looks: the array would no longer be uniquely referenced, so the next
    /// `withUnsafeMutableBufferPointer` in the march would deep-copy 23 MB.
    /// Downscaling first hands over a small, already-detached copy.
    func paint(_ buffer: [UInt8], width w: Int, height h: Int) {
        guard Date().timeIntervalSince(lastPaint) >= interval else { return }
        guard !inFlight.value else { return }        // drop frames rather than queue them
        lastPaint = Date()
        inFlight.value = true

        let (small, sw, sh) = Self.downscale(buffer, width: w, height: h, maxWidth: width)
        counter += 1
        let slot = directory.appendingPathComponent("slot-\(counter % Self.slotCount).jpg")
        let scratch = directory.appendingPathComponent("scratch-\(counter).jpg")

        queue.async { [self] in
            defer { inFlight.value = false }
            guard let image = ImageWriter.makeImage(small, width: sw, height: sh),
                  let dest = CGImageDestinationCreateWithURL(
                    scratch as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(
                dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            guard Self.replace(scratch, with: slot) else { return }
            Self.setDesktop(slot)
        }
    }

    /// A fixed ring of filenames, cycled through and overwritten in place.
    ///
    /// Nothing is deleted while a render is running, and that is the whole
    /// point. macOS reads a wallpaper asynchronously and can lag several frames
    /// behind; deleting a file it is about to read drops it to the stock system
    /// wallpaper, which is glaringly visible. Overwriting a slot instead means
    /// every path ever handed to macOS still exists — the worst case is that it
    /// reads a slightly stale frame, which is invisible at ten a second.
    ///
    /// The ring also bounds disk use at roughly 6 MB no matter how long the
    /// render runs, which matters for a 32-frame day cycle.
    private static let slotCount = 16

    /// rename(2): atomic, and it replaces an existing destination rather than
    /// failing like FileManager.moveItem. So a slot is never absent and never
    /// half-written, even if macOS reads it at the wrong moment.
    private static func replace(_ source: URL, with destination: URL) -> Bool {
        source.withUnsafeFileSystemRepresentation { s in
            destination.withUnsafeFileSystemRepresentation { d in
                guard let s, let d else { return false }
                return rename(s, d) == 0
            }
        }
    }

    /// Put back whatever was there before. Used when a render is cancelled.
    func restore() {
        queue.sync {}                        // let any in-flight frame land first
        if let restoreURL { Self.setDesktop(restoreURL) }
        releaseAfterHandover()
    }

    /// Remove every temp frame.
    ///
    /// Only ever called after the real wallpaper has been set and given time to
    /// land — never while a render is running, because a file macOS is still
    /// referencing must not disappear.
    private func purge() {
        queue.sync {
            let fm = FileManager.default
            let leftovers = (try? fm.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: nil)) ?? []
            for url in leftovers { try? fm.removeItem(at: url) }
        }
    }

    /// Call once the real wallpaper has been set. The delay is not politeness:
    /// setDesktopImageURL returns before macOS has finished reading the file it
    /// was handed, and the agent lags further behind still.
    func releaseAfterHandover(delay: TimeInterval = 5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in purge() }
    }

    private static func setDesktop(_ url: URL) {
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }

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
