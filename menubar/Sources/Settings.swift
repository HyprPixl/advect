import AppKit
import Foundation

/// A palette the user built in the editor. Stored beside the built-ins rather
/// than in them, so `PaletteSpec.named` stays the fixed set the renderer ships.
struct CustomPalette: Codable {
    var name: String
    var background: [Int]        // r, g, b
    var strokes: [[Int]]         // four r,g,b triples

    var spec: PaletteSpec { PaletteSpec(background: background, strokes: strokes) }
}

/// Render size, as a fraction of the display's native pixel size. Native looks
/// best; the smaller ones exist because a full-size Python render is minutes.
enum Quality: String, CaseIterable {
    case native, half, quarter

    var title: String {
        switch self {
        case .native: return "Native"
        case .half: return "Half"
        case .quarter: return "Quarter"
        }
    }

    var divisor: Int {
        switch self {
        case .native: return 1
        case .half: return 2
        case .quarter: return 4
        }
    }

    /// Pixel dimensions to hand the renderer, capped the same way the CLI caps them.
    var size: (w: Int, h: Int) {
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let frame = screen?.frame.size ?? CGSize(width: 1728, height: 1117)
        let w = min(Int(frame.width * scale), 3840) / divisor
        let h = min(Int(frame.height * scale), 2560) / divisor
        return (max(w, 320), max(h, 200))
    }
}

enum Rotate: Int, CaseIterable {
    case off = 0
    case min30 = 1800
    case hour1 = 3600
    case hour6 = 21600
    case day1 = 86400

    var title: String {
        switch self {
        case .off: return "Off"
        case .min30: return "Every 30 minutes"
        case .hour1: return "Hourly"
        case .hour6: return "Every 6 hours"
        case .day1: return "Daily"
        }
    }
}

/// Everything the menu can toggle, persisted in UserDefaults.
final class Settings {
    static let shared = Settings()
    private let store = UserDefaults.standard

    private init() {
        store.register(defaults: [
            "palette": Settings.randomPalette,
            "quality": Quality.native.rawValue,
            "rotate": Rotate.off.rawValue,
            "frames": 32,
            // The desktop is the better preview: it's the actual size, the
            // actual thing. The panel stays available for anyone who'd rather
            // not have their wallpaper move while it works.
            "showPreview": false,
            "paintOnDesktop": true,
        ])
    }

    /// The name stored when the palette is left up to the renderer. It can't
    /// collide with a real one: the editor refuses it as a custom name.
    static let randomPalette = "random"

    /// A palette name — a built-in, one of the user's own, or `randomPalette`.
    var palette: String {
        get { store.string(forKey: "palette") ?? Settings.randomPalette }
        set { store.set(newValue, forKey: "palette") }
    }

    /// The user's palettes, JSON in UserDefaults. A decode failure means the key
    /// holds something we didn't write, and an empty list is the honest answer.
    var customPalettes: [CustomPalette] {
        get {
            guard let data = store.data(forKey: "customPalettes"),
                  let list = try? JSONDecoder().decode([CustomPalette].self, from: data)
            else { return [] }
            return list
        }
        set { store.set(try? JSONEncoder().encode(newValue), forKey: "customPalettes") }
    }

    /// Every palette that can be rendered, built-ins first, in menu order.
    var paletteNames: [String] { PaletteSpec.order + customPalettes.map(\.name) }

    /// The one lookup everything renders through: a custom palette shadows
    /// nothing, but is found by name exactly the way a built-in is.
    func paletteSpec(named name: String) -> PaletteSpec? {
        PaletteSpec.named[name] ?? customPalettes.first { $0.name == name }?.spec
    }

    var quality: Quality {
        get { Quality(rawValue: store.string(forKey: "quality") ?? "") ?? .native }
        set { store.set(newValue.rawValue, forKey: "quality") }
    }

    var rotate: Rotate {
        get { Rotate(rawValue: store.integer(forKey: "rotate")) ?? .off }
        set { store.set(newValue.rawValue, forKey: "rotate") }
    }

    /// Frames packed into a Dynamic .heic — more is smoother, and much slower.
    var frames: Int {
        get { max(store.integer(forKey: "frames"), 2) }
        set { store.set(newValue, forKey: "frames") }
    }

    /// Whether the floating live-paint window opens while a render runs.
    var showPreview: Bool {
        get { store.bool(forKey: "showPreview") }
        set { store.set(newValue, forKey: "showPreview") }
    }

    /// Paint onto the desktop itself as it renders. Costs roughly 7% of a
    /// render; on by default, because watching the wallpaper draw itself at
    /// full size is better than watching a thumbnail of it.
    var paintOnDesktop: Bool {
        get { store.bool(forKey: "paintOnDesktop") }
        set { store.set(newValue, forKey: "paintOnDesktop") }
    }

    /// When auto-rotate last fired, so quitting doesn't restart the clock.
    var lastRotate: Date {
        get { store.object(forKey: "lastRotate") as? Date ?? .distantPast }
        set { store.set(newValue, forKey: "lastRotate") }
    }
}
