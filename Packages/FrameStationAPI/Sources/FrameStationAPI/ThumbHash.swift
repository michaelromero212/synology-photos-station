import Foundation

/// ThumbHash — a ~25-byte perceptual placeholder for an image.
///
/// Lives in the shared package on purpose: the **server encodes** at ingest and
/// the **clients decode** while scrolling, so both sides run this exact code.
/// That makes the representation self-consistent by construction rather than by
/// two implementations agreeing.
///
/// Why it matters here: the timeline manifest carries one of these per asset
/// (~2.5 MB across a 100k library), so a grid cell paints a recognisable blur
/// immediately with **zero** network requests, and the real thumbnail swaps in
/// when it lands. See ARCHITECTURE.md §6.
///
/// Format follows Evan Wallace's ThumbHash: a small DCT over luminance, two
/// chroma channels, and optionally alpha, quantised to 4–6 bits per term.
public enum ThumbHash {

    // MARK: - Encoding

    /// - Parameters:
    ///   - width: source width, **must be ≤ 100**
    ///   - height: source height, **must be ≤ 100**
    ///   - rgba: row-major RGBA8, `width * height * 4` bytes
    public static func encode(width: Int, height: Int, rgba: [UInt8]) -> [UInt8] {
        precondition(width > 0 && height > 0, "ThumbHash needs a non-empty image")
        precondition(width <= 100 && height <= 100, "ThumbHash input must be ≤ 100×100")
        precondition(rgba.count == width * height * 4, "rgba must be width*height*4 bytes")

        let pixelCount = width * height

        // Alpha-weighted average colour.
        var avgR = 0.0, avgG = 0.0, avgB = 0.0, avgA = 0.0
        for i in 0..<pixelCount {
            let j = i * 4
            let alpha = Double(rgba[j + 3]) / 255
            avgR += alpha / 255 * Double(rgba[j])
            avgG += alpha / 255 * Double(rgba[j + 1])
            avgB += alpha / 255 * Double(rgba[j + 2])
            avgA += alpha
        }
        if avgA > 0 {
            avgR /= avgA
            avgG /= avgA
            avgB /= avgA
        }

        let hasAlpha = avgA < Double(pixelCount)
        let luminanceLimit = hasAlpha ? 5.0 : 7.0
        let maxDimension = Double(max(width, height))
        let lx = max(1, Int((luminanceLimit * Double(width) / maxDimension).rounded()))
        let ly = max(1, Int((luminanceLimit * Double(height) / maxDimension).rounded()))

        var l = [Double](repeating: 0, count: pixelCount)
        var p = [Double](repeating: 0, count: pixelCount)
        var q = [Double](repeating: 0, count: pixelCount)
        var a = [Double](repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            let j = i * 4
            let alpha = Double(rgba[j + 3]) / 255
            let r = avgR * (1 - alpha) + alpha / 255 * Double(rgba[j])
            let g = avgG * (1 - alpha) + alpha / 255 * Double(rgba[j + 1])
            let b = avgB * (1 - alpha) + alpha / 255 * Double(rgba[j + 2])
            l[i] = (r + g + b) / 3
            p[i] = (r + g) / 2 - b
            q[i] = r - g
            a[i] = alpha
        }

        func encodeChannel(
            _ channel: [Double], _ nx: Int, _ ny: Int
        ) -> (dc: Double, ac: [Double], scale: Double) {
            var dc = 0.0
            var ac: [Double] = []
            var scale = 0.0
            var fx = [Double](repeating: 0, count: width)

            for cy in 0..<ny {
                var cx = 0
                while cx * ny < nx * (ny - cy) {
                    var f = 0.0
                    for x in 0..<width {
                        fx[x] = cos(.pi / Double(width) * Double(cx) * (Double(x) + 0.5))
                    }
                    for y in 0..<height {
                        let fy = cos(.pi / Double(height) * Double(cy) * (Double(y) + 0.5))
                        for x in 0..<width {
                            f += channel[x + y * width] * fx[x] * fy
                        }
                    }
                    f /= Double(pixelCount)
                    if cx > 0 || cy > 0 {
                        ac.append(f)
                        scale = max(scale, abs(f))
                    } else {
                        dc = f
                    }
                    cx += 1
                }
            }

            if scale > 0 {
                for i in ac.indices { ac[i] = 0.5 + 0.5 / scale * ac[i] }
            }
            return (dc, ac, scale)
        }

        let lChannel = encodeChannel(l, max(3, lx), max(3, ly))
        let pChannel = encodeChannel(p, 3, 3)
        let qChannel = encodeChannel(q, 3, 3)
        let aChannel = hasAlpha ? encodeChannel(a, 5, 5) : nil

        let isLandscape = width > height
        let header24 = UInt32((63 * lChannel.dc).rounded())
            | (UInt32((31.5 + 31.5 * pChannel.dc).rounded()) << 6)
            | (UInt32((31.5 + 31.5 * qChannel.dc).rounded()) << 12)
            | (UInt32((31 * lChannel.scale).rounded()) << 18)
            | (hasAlpha ? UInt32(1) << 23 : 0)

        let header16 = UInt16(isLandscape ? ly : lx)
            | (UInt16((63 * pChannel.scale).rounded()) << 3)
            | (UInt16((63 * qChannel.scale).rounded()) << 9)
            | (isLandscape ? UInt16(1) << 15 : 0)

        var hash: [UInt8] = [
            UInt8(header24 & 255),
            UInt8((header24 >> 8) & 255),
            UInt8(header24 >> 16),
            UInt8(header16 & 255),
            UInt8(header16 >> 8),
        ]

        if let aChannel {
            hash.append(
                UInt8((15 * aChannel.dc).rounded()) | (UInt8((15 * aChannel.scale).rounded()) << 4)
            )
        }

        let acStart = hasAlpha ? 6 : 5
        var acIndex = 0
        var acChannels = [lChannel.ac, pChannel.ac, qChannel.ac]
        if let aChannel { acChannels.append(aChannel.ac) }

        for channel in acChannels {
            for f in channel {
                let byteIndex = acStart + (acIndex >> 1)
                while hash.count <= byteIndex { hash.append(0) }
                let nibble = UInt8(max(0, min(15, (15 * f).rounded())))
                hash[byteIndex] |= nibble << ((acIndex & 1) << 2)
                acIndex += 1
            }
        }

        return hash
    }

