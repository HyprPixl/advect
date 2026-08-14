import Foundation

/// Value noise + fBm — the field the particles march through.
///
/// A direct transcription of the Python `Noise` class. The 64×64 grid is drawn
/// from the shared RNG in exactly the same order, so the field a seed produces
/// here is the field it produces there.
struct Noise {
    private var grid: [Double]
    let cell: Double

    /// Consumes 4096 draws, row-major — matching `[[rng.random() for _ in
    /// range(64)] for _ in range(64)]`.
    init(rng: inout PythonRandom, cell: Double) {
        var g = [Double](repeating: 0, count: 64 * 64)
        for i in 0..<(64 * 64) { g[i] = rng.next() }
        self.grid = g
        self.cell = cell
    }

    /// The flat grid, for handing to the C kernel.
    var flattened: [Double] { grid }

    @inline(__always)
    func raw(_ x: Double, _ y: Double) -> Double {
        let gx = x / cell, gy = y / cell
        // Python's int() truncates toward zero; so does Swift's Int(). The & 63
        // then wraps the same way in both, two's complement.
        let tx = Int(gx), ty = Int(gy)
        let ix = tx & 63, iy = ty & 63
        let fx = gx - Double(tx), fy = gy - Double(ty)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let ix1 = (ix + 1) & 63, iy1 = (iy + 1) & 63
        let a = grid[iy * 64 + ix], b = grid[iy * 64 + ix1]
        let c = grid[iy1 * 64 + ix], d = grid[iy1 * 64 + ix1]
        return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
    }

    @inline(__always)
    func fbm(_ x: Double, _ y: Double) -> Double {
        raw(x, y) * 0.5
            + raw(x * 2.1 + 31, y * 2.1 + 57) * 0.3
            + raw(x * 4.3 + 89, y * 4.3 + 13) * 0.2
    }
}
