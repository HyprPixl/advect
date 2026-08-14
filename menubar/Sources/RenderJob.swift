import AppKit
import Foundation

struct RenderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One render, run on a background queue.
///
/// There is no subprocess and no interpreter: the renderer is compiled into this
/// binary, so the app is self-contained and works on a Mac with nothing else
/// installed. Callbacks arrive on the main queue.
final class RenderJob {
    enum Kind { case still, dynamic }

    let kind: Kind
    let seed: Int
    let paletteName: String        // the palette actually used, once Random is resolved

    var onProgress: ((Double, String) -> Void)?     // 0–100, status line
    var onPreview: ((NSImage) -> Void)?
    var onFinish: ((Result<URL, RenderError>) -> Void)?

    private let size: (w: Int, h: Int)
    private let frames: Int
    private let cancelled = NSLock.Flag()
    private var lastPreview = Date.distantPast

    /// The panel is 420pt wide, so this is its backing resolution on a Retina
    /// display — anything less gets stretched back up and looks soft. It's also
    /// *cheaper* than a smaller preview: sampling every 4th pixel out of the
    /// render buffer reads more sequentially than every 5th, and the downscale
    /// is memory-bound. Measured at 0.48 ms against 0.77 ms for 640px.
    private let previewWidth = 840

    /// Cap on preview rate. At native size the march yields roughly this often
    /// anyway; the cap only matters for small renders, where 48 chunks can
    /// finish in a tenth of a second and would otherwise flood the main queue.
    /// 30/s costs about 1.5% of a render.
    private let previewInterval = 1.0 / 30.0

    init(kind: Kind, settings: Settings = .shared) {
        self.kind = kind
        self.seed = Int.random(in: 0..<(1 << 20))
        self.size = settings.quality.size
        self.frames = settings.frames
        let chosen = settings.palette.flag ?? PaletteSpec.order.randomElement()!
        self.paletteName = chosen
    }

    var summary: String {
        let what = kind == .dynamic ? "day cycle" : paletteName
        return "\(what) · seed \(seed) · \(size.w)×\(size.h)"
    }

    var isCancelled: Bool { cancelled.value }

    func cancel() { cancelled.value = true }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result: Result<URL, RenderError>
            switch kind {
            case .still: result = renderStill()
            case .dynamic: result = renderDayCycle()
            }
            DispatchQueue.main.async { self.onFinish?(result) }
        }
    }

    // MARK: - the two jobs

    private func renderStill() -> Result<URL, RenderError> {
        guard let palette = PaletteSpec.named[paletteName] else {
            return .failure(RenderError(message: "Unknown palette “\(paletteName)”."))
        }
        guard let buffer = Renderer.render(
            width: size.w, height: size.h, seed: seed, palette: palette,
            sharp: 0.6, glow: 0.7, softness: 1.0,
            onProgress: { [self] pct, buf in report(Double(pct), "painting", buf) },
            isCancelled: { [self] in cancelled.value })
        else { return .failure(.cancelled) }

        report(100, "writing PNG", nil)
        let url = Gallery.folder.appendingPathComponent("\(paletteName)-\(seed).png")
        guard ensureGallery(), ImageWriter.writePNG(buffer, width: size.w, height: size.h, to: url) else {
            return .failure(RenderError(message: "Couldn’t write \(url.lastPathComponent)."))
        }
        return .success(url)
    }

    private func renderDayCycle() -> Result<URL, RenderError> {
        // The schedule depends only on the time of day, so it's known before any
        // pixels exist — which lets frames stream straight out to disk.
        let looks = (0..<frames).map { dayLook(Double($0) / Double(frames)) }
        let times = (0..<frames).map { Double($0) / Double(frames) }
        let brightness = looks.map { $0.palette.background.reduce(0, +) }
        let lightIndex = brightness.firstIndex(of: brightness.max()!)!
        let darkIndex = brightness.firstIndex(of: brightness.min()!)!

        let url = Gallery.folder.appendingPathComponent("day-\(seed).heic")
        guard ensureGallery(),
              let writer = ImageWriter.DynamicHEIC(
                url: url, frameCount: frames, times: times,
                lightIndex: lightIndex, darkIndex: darkIndex, quality: 0.86)
        else { return .failure(RenderError(message: "Couldn’t start writing \(url.lastPathComponent).")) }

        for (i, look) in looks.enumerated() {
            let base = Double(i) * 100.0 / Double(frames)
            let span = 100.0 / Double(frames)
            // Name the hour this frame stands for — "frame 7/32" says nothing
            // about what you're watching appear.
            let minutes = Int(times[i] * 24 * 60)
            let clock = String(format: "%02d:%02d", minutes / 60, minutes % 60)
            guard let buffer = Renderer.render(
                width: size.w, height: size.h, seed: seed, palette: look.palette,
                sharp: 0.6, glow: look.glow, softness: look.softness,
                onProgress: { [self] pct, buf in
                    report(base + span * Double(pct) / 100.0,
                           "\(clock) · frame \(i + 1)/\(frames)", buf)
                },
                isCancelled: { [self] in cancelled.value })
            else {
                try? FileManager.default.removeItem(at: url)
                return .failure(.cancelled)
            }
            guard writer.add(buffer, width: size.w, height: size.h) else {
                return .failure(RenderError(message: "Couldn’t encode frame \(i + 1)."))
            }
        }
        report(100, "packing dynamic wallpaper", nil)
        guard writer.finish() else {
            return .failure(RenderError(message: "Couldn’t finish \(url.lastPathComponent)."))
        }
        return .success(url)
    }

    // MARK: - progress and preview

    private func ensureGallery() -> Bool {
        (try? FileManager.default.createDirectory(at: Gallery.folder,
                                                  withIntermediateDirectories: true)) != nil
    }

    /// Called from the render thread. The preview is throttled and downscaled
    /// here so the main queue only ever receives a small finished image.
    private func report(_ percent: Double, _ phase: String, _ buffer: [UInt8]?) {
        let status = "\(summary) · \(phase) · \(Int(percent))%"
        var image: NSImage?
        if let buffer, Date().timeIntervalSince(lastPreview) >= previewInterval {
            lastPreview = Date()
            image = Self.preview(buffer, width: size.w, height: size.h, maxWidth: previewWidth)
        }
        DispatchQueue.main.async { [self] in
            onProgress?(percent, status)
            if let image { onPreview?(image) }
        }
    }

    /// Nearest-neighbour downscale straight out of the render buffer — cheap
    /// enough to run mid-paint, which a full-size CGImage would not be.
    private static func preview(_ buffer: [UInt8], width w: Int, height h: Int,
                                maxWidth: Int) -> NSImage? {
        let dw = min(w, maxWidth)
        let dh = max(1, h * dw / w)
        var out = [UInt8](repeating: 0, count: dw * dh * 3)
        let xs = (0..<dw).map { ($0 * w / dw) * 3 }
        for y in 0..<dh {
            let src = (y * h / dh) * w * 3
            let dst = y * dw * 3
            for x in 0..<dw {
                let s = src + xs[x], d = dst + x * 3
                out[d] = buffer[s]; out[d + 1] = buffer[s + 1]; out[d + 2] = buffer[s + 2]
            }
        }
        guard let cg = ImageWriter.makeImage(out, width: dw, height: dh) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: dw, height: dh))
    }
}

extension RenderError {
    /// Cancellation isn't worth an alert; the UI checks for it.
    static let cancelled = RenderError(message: "")
}

extension NSLock {
    /// A tiny lock-guarded Bool, for the cancel flag the render loop polls.
    final class Flag {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
