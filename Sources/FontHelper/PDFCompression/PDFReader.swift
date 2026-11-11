import Foundation

/// Reads the objects of a PDF file: classic and stream cross-reference tables, object streams,
/// and a full rescan of the file when the cross-reference data is broken.
final class PDFReader {
    enum Entry {
        case offset(Int)
        case compressed(stream: Int, index: Int)
    }

    let b: [UInt8]
    private(set) var entries: [Int: Entry] = [:]
    private(set) var trailer = PDFDict()
    private var cache: [Int: PDFObject] = [:]
    private var objectStreams: [Int: [Int: PDFValue]] = [:]
    private var loading: Set<Int> = []
    private var rescanned = false
    private var headerOffset = 0
    private var initializing = true

    var maxObjectNumber: Int { entries.keys.max() ?? 0 }

    init(data: Data) throws {
        b = [UInt8](data)
        guard let h = b.find(Array("%PDF-".utf8), to: min(b.count, 1024)) else { throw PDFError.notPDF }
        headerOffset = h
        do {
            try readCrossReferences()
        } catch {
            entries = [:]
            trailer = PDFDict()
        }
        if trailer["Root"] == nil || entries.isEmpty {
            rescan()
        }
        guard trailer["Root"] != nil else { throw PDFError.malformed("no document catalog") }
        initializing = false
    }

    // MARK: - Objects

    func object(_ num: Int) -> PDFObject? {
        if let o = cache[num] { return o }
        guard !loading.contains(num) else { return nil }
        loading.insert(num)
        defer { loading.remove(num) }
        var result = load(num)
        if result == nil, !rescanned, !initializing {
            rescan()
            result = load(num)
        }
        if let result { cache[num] = result }
        return result
    }

    /// Follows references until a direct value is reached.
    func resolve(_ v: PDFValue?) -> PDFValue? {
        var v = v
        var hops = 0
        while case .ref(let n, _)? = v, hops < 32 {
            v = object(n)?.value
            hops += 1
        }
        return v
    }

    func dict(_ v: PDFValue?) -> PDFDict? { resolve(v)?.dict }

    private func load(_ num: Int) -> PDFObject? {
        guard let e = entries[num] else { return nil }
        switch e {
        case .offset(let off):
            for base in Set([off, off + headerOffset]) where base >= 0 && base < b.count {
                if let (n, obj) = try? parseIndirect(at: base), n == num { return obj }
            }
            return nil
        case .compressed(let stm, _):
            if objectStreams[stm] == nil { objectStreams[stm] = parseObjectStream(stm) ?? [:] }
            if let v = objectStreams[stm]?[num] { return PDFObject(value: v, stream: nil) }
            return nil
        }
    }

    private func parseIndirect(at off: Int) throws -> (Int, PDFObject) {
        var p = PDFParser(b, at: off)
        guard let num = p.readInt(), let _ = p.readInt() else { throw PDFError.malformed("object header") }
        p.skipWhite()
        guard p.matches("obj") else { throw PDFError.malformed("object header") }
        p.pos += 3
        let value = try p.parseValue()
        p.skipWhite()
        guard case .dict(let d) = value, p.matches("stream") else { return (num, PDFObject(value: value, stream: nil)) }
        p.pos += 6
        if p.pos < b.count, b[p.pos] == 13 { p.pos += 1 }
        if p.pos < b.count, b[p.pos] == 10 { p.pos += 1 }
        let start = p.pos
        var end: Int?
        if let len = (d["Length"].flatMap { v -> Int? in
            if case .ref(let n, _) = v { return n == num ? nil : object(n)?.value.intValue }
            return v.intValue
        }), len >= 0, start + len <= b.count {
            var q = PDFParser(b, at: start + len)
            q.skipWhite()
            if q.matches("endstream") { end = start + len }
        }
        if end == nil {
            guard var e = b.find(Array("endstream".utf8), from: start) else { throw PDFError.malformed("stream end") }
            if e > start, b[e - 1] == 10 { e -= 1 }
            if e > start, b[e - 1] == 13 { e -= 1 }
            end = e
        }
        return (num, PDFObject(value: value, stream: Data(b[start..<end!])))
    }

    private func parseObjectStream(_ stm: Int) -> [Int: PDFValue]? {
        guard let obj = object(stm), case .dict(let d) = obj.value, let raw = obj.stream,
              let data = Filters.decode(d, raw, reader: self),
              let n = resolve(d["N"])?.intValue, let first = resolve(d["First"])?.intValue else { return nil }
        let bytes = [UInt8](data)
        var p = PDFParser(bytes)
        var pairs: [(Int, Int)] = []
        for _ in 0..<n {
            guard let num = p.readInt(), let off = p.readInt() else { break }
            pairs.append((num, off))
        }
        var out: [Int: PDFValue] = [:]
        for (num, off) in pairs {
            var q = PDFParser(bytes, at: first + off)
            if let v = try? q.parseValue() { out[num] = v }
        }
        return out
    }

