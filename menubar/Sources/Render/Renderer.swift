import Foundation

/// Renders a flow field to an RGB byte buffer.
///
/// Python owns nothing here any more: the RNG, the scene and the light layer are
/// all Swift, and the hot march is the same C kernel the CLI uses, linked in at
/// build time. Same seed, same picture, no interpreter and no compiler needed at
/// run time.
enum Renderer {

    /// Separable clamped-edge box blur over one channel, in place. Two passes
    /// fake a Gaussian well enough for a light layer.
    ///
    /// The running sum is a Double even though the buffer is Float. That isn't
    /// incidental: Python's floats are doubles, so its sliding window accumulates
    /// at double precision and only narrows on the store. Accumulating in Float
    /// instead shifts the odd channel by one level and shows up as faint vertical
    /// banding against the reference render.
    static func boxBlur(_ a: inout [Float], width w: Int, height h: Int, radius r: Int, passes: Int = 2) {
        let win = Double(2 * r + 1)
        var tmp = [Float](repeating: 0, count: a.count)
        for _ in 0..<passes {
            for y in 0..<h {                                        // horizontal → tmp
                let row = y * w
                var s: Double = 0
                for k in -r...r { s += Double(a[row + min(max(k, 0), w - 1)]) }
                for x in 0..<w {
                    tmp[row + x] = Float(s / win)
                    s -= Double(a[row + max(0, x - r)])
                    s += Double(a[row + min(w - 1, x + r + 1)])
                }
            }
            for x in 0..<w {                                        // vertical → a
                var s: Double = 0
                for k in -r...r { s += Double(tmp[min(max(k, 0), h - 1) * w + x]) }
                for y in 0..<h {
                    a[y * w + x] = Float(s / win)
                    s -= Double(tmp[max(0, y - r) * w + x])
                    s += Double(tmp[min(h - 1, y + r + 1) * w + x])
                }
            }
        }
    }

    /// Paint one frame. `onProgress` reports 0–100 and may be called often;
    /// `isCancelled` is polled between chunks so a render can be abandoned.
    static func render(width w: Int, height h: Int, seed: Int, palette: PaletteSpec,
                       sharp: Double, glow: Double, softness: Double,
                       onProgress: ((Int, [UInt8]) -> Void)? = nil,
                       isCancelled: (() -> Bool)? = nil) -> [UInt8]? {
        var scene = Scene(width: w, height: h, seed: seed, palette: palette, sharp: sharp, glow: glow)
        var light = [Float](repeating: 0, count: scene.useGlow ? scene.lightWidth * scene.lightHeight * 3 : 0)

        // March in chunks so progress and the live preview have something to
        // show. The kernel keeps no state between particles and still walks them
        // in order, so chunking is bit-identical to one big call.
        let chunk = max(1, (scene.count + 47) / 48)
        var done = 0
        while done < scene.count {
            if isCancelled?() == true { return nil }
            let m = min(chunk, scene.count - done)
            scene.fieldGrid.withUnsafeBufferPointer { gp in
            scene.taper.withUnsafeBufferPointer { tp in
            scene.px.withUnsafeBufferPointer { xp in
            scene.py.withUnsafeBufferPointer { yp in
            scene.mode.withUnsafeBufferPointer { mp in
            scene.alpha.withUnsafeBufferPointer { ap in
            scene.colors.withUnsafeBufferPointer { cp in
            scene.buffer.withUnsafeMutableBufferPointer { bp in
            light.withUnsafeMutableBufferPointer { lp in
                fp_march(gp.baseAddress, scene.cell, scene.twist, Int32(w), Int32(h),
                         xp.baseAddress! + done, yp.baseAddress! + done,
                         mp.baseAddress! + done, ap.baseAddress! + done,
                         cp.baseAddress! + done * 3,
                         Int32(m), Int32(scene.steps), tp.baseAddress,
                         bp.baseAddress,
                         scene.useGlow ? 1 : 0,
                         scene.useGlow ? lp.baseAddress : nil,
                         Int32(scene.lightWidth), Int32(scene.lightHeight),
                         Int32(scene.downsample), kLightK * depositScale())
            }}}}}}}}}
            done += m
            onProgress?(100 * done / scene.count, scene.buffer)
        }

        if scene.useGlow {
            if isCancelled?() == true { return nil }
            let r = max(1, Int((3 * softness).rounded(.toNearestOrEven)))
            // Blur each channel independently, de-interleaving and back.
            let cells = scene.lightWidth * scene.lightHeight
            for c in 0..<3 {
                var channel = [Float](repeating: 0, count: cells)
                for i in 0..<cells { channel[i] = light[i * 3 + c] }
                boxBlur(&channel, width: scene.lightWidth, height: scene.lightHeight, radius: r)
                for i in 0..<cells { light[i * 3 + c] = channel[i] }
            }
            scene.buffer.withUnsafeMutableBufferPointer { bp in
                light.withUnsafeBufferPointer { lp in
                    fp_composite(bp.baseAddress, lp.baseAddress, glow,
                                 Int32(scene.lightWidth), Int32(scene.lightHeight),
                                 Int32(scene.downsample), Int32(w), Int32(h))
                }
            }
        }
        onProgress?(100, scene.buffer)
        return scene.buffer
    }
}
