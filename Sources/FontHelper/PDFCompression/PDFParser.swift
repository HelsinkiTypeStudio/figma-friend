import Foundation

/// Parses PDF object syntax from a byte array.
struct PDFParser {
    let b: [UInt8]
    var pos: Int

    init(_ bytes: [UInt8], at pos: Int = 0) {
        b = bytes
        self.pos = pos
    }

    @inline(__always) static func isWhite(_ c: UInt8) -> Bool {
        c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0
    }

    @inline(__always) static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    @inline(__always) static func isRegular(_ c: UInt8) -> Bool { !isWhite(c) && !isDelimiter(c) }

    var atEnd: Bool { pos >= b.count }

    mutating func skipWhite() {
        while pos < b.count {
            let c = b[pos]
            if Self.isWhite(c) {
                pos += 1
            } else if c == 0x25 { // % comment
                while pos < b.count, b[pos] != 10, b[pos] != 13 { pos += 1 }
            } else {
                return
            }
        }
    }

    /// True when the next token is exactly `word` (followed by a delimiter, whitespace or the end).
    func matches(_ word: String) -> Bool {
        let w = Array(word.utf8)
        guard pos + w.count <= b.count else { return false }
        for i in 0..<w.count where b[pos + i] != w[i] { return false }
        let after = pos + w.count
        return after >= b.count || !Self.isRegular(b[after])
    }

    mutating func regularToken() -> ArraySlice<UInt8> {
        let start = pos
        while pos < b.count, Self.isRegular(b[pos]) { pos += 1 }
        return b[start..<pos]
    }

    mutating func readInt() -> Int? {
        skipWhite()
        let save = pos
        let t = regularToken()
        if let v = Self.parseInt(t) { return v }
        pos = save
        return nil
    }

    static func parseInt(_ t: ArraySlice<UInt8>) -> Int? {
        guard !t.isEmpty, t.count < 19 else { return nil }
        var i = t.startIndex
        var neg = false
        if t[i] == 0x2B || t[i] == 0x2D { neg = t[i] == 0x2D; i += 1 }
        guard i < t.endIndex else { return nil }
        var v = 0
        while i < t.endIndex {
            let c = t[i]
            guard c >= 0x30, c <= 0x39 else { return nil }
            v = v * 10 + Int(c - 0x30)
            i += 1
        }
        return neg ? -v : v
    }

    /// Parses a number token (integers, reals like ".5", "-3.", and tolerates a doubled sign).
    static func parseNumber(_ t: ArraySlice<UInt8>) -> (Double, isInt: Bool)? {
        guard !t.isEmpty else { return nil }
        var i = t.startIndex
        var neg = false
        while i < t.endIndex, t[i] == 0x2B || t[i] == 0x2D { if t[i] == 0x2D { neg.toggle() }; i += 1 }
        var intPart = 0.0, frac = 0.0, scale = 1.0
        var digits = 0, dot = false
        while i < t.endIndex {
            let c = t[i]
            if c >= 0x30, c <= 0x39 {
                digits += 1
                if dot { scale /= 10; frac += Double(c - 0x30) * scale } else { intPart = intPart * 10 + Double(c - 0x30) }
            } else if c == 0x2E, !dot {
                dot = true
            } else {
                return nil
            }
            i += 1
        }
        guard digits > 0 else { return nil }
        let v = intPart + frac
        return (neg ? -v : v, !dot)
    }

