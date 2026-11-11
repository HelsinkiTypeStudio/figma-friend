import CoreGraphics
import Foundation

/// One fixed setting: sharp even when zoomed in.
enum CompressionSettings {
    /// Image sharpness, in pixels per inch at the size the image is shown on the page.
    static let ppi = 220.0
    /// ImageIO's quality scale runs much higher than libjpeg's (0.75 here is about libjpeg 93).
    /// 0.56 matches libjpeg quality 85.
    static let jpegQuality = 0.56
}

struct CompressionResult {
    let inputBytes: Int
    let outputBytes: Int
    let output: URL
    let imagesChanged: Int
}

final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

enum Compressor {
    struct Cancelled: Error {}

    static func outputURL(for input: URL) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        return input.deletingLastPathComponent().appendingPathComponent("\(base)-compressed.pdf")
    }

    static func compress(input: URL, output: URL, flag: CancelFlag? = nil,
                         progress: (Double, String) -> Void = { _, _ in }) throws -> CompressionResult {
        let original = try Data(contentsOf: input, options: .mappedIfSafe)
        progress(0.02, "Reading…")
        let (data, images) = try compress(data: original, flag: flag, progress: progress)
        guard Double(data.count) < Double(original.count) * 0.98 else { throw PDFError.notSmaller }
        try data.write(to: output, options: .atomic)
        return CompressionResult(inputBytes: original.count, outputBytes: data.count, output: output, imagesChanged: images)
    }

    static func compress(data original: Data, flag: CancelFlag? = nil,
                         progress: (Double, String) -> Void = { _, _ in }) throws -> (Data, Int) {
        let reader = try PDFReader(data: original)
        guard reader.trailer["Encrypt"] == nil else { throw PDFError.encrypted }
        guard !isSigned(reader) else { throw PDFError.signed }
        func check() throws { if flag?.isSet == true { throw Cancelled() } }

        var overrides: [Int: PDFObject] = [:]
        var nextNumber = reader.maxObjectNumber + 1

        // Pages, with inherited resources.
        let pages = collectPages(reader)
        guard !pages.isEmpty else { throw PDFError.noPages }

        // 1. Where is every image drawn, and how large?
        progress(0.05, "Measuring images…")
        let scanner = PlacementScanner(reader: reader)
        var contentStreams: [(page: Int, streams: [Int])] = []
        for (i, page) in pages.enumerated() {
            try check()
            let streams = contentRefs(page.dict, reader)
            contentStreams.append((page.number, streams))
            var bytes = [UInt8]()
            for s in streams {
                guard let o = reader.object(s), let d = o.value.dict, let raw = o.stream,
                      let dec = Filters.decode(d, raw, reader: reader) else { continue }
                bytes += [UInt8](dec)
                bytes.append(10)
            }
            let userUnit = reader.resolve(page.dict["UserUnit"])?.doubleValue ?? 1
            var start = Matrix.identity
            start.a = userUnit; start.d = userUnit
            scanner.scan(bytes, resources: page.resources, ctm: start)
            progress(0.05 + 0.1 * Double(i + 1) / Double(pages.count), "Measuring images…")
        }

        // 2. Recompress images (in parallel).
        var jobs: [ImageJob] = []
        for (num, size) in scanner.imageSizes {
            if let job = makeJob(num, size: size, reader: reader) { jobs.append(job) }
        }
        jobs.sort { $0.data.count > $1.data.count }
        try check()
        progress(0.15, jobs.isEmpty ? "Compressing…" : "Compressing images…")
        var results = [ImageResult?](repeating: nil, count: jobs.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            guard flag?.isSet != true else { return }
            let r = ImageRecompressor.process(jobs[i], ppi: CompressionSettings.ppi, quality: CompressionSettings.jpegQuality)
            lock.lock()
            results[i] = r
            done += 1
            let n = done
            lock.unlock()
            progress(0.15 + 0.55 * Double(n) / Double(jobs.count), "Compressing image \(n) of \(jobs.count)…")
        }
        try check()
        var imagesChanged = 0
        for r in results.compactMap({ $0 }) {
            guard let obj = reader.object(r.number), var d = obj.value.dict else { continue }
            var data = obj.stream
            if let img = r.image {
                d = img.dict
                data = img.data
                imagesChanged += 1
            }
            switch r.mask {
            case .keep: break
            case .remove: d["SMask"] = nil
            case .replace(let md, let mdata):
                overrides[nextNumber] = PDFObject(value: .dict(md), stream: mdata)
                d["SMask"] = .ref(nextNumber, 0)
                nextNumber += 1
            }
            overrides[r.number] = PDFObject(value: .dict(d), stream: data)
        }

        // 3. Shorter path coordinates in page contents and drawn forms.
        progress(0.72, "Tidying vector graphics…")
        var rounded = Set<Int>()
        for (k, entry) in contentStreams.enumerated() {
            try check()
            var state = PathRounder.State()
            for s in entry.streams where !rounded.contains(s) {
                rounded.insert(s)
                if let o = roundedStream(s, baseScale: 1, state: &state, reader: reader) { overrides[s] = o }
            }
            progress(0.72 + 0.1 * Double(k + 1) / Double(contentStreams.count), "Tidying vector graphics…")
        }
        for (num, scale) in scanner.formScales where !rounded.contains(num) && overrides[num] == nil {
            rounded.insert(num)
            var state = PathRounder.State()
            if let o = roundedStream(num, baseScale: scale, state: &state, reader: reader) { overrides[num] = o }
        }

        // 4. Drop page thumbnails and private editor data (Illustrator can store a whole .ai file here).
        for page in pages {
            guard overrides[page.number] == nil, let o = reader.object(page.number), var d = o.value.dict else { continue }
            if d["Thumb"] != nil || d["PieceInfo"] != nil {
                d["Thumb"] = nil
                d["PieceInfo"] = nil
                overrides[page.number] = PDFObject(value: .dict(d), stream: o.stream)
            }
        }
        if let root = reader.trailer["Root"]?.refNumber, let o = reader.object(root), var d = o.value.dict, d["PieceInfo"] != nil {
            d["PieceInfo"] = nil
            overrides[root] = PDFObject(value: .dict(d), stream: o.stream)
        }

        // 5. Write, recompressing every other stream losslessly at the highest level.
        try check()
        progress(0.84, "Saving…")
        let out = try write(reader: reader, overrides: overrides, flag: flag) { f in
            progress(0.84 + 0.14 * f, "Saving…")
        }

        // 6. Make sure the result opens and has every page.
        progress(0.99, "Checking…")
        let outData = Data(out)
        guard let provider = CGDataProvider(data: outData as CFData), let doc = CGPDFDocument(provider),
              doc.numberOfPages == pages.count else { throw PDFError.invalidOutput }
        if let inProvider = CGDataProvider(data: original as CFData), let inDoc = CGPDFDocument(inProvider),
           inDoc.numberOfPages != doc.numberOfPages { throw PDFError.invalidOutput }
        return (outData, imagesChanged)
    }

    // MARK: - Signatures

    /// True when the PDF carries a digital signature, which any rewrite would invalidate.
    static func isSigned(_ reader: PDFReader) -> Bool {
        guard let catalog = reader.dict(reader.trailer["Root"]) else { return false }
        if let perms = reader.dict(catalog["Perms"]), perms["DocMDP"] != nil { return true }
        guard let form = reader.dict(catalog["AcroForm"]) else { return false }
        if let flags = reader.resolve(form["SigFlags"])?.intValue, flags & 1 != 0 { return true }
        var seen = Set<Int>()
        func signedField(_ v: PDFValue, depth: Int) -> Bool {
            if let n = v.refNumber { guard seen.insert(n).inserted else { return false } }
            guard depth < 32, let d = reader.dict(v) else { return false }
            if reader.resolve(d["FT"])?.nameValue == "Sig", let value = reader.resolve(d["V"]), value.dict != nil { return true }
            return (reader.resolve(d["Kids"])?.array ?? []).contains { signedField($0, depth: depth + 1) }
        }
        return (reader.resolve(form["Fields"])?.array ?? []).contains { signedField($0, depth: 0) }
    }

    // MARK: - Pages

    struct Page {
        let number: Int
        let dict: PDFDict
        let resources: PDFDict?
    }

    static func collectPages(_ reader: PDFReader) -> [Page] {
        guard let catalog = reader.dict(reader.trailer["Root"]), let pagesRef = catalog["Pages"] else { return [] }
        var out: [Page] = []
        var seen = Set<Int>()
        func walk(_ v: PDFValue, inherited: PDFDict?, depth: Int) {
            guard depth < 64, let num = v.refNumber, !seen.contains(num),
                  let d = reader.object(num)?.value.dict else { return }
            seen.insert(num)
            let res = reader.dict(d["Resources"]) ?? inherited
            if let kids = reader.resolve(d["Kids"])?.array {
                for k in kids { walk(k, inherited: res, depth: depth + 1) }
            } else if reader.resolve(d["Type"])?.nameValue != "Pages" {
                out.append(Page(number: num, dict: d, resources: res))
            }
        }
        walk(pagesRef, inherited: nil, depth: 0)
        return out
    }

    static func contentRefs(_ page: PDFDict, _ reader: PDFReader) -> [Int] {
        switch page["Contents"] {
        case .ref(let n, _)?:
            if case .array(let a)? = reader.object(n)?.value { return a.compactMap { $0.refNumber } }
            return [n]
        case .array(let a)?: return a.compactMap { $0.refNumber }
        default: return []
        }
    }

    // MARK: - Images

    private static func makeJob(_ num: Int, size: (w: Double, h: Double), reader: PDFReader) -> ImageJob? {
        guard let obj = reader.object(num), let d = obj.value.dict, let data = obj.stream else { return nil }
        if reader.resolve(d["ImageMask"])?.boolValue == true { return nil }
        if d["Decode"] != nil || d["SMaskInData"] != nil { return nil }
        if case .array? = reader.resolve(d["Mask"]) { return nil }
        guard let w = reader.resolve(d["Width"])?.intValue, let h = reader.resolve(d["Height"])?.intValue,
              let bpc = reader.resolve(d["BitsPerComponent"])?.intValue ?? (isDCT(d, reader) ? 8 : nil),
              let comps = components(reader.resolve(d["ColorSpace"]), reader),
              let enc = encoding(d, reader) else { return nil }
        // CMYK JPEGs are often stored inverted (Adobe); leave them exactly as they are.
        if case .dct = enc, comps == 4 { return nil }

        var mask: ImageJob.Mask?
        if let smaskNum = d["SMask"]?.refNumber {
            guard let mo = reader.object(smaskNum), let md = mo.value.dict, let mdata = mo.stream,
                  md["Matte"] == nil, md["Decode"] == nil,
                  let mw = reader.resolve(md["Width"])?.intValue, let mh = reader.resolve(md["Height"])?.intValue,
                  let menc = encoding(md, reader) else { return nil }
            let mbpc = reader.resolve(md["BitsPerComponent"])?.intValue ?? 8
            mask = ImageJob.Mask(width: mw, height: mh, bpc: mbpc, encoding: menc, data: mdata)
        }
        return ImageJob(number: num, dict: d, data: data, encoding: enc, width: w, height: h, bpc: bpc,
                        components: comps, shownWidth: size.w, shownHeight: size.h, mask: mask)
    }

    private static func isDCT(_ d: PDFDict, _ reader: PDFReader) -> Bool {
        if case .dct? = encoding(d, reader) { return true }
        return false
    }

    private static func encoding(_ d: PDFDict, _ reader: PDFReader) -> ImageJob.Encoding? {
        var filter = reader.resolve(d["Filter"])
        if case .array(let a)? = filter {
            guard a.count <= 1 else { return nil }
            filter = a.first.flatMap { reader.resolve($0) }
        }
        var parms = reader.resolve(d["DecodeParms"])
        if case .array(let a)? = parms { parms = a.first.flatMap { reader.resolve($0) } }
        if filter == nil { return .raw }
        if case .null? = filter { return .raw }
        switch filter?.nameValue {
        case "FlateDecode", "Fl":
            let p = parms?.dict
            func param(_ key: String, _ fallback: Int) -> Int {
                guard let p else { return fallback }
                return reader.resolve(p[key])?.intValue ?? fallback
            }
            return .flate(predictor: param("Predictor", 1), columns: param("Columns", 1),
                          colors: param("Colors", 1), bpc: param("BitsPerComponent", 8))
        case "DCTDecode", "DCT": return .dct
        default: return nil
        }
    }

    private static func components(_ cs: PDFValue?, _ reader: PDFReader) -> Int? {
        switch cs {
        case .name(let n)?:
            switch n {
            case "DeviceGray", "G", "CalGray": return 1
            case "DeviceRGB", "RGB", "CalRGB": return 3
            case "DeviceCMYK", "CMYK": return 4
            default: return nil
            }
        case .array(let a)?:
            guard let kind = a.first.flatMap({ reader.resolve($0)?.nameValue }) else { return nil }
            switch kind {
            case "ICCBased":
                guard a.count > 1, let s = reader.dict(a[1]), let n = reader.resolve(s["N"])?.intValue,
                      [1, 3, 4].contains(n) else { return nil }
                return n
            case "CalGray": return 1
            case "CalRGB": return 3
            default: return nil
            }
        default: return nil
        }
    }

    // MARK: - Content streams

    private static func roundedStream(_ num: Int, baseScale: Double, state: inout PathRounder.State,
                                      reader: PDFReader) -> PDFObject? {
        guard let o = reader.object(num), var d = o.value.dict, let raw = o.stream,
              Filters.isPlainOrFlate(d, reader: reader),
              let dec = Filters.decode(d, raw, reader: reader),
              let r = PathRounder.round([UInt8](dec), baseScale: baseScale, state: &state),
              r.count < dec.count,
              let z = Flate.deflate(r), z.count < raw.count else { return nil }
        d["Filter"] = .name("FlateDecode")
        d["DecodeParms"] = nil
        d["Length"] = nil
        return PDFObject(value: .dict(d), stream: z)
    }

    // MARK: - Writing

    private static func write(reader: PDFReader, overrides: [Int: PDFObject], flag: CancelFlag?,
                              progress: (Double) -> Void) throws -> [UInt8] {
        func object(_ n: Int) -> PDFObject? { overrides[n] ?? reader.object(n) }

        // Number the objects reachable from the catalog and the document info, in visiting order.
        var newNumber: [Int: Int] = [:]
        var order: [Int] = []
        var queue: [Int] = []
        func visit(_ v: PDFValue) {
            switch v {
            case .ref(let n, _):
                if newNumber[n] == nil, object(n) != nil {
                    order.append(n)
                    newNumber[n] = order.count
                    queue.append(n)
                }
            case .array(let a): a.forEach(visit)
            case .dict(let d): d.entries.forEach { visit($0.value) }
            default: break
            }
        }
        if let r = reader.trailer["Root"] { visit(r) }
        if let i = reader.trailer["Info"] { visit(i) }
        var qi = 0
        while qi < queue.count {
            if let o = object(queue[qi]) { visit(o.value) }
            qi += 1
        }

        // Lossless recompression of the remaining streams, in parallel.
        var recompressed = [Data?](repeating: nil, count: order.count)
        var candidates: [(index: Int, decoded: Data, rawCount: Int)] = []
        for (i, n) in order.enumerated() where overrides[n] == nil {
            guard let o = reader.object(n), let d = o.value.dict, let raw = o.stream, raw.count > 256,
                  reader.resolve(d["Type"])?.nameValue != "Metadata",
                  Filters.isPlainOrFlate(d, reader: reader),
                  let dec = Filters.decode(d, raw, reader: reader) else { continue }
            candidates.append((i, dec, raw.count))
        }
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { k in
            guard flag?.isSet != true else { return }
            let c = candidates[k]
            if let z = Flate.deflate(c.decoded), Double(z.count) < Double(c.rawCount) * 0.98 {
                lock.lock(); recompressed[c.index] = z; lock.unlock()
            }
        }
        if flag?.isSet == true { throw Cancelled() }

        var out = [UInt8]()
        out.reserveCapacity(reader.b.count / 4)
        out += Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 10]
        var offsets = [Int](repeating: 0, count: order.count + 1)
        let map: (Int) -> Int? = { newNumber[$0] }
        for (i, n) in order.enumerated() {
            guard let o = object(n) else { continue }
            offsets[i + 1] = out.count
            out += Array("\(i + 1) 0 obj\n".utf8)
            if var data = o.stream, case .dict(var d) = o.value {
                if let z = recompressed[i] {
                    data = z
                    d["Filter"] = .name("FlateDecode")
                    d["DecodeParms"] = nil
                }
                d["Length"] = .int(data.count)
                PDFSerializer.append(.dict(d), to: &out, refMap: map)
                out += Array("\nstream\n".utf8)
                out += data
                out += Array("\nendstream".utf8)
            } else {
                PDFSerializer.append(o.value, to: &out, refMap: map)
            }
            out += Array("\nendobj\n".utf8)
            if i % 200 == 0 { progress(Double(i) / Double(order.count)) }
        }

        let xref = out.count
        out += Array("xref\n0 \(order.count + 1)\n0000000000 65535 f \n".utf8)
        for i in 1...max(order.count, 1) where i <= order.count {
            out += Array(String(format: "%010d 00000 n \n", offsets[i]).utf8)
        }
        var trailer = PDFDict()
        trailer["Size"] = .int(order.count + 1)
        if let r = reader.trailer["Root"] { trailer["Root"] = r }
        if let i = reader.trailer["Info"], let n = i.refNumber, newNumber[n] != nil { trailer["Info"] = i }
        if let id = reader.resolve(reader.trailer["ID"]), case .array = id { trailer["ID"] = id }
        out += Array("trailer\n".utf8)
        PDFSerializer.append(.dict(trailer), to: &out, refMap: map)
        out += Array("\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return out
    }
}