    // MARK: - Cross-reference tables

    private func readCrossReferences() throws {
        let tail = max(0, b.count - 4096)
        guard let sx = b.findLast(Array("startxref".utf8), from: tail) else { throw PDFError.malformed("startxref") }
        var p = PDFParser(b, at: sx + 9)
        guard var next = p.readInt() else { throw PDFError.malformed("startxref") }
        var visited = Set<Int>()
        while next >= 0, !visited.contains(next) {
            visited.insert(next)
            var off = next
            var q = PDFParser(b, at: off)
            q.skipWhite()
            if !q.matches("xref"), headerOffset > 0 { off += headerOffset }
            let t = try readSection(at: off)
            for k in ["Root", "Info", "ID", "Encrypt"] where trailer[k] == nil {
                if let v = t[k] { trailer[k] = v }
            }
            if let x = t["XRefStm"]?.intValue, !visited.contains(x) {
                visited.insert(x)
                _ = try? readSection(at: x + (headerOffset > 0 ? headerOffset : 0))
            }
            guard let prev = t["Prev"]?.intValue else { break }
            next = prev
        }
    }

    private func readSection(at off: Int) throws -> PDFDict {
        var p = PDFParser(b, at: off)
        p.skipWhite()
        if p.matches("xref") {
            p.pos += 4
            while true {
                p.skipWhite()
                if p.matches("trailer") {
                    p.pos += 7
                    guard case .dict(let d) = try p.parseValue() else { throw PDFError.malformed("trailer") }
                    return d
                }
                guard let start = p.readInt(), let count = p.readInt(), count >= 0 else {
                    throw PDFError.malformed("xref table")
                }
                for i in 0..<count {
                    guard let o = p.readInt(), p.readInt() != nil else { throw PDFError.malformed("xref entry") }
                    p.skipWhite()
                    let kind = p.regularToken()
                    if kind.first == UInt8(ascii: "n"), o > 0, entries[start + i] == nil {
                        entries[start + i] = .offset(o)
                    }
                }
            }
        }
        // Cross-reference stream.
        let (_, obj) = try parseIndirect(at: off)
        guard case .dict(let d) = obj.value, d["Type"]?.nameValue == "XRef", let raw = obj.stream,
              let data = Filters.decode(d, raw, reader: self),
              let w = d["W"]?.array?.compactMap({ $0.intValue }), w.count == 3 else {
            throw PDFError.malformed("xref stream")
        }
        let size = d["Size"]?.intValue ?? 0
        let index = d["Index"]?.array?.compactMap({ $0.intValue }) ?? [0, size]
        let bytes = [UInt8](data)
        let rowLen = w[0] + w[1] + w[2]
        guard rowLen > 0 else { throw PDFError.malformed("xref stream") }
        var pos = 0
        func field(_ width: Int) -> Int {
            var v = 0
            for _ in 0..<width {
                v = v << 8 | Int(pos < bytes.count ? bytes[pos] : 0)
                pos += 1
            }
            return v
        }
        var k = 0
        while k + 1 < index.count {
            let start = index[k], count = index[k + 1]
            for i in 0..<count {
                guard pos + rowLen <= bytes.count else { break }
                let type = w[0] == 0 ? 1 : field(w[0])
                let f2 = field(w[1])
                let f3 = field(w[2])
                let num = start + i
                guard entries[num] == nil else { continue }
                if type == 1, f2 > 0 { entries[num] = .offset(f2) }
                if type == 2 { entries[num] = .compressed(stream: f2, index: f3) }
            }
            k += 2
        }
        return d
    }

