import Foundation

/// A parsed PDF object. Names keep their raw spelling (without the slash) so they round-trip unchanged.
indirect enum PDFValue {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case name(String)
    case string(Data)
    case hexString(Data)
    case array([PDFValue])
    case dict(PDFDict)
    case ref(Int, Int)

    var dict: PDFDict? { if case .dict(let d) = self { return d }; return nil }
    var array: [PDFValue]? { if case .array(let a) = self { return a }; return nil }
    var nameValue: String? { if case .name(let n) = self { return n }; return nil }
    var refNumber: Int? { if case .ref(let n, _) = self { return n }; return nil }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .real(let r) where r.isFinite && abs(r) < 1e15: return Int(r)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .real(let r): return r
        default: return nil
        }
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
}

/// A dictionary that keeps its keys in file order.
struct PDFDict {
    private(set) var entries: [(key: String, value: PDFValue)] = []

    subscript(key: String) -> PDFValue? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            if let i = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[i].value = newValue } else { entries.remove(at: i) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }
}

/// An indirect object: its value, plus the raw (still encoded) bytes when it is a stream.
struct PDFObject {
    var value: PDFValue
    var stream: Data?
}

enum PDFError: LocalizedError {
    case notPDF
    case malformed(String)
    case encrypted
    case signed
    case noPages
    case notSmaller
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .notPDF: return "Not a PDF file."
        case .malformed(let what): return "The PDF is damaged (\(what))."
        case .encrypted: return "Password-protected PDFs can't be compressed."
        case .signed: return "This PDF is digitally signed. Compressing it would break the signature, so it was left as is."
        case .noPages: return "The PDF has no pages."
        case .notSmaller: return "Already compact. No smaller version was saved."
        case .invalidOutput: return "The compressed file didn't check out, so it wasn't saved."
        }
    }
}

// MARK: - Serialization

enum PDFSerializer {
    static func append(_ v: PDFValue, to out: inout [UInt8], refMap: (Int) -> Int?) {
        switch v {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .int(let i): out += Array(String(i).utf8)
        case .real(let r): out += Array(formatReal(r).utf8)
        case .name(let n):
            out.append(UInt8(ascii: "/"))
            out += Array(n.data(using: .isoLatin1) ?? Data(n.utf8))
        case .string(let d):
            out.append(UInt8(ascii: "("))
            for c in d {
                switch c {
                case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                    out.append(UInt8(ascii: "\\")); out.append(c)
                case 13: out += Array("\\r".utf8)
                default: out.append(c)
                }
            }
            out.append(UInt8(ascii: ")"))
        case .hexString(let d):
            out.append(UInt8(ascii: "<"))
            let hex = Array("0123456789ABCDEF".utf8)
            for c in d { out.append(hex[Int(c >> 4)]); out.append(hex[Int(c & 15)]) }
            out.append(UInt8(ascii: ">"))
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (i, x) in a.enumerated() {
                if i > 0 { out.append(32) }
                append(x, to: &out, refMap: refMap)
            }
            out.append(UInt8(ascii: "]"))
        case .dict(let d):
            out += Array("<<".utf8)
            for (k, x) in d.entries {
                out.append(UInt8(ascii: "/"))
                out += Array(k.data(using: .isoLatin1) ?? Data(k.utf8))
                out.append(32)
                append(x, to: &out, refMap: refMap)
            }
            out += Array(">>".utf8)
        case .ref(let n, _):
            if let m = refMap(n) { out += Array("\(m) 0 R".utf8) } else { out += Array("null".utf8) }
        }
    }

    static func formatReal(_ r: Double) -> String {
        guard r.isFinite else { return "0" }
        if r == r.rounded(), abs(r) < 1e15 { return String(Int(r)) }
        var s = String(format: "%.6f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "-0" { s = "0" }
        return s
    }
}
