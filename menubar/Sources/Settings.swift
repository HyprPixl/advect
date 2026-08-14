import AppKit
import Foundation

enum Palette: String, CaseIterable {
    case random, harbor, ember, moss, dune

    var title: String { self == .random ? "Random" : rawValue.capitalized }
    /// nil means "let the renderer pick one", which is what --palette omitted does.
    var flag: String? { self == .random ? nil : rawValue }
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
            "palette": Palette.random.rawValue,
            "quality": Quality.native.rawValue,
            "rotate": Rotate.off.rawValue,
            "frames": 32,
            "showPreview": true,
        ])
    }

    var palette: Palette {
        get { Palette(rawValue: store.string(forKey: "palette") ?? "") ?? .random }
        set { store.set(newValue.rawValue, forKey: "palette") }
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

    /// When auto-rotate last fired, so quitting doesn't restart the clock.
    var lastRotate: Date {
        get { store.object(forKey: "lastRotate") as? Date ?? .distantPast }
        set { store.set(newValue, forKey: "lastRotate") }
    }
}
