import AppKit
import Foundation

struct RenderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One line of the renderer's `--progress` stream.
struct RenderEvent {
    let phase: String
    var pct: Double?
    var overall: Double?
    var path: String?
    var frame: Int?
    var frames: Int?
    var clock: String?

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = obj["phase"] as? String
        else { return nil }
        self.phase = phase
        pct = obj["pct"] as? Double
        overall = obj["overall"] as? Double
        path = obj["path"] as? String
        frame = obj["frame"] as? Int
        frames = obj["frames"] as? Int
        clock = obj["clock"] as? String
    }
}

/// Finds a python3 that can actually run the job. The bundle can't rely on the
/// launching PATH — an app started by Finder doesn't see Homebrew — so we probe
/// the usual locations, and for Dynamic mode insist on one that has pillow-heif.
enum Python {
    private static var cache: [Bool: String] = [:]

    private static var candidates: [String] {
        var paths: [String] = []
        if let override = UserDefaults.standard.string(forKey: "pythonPath") { paths.append(override) }
        paths += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        return paths
    }

    static func interpreter(needsHEIF: Bool) -> String? {
        if let hit = cache[needsHEIF] { return hit }
        let usable = candidates.first { path in
            guard FileManager.default.isExecutableFile(atPath: path) else { return false }
            return needsHEIF ? canImport("pillow_heif", python: path) : true
        }
        cache[needsHEIF] = usable
        return usable
    }

    private static func canImport(_ module: String, python: String) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: python)
        probe.arguments = ["-c", "import \(module)"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }
}

/// A single run of the renderer, wrapped so the menu bar can watch it paint.
///
/// stderr carries the JSON event stream; stdout is only kept so a crash can be
/// reported with something readable in it.
final class RenderJob {
    enum Kind { case still, dynamic }

    let kind: Kind
    let seed: Int
    let palette: Palette

    var onEvent: ((RenderEvent) -> Void)?
    var onPreview: ((NSImage) -> Void)?
    var onFinish: ((Result<URL, RenderError>) -> Void)?

    private let process = Process()
    private let previewURL: URL
    private var pending = Data()
    private var output = Data()
    private var diagnostics: [String] = []      // stderr lines that weren't events
    private var announcedPath: String?          // destination, as reported by the events
    private let lock = NSLock()                 // guards the three fields above
    private var finished = false
    private(set) var cancelled = false

    init(kind: Kind, settings: Settings = .shared) {
        self.kind = kind
        self.seed = Int.random(in: 0..<(1 << 20))
        self.palette = settings.palette
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Advect", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        previewURL = caches.appendingPathComponent("paint-\(seed).png")
    }

    /// A one-line description of what this job is making, for the menu and panel.
    var summary: String {
        let size = Settings.shared.quality.size
        let what = kind == .dynamic ? "day cycle" : (palette.flag ?? "random")
        return "\(what) · seed \(seed) · \(size.w)×\(size.h)"
    }

    func start() throws {
        let settings = Settings.shared
        guard let python = Python.interpreter(needsHEIF: kind == .dynamic) else {
            throw RenderError(message: kind == .dynamic
                ? "Dynamic mode needs a python3 with pillow-heif installed.\n\n"
                  + "Install it with:\n    python3 -m pip install --user --break-system-packages pillow-heif"
                : "No python3 found in /opt/homebrew/bin, /usr/local/bin or /usr/bin.")
        }
        guard let script = Bundle.main.url(forResource: "advect", withExtension: nil) else {
            throw RenderError(message: "The advect renderer is missing from the app bundle.")
        }

        let size = settings.quality.size
        var args = [
            script.path,
            "--seed", String(seed),
            "--size", "\(size.w)x\(size.h)",
            "--backend", settings.backend.rawValue,
            "--progress",
            "--preview", previewURL.path,
            "--preview-interval", "0.7",
        ]
        if kind == .dynamic {
            args += ["--dynamic", "--frames", String(settings.frames)]
        } else if let name = palette.flag {
            args += ["--palette", name]
        }

        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        // The C backend shells out to `cc`, so /usr/bin has to be reachable even
        // when the app was launched by Finder rather than a shell.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let events = Pipe(), stdout = Pipe()
        process.standardError = events
        process.standardOutput = stdout
        process.standardInput = FileHandle.nullDevice

        // stderr streams, because that's the live progress. stdout deliberately
        // does not: it carries one line — the finished path — and reading it only
        // after the process exits is the difference between a deterministic read
        // and racing a readability callback against the termination handler.
        // (One path line can't come close to filling the pipe buffer.)
        events.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        process.terminationHandler = { [weak self] proc in
            events.fileHandleForReading.readabilityHandler = nil
            let tailErr = events.fileHandleForReading.readDataToEndOfFile()
            let tailOut = stdout.fileHandleForReading.readDataToEndOfFile()
            self?.consume(tailErr)
            DispatchQueue.main.async {
                self?.output.append(tailOut)
                self?.complete(status: proc.terminationStatus)
            }
        }

        try process.run()
    }

    func cancel() {
        guard process.isRunning else { return }
        cancelled = true
        process.terminate()
    }

    // MARK: - event stream

    /// Called off the main thread; splits the stream into whole lines and hands
    /// each parsed event back on the main queue. Anything that isn't an event is
    /// kept as diagnostics, since that's where a Python traceback shows up.
    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            if let text = String(data: line, encoding: .utf8) { lines.append(text) }
        }
        var noise: [String] = []
        var events: [RenderEvent] = []
        for line in lines {
            guard let event = RenderEvent(line: line) else { noise.append(line); continue }
            events.append(event)
            // The start and done events both name the destination, so the result
            // doesn't hang on stdout arriving. ("preview" names a snapshot, not it.)
            if event.phase == "start" || event.phase == "done" { announcedPath = event.path }
        }
        diagnostics.append(contentsOf: noise)
        lock.unlock()

        for event in events {
            if event.phase == "preview" {
                // Decode off the main thread — it happens once a second.
                let image = Self.loadImage(previewURL)
                DispatchQueue.main.async { image.map { self.onPreview?($0) } }
            } else {
                DispatchQueue.main.async { self.onEvent?(event) }
            }
        }
    }

    /// Read through Data rather than NSImage(contentsOf:), which caches by path —
    /// every snapshot lands at the same path, so a cached read would freeze the
    /// preview on the first frame.
    private static func loadImage(_ url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private func complete(status: Int32) {
        guard !finished else { return }
        finished = true
        try? FileManager.default.removeItem(at: previewURL)
        // The callbacks capture this job; drop them once it's over so it can go.
        defer { onEvent = nil; onPreview = nil; onFinish = nil }

        if cancelled {
            onFinish?(.failure(RenderError(message: "")))
            return
        }
        lock.lock()
        let announced = announcedPath
        let detail = diagnostics.suffix(12).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()

        let text = String(data: output, encoding: .utf8) ?? ""
        let printed = text.split(separator: "\n").last { $0.hasPrefix("/") }.map(String.init)
        let path = [printed, announced].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0) }

        guard status == 0, let path else {
            onFinish?(.failure(RenderError(message: detail.isEmpty
                ? "The renderer exited with status \(status)."
                : detail)))
            return
        }
        onFinish?(.success(URL(fileURLWithPath: path)))
    }
}
