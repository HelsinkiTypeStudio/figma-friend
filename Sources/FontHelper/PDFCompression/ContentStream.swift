import Foundation

struct Matrix {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    static let identity = Matrix()

    init() {}
    init(_ v: [Double]) {
        guard v.count >= 6 else { return }
        (a, b, c, d, e, f) = (v[0], v[1], v[2], v[3], v[4], v[5])
    }

    /// self applied first, then m.
    func concat(_ m: Matrix) -> Matrix {
        var r = Matrix()
        r.a = a * m.a + b * m.c
        r.b = a * m.b + b * m.d
        r.c = c * m.a + d * m.c
        r.d = c * m.b + d * m.d
        r.e = e * m.a + f * m.c + m.e
        r.f = e * m.b + f * m.d + m.f
        return r
    }

    /// The largest stretch this matrix applies.
    var scale: Double { max(hypot(a, b), hypot(c, d)) }
}

/// Splits a content stream into tokens without copying.
struct ContentLexer {
    enum Kind { case number, name, string, arrayOpen, arrayClose, dictOpen, dictClose, op, inlineImage, other }

    struct Token {
        var kind: Kind
        var start: Int
        var end: Int
        var number: Double = 0
    }

    let b: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) { b = bytes }

    mutating func next() throws -> Token? {
        while pos < b.count {
            let c = b[pos]
            if PDFParser.isWhite(c) { pos += 1; continue }
            if c == 0x25 { while pos < b.count, b[pos] != 10, b[pos] != 13 { pos += 1 }; continue }
            break
        }
        guard pos < b.count else { return nil }
        let start = pos
        let c = b[pos]
        switch c {
        case 0x28:
            var depth = 0
            while pos < b.count {
                let x = b[pos]
                if x == 0x5C { pos += 2; continue }
                if x == 0x28 { depth += 1 }
                if x == 0x29 { depth -= 1; if depth == 0 { pos += 1; return Token(kind: .string, start: start, end: pos) } }
                pos += 1
            }
            throw PDFError.malformed("string in content")
        case 0x3C:
            if pos + 1 < b.count, b[pos + 1] == 0x3C { pos += 2; return Token(kind: .dictOpen, start: start, end: pos) }
            guard let e = b.find([0x3E], from: pos) else { throw PDFError.malformed("hex string in content") }
            pos = e + 1
            return Token(kind: .string, start: start, end: pos)
        case 0x3E:
            if pos + 1 < b.count, b[pos + 1] == 0x3E { pos += 2; return Token(kind: .dictClose, start: start, end: pos) }
            throw PDFError.malformed("stray >")
        case 0x5B: pos += 1; return Token(kind: .arrayOpen, start: start, end: pos)
        case 0x5D: pos += 1; return Token(kind: .arrayClose, start: start, end: pos)
        case 0x7B, 0x7D: pos += 1; return Token(kind: .other, start: start, end: pos)
        case 0x29: throw PDFError.malformed("stray )")
        case 0x2F:
            pos += 1
            while pos < b.count, PDFParser.isRegular(b[pos]) { pos += 1 }
            return Token(kind: .name, start: start, end: pos)
        default:
            while pos < b.count, PDFParser.isRegular(b[pos]) { pos += 1 }
            let t = b[start..<pos]
            if let (v, _) = PDFParser.parseNumber(t) { return Token(kind: .number, start: start, end: pos, number: v) }
            if t.count == 2, t[start] == UInt8(ascii: "B"), t[start + 1] == UInt8(ascii: "I") {
                try skipInlineImage()
                return Token(kind: .inlineImage, start: start, end: pos)
            }
            return Token(kind: .op, start: start, end: pos)
        }
    }

    /// Moves past "... ID <binary> EI".
    private mutating func skipInlineImage() throws {
        // Find the ID operator.
        while true {
            guard let t = try next() else { throw PDFError.malformed("inline image") }
            if t.kind == .op, t.end - t.start == 2, b[t.start] == UInt8(ascii: "I"), b[t.start + 1] == UInt8(ascii: "D") { break }
        }
        pos += 1 // single whitespace after ID
        var i = pos
        while i + 1 < b.count {
            if b[i] == UInt8(ascii: "E"), b[i + 1] == UInt8(ascii: "I"),
               i > 0, PDFParser.isWhite(b[i - 1]),
               i + 2 >= b.count || PDFParser.isWhite(b[i + 2]) || PDFParser.isDelimiter(b[i + 2]) {
                pos = i + 2
                return
            }
            i += 1
        }
        throw PDFError.malformed("inline image end")
    }

    func text(_ t: Token) -> String { String(decoding: b[t.start..<t.end], as: UTF8.self) }

    func isOp(_ t: Token, _ s: StaticString) -> Bool {
        let n = s.utf8CodeUnitCount
        guard t.kind == .op, t.end - t.start == n else { return false }
        let p = s.utf8Start
        for i in 0..<n where b[t.start + i] != p[i] { return false }
        return true
    }
}

