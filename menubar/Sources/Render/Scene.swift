import Foundation

/// A colour scheme: a near-black ground and the stroke colours that blaze on it.
struct PaletteSpec {
    var background: [Int]      // r, g, b
    var strokes: [[Int]]       // four r,g,b triples

    static let named: [String: PaletteSpec] = [
        "harbor": PaletteSpec(background: [20, 10, 12],
                              strokes: [[255, 72, 58], [220, 40, 50], [255, 132, 108], [150, 44, 62]]),
        "ember": PaletteSpec(background: [24, 15, 18],
                             strokes: [[242, 149, 68], [214, 78, 60], [255, 209, 102], [120, 60, 80]]),
        "moss": PaletteSpec(background: [14, 14, 22],
                            strokes: [[155, 93, 229], [45, 166, 178], [200, 160, 255], [58, 40, 90]]),
        "dune": PaletteSpec(background: [22, 17, 10],
                            strokes: [[255, 183, 59], [224, 122, 29], [255, 214, 133], [94, 64, 24]]),
    ]

    static let order = ["harbor", "ember", "moss", "dune"]
}

/// A 24-hour journey of moods: (time 0=midnight..1, palette, glow, softness).
/// `dayLook` interpolates between them, so colour and light only ever drift.
private let moods: [(t: Double, palette: String, glow: Double, softness: Double)] = [
    (0.00, "harbor", 1.05, 1.40),
    (0.16, "harbor", 0.80, 1.30),
    (0.27, "ember", 0.66, 1.15),
    (0.36, "ember", 0.52, 1.05),
    (0.45, "dune", 0.40, 1.00),
    (0.52, "dune", 0.26, 1.00),
    (0.62, "moss", 0.44, 1.05),
    (0.72, "moss", 0.60, 1.12),
    (0.81, "ember", 0.92, 1.25),
    (0.90, "ember", 1.06, 1.35),
]

@inline(__always) private func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double {
    a + (b - a) * u
}

/// Ease-in-out, so the drift between moods is gentle.
@inline(__always) private func smooth(_ u: Double) -> Double { u * u * (3 - 2 * u) }

/// Python's `round()` is banker's rounding — halves go to even, not away from
/// zero. Swift's default `.rounded()` disagrees, and the difference is visible
/// in interpolated palette channels, so be explicit.
@inline(__always) private func pyRound(_ x: Double) -> Int {
    Int(x.rounded(.toNearestOrEven))
}

/// The look at time-of-day t ∈ [0,1): a palette blended between the two nearest
/// moods, plus the glow and softness for that hour.
func dayLook(_ t: Double) -> (palette: PaletteSpec, glow: Double, softness: Double) {
    var anchors = moods
    anchors.append((moods[0].t + 1.0, moods[0].palette, moods[0].glow, moods[0].softness))
    for i in 0..<(anchors.count - 1) {
        let a = anchors[i], b = anchors[i + 1]
        guard a.t <= t && t < b.t else { continue }
        let u = smooth((t - a.t) / (b.t - a.t))
        let p0 = PaletteSpec.named[a.palette]!, p1 = PaletteSpec.named[b.palette]!
        let bg = (0..<3).map { pyRound(lerp(Double(p0.background[$0]), Double(p1.background[$0]), u)) }
        let cols = zip(p0.strokes, p1.strokes).map { c0, c1 in
            (0..<3).map { pyRound(lerp(Double(c0[$0]), Double(c1[$0]), u)) }
        }
        return (PaletteSpec(background: bg, strokes: cols), lerp(a.glow, b.glow, u), lerp(a.softness, b.softness, u))
    }
    let fallback = PaletteSpec.named[moods[0].palette]!
    return (fallback, moods[0].glow, moods[0].softness)
}

// Tuning constants, shared with the Python renderer.
let kDensity = 105              // one stroke per this many pixels
let kStrokeLen = 1.05           // steps ≈ this × max(w, h)
let kDensityRef = 105
let kDepositExp = 0.85
let kFieldFreq = 1.0
let kLightK = 0.004             // energy a diffuse stroke emits per step
let kAlpha = 0.13               // sharp-stroke opacity

func nParticles(_ w: Int, _ h: Int) -> Int { max(w * h / kDensity, 800) }

func depositScale() -> Double { pow(Double(kDensity) / Double(kDensityRef), kDepositExp) }

