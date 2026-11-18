import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything needed to recompress one image, gathered up front so the work can run in parallel.
struct ImageJob {
    enum Encoding {
        case raw
        case flate(predictor: Int, columns: Int, colors: Int, bpc: Int)
        case dct
    }

    struct Mask {
        let width: Int
        let height: Int
        let bpc: Int
        let encoding: Encoding
        let data: Data
    }

    let number: Int
    let dict: PDFDict
    let data: Data
    let encoding: Encoding
    let width: Int
    let height: Int
    let bpc: Int
    let components: Int
    /// Largest size the image is drawn at, in points.
    let shownWidth: Double
    let shownHeight: Double
    let mask: Mask?
}

struct ImageResult {
    enum MaskChange {
        case keep
        case remove
        case replace(PDFDict, Data)
    }

    let number: Int
    /// nil keeps the image's own data and dictionary.
    let image: (dict: PDFDict, data: Data)?
    let mask: MaskChange
}

enum ImageRecompressor {
    static func process(_ job: ImageJob, ppi: Double, quality: Double) -> ImageResult? {
        let W = job.width, H = job.height
        guard W > 0, H > 0, W * H < 400_000_000 else { return nil }

        let wantW = job.shownWidth / 72 * ppi
        let wantH = job.shownHeight / 72 * ppi
        var scale = min(1, max(wantW / Double(W), wantH / Double(H)))
        if scale > 0.9 { scale = 1 }
        let downsample = scale < 1
        let tw = max(1, Int((Double(W) * scale).rounded()))
        let th = max(1, Int((Double(H) * scale).rounded()))

        // The soft mask (transparency) first: it decides whether the image can change at all.
        var maskChange = ImageResult.MaskChange.keep
        if let m = job.mask {
            if let gray = decodeGray(m) {
                if gray.pixels.allSatisfy({ $0 == 255 }) {
                    maskChange = .remove
                } else if downsample {
                    guard let img = makeImage(gray.pixels, width: gray.width, height: gray.height, components: 1, bpc: 8),
                          let small = render(img, width: tw, height: th, components: 1),
                          let z = Flate.deflate(small) else { return nil }
                    var d = PDFDict()
                    d["Type"] = .name("XObject")
                    d["Subtype"] = .name("Image")
                    d["Width"] = .int(tw)
                    d["Height"] = .int(th)
                    d["ColorSpace"] = .name("DeviceGray")
                    d["BitsPerComponent"] = .int(8)
                    d["Filter"] = .name("FlateDecode")
                    maskChange = .replace(d, z)
                }
            } else if downsample {
                return nil
            }
        }

        let isJPEG: Bool
        if case .dct = job.encoding { isJPEG = true } else { isJPEG = false }
        // Leave JPEGs alone unless they are much larger than they are shown.
        if isJPEG, !downsample {
            if case .keep = maskChange { return nil }
            return ImageResult(number: job.number, image: nil, mask: maskChange)
        }

        guard let source = decode(job), let pixels = render(source, width: tw, height: th, components: job.components) else {
            if case .keep = maskChange { return nil }
            return ImageResult(number: job.number, image: nil, mask: maskChange)
        }

        // Lossless candidate (keeps flat graphics crisp) and JPEG candidate (photos).
        let flate = Flate.deflate(pixels)
        var jpeg: Data?
        if job.components != 4,
           let img = makeImage(pixels, width: tw, height: th, components: job.components, bpc: 8) {
            jpeg = encodeJPEG(img, quality: quality)
        }

        var chosen: (data: Data, filter: String)?
        switch (flate, jpeg) {
        case let (f?, j?): chosen = Double(f.count) <= Double(j.count) * 1.5 ? (f, "FlateDecode") : (j, "DCTDecode")
        case let (f?, nil): chosen = (f, "FlateDecode")
        case let (nil, j?): chosen = (j, "DCTDecode")
        default: chosen = nil
        }
        guard let pick = chosen, Double(pick.data.count) < Double(job.data.count) * 0.9 else {
            if case .keep = maskChange { return nil }
            // Without the image shrinking, a resized mask would no longer match.
            if case .replace = maskChange { return nil }
            return ImageResult(number: job.number, image: nil, mask: maskChange)
        }

        var d = job.dict
        d["Width"] = .int(tw)
        d["Height"] = .int(th)
        d["BitsPerComponent"] = .int(8)
        d["Filter"] = .name(pick.filter)
        d["DecodeParms"] = nil
        d["DP"] = nil
        d["Length"] = nil
        return ImageResult(number: job.number, image: (d, pick.data), mask: maskChange)
    }

