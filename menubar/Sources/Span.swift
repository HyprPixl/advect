import AppKit
import Foundation

/// The display arrangement as one canvas, so a single render can run across
/// every screen as if they were one.
///
/// Geometry comes from the arrangement in System Settings › Displays, which is
/// in points: two screens side by side there are side by side here, offsets and
/// gaps included. A gap in the arrangement is painted but never shown, which is
/// the honest reading of "continuous" — a stroke leaving one screen re-enters the
/// next where the arrangement says it would.
struct SpanLayout {
    /// One display's piece of the canvas, in canvas pixels, top-left origin.
    struct Tile {
        let display: String
        let rect: CGRect
    }

    let width: Int, height: Int
    let tiles: [Tile]

    /// Ceilings on the canvas, applied as one uniform scale so the tiles keep
    /// the arrangement's proportions. Render time grows with area *and* with the
    /// long side (stroke length is a multiple of it), so both are bounded.
    private static let maxSide = 7680
    private static let maxPixels = 16_600_000

    /// The current arrangement, or nil when there's nothing to span.
    ///
    /// Pixel density is the densest screen's, so a Retina display gets a native
    /// tile and a 1x neighbour is handed more pixels than it needs, not fewer.
    static func current(divisor: Int = 1) -> SpanLayout? {
        let screens = NSScreen.screens.compactMap { s in Self.displayID(s).map { (s, $0) } }
        guard screens.count > 1 else { return nil }

        let union = screens.map(\.0.frame).reduce(CGRect.null) { $0.union($1) }
        var scale = screens.map(\.0.backingScaleFactor).max() ?? 1
        scale = min(scale, CGFloat(maxSide) / max(union.width, union.height))
        scale = min(scale, (CGFloat(maxPixels) / (union.width * union.height)).squareRoot())
        scale /= CGFloat(divisor)

        let width = max(Int((union.width * scale).rounded()), 320)
        let height = max(Int((union.height * scale).rounded()), 200)
        let tiles = screens.map { screen, id in
            let f = screen.frame
            // NSScreen frames have a bottom-left origin; the canvas is top-left.
            let rect = CGRect(x: ((f.minX - union.minX) * scale).rounded(),
                              y: ((union.maxY - f.maxY) * scale).rounded(),
                              width: (f.width * scale).rounded(),
                              height: (f.height * scale).rounded())
            return Tile(display: id, rect: rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)))
        }
        return SpanLayout(width: width, height: height, tiles: tiles)
    }

    /// The tile for this screen, as a fraction of the canvas.
    func unitRect(for screen: NSScreen) -> CGRect? {
        guard let id = Self.displayID(screen), let tile = tiles.first(where: { $0.display == id })
        else { return nil }
        let r = tile.rect
        return CGRect(x: r.minX / CGFloat(width), y: r.minY / CGFloat(height),
                      width: r.width / CGFloat(width), height: r.height / CGFloat(height))
    }

    /// A display's UUID. `CGDirectDisplayID` would be simpler, but it is only
    /// stable for as long as the display stays attached; tiles outlive that, so
    /// they're keyed by something that survives a replug or a reboot.
    static func displayID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

extension CGImage {
    /// Crop by a rect given as a fraction of the image, top-left origin.
    func cropping(unit r: CGRect) -> CGImage? {
        let w = CGFloat(width), h = CGFloat(height)
        return cropping(to: CGRect(x: (r.minX * w).rounded(), y: (r.minY * h).rounded(),
                                   width: max(1, (r.width * w).rounded()),
                                   height: max(1, (r.height * h).rounded())))
    }
}