    // MARK: - Decoding

    public struct Decoded: Equatable {
        public let width: Int
        public let height: Int
        /// Row-major RGBA8.
        public let rgba: [UInt8]
    }

    /// Renders the hash back to a small RGBA image for use as a placeholder.
    public static func decode(_ hash: [UInt8], maxDimension: Int = 32) -> Decoded? {
        guard hash.count >= 5 else { return nil }

        let header24 = UInt32(hash[0]) | (UInt32(hash[1]) << 8) | (UInt32(hash[2]) << 16)
        let header16 = UInt32(hash[3]) | (UInt32(hash[4]) << 8)

        let lDC = Double(header24 & 63) / 63
        let pDC = Double((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Double((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Double((header24 >> 18) & 31) / 31
        let hasAlpha = (header24 >> 23) != 0
        let pScale = Double((header16 >> 3) & 63) / 63
        let qScale = Double((header16 >> 9) & 63) / 63
        let isLandscape = (header16 >> 15) != 0

        let luminanceCount = Int(header16 & 7)
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : luminanceCount)
        let ly = max(3, isLandscape ? luminanceCount : (hasAlpha ? 5 : 7))

        guard hash.count > (hasAlpha ? 5 : 4) else { return nil }
        let aDC = hasAlpha ? Double(hash[5] & 15) / 15 : 1.0
        let aScale = hasAlpha ? Double(hash[5] >> 4) / 15 : 0.0

        var acIndex = 0
        let acStart = hasAlpha ? 6 : 5

        func decodeChannel(_ nx: Int, _ ny: Int, _ scale: Double) -> [Double] {
            var ac: [Double] = []
            for cy in 0..<ny {
                var cx = 0
                while cx * ny < nx * (ny - cy) {
                    if cx > 0 || cy > 0 {
                        let byteIndex = acStart + (acIndex >> 1)
                        let nibble: UInt8 = byteIndex < hash.count
                            ? ((hash[byteIndex] >> ((acIndex & 1) << 2)) & 15)
                            : 7
                        ac.append((Double(nibble) / 7.5 - 1) * scale)
                        acIndex += 1
                    }
                    cx += 1
                }
            }
            return ac
        }

        let lAC = decodeChannel(lx, ly, lScale)
        let pAC = decodeChannel(3, 3, pScale * 1.25)
        let qAC = decodeChannel(3, 3, qScale * 1.25)
        let aAC = hasAlpha ? decodeChannel(5, 5, aScale) : []

        let ratio = isLandscape ? Double(lx) / Double(ly) : Double(lx) / Double(ly)
        let w = isLandscape ? maxDimension : max(1, Int((Double(maxDimension) * ratio).rounded()))
        let h = isLandscape ? max(1, Int((Double(maxDimension) / ratio).rounded())) : maxDimension

        var rgba = [UInt8](repeating: 0, count: w * h * 4)

        for y in 0..<h {
            for x in 0..<w {
                var l = lDC, p = pDC, q = qDC, alpha = aDC

                func accumulate(
                    _ ac: [Double], _ nx: Int, _ ny: Int, _ target: inout Double
                ) {
                    var index = 0
                    for cy in 0..<ny {
                        let fy = cos(.pi / Double(h) * Double(cy) * (Double(y) + 0.5))
                        var cx = 0
                        while cx * ny < nx * (ny - cy) {
                            if cx > 0 || cy > 0 {
                                guard index < ac.count else { cx += 1; continue }
                                let fx = cos(.pi / Double(w) * Double(cx) * (Double(x) + 0.5))
                                target += ac[index] * fx * fy * 2
                                index += 1
                            }
                            cx += 1
                        }
                    }
                }

                accumulate(lAC, lx, ly, &l)
                accumulate(pAC, 3, 3, &p)
                accumulate(qAC, 3, 3, &q)
                if hasAlpha { accumulate(aAC, 5, 5, &alpha) }

                let b = l - 2.0 / 3.0 * p
                let r = (3 * l - b + q) / 2
                let g = r - q

                let offset = (x + y * w) * 4
                rgba[offset] = clamp8(r)
                rgba[offset + 1] = clamp8(g)
                rgba[offset + 2] = clamp8(b)
                rgba[offset + 3] = clamp8(alpha)
            }
        }

        return Decoded(width: w, height: h, rgba: rgba)
    }

    /// Average colour without rendering — enough for an instant single-colour
    /// fill before the blur is even computed.
    public static func averageRGBA(_ hash: [UInt8]) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard hash.count >= 5 else { return nil }
        let header = UInt32(hash[0]) | (UInt32(hash[1]) << 8) | (UInt32(hash[2]) << 16)
        let l = Double(header & 63) / 63
        let p = Double((header >> 6) & 63) / 31.5 - 1
        let q = Double((header >> 12) & 63) / 31.5 - 1
        let hasAlpha = (header >> 23) != 0
        let b = l - 2.0 / 3.0 * p
        let r = (3 * l - b + q) / 2
        let g = r - q
        let a = hasAlpha && hash.count > 5 ? Double(hash[5] & 15) / 15 : 1
        return (min(1, max(0, r)), min(1, max(0, g)), min(1, max(0, b)), a)
    }

    private static func clamp8(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }
}