/// How far a stroke travels, and its per-step taper: full brightness for most of
/// the run, easing off gently at both ends so nothing stops dead.
func strokePlan(_ w: Int, _ h: Int) -> (steps: Int, taper: [Double]) {
    let steps = max(Int(Double(max(w, h)) * kStrokeLen), 320)
    let fin = max(1, Int(Double(steps) * 0.03))
    let fout = max(1, Int(Double(steps) * 0.16))
    func ease(_ x: Double) -> Double {
        let c = x < 1.0 ? x : 1.0
        return c * c * (3 - 2 * c)
    }
    var taper = [Double](repeating: 0, count: steps)
    for s in 0..<steps {
        taper[s] = ease(Double(s + 1) / Double(fin)) * ease(Double(steps - s) / Double(fout))
    }
    return (steps, taper)
}

/// Everything the kernel needs, with every RNG draw already made.
///
/// This mirrors Python's `build_scene` draw for draw. The order matters more
/// than it looks: the field's `cell` argument is evaluated *before* the grid is
/// filled, and the per-particle mode check short-circuits when glow is off, so
/// it consumes a different number of draws. Get either wrong and the seed stops
/// naming the same picture.
struct Scene {
    let width: Int, height: Int
    let fieldGrid: [Double]
    let cell: Double
    let twist: Double
    var px: [Double], py: [Double]
    var mode: [UInt8]          // 1 = diffuse, 0 = sharp
    var alpha: [Double]
    var colors: [UInt8]        // three bytes per particle
    let count: Int
    let steps: Int
    let taper: [Double]
    var buffer: [UInt8]        // background-filled RGB canvas
    let useGlow: Bool
    let downsample = 3
    let lightWidth: Int, lightHeight: Int

    init(width w: Int, height h: Int, seed: Int, palette: PaletteSpec, sharp: Double, glow: Double) {
        width = w; height = h
        var rng = PythonRandom(seed: seed)

        // The uniform is drawn while evaluating the cell size, i.e. before the
        // field's 4096 grid values — same as Python's argument evaluation.
        let fieldCell = Double(max(w, h)) / (rng.uniform(4.5, 7.5) * kFieldFreq)
        let field = Noise(rng: &rng, cell: fieldCell)
        let band = Noise(rng: &rng, cell: Double(max(w, h)) / 3.0)
        fieldGrid = field.flattened
        cell = field.cell

        let bg = palette.background
        buffer = [UInt8](repeating: 0, count: w * h * 3)
        for i in stride(from: 0, to: buffer.count, by: 3) {
            buffer[i] = UInt8(bg[0]); buffer[i + 1] = UInt8(bg[1]); buffer[i + 2] = UInt8(bg[2])
        }

        useGlow = glow > 0 && sharp < 1.0
        lightWidth = (w + 2) / 3
        lightHeight = (h + 2) / 3

        count = nParticles(w, h)
        (steps, taper) = strokePlan(w, h)
        let strokeAlpha = kAlpha * depositScale()
        twist = rng.uniform(2.5, 4.5) * Double.pi

        px = [Double](repeating: 0, count: count)
        py = [Double](repeating: 0, count: count)
        mode = [UInt8](repeating: 0, count: count)
        alpha = [Double](repeating: 0, count: count)
        colors = [UInt8](repeating: 0, count: count * 3)

        let strokeCount = palette.strokes.count
        for p in 0..<count {
            let x = rng.uniform(0, Double(w))
            let y = rng.uniform(0, Double(h))
            let idx = min(Int(band.fbm(x, y) * Double(strokeCount) * 1.35), strokeCount - 1)
            let c = palette.strokes[idx]

            // Python short-circuits `use_glow and rng.random() >= sharp`, so with
            // glow off the mode draw never happens at all.
            var diffuse = false
            if useGlow {
                diffuse = rng.next() >= sharp
            }
            if diffuse {
                mode[p] = 1
            } else {
                let thick = rng.next() < 0.18
                alpha[p] = strokeAlpha * (thick ? 1.5 : 1.0)
            }
            px[p] = x; py[p] = y
            colors[p * 3] = UInt8(c[0]); colors[p * 3 + 1] = UInt8(c[1]); colors[p * 3 + 2] = UInt8(c[2])
        }
    }
}