    // MARK: - Decoding

    private static func deviceSpace(_ components: Int) -> CGColorSpace? {
        switch components {
        case 1: return CGColorSpaceCreateDeviceGray()
        case 3: return CGColorSpaceCreateDeviceRGB()
        case 4: return CGColorSpaceCreateDeviceCMYK()
        default: return nil
        }
    }

    private static func inflate(_ data: Data, _ e: ImageJob.Encoding) -> Data? {
        switch e {
        case .raw: return data
        case .dct: return nil
        case .flate(let predictor, let columns, let colors, let bpc):
            guard let d = Flate.inflate(data) else { return nil }
            if predictor >= 10 { return Flate.unpredictPNG(d, columns: columns, colors: colors, bitsPerComponent: bpc) }
            return predictor > 1 ? nil : d
        }
    }

    /// The image as a CGImage in a device color space, so no color conversion ever happens:
    /// the PDF keeps its own color space and the numbers are carried over as they are.
    private static func decode(_ job: ImageJob) -> CGImage? {
        guard let space = deviceSpace(job.components) else { return nil }
        if case .dct = job.encoding {
            guard let src = CGImageSourceCreateWithData(job.data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  img.colorSpace?.numberOfComponents == job.components else { return nil }
            return img.copy(colorSpace: space)
        }
        guard job.bpc == 8 || job.bpc == 16, let bytes = inflate(job.data, job.encoding) else { return nil }
        let rowBytes = (job.width * job.components * job.bpc + 7) / 8
        guard bytes.count >= rowBytes * job.height else { return nil }
        let info: CGBitmapInfo = job.bpc == 16 ? [.byteOrder16Big] : []
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: job.width, height: job.height, bitsPerComponent: job.bpc,
                       bitsPerPixel: job.bpc * job.components, bytesPerRow: rowBytes, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info.rawValue | CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func decodeGray(_ m: ImageJob.Mask) -> (pixels: [UInt8], width: Int, height: Int)? {
        if case .dct = m.encoding {
            guard let src = CGImageSourceCreateWithData(m.data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  img.colorSpace?.numberOfComponents == 1,
                  let gray = img.copy(colorSpace: CGColorSpaceCreateDeviceGray()),
                  let px = render(gray, width: img.width, height: img.height, components: 1) else { return nil }
            return (px, img.width, img.height)
        }
        guard m.bpc == 8 || m.bpc == 16, let bytes = inflate(m.data, m.encoding) else { return nil }
        let n = m.width * m.height
        let step = m.bpc / 8
        guard n > 0, bytes.count >= n * step else { return nil }
        var px = [UInt8](repeating: 0, count: n)
        bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<n { px[i] = p[i * step] }
        }
        return (px, m.width, m.height)
    }

    // MARK: - Pixels

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int, components: Int, bpc: Int) -> CGImage? {
        guard let space = deviceSpace(components),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc * components,
                       bytesPerRow: width * components * bpc / 8, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Draws the image at the given size with high-quality resampling and returns tightly packed 8-bit samples.
    private static func render(_ img: CGImage, width: Int, height: Int, components: Int) -> [UInt8]? {
        guard let space = deviceSpace(components) else { return nil }
        let alpha: CGImageAlphaInfo = components == 3 ? .noneSkipLast : .none
        let ctxComponents = components == 3 ? 4 : components
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: alpha.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let src = base.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        var out = [UInt8](repeating: 0, count: width * height * components)
        out.withUnsafeMutableBufferPointer { dst in
            var o = 0
            for y in 0..<height {
                let row = src + y * rowBytes
                if ctxComponents == components {
                    for i in 0..<(width * components) { dst[o + i] = row[i] }
                    o += width * components
                } else {
                    for x in 0..<width {
                        dst[o] = row[x * 4]; dst[o + 1] = row[x * 4 + 1]; dst[o + 2] = row[x * 4 + 2]
                        o += 3
                    }
                }
            }
        }
        return out
    }

    private static func encodeJPEG(_ img: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