/// Finds how large every image is drawn (in points), following Form XObjects.
final class PlacementScanner {
    let reader: PDFReader
    private(set) var imageSizes: [Int: (w: Double, h: Double)] = [:]
    /// Largest scale each Form XObject is drawn at (its own space to page points).
    private(set) var formScales: [Int: Double] = [:]
    /// Forms that are scanned and therefore safe to rewrite.
    private var visiting = Set<Int>()

    init(reader: PDFReader) { self.reader = reader }

    func scan(_ content: [UInt8], resources: PDFDict?, ctm start: Matrix, depth: Int = 0) {
        var lx = ContentLexer(content)
        var ctm = start
        var stack: [Matrix] = []
        var nums: [Double] = []
        var lastName: String?
        var arrayDepth = 0
        while let t = try? lx.next() {
            switch t.kind {
            case .number: if arrayDepth == 0 { nums.append(t.number) }
            case .name: if arrayDepth == 0 { lastName = String(decoding: content[(t.start + 1)..<t.end], as: UTF8.self) }
            case .arrayOpen: arrayDepth += 1
            case .arrayClose: arrayDepth = max(0, arrayDepth - 1)
            case .op:
                if lx.isOp(t, "q") {
                    stack.append(ctm)
                } else if lx.isOp(t, "Q") {
                    if let m = stack.popLast() { ctm = m }
                } else if lx.isOp(t, "cm"), nums.count >= 6 {
                    ctm = Matrix(Array(nums.suffix(6))).concat(ctm)
                } else if lx.isOp(t, "Do"), let name = lastName {
                    draw(name, resources: resources, ctm: ctm, depth: depth)
                }
                nums.removeAll(keepingCapacity: true)
                lastName = nil
                arrayDepth = 0
            default: break
            }
        }
    }

    private func draw(_ name: String, resources: PDFDict?, ctm: Matrix, depth: Int) {
        guard let xobjects = reader.dict(resources?["XObject"]),
              let num = xobjects[name]?.refNumber,
              let obj = reader.object(num), let d = obj.value.dict else { return }
        switch reader.resolve(d["Subtype"])?.nameValue {
        case "Image":
            let w = hypot(ctm.a, ctm.b), h = hypot(ctm.c, ctm.d)
            let old = imageSizes[num] ?? (0, 0)
            imageSizes[num] = (max(old.w, w), max(old.h, h))
        case "Form":
            guard depth < 16, !visiting.contains(num), let raw = obj.stream,
                  let data = Filters.decode(d, raw, reader: reader) else { return }
            let m = reader.resolve(d["Matrix"])?.array.map { Matrix($0.compactMap { reader.resolve($0)?.doubleValue }) } ?? .identity
            let formCTM = m.concat(ctm)
            formScales[num] = max(formScales[num] ?? 0, formCTM.scale)
            visiting.insert(num)
            scan([UInt8](data), resources: reader.dict(d["Resources"]) ?? resources, ctm: formCTM, depth: depth + 1)
            visiting.remove(num)
        default: break
        }
    }
}

