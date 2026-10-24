import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum ImageWriter {

    /// Wrap a tightly-packed RGB byte buffer as a CGImage. No alpha channel, no
    /// row padding — the renderer produces exactly w*h*3 bytes.
    static func makeImage(_ buffer: [UInt8], width w: Int, height h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    static func writePNG(_ buffer: [UInt8], width w: Int, height h: Int, to url: URL) -> Bool {
        guard let image = makeImage(buffer, width: w, height: h) else { return false }
        return writePNG(image, to: url)
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Apple's `h24` schedule: a base64'd binary plist naming, for each frame, the
    /// time of day it takes over, plus which frames to use for Light and Dark
    /// appearance. This is the whole trick behind a Dynamic wallpaper.
    fileprivate static func h24Payload(times: [Double], light: Int, dark: Int) -> String? {
        let entries = times.enumerated().map { ["t": $0.element, "i": $0.offset] as [String: Any] }
        let plist: [String: Any] = ["ti": entries, "ap": ["l": light, "d": dark]]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                             format: .binary, options: 0)
        else { return nil }
        return data.base64EncodedString()
    }

    /// Writes a macOS Dynamic `.heic` one frame at a time.
    ///
    /// Streaming rather than collecting: at native resolution a 32-frame day
    /// cycle is ~740 MB of pixels if you hold them all, and there's no need —
    /// the schedule depends only on the time of day, so it can be computed
    /// before a single frame is painted and attached to the primary image.
    /// Without that XMP this is just a multi-image HEIC and macOS shows a still.
    final class DynamicHEIC {
        private let dest: CGImageDestination
        private let metadata: CGMutableImageMetadata
        private let options: CFDictionary
        private var added = 0

        init?(url: URL, frameCount: Int, times: [Double],
              lightIndex: Int, darkIndex: Int, quality: Double) {
            guard frameCount > 0,
                  let payload = ImageWriter.h24Payload(times: times, light: lightIndex, dark: darkIndex),
                  let d = CGImageDestinationCreateWithURL(url as CFURL,
                                                          UTType.heic.identifier as CFString,
                                                          frameCount, nil)
            else { return nil }
            dest = d
            metadata = CGImageMetadataCreateMutable()
            CGImageMetadataRegisterNamespaceForPrefix(
                metadata, "http://ns.apple.com/namespace/1.0/" as CFString,
                "apple_desktop" as CFString, nil)
            CGImageMetadataSetValueWithPath(metadata, nil,
                                            "apple_desktop:h24" as CFString, payload as CFString)
            options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        }

        func add(_ buffer: [UInt8], width w: Int, height h: Int) -> Bool {
            guard let image = ImageWriter.makeImage(buffer, width: w, height: h) else { return false }
            if added == 0 {
                CGImageDestinationAddImageAndMetadata(dest, image, metadata, options)
            } else {
                CGImageDestinationAddImage(dest, image, options)
            }
            added += 1
            return true
        }

        func finish() -> Bool { CGImageDestinationFinalize(dest) }
    }
}