    mutating func parseValue(depth: Int = 0) throws -> PDFValue {
        guard depth < 200 else { throw PDFError.malformed("nesting too deep") }
        skipWhite()
        guard pos < b.count else { throw PDFError.malformed("unexpected end") }
        let c = b[pos]
        switch c {
        case 0x2F: // /name
            pos += 1
            let t = regularToken()
            return .name(String(bytes: t, encoding: .isoLatin1) ?? "")
        case 0x28: // (string)
            return .string(try parseLiteralString())
        case 0x3C:
            if pos + 1 < b.count, b[pos + 1] == 0x3C {
                pos += 2
                var d = PDFDict()
                while true {
                    skipWhite()
                    guard pos < b.count else { throw PDFError.malformed("unterminated dictionary") }
                    if b[pos] == 0x3E {
                        if pos + 1 < b.count, b[pos + 1] == 0x3E { pos += 2; break }
                        pos += 1; continue
                    }
                    guard b[pos] == 0x2F else {
                        // Junk inside a dictionary: skip one token and carry on.
                        _ = try? parseValue(depth: depth + 1)
                        if pos < b.count, !Self.isRegular(b[pos]), b[pos] != 0x2F, b[pos] != 0x3E { pos += 1 }
                        continue
                    }
                    pos += 1
                    let key = String(bytes: regularToken(), encoding: .isoLatin1) ?? ""
                    skipWhite()
                    if pos < b.count, b[pos] == 0x3E { d[key] = .null; continue }
                    let v = try parseValue(depth: depth + 1)
                    d[key] = v
                }
                return .dict(d)
            }
            return .hexString(try parseHexString())
        case 0x5B: // [array]
            pos += 1
            var a: [PDFValue] = []
            while true {
                skipWhite()
                guard pos < b.count else { throw PDFError.malformed("unterminated array") }
                if b[pos] == 0x5D { pos += 1; break }
                a.append(try parseValue(depth: depth + 1))
            }
            return .array(a)
        default:
            guard Self.isRegular(c) else { pos += 1; throw PDFError.malformed("unexpected character") }
            let save = pos
            let t = regularToken()
            if let (v, isInt) = Self.parseNumber(t) {
                if isInt, let n = Self.parseInt(t) {
                    // Look ahead for "gen R".
                    let after = pos
                    if let g = readInt(), g >= 0 {
                        skipWhite()
                        if matches("R") { pos += 1; return .ref(n, g) }
                    }
                    pos = after
                    return .int(n)
                }
                return .real(v)
            }
            switch String(decoding: t, as: UTF8.self) {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                pos = save
                throw PDFError.malformed("unexpected keyword")
            }
        }
    }

    mutating func parseLiteralString() throws -> Data {
        pos += 1
        var out = [UInt8]()
        var depth = 1
        while pos < b.count {
            let c = b[pos]
            pos += 1
            switch c {
            case 0x28: depth += 1; out.append(c)
            case 0x29:
                depth -= 1
                if depth == 0 { return Data(out) }
                out.append(c)
            case 0x5C:
                guard pos < b.count else { break }
                let e = b[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "n"): out.append(10)
                case UInt8(ascii: "r"): out.append(13)
                case UInt8(ascii: "t"): out.append(9)
                case UInt8(ascii: "b"): out.append(8)
                case UInt8(ascii: "f"): out.append(12)
                case 13: if pos < b.count, b[pos] == 10 { pos += 1 }
                case 10: break
                case 0x30...0x37:
                    var v = Int(e - 0x30)
                    var n = 1
                    while n < 3, pos < b.count, b[pos] >= 0x30, b[pos] <= 0x37 {
                        v = v * 8 + Int(b[pos] - 0x30); pos += 1; n += 1
                    }
                    out.append(UInt8(v & 0xFF))
                default: out.append(e)
                }
            default: out.append(c)
            }
        }
        throw PDFError.malformed("unterminated string")
    }

    mutating func parseHexString() throws -> Data {
        pos += 1
        var out = [UInt8]()
        var hi: UInt8?
        while pos < b.count {
            let c = b[pos]
            pos += 1
            if c == 0x3E {
                if let h = hi { out.append(h << 4) }
                return Data(out)
            }
            let v: UInt8
            switch c {
            case 0x30...0x39: v = c - 0x30
            case 0x41...0x46: v = c - 0x41 + 10
            case 0x61...0x66: v = c - 0x61 + 10
            default: continue
            }
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        throw PDFError.malformed("unterminated hex string")
    }
}

extension Array where Element == UInt8 {
    /// Index of the first occurrence of `pattern` at or after `from`.
    func find(_ pattern: [UInt8], from: Int = 0, to end: Int? = nil) -> Int? {
        let limit = Swift.min(end ?? count, count) - pattern.count
        guard !pattern.isEmpty, from <= limit else { return nil }
        let first = pattern[0]
        return withUnsafeBufferPointer { buf -> Int? in
            var i = Swift.max(from, 0)
            while i <= limit {
                if buf[i] == first {
                    var ok = true
                    for j in 1..<pattern.count where buf[i + j] != pattern[j] { ok = false; break }
                    if ok { return i }
                }
                i += 1
            }
            return nil
        }
    }

    /// Index of the last occurrence of `pattern` that starts at or after `from`.
    func findLast(_ pattern: [UInt8], from: Int = 0) -> Int? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        var i = count - pattern.count
        while i >= Swift.max(from, 0) {
            if self[i] == pattern[0] {
                var ok = true
                for j in 1..<pattern.count where self[i + j] != pattern[j] { ok = false; break }
                if ok { return i }
            }
            i -= 1
        }
        return nil
    }
}
