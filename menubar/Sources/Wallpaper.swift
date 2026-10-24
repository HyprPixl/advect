import AppKit
import Foundation
import ImageIO

enum Wallpaper {
    /// The image this app last set, so it can be re-asserted on a screen that
    /// turns up later. macOS records the desktop picture per Space *and* per
    /// display, and `set` can only reach the screens attached when it runs, so a
    /// display that was elsewhere at the time keeps whatever it had — which may
    /// be a render that has since been pruned.
    private(set) static var current: URL?

    /// Set every screen's desktop picture.
    ///
    /// A spanned render is set as its tiles, each on the display it was cut for.
    /// A display with no tile — attached since, or never part of the span — gets
    /// the whole canvas rather than being left on something stale.
    ///
    /// NSWorkspace is deliberate: the CLI drives System Events over AppleScript,
    /// which would make the app ask for Automation permission on first render.
    /// This route needs no permission at all. AppleScript stays as a fallback for
    /// the case where NSWorkspace refuses the file.
    static func set(_ url: URL) throws {
        var failure: Error?
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(image(for: screen, from: url),
                                                          for: screen, options: [:])
            } catch {
                failure = error
            }
        }
        current = url
        guard let failure else { return }
        if !setViaAppleScript(url) { throw failure }
    }

    /// What this screen should show for `url`: its own tile if `url` is a
    /// spanned canvas that has one, otherwise `url` itself.
    private static func image(for screen: NSScreen, from url: URL) -> URL {
        guard let id = SpanLayout.displayID(screen) else { return url }
        let tile = Gallery.tile(of: url, display: id)
        return FileManager.default.fileExists(atPath: tile.path) ? tile : url
    }

    /// Pick up the wallpaper already on screen at launch, so a display attached
    /// before the first render of a session still gets re-asserted.
    ///
    /// Deliberately only adopts one of our own renders. If the desktop is
    /// showing something the user chose elsewhere, re-applying it across their
    /// other displays would be overriding a choice we were never asked about.
    static func adoptCurrent() {
        guard current == nil, let screen = NSScreen.main,
              let shown = NSWorkspace.shared.desktopImageURL(for: screen),
              shown.resolvingSymlinksInPath().path
                .hasPrefix(Gallery.folder.resolvingSymlinksInPath().path + "/")
        else { return }
        // A tile stands for the canvas it was cut from; adopting the tile itself
        // would copy one display's slice onto all the others.
        let url = Gallery.canvas(ofTile: shown) ?? shown
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        current = url
    }

    /// Re-apply the current wallpaper to any screen that isn't already showing
    /// it. Called when the screen arrangement changes: a display attached now
    /// resolves whatever path it last had, which is very often a file this app
    /// has since deleted, and a missing file means the stock system wallpaper.
    static func reassert() {
        guard let current, FileManager.default.fileExists(atPath: current.path) else { return }
        for screen in NSScreen.screens {
            let wanted = image(for: screen, from: current)
            guard NSWorkspace.shared.desktopImageURL(for: screen) != wanted else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(wanted, for: screen, options: [:])
        }
    }

    private static func setViaAppleScript(_ url: URL) -> Bool {
        let source = "tell application \"System Events\" to set picture of every desktop "
            + "to POSIX file \"\(url.path)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

enum Gallery {
    static let folder = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Pictures/advect", isDirectory: true)

    /// Newest renders first. Dynamic .heic files can be hundreds of megabytes, so
    /// nothing here ever opens one — only ImageIO thumbnails them.
    static func recent(limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        return entries
            .filter { ["png", "heic"].contains($0.pathExtension.lowercased()) }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Delete everything past the newest `keep` renders, so the gallery never
    /// grows unbounded — except anything the wallpaper store still points at.
    ///
    /// That exception is the whole point. macOS keeps the desktop picture as a
    /// *path*, per Space and per display, and resolves it lazily; deleting the
    /// file it names doesn't fall back to something sensible, it falls back to
    /// the stock system wallpaper. Pruning by age alone quietly broke every
    /// Space whose wallpaper was more than `keep` renders old, which only became
    /// visible when that Space or display next came up.
    ///
    /// A spanned render goes as a unit with its tiles: it stays while the canvas
    /// or any one tile is still named, and when it goes the tiles go with it.
    static func prune(keep: Int) {
        let referenced = referencedPaths()
        let isReferenced = { (url: URL) in referenced.contains(url.resolvingSymlinksInPath().path) }
        let fm = FileManager.default
        for url in recent(limit: .max).dropFirst(keep) {
            let tiles = (try? fm.contentsOfDirectory(at: tilesFolder(of: url),
                                                     includingPropertiesForKeys: nil)) ?? []
            guard !isReferenced(url), !tiles.contains(where: isReferenced) else { continue }
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: tilesFolder(of: url))
        }
    }

    /// Where a spanned canvas keeps its per-display tiles. Hidden, so neither
    /// Recent nor a glance at the folder in Finder lists the slices as renders.
    static func tilesFolder(of canvas: URL) -> URL {
        folder.appendingPathComponent(".span", isDirectory: true)
            .appendingPathComponent(canvas.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    static func tile(of canvas: URL, display: String) -> URL {
        tilesFolder(of: canvas).appendingPathComponent("\(display).png")
    }

    /// The canvas a tile was cut from, or nil if `url` isn't a tile.
    static func canvas(ofTile url: URL) -> URL? {
        let dir = url.deletingLastPathComponent()
        guard dir.deletingLastPathComponent().lastPathComponent == ".span" else { return nil }
        return folder.appendingPathComponent(dir.lastPathComponent + ".png")
    }

    /// Every file path the wallpaper system currently names.
    ///
    /// Read from two places, because neither is complete. `desktopImageURL`
    /// covers the attached screens on the current Space only. The rest live in
    /// the wallpaper agent's own store, one entry per Space per display, each
    /// holding a nested binary plist of the form
    /// `{type: imageFile, url: {relative: "file:///…"}}`. Reading it is
    /// unsupported but harmless — a parse failure just means a smaller
    /// exclusion set, and the worst case is the old behaviour.
    static func referencedPaths() -> Set<String> {
        var paths = Set<String>()
        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
                paths.insert(url.resolvingSymlinksInPath().path)
            }
        }
        let store = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store),
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        else { return paths }
        collectPaths(root, into: &paths)
        return paths
    }

    /// Walk the store looking for the embedded configuration blobs. The shape
    /// around them has changed across macOS releases, so this hunts for `Data`
    /// that parses as a plist naming a file rather than following a fixed key
    /// path.
    private static func collectPaths(_ node: Any, into paths: inout Set<String>) {
        switch node {
        case let dict as [String: Any]:
            for value in dict.values { collectPaths(value, into: &paths) }
        case let array as [Any]:
            for value in array { collectPaths(value, into: &paths) }
        case let data as Data:
            guard let inner = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any],
                  let url = inner["url"] as? [String: Any],
                  let relative = url["relative"] as? String,
                  let parsed = URL(string: relative), parsed.isFileURL
            else { return }
            paths.insert(parsed.resolvingSymlinksInPath().path)
        default:
            break
        }
    }

    private static var thumbnails: [String: NSImage] = [:]

    /// A small thumbnail, cached by path and mtime. Uses ImageIO so a 150 MB
    /// dynamic wallpaper costs a decode of its embedded preview, not the frame.
    static func thumbnail(_ url: URL, maxPixel: Int) -> NSImage? {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)|\(maxPixel)"
        if let hit = thumbnails[key] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails[key] = image
        return image
    }
}
