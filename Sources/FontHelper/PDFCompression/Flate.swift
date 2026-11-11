import CZlib
import Foundation

enum Flate {
    /// Decompresses zlib/deflate data. Returns nil when the data is damaged (unless `allowPartial`).
    static func inflate(_ data: Data, allowPartial: Bool = false) -> Data? {
        guard !data.isEmpty else { return Data() }
        return data.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var len = 0
            var complete: Int32 = 0
            guard let p = cz_inflate(base, raw.count, &len, &complete) else { return nil }
            defer { cz_free(p) }
            if complete == 0 && !allowPartial { return nil }
            return Data(bytes: p, count: len)
        }
    }

    static func deflate(_ data: Data, level: Int32 = 9) -> Data? {
        data.withUnsafeBytes { raw -> Data? in
            let base = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
            var len = 0
            guard let p = cz_deflate(base, raw.count, level, &len) else { return nil }
            defer { cz_free(p) }
            return Data(bytes: p, count: len)
        }
    }

    static func deflate(_ bytes: [UInt8], level: Int32 = 9) -> Data? {
        bytes.withUnsafeBufferPointer { buf -> Data? in
            let base = buf.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
            var len = 0
            guard let p = cz_deflate(base, buf.count, level, &len) else { return nil }
            defer { cz_free(p) }
            return Data(bytes: p, count: len)
        }
    }

    /// Undoes PNG row predictors (DecodeParms /Predictor 10–15).
    static func unpredictPNG(_ data: Data, columns: Int, colors: Int, bitsPerComponent: Int) -> Data? {
        let bpp = max(1, colors * bitsPerComponent / 8)
        let rowLen = (columns * colors * bitsPerComponent + 7) / 8
        guard rowLen > 0 else { return nil }
        let src = [UInt8](data)
        let rows = src.count / (rowLen + 1)
        var out = [UInt8](repeating: 0, count: rows * rowLen)
        var prev = [UInt8](repeating: 0, count: rowLen)
        for r in 0..<rows {
            let s = r * (rowLen + 1)
            let filter = src[s]
            let o = r * rowLen
            for i in 0..<rowLen {
                let x = src[s + 1 + i]
                let a: Int = i >= bpp ? Int(out[o + i - bpp]) : 0
                let up = Int(prev[i])
                let c: Int = i >= bpp ? Int(prev[i - bpp]) : 0
                let v: Int
                switch filter {
                case 0: v = Int(x)
                case 1: v = Int(x) + a
                case 2: v = Int(x) + up
                case 3: v = Int(x) + (a + up) / 2
                case 4:
                    let p = a + up - c
                    let pa = abs(p - a), pb = abs(p - up), pc = abs(p - c)
                    let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? up : c)
                    v = Int(x) + pred
                default: return nil
                }
                out[o + i] = UInt8(truncatingIfNeeded: v)
            }
            for i in 0..<rowLen { prev[i] = out[o + i] }
        }
        return Data(out)
    }
}