    /// Rebuilds the object table by scanning the whole file for "n g obj".
    private func rescan() {
        rescanned = true
        cache = [:]
        objectStreams = [:]
        let obj = Array("obj".utf8)
        var i = 0
        var found: [Int: Int] = [:]
        while let j = b.find(obj, from: i) {
            i = j + 3
            if j + 3 < b.count, PDFParser.isRegular(b[j + 3]) { continue }
            var k = j - 1
            guard k > 0, PDFParser.isWhite(b[k]) else { continue }
            while k > 0, PDFParser.isWhite(b[k]) { k -= 1 }
            var genStart = k
            while genStart > 0, b[genStart - 1] >= 0x30, b[genStart - 1] <= 0x39 { genStart -= 1 }
            guard genStart <= k, b[k] >= 0x30, b[k] <= 0x39 else { continue }
            var m = genStart - 1
            guard m > 0, PDFParser.isWhite(b[m]) else { continue }
            while m > 0, PDFParser.isWhite(b[m]) { m -= 1 }
            var numStart = m
            while numStart > 0, b[numStart - 1] >= 0x30, b[numStart - 1] <= 0x39 { numStart -= 1 }
            guard b[m] >= 0x30, b[m] <= 0x39 else { continue }
            if numStart > 0, PDFParser.isRegular(b[numStart - 1]) { continue }
            if let n = PDFParser.parseInt(b[numStart...m]) { found[n] = numStart }
        }
        // Scanned offsets are absolute; load() tries both absolute and header-relative offsets.
        for (n, off) in found { entries[n] = .offset(off) }

        if trailer["Root"] == nil {
            if let t = b.findLast(Array("trailer".utf8)) {
                var p = PDFParser(b, at: t + 7)
                if case .dict(let d)? = try? p.parseValue() {
                    for k in ["Root", "Info", "ID", "Encrypt"] where trailer[k] == nil { if let v = d[k] { trailer[k] = v } }
                }
            }
        }
        // Register objects stored inside object streams, and find the catalog if still missing.
        for (n, _) in found.sorted(by: { $0.key < $1.key }) {
            guard let o = load(n) else { continue }
            cache[n] = o
            guard case .dict(let d) = o.value else { continue }
            if d["Type"]?.nameValue == "ObjStm", let vals = parseObjectStream(n) {
                for (m, _) in vals where found[m] == nil { entries[m] = .compressed(stream: n, index: 0) }
                objectStreams[n] = vals
            }
            if trailer["Root"] == nil, d["Type"]?.nameValue == "XRef", let r = d["Root"] {
                trailer["Root"] = r
                if let i = d["Info"] { trailer["Info"] = i }
            }
        }
        if trailer["Root"] == nil {
            for (n, _) in found where load(n)?.value.dict?["Type"]?.nameValue == "Catalog" {
                trailer["Root"] = .ref(n, 0)
                break
            }
        }
    }
}

enum Filters {
    /// Decodes a stream's data. Returns nil for filters this app doesn't decode (the stream is then left as is).
    static func decode(_ dict: PDFDict, _ raw: Data, reader: PDFReader) -> Data? {
        let filters: [String]
        switch reader.resolve(dict["Filter"]) {
        case nil, .null?: return raw
        case .name(let n)?: filters = [n]
        case .array(let a)?: filters = a.compactMap { reader.resolve($0)?.nameValue }
        default: return nil
        }
        if filters.isEmpty { return raw }
        guard filters.count == 1, filters[0] == "FlateDecode" || filters[0] == "Fl" else { return nil }
        guard var out = Flate.inflate(raw) else { return nil }
        var parms = reader.resolve(dict["DecodeParms"]) ?? reader.resolve(dict["DP"])
        if case .array(let a)? = parms { parms = a.first.flatMap { reader.resolve($0) } }
        if let p = parms?.dict, let predictor = reader.resolve(p["Predictor"])?.intValue, predictor > 1 {
            guard predictor >= 10 else { return nil }
            let columns = reader.resolve(p["Columns"])?.intValue ?? 1
            let colors = reader.resolve(p["Colors"])?.intValue ?? 1
            let bpc = reader.resolve(p["BitsPerComponent"])?.intValue ?? 8
            guard let u = Flate.unpredictPNG(out, columns: columns, colors: colors, bitsPerComponent: bpc) else { return nil }
            out = u
        }
        return out
    }

    /// True when the stream uses no filter, or only FlateDecode without a predictor.
    static func isPlainOrFlate(_ dict: PDFDict, reader: PDFReader) -> Bool {
        let f = reader.resolve(dict["Filter"])
        var parms = reader.resolve(dict["DecodeParms"])
        if case .array(let a)? = parms { parms = a.first.flatMap { reader.resolve($0) } }
        if let p = parms?.dict, (reader.resolve(p["Predictor"])?.intValue ?? 1) > 1 { return false }
        switch f {
        case nil, .null?: return true
        case .name(let n)?: return n == "FlateDecode" || n == "Fl"
        case .array(let a)?: return a.isEmpty || (a.count == 1 && ["FlateDecode", "Fl"].contains(reader.resolve(a[0])?.nameValue ?? ""))
        default: return false
        }
    }
}
