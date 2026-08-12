import AppKit
import Foundation
import ImageIO

enum Wallpaper {
    /// Set every screen's desktop picture.
    ///
    /// NSWorkspace is deliberate: the CLI drives System Events over AppleScript,
    /// which would make the app ask for Automation permission on first render.
    /// This route needs no permission at all. AppleScript stays as a fallback for
    /// the case where NSWorkspace refuses the file.
    static func set(_ url: URL) throws {
        var failure: Error?
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch {
                failure = error
            }
        }
        guard let failure else { return }
        if !setViaAppleScript(url) { throw failure }
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
