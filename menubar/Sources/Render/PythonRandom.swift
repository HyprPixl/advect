import Foundation

/// CPython's `random.Random`, reproduced exactly.
///
/// The renderer's whole contract is that a seed names a picture: the same seed
/// has to give the same geometry whether it came from the Python CLI or from
/// this app. Every particle position and every noise cell is drawn from here, so
/// this has to agree with CPython bit for bit — not merely be "a Mersenne
/// Twister". Two details do the work:
///
///  * seeding an int goes through `init_by_array` over the absolute value split
///    into 32-bit little-endian words, not the simpler `init_genrand`
///  * `random()` is `genrand_res53`: two draws combined into a 53-bit double,
///    which is what makes the low bits line up
struct PythonRandom {
    private var mt = [UInt32](repeating: 0, count: 624)
    private var index = 625

    init(seed: Int) {
        // CPython takes the absolute value and feeds it in as 32-bit words.
        var magnitude = UInt64(seed.magnitude)
        var key: [UInt32] = []
        repeat {
            key.append(UInt32(truncatingIfNeeded: magnitude))
            magnitude >>= 32
        } while magnitude > 0
        initByArray(key)
    }

    private mutating func initGenrand(_ s: UInt32) {
        mt[0] = s
        for i in 1..<624 {
            mt[i] = 1812433253 &* (mt[i - 1] ^ (mt[i - 1] >> 30)) &+ UInt32(i)
        }
        index = 624
    }

    private mutating func initByArray(_ key: [UInt32]) {
        initGenrand(19650218)
        var i = 1, j = 0
        var k = max(624, key.count)
        while k > 0 {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1664525)) &+ key[j] &+ UInt32(j)
            i += 1; j += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
            if j >= key.count { j = 0 }
            k -= 1
        }
        k = 623
        while k > 0 {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1566083941)) &- UInt32(i)
            i += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
            k -= 1
        }
        mt[0] = 0x8000_0000
    }

    private mutating func generate() {
        let upperMask: UInt32 = 0x8000_0000, lowerMask: UInt32 = 0x7fff_ffff
        for i in 0..<624 {
            let y = (mt[i] & upperMask) | (mt[(i + 1) % 624] & lowerMask)
            var next = mt[(i + 397) % 624] ^ (y >> 1)
            if y & 1 != 0 { next ^= 0x9908_b0df }
            mt[i] = next
        }
        index = 0
    }

    private mutating func nextUInt32() -> UInt32 {
        if index >= 624 { generate() }
        var y = mt[index]
        index += 1
        y ^= y >> 11
        y ^= (y << 7) & 0x9d2c_5680
        y ^= (y << 15) & 0xefc6_0000
        y ^= y >> 18
        return y
    }

    /// `random.random()` — genrand_res53, two draws into one 53-bit double.
    mutating func next() -> Double {
        let a = Double(nextUInt32() >> 5)
        let b = Double(nextUInt32() >> 6)
        return (a * 67108864.0 + b) * (1.0 / 9007199254740992.0)
    }

    /// `random.uniform(a, b)` — CPython computes it exactly this way, and the
    /// rounding of this expression is observable in the output.
    mutating func uniform(_ a: Double, _ b: Double) -> Double {
        a + (b - a) * next()
    }
}