/// Rewrites path coordinates with fewer decimals. Figma writes six decimals for every point of
/// every outlined letter; two are plenty at page scale (0.005 pt), and the precision grows
/// automatically wherever the current transform enlarges the drawing.
enum PathRounder {
    struct State {
        var ctm = Matrix.identity
        var stack: [Matrix] = []
        var inText = false
    }

    private static let pow10: [Double] = [1, 10, 100, 1000, 10000, 100000, 1000000]

    /// Returns nil when the stream can't be tokenized (it is then kept unchanged).
    static func round(_ b: [UInt8], baseScale: Double, state: inout State) -> [UInt8]? {
        var lx = ContentLexer(b)
        var out = [UInt8]()
        out.reserveCapacity(b.count / 2)
        var pending: [ContentLexer.Token] = []

        func emitRaw(_ t: ContentLexer.Token) {
            if !out.isEmpty, out.last != 10 { out.append(32) }
            out.append(contentsOf: b[t.start..<t.end])
        }

        do {
            while let t = try lx.next() {
                if t.kind == .inlineImage {
                    for p in pending { emitRaw(p) }
                    pending.removeAll(keepingCapacity: true)
                    emitRaw(t)
                    out.append(10)
                    continue
                }
                guard t.kind == .op else { pending.append(t); continue }

                let arity: Int
                if lx.isOp(t, "c") { arity = 6 }
                else if lx.isOp(t, "l") || lx.isOp(t, "m") { arity = 2 }
                else if lx.isOp(t, "v") || lx.isOp(t, "y") || lx.isOp(t, "re") { arity = 4 }
                else { arity = 0 }

                if arity > 0, !state.inText, pending.count == arity, pending.allSatisfy({ $0.kind == .number }) {
                    let s = max(baseScale * state.ctm.scale, 1e-6)
                    let digits = min(6, max(2, Int((log10(s * 100)).rounded(.up))))
                    for p in pending {
                        if !out.isEmpty, out.last != 10 { out.append(32) }
                        appendNumber(p.number, digits: digits, to: &out)
                    }
                } else {
                    if lx.isOp(t, "q") { state.stack.append(state.ctm) }
                    else if lx.isOp(t, "Q") { if let m = state.stack.popLast() { state.ctm = m } }
                    else if lx.isOp(t, "cm"), pending.count >= 6, pending.suffix(6).allSatisfy({ $0.kind == .number }) {
                        state.ctm = Matrix(pending.suffix(6).map { $0.number }).concat(state.ctm)
                    }
                    else if lx.isOp(t, "BT") { state.inText = true }
                    else if lx.isOp(t, "ET") { state.inText = false }
                    for p in pending { emitRaw(p) }
                }
                pending.removeAll(keepingCapacity: true)
                emitRaw(t)
                out.append(10)
            }
        } catch {
            return nil
        }
        for p in pending { emitRaw(p) }
        return out
    }

    static func appendNumber(_ v: Double, digits: Int, to out: inout [UInt8]) {
        let scaled = (v * pow10[digits]).rounded()
        guard scaled.isFinite, abs(scaled) < 9e15 else {
            out.append(contentsOf: Array(PDFSerializer.formatReal(v).utf8))
            return
        }
        var n = Int64(scaled)
        if n == 0 { out.append(0x30); return }
        if n < 0 { out.append(0x2D); n = -n }
        var d = digits
        // Drop trailing zeros of the fraction.
        while d > 0, n % 10 == 0 { n /= 10; d -= 1 }
        var digitsText = Array(String(n).utf8)
        if d > 0 {
            if digitsText.count <= d {
                digitsText = [UInt8](repeating: 0x30, count: d - digitsText.count + 1) + digitsText
            }
            digitsText.insert(0x2E, at: digitsText.count - d)
        }
        out.append(contentsOf: digitsText)
    }
}
