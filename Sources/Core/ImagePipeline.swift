import Foundation
import CoreGraphics
import ImageIO
import Accelerate

enum ImagePipelineError: Error, LocalizedError {
    case invalidRawDimensions(bytes: Int, expectedW: Int, expectedH: Int)
    case jpegDecodeFailed
    case colorConversionFailed(Int)
    case cgImageCreationFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRawDimensions(let b, let w, let h):
            return "Unexpected raw byte size (\(b) bytes) for ~\(w)×\(h) scan."
        case .jpegDecodeFailed:
            return "Failed to decode JPEG data from scanner."
        case .colorConversionFailed(let code):
            return "ColorSync / vImage conversion failed (error \(code))."
        case .cgImageCreationFailed:
            return "Failed to create CGImage from pixel buffer."
        case .exportFailed(let msg):
            return "Failed to save image: \(msg)"
        }
    }
}

enum ImagePipeline {

    // MARK: - Decode eSCL Response -> Packed RawImageBuffer

    static func decodeToRawBuffer(download: ScanDownloadResult, request: ScanJobRequest) throws -> RawImageBuffer {
        let isJPEG = download.contentType.lowercased().contains("jpeg")
            || (download.data.count >= 3 && download.data[0] == 0xFF && download.data[1] == 0xD8 && download.data[2] == 0xFF)

        if isJPEG {
            return try decodeJPEG(data: download.data, colorMode: request.colorMode, dpi: request.resolution)
        } else {
            return try decodeRawOctetStream(download: download, request: request)
        }
    }

    private static func decodeJPEG(data: Data, colorMode: ScanColorMode, dpi: Int) throws -> RawImageBuffer {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImagePipelineError.jpegDecodeFailed
        }

        let w = cgImg.width
        let h = cgImg.height
        let bpp = colorMode.bytesPerPixel
        let cs: CGColorSpace = (colorMode == .rgb24)
            ? CGColorSpace(name: CGColorSpace.sRGB)!
            : CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!

        var fmt = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: UInt32(bpp * 8),
            colorSpace: Unmanaged.passUnretained(cs),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var vBuf = vImage_Buffer()
        let err = vImageBuffer_InitWithCGImage(&vBuf, &fmt, nil, cgImg, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError, let basePtr = vBuf.data else {
            throw ImagePipelineError.jpegDecodeFailed
        }
        defer { free(basePtr) }

        let packedRowBytes = w * bpp
        var packed = Data(count: packedRowBytes * h)
        packed.withUnsafeMutableBytes { dstRaw in
            let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
            let srcBase = basePtr.assumingMemoryBound(to: UInt8.self)
            if vBuf.rowBytes == packedRowBytes {
                memcpy(dst, srcBase, packedRowBytes * h)
            } else {
                for y in 0..<h {
                    memcpy(dst + y * packedRowBytes, srcBase + y * vBuf.rowBytes, packedRowBytes)
                }
            }
        }

        return RawImageBuffer(data: packed, width: w, height: h, bytesPerRow: packedRowBytes, colorMode: colorMode, dpi: dpi)
    }

    private static func decodeRawOctetStream(download: ScanDownloadResult, request: ScanJobRequest) throws -> RawImageBuffer {
        let data = download.data
        let bpp = request.colorMode.bytesPerPixel
        let expW = request.expectedPixelWidth
        let expH = request.expectedPixelHeight

        let resolvedW: Int
        let resolvedH: Int
        let resolvedRowBytes: Int

        let jobID = download.jobLocation.lastPathComponent
        if let info = download.imageInfo,
           info.actualWidth > 0,
           info.actualHeight > 0,
           info.actualBytesPerLine >= info.actualWidth * bpp,
           (info.jobUUID == nil || info.jobUUID == jobID || info.actualBytesPerLine * info.actualHeight == data.count),
           info.actualBytesPerLine * info.actualHeight <= data.count + info.actualBytesPerLine {
            resolvedW = info.actualWidth
            resolvedH = min(info.actualHeight, data.count / info.actualBytesPerLine)
            resolvedRowBytes = info.actualBytesPerLine
        } else {
            // Infer exact width near expectedPixelWidth (HP sometimes aligns width to 4 or 8 px)
            var matchedW: Int?
            let candidates = [expW] + (1...16).flatMap { [expW - $0, expW + $0] }
            for candW in candidates where candW > 0 {
                let rowB = candW * bpp
                if data.count % rowB == 0 {
                    let candH = data.count / rowB
                    if abs(candH - expH) <= max(32, expH / 20) {
                        matchedW = candW
                        break
                    }
                }
            }
            resolvedW = matchedW ?? expW
            resolvedRowBytes = resolvedW * bpp
            resolvedH = resolvedRowBytes > 0 ? (data.count / resolvedRowBytes) : 0
        }

        guard resolvedW > 0, resolvedH > 0 else {
            throw ImagePipelineError.invalidRawDimensions(bytes: data.count, expectedW: expW, expectedH: expH)
        }

        let packedRowBytes = resolvedW * bpp
        let packedByteCount = packedRowBytes * resolvedH
        let packedData: Data

        if resolvedRowBytes == packedRowBytes && data.count == packedByteCount {
            packedData = data
        } else if resolvedRowBytes == packedRowBytes && data.count > packedByteCount {
            packedData = data.prefix(packedByteCount)
        } else {
            var tight = Data(count: packedByteCount)
            data.withUnsafeBytes { srcRaw in
                tight.withUnsafeMutableBytes { dstRaw in
                    let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
                    let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                    for y in 0..<resolvedH {
                        memcpy(dst + y * packedRowBytes, src + y * resolvedRowBytes, packedRowBytes)
                    }
                }
            }
            packedData = tight
        }

        return RawImageBuffer(
            data: packedData,
            width: resolvedW,
            height: resolvedH,
            bytesPerRow: packedRowBytes,
            colorMode: request.colorMode,
            dpi: request.resolution
        )
    }

    // MARK: - Process Raw Buffer (Rotate -> Software LUT -> ColorSync/vImage -> CGImage)

    static func renderCGImage(
        from raw: RawImageBuffer,
        rotation: ScanRotation,
        colorProfile: ColorProfileMode,
        toneAdjustments: ToneAdjustments
    ) throws -> CGImage {
        let bpp = raw.colorMode.bytesPerPixel
        let lut: [UInt8]? = toneAdjustments.isIdentity ? nil : toneAdjustments.makeLUT()

        // 1. Rotate & optionally apply tone LUT in a single parallel pass
        let (processedData, outW, outH) = transformPixels(
            data: raw.data,
            width: raw.width,
            height: raw.height,
            bpp: bpp,
            rotation: rotation,
            lut: lut
        )
        let outRowBytes = outW * bpp

        // 2. Grayscale path
        if raw.colorMode == .grayscale8 {
            let graySpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
            guard let provider = CGDataProvider(data: processedData as CFData),
                  let cg = CGImage(
                    width: outW,
                    height: outH,
                    bitsPerComponent: 8,
                    bitsPerPixel: 8,
                    bytesPerRow: outRowBytes,
                    space: graySpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else {
                throw ImagePipelineError.cgImageCreationFailed
            }
            return cg
        }

        // 3. RGB24 path — zero-copy for sRGB or Display P3 Assign; vImage SIMD for sRGB -> Display P3 Convert
        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let p3Space = CGColorSpace(name: CGColorSpace.displayP3)!

        switch colorProfile {
        case .sRGB, .displayP3Assign:
            let targetSpace = (colorProfile == .sRGB) ? srgbSpace : p3Space
            guard let provider = CGDataProvider(data: processedData as CFData),
                  let cg = CGImage(
                    width: outW,
                    height: outH,
                    bitsPerComponent: 8,
                    bitsPerPixel: 24,
                    bytesPerRow: outRowBytes,
                    space: targetSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else {
                throw ImagePipelineError.cgImageCreationFailed
            }
            return cg

        case .displayP3Convert:
            var srcFmt = vImage_CGImageFormat(
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                colorSpace: Unmanaged.passUnretained(srgbSpace),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                version: 0,
                decode: nil,
                renderingIntent: .defaultIntent
            )
            var dstFmt = vImage_CGImageFormat(
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                colorSpace: Unmanaged.passUnretained(p3Space),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                version: 0,
                decode: nil,
                renderingIntent: .perceptual
            )

            var convErr: vImage_Error = kvImageNoError
            guard let unmanagedConv = vImageConverter_CreateWithCGImageFormat(
                &srcFmt,
                &dstFmt,
                nil,
                vImage_Flags(kvImageNoFlags),
                &convErr
            ), convErr == kvImageNoError else {
                throw ImagePipelineError.colorConversionFailed(Int(convErr))
            }
            let converter = unmanagedConv.takeRetainedValue()

            var dstData = Data(count: outRowBytes * outH)
            let convertErr: vImage_Error = processedData.withUnsafeBytes { srcRaw in
                dstData.withUnsafeMutableBytes { dstRaw in
                    var srcBuf = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: srcRaw.baseAddress!),
                        height: vImagePixelCount(outH),
                        width: vImagePixelCount(outW),
                        rowBytes: outRowBytes
                    )
                    var dstBuf = vImage_Buffer(
                        data: dstRaw.baseAddress!,
                        height: vImagePixelCount(outH),
                        width: vImagePixelCount(outW),
                        rowBytes: outRowBytes
                    )
                    return vImageConvert_AnyToAny(converter, &srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
                }
            }
            guard convertErr == kvImageNoError else {
                throw ImagePipelineError.colorConversionFailed(Int(convertErr))
            }

            guard let provider = CGDataProvider(data: dstData as CFData),
                  let cg = CGImage(
                    width: outW,
                    height: outH,
                    bitsPerComponent: 8,
                    bitsPerPixel: 24,
                    bytesPerRow: outRowBytes,
                    space: p3Space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .perceptual
                  ) else {
                throw ImagePipelineError.cgImageCreationFailed
            }
            return cg
        }
    }

    // MARK: - Multi-threaded Rotate + LUT Pass

    private struct UncheckedReadPtr: @unchecked Sendable {
        let base: UnsafePointer<UInt8>
    }

    private struct UncheckedWritePtr: @unchecked Sendable {
        let base: UnsafeMutablePointer<UInt8>
    }

    private static func transformPixels(
        data: Data,
        width: Int,
        height: Int,
        bpp: Int,
        rotation: ScanRotation,
        lut: [UInt8]?
    ) -> (Data, Int, Int) {
        if rotation == .deg0 && lut == nil {
            return (data, width, height)
        }

        let outW = (rotation == .deg90 || rotation == .deg270) ? height : width
        let outH = (rotation == .deg90 || rotation == .deg270) ? width : height
        var out = Data(count: outW * outH * bpp)

        data.withUnsafeBytes { srcRaw in
            out.withUnsafeMutableBytes { dstRaw in
                let srcBox = UncheckedReadPtr(base: srcRaw.bindMemory(to: UInt8.self).baseAddress!)
                let dstBox = UncheckedWritePtr(base: dstRaw.bindMemory(to: UInt8.self).baseAddress!)

                if rotation == .deg0, let lut {
                    let totalBytes = width * height * bpp
                    let chunk = max(65536, (totalBytes + 15) / 16)
                    let numChunks = (totalBytes + chunk - 1) / chunk
                    lut.withUnsafeBufferPointer { lutPtr in
                        let lutBox = UncheckedReadPtr(base: lutPtr.baseAddress!)
                        DispatchQueue.concurrentPerform(iterations: numChunks) { c in
                            let start = c * chunk
                            let end = min(totalBytes, start + chunk)
                            let src = srcBox.base
                            let dst = dstBox.base
                            let l = lutBox.base
                            for i in start..<end {
                                dst[i] = l[Int(src[i])]
                            }
                        }
                    }
                    return
                }

                // Multi-threaded rotation with optional fused LUT
                let srcRowBytes = width * bpp
                let dstRowBytes = outW * bpp

                let runWithLUT: (UncheckedReadPtr?) -> Void = { lutBox in
                    DispatchQueue.concurrentPerform(iterations: height) { sy in
                        let src = srcBox.base
                        let dst = dstBox.base
                        let l = lutBox?.base
                        let srcRow = src + sy * srcRowBytes
                        switch rotation {
                        case .deg0:
                            break
                        case .deg180:
                            let dy = height - 1 - sy
                            let dstRow = dst + dy * dstRowBytes
                            for sx in 0..<width {
                                let sOff = sx * bpp
                                let dOff = (width - 1 - sx) * bpp
                                if let l {
                                    for c in 0..<bpp { dstRow[dOff + c] = l[Int(srcRow[sOff + c])] }
                                } else {
                                    for c in 0..<bpp { dstRow[dOff + c] = srcRow[sOff + c] }
                                }
                            }
                        case .deg90:
                            // 90 deg clockwise: (sx, sy) -> (dx = height - 1 - sy, dy = sx)
                            let dx = height - 1 - sy
                            let dxOff = dx * bpp
                            for sx in 0..<width {
                                let sOff = sx * bpp
                                let dBase = sx * dstRowBytes + dxOff
                                if let l {
                                    for c in 0..<bpp { dst[dBase + c] = l[Int(srcRow[sOff + c])] }
                                } else {
                                    for c in 0..<bpp { dst[dBase + c] = srcRow[sOff + c] }
                                }
                            }
                        case .deg270:
                            // 270 deg clockwise (90 CCW): (sx, sy) -> (dx = sy, dy = width - 1 - sx)
                            let dx = sy
                            let dxOff = dx * bpp
                            for sx in 0..<width {
                                let sOff = sx * bpp
                                let dy = width - 1 - sx
                                let dBase = dy * dstRowBytes + dxOff
                                if let l {
                                    for c in 0..<bpp { dst[dBase + c] = l[Int(srcRow[sOff + c])] }
                                } else {
                                    for c in 0..<bpp { dst[dBase + c] = srcRow[sOff + c] }
                                }
                            }
                        }
                    }
                }

                if let lut {
                    lut.withUnsafeBufferPointer { lutPtr in
                        runWithLUT(UncheckedReadPtr(base: lutPtr.baseAddress!))
                    }
                } else {
                    runWithLUT(nil)
                }
            }
        }

        return (out, outW, outH)
    }

    // MARK: - ImageIO Export (with ICC Profile + DPI + Metadata)

    static func export(
        cgImage: CGImage,
        dpi: Int,
        settings: ExportSettings,
        to destinationURL: URL
    ) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            settings.format.uti as CFString,
            1,
            nil
        ) else {
            throw ImagePipelineError.exportFailed("Could not create destination at \(destinationURL.path)")
        }

        var tiffDict: [CFString: Any] = [
            kCGImagePropertyTIFFSoftware: "ChromaScan",
            kCGImagePropertyTIFFXResolution: dpi,
            kCGImagePropertyTIFFYResolution: dpi,
            kCGImagePropertyTIFFResolutionUnit: 2 // inches
        ]
        if let model = settings.scannerMakeAndModel, !model.isEmpty {
            tiffDict[kCGImagePropertyTIFFModel] = model
        }

        switch settings.format {
        case .tiffLZW:
            tiffDict[kCGImagePropertyTIFFCompression] = 5
        case .tiffUncompressed:
            tiffDict[kCGImagePropertyTIFFCompression] = 1
        default:
            break
        }

        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: tiffDict
        ]

        if settings.format.supportsQuality {
            props[kCGImageDestinationLossyCompressionQuality] = max(0.1, min(1.0, settings.quality))
        }

        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImagePipelineError.exportFailed("CGImageDestinationFinalize failed for \(settings.format.displayName)")
        }
    }

    // MARK: - Live Format Compression Preview & Proxy Downsampling

    /// Encodes `cgImage` in-memory with the target lossy format & quality, then decodes it back
    /// so the canvas displays real JPEG/HEIC compression artifacts and exact encoded byte size.
    static func simulateLossyFormat(
        cgImage: CGImage,
        format: OutputFormat,
        quality: Double
    ) -> (image: CGImage, encodedBytes: Int)? {
        guard format.supportsQuality else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, format.uti as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.1, min(1.0, quality))
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let data = mutableData as Data
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        return (decoded, data.count)
    }

    /// Creates a fast downsampled copy of a large RawImageBuffer (e.g. 1200 DPI -> ~2200px)
    /// for instant live Color Profile / Tone / Format slider feedback.
    static func makeProxyBuffer(from raw: RawImageBuffer, maxDimension: Int = 2200) -> RawImageBuffer {
        let longest = max(raw.width, raw.height)
        if longest <= maxDimension { return raw }

        let scale = Double(maxDimension) / Double(longest)
        let dstW = max(1, Int((Double(raw.width) * scale).rounded()))
        let dstH = max(1, Int((Double(raw.height) * scale).rounded()))
        let bpp = raw.colorMode.bytesPerPixel
        let dstRowBytes = dstW * bpp
        var dstData = Data(count: dstRowBytes * dstH)

        let srcW = raw.width
        let srcH = raw.height
        let srcRowBytes = raw.bytesPerRow

        raw.data.withUnsafeBytes { srcRaw in
            dstData.withUnsafeMutableBytes { dstRaw in
                let srcBox = UncheckedReadPtr(base: srcRaw.bindMemory(to: UInt8.self).baseAddress!)
                let dstBox = UncheckedWritePtr(base: dstRaw.bindMemory(to: UInt8.self).baseAddress!)
                // Fast box/area-averaged downsample across CPU cores
                let stepX = Double(srcW) / Double(dstW)
                let stepY = Double(srcH) / Double(dstH)
                DispatchQueue.concurrentPerform(iterations: dstH) { dy in
                    let src = srcBox.base
                    let dst = dstBox.base
                    let sy0 = min(srcH - 1, Int(Double(dy) * stepY))
                    let sy1 = min(srcH, max(sy0 + 1, Int((Double(dy + 1) * stepY).rounded(.up))))
                    let dstRow = dst + dy * dstRowBytes
                    for dx in 0..<dstW {
                        let sx0 = min(srcW - 1, Int(Double(dx) * stepX))
                        let sx1 = min(srcW, max(sx0 + 1, Int((Double(dx + 1) * stepX).rounded(.up))))
                        // Sample up to 4x4 grid inside the source box for crisp anti-aliased proxy
                        let strideY = max(1, (sy1 - sy0) / 4)
                        let strideX = max(1, (sx1 - sx0) / 4)
                        if bpp == 3 {
                            var rSum = 0, gSum = 0, bSum = 0, n = 0
                            var sy = sy0
                            while sy < sy1 {
                                let rowPtr = src + sy * srcRowBytes
                                var sx = sx0
                                while sx < sx1 {
                                    let p = rowPtr + sx * 3
                                    rSum += Int(p[0])
                                    gSum += Int(p[1])
                                    bSum += Int(p[2])
                                    n += 1
                                    sx += strideX
                                }
                                sy += strideY
                            }
                            let dOff = dx * 3
                            dstRow[dOff] = UInt8(rSum / max(1, n))
                            dstRow[dOff + 1] = UInt8(gSum / max(1, n))
                            dstRow[dOff + 2] = UInt8(bSum / max(1, n))
                        } else {
                            var gSum = 0, n = 0
                            var sy = sy0
                            while sy < sy1 {
                                let rowPtr = src + sy * srcRowBytes
                                var sx = sx0
                                while sx < sx1 {
                                    gSum += Int(rowPtr[sx])
                                    n += 1
                                    sx += strideX
                                }
                                sy += strideY
                            }
                            dstRow[dx] = UInt8(gSum / max(1, n))
                        }
                    }
                }
            }
        }

        return RawImageBuffer(
            data: dstData,
            width: dstW,
            height: dstH,
            bytesPerRow: dstRowBytes,
            colorMode: raw.colorMode,
            dpi: max(1, Int((Double(raw.dpi) * scale).rounded()))
        )
    }

    // MARK: - Companion Image & 1:1 Tile Encoding (Display P3 / sRGB ICC Preserved)

    /// Encodes a CGImage into compact HEIC (preferred) or JPEG bytes preserving embedded Display P3 / sRGB ICC profile.
    static func encodeCompanionImage(
        cgImage: CGImage,
        preferHEIC: Bool = true,
        quality: Double = 0.88,
        dpi: Int? = nil
    ) -> Data? {
        let clampedQ = max(0.1, min(1.0, quality))
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: clampedQ
        ]
        if let dpi, dpi > 0 {
            props[kCGImagePropertyDPIWidth] = dpi
            props[kCGImagePropertyDPIHeight] = dpi
        }

        let utis: [String] = preferHEIC ? ["public.heic", "public.jpeg"] : ["public.jpeg", "public.heic"]
        for uti in utis {
            let mutableData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, uti as CFString, 1, nil) else {
                continue
            }
            CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
            if CGImageDestinationFinalize(dest), mutableData.length > 0 {
                return mutableData as Data
            }
        }
        return nil
    }

    /// Crops a visible 1:1 pixel tile from `fullCG`, optionally applies lossy compression preview and optional max-width scaling,
    /// then encodes as HEIC/JPEG with the exact pixel-snapped normalized rect.
    static func cropAndEncodeTile(
        from fullCG: CGImage,
        normalizedRect: NormalizedCropRect,
        maxPixelWidth: Int,
        simulateFormat: OutputFormat?,
        simulateQuality: Double,
        preferHEIC: Bool = true
    ) -> (data: Data, width: Int, height: Int, exactNormalizedRect: NormalizedCropRect)? {
        let clamped = normalizedRect.clamped(minSize: 0.005)
        let fw = Double(fullCG.width)
        let fh = Double(fullCG.height)

        let pxX = max(0, Int((clamped.x * fw).rounded(.down)))
        let pxY = max(0, Int((clamped.y * fh).rounded(.down)))
        let pxMaxX = min(fullCG.width, Int(((clamped.x + clamped.width) * fw).rounded(.up)))
        let pxMaxY = min(fullCG.height, Int(((clamped.y + clamped.height) * fh).rounded(.up)))
        let pxW = pxMaxX - pxX
        let pxH = pxMaxY - pxY
        guard pxW > 4, pxH > 4 else { return nil }
        guard pxW * pxH <= 24_000_000 else { return nil }

        let cropRectPx = CGRect(x: pxX, y: pxY, width: pxW, height: pxH)
        guard let cropped = fullCG.cropping(to: cropRectPx) else { return nil }

        let simulated: CGImage
        if let format = simulateFormat, format.supportsQuality,
           let sim = simulateLossyFormat(cgImage: cropped, format: format, quality: simulateQuality) {
            simulated = sim.image
        } else {
            simulated = cropped
        }

        let targetImage: CGImage
        if maxPixelWidth > 0 && simulated.width > maxPixelWidth {
            let scale = Double(maxPixelWidth) / Double(simulated.width)
            let dstW = max(1, maxPixelWidth)
            let dstH = max(1, Int((Double(simulated.height) * scale).rounded()))
            if let cs = simulated.colorSpace,
               let ctx = CGContext(
                data: nil,
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
               ) {
                ctx.interpolationQuality = .high
                ctx.draw(simulated, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
                targetImage = ctx.makeImage() ?? simulated
            } else {
                targetImage = simulated
            }
        } else {
            targetImage = simulated
        }

        guard let encoded = encodeCompanionImage(cgImage: targetImage, preferHEIC: preferHEIC, quality: 0.90) else {
            return nil
        }

        let exactNorm = NormalizedCropRect(
            x: Double(pxX) / fw,
            y: Double(pxY) / fh,
            width: Double(pxW) / fw,
            height: Double(pxH) / fh
        )
        return (encoded, targetImage.width, targetImage.height, exactNorm)
    }

    // MARK: - Auto-Trim Empty Space (Border Detection & Pixel Crop)

    /// Returns the exact pixel dimensions produced by cropping `raw` to `normalizedRect`.
    static func croppedPixelBounds(
        of raw: RawImageBuffer,
        normalizedRect: NormalizedCropRect
    ) -> (x: Int, y: Int, width: Int, height: Int) {
        if normalizedRect.isFull {
            return (0, 0, raw.width, raw.height)
        }
        let c = normalizedRect.clamped(minSize: 0.01)
        let pxX = max(0, min(raw.width - 1, Int((c.x * Double(raw.width)).rounded(.down))))
        let pxY = max(0, min(raw.height - 1, Int((c.y * Double(raw.height)).rounded(.down))))
        let pxMaxX = min(raw.width, max(pxX + 1, Int(((c.x + c.width) * Double(raw.width)).rounded(.up))))
        let pxMaxY = min(raw.height, max(pxY + 1, Int(((c.y + c.height) * Double(raw.height)).rounded(.up))))
        return (pxX, pxY, max(1, pxMaxX - pxX), max(1, pxMaxY - pxY))
    }

    /// Crops `raw` to `normalizedRect` in physical buffer coordinates, returning a tightly packed `RawImageBuffer`.
    static func cropRawBuffer(_ raw: RawImageBuffer, to normalizedRect: NormalizedCropRect) -> RawImageBuffer {
        if normalizedRect.isFull { return raw }
        let b = croppedPixelBounds(of: raw, normalizedRect: normalizedRect)
        if b.x == 0 && b.y == 0 && b.width == raw.width && b.height == raw.height {
            return raw
        }

        let bpp = raw.colorMode.bytesPerPixel
        let dstRowBytes = b.width * bpp
        let srcRowBytes = raw.bytesPerRow
        var dstData = Data(count: dstRowBytes * b.height)

        raw.data.withUnsafeBytes { srcRaw in
            dstData.withUnsafeMutableBytes { dstRaw in
                let srcBox = UncheckedReadPtr(base: srcRaw.bindMemory(to: UInt8.self).baseAddress!)
                let dstBox = UncheckedWritePtr(base: dstRaw.bindMemory(to: UInt8.self).baseAddress!)
                let xByteOffset = b.x * bpp
                let startY = b.y
                if b.height >= 256 {
                    DispatchQueue.concurrentPerform(iterations: b.height) { dy in
                        let srcPtr = srcBox.base + (startY + dy) * srcRowBytes + xByteOffset
                        let dstPtr = dstBox.base + dy * dstRowBytes
                        memcpy(dstPtr, srcPtr, dstRowBytes)
                    }
                } else {
                    for dy in 0..<b.height {
                        let srcPtr = srcBox.base + (startY + dy) * srcRowBytes + xByteOffset
                        let dstPtr = dstBox.base + dy * dstRowBytes
                        memcpy(dstPtr, srcPtr, dstRowBytes)
                    }
                }
            }
        }

        return RawImageBuffer(
            data: dstData,
            width: b.width,
            height: b.height,
            bytesPerRow: dstRowBytes,
            colorMode: raw.colorMode,
            dpi: raw.dpi
        )
    }

    /// Detects the bounding box of non-empty content inside a flatbed/document scan buffer,
    /// returning a normalized crop rect in physical buffer coordinates (`nil` if no meaningful empty border is found).
    static func detectContentBounds(
        in raw: RawImageBuffer,
        paddingFraction: Double = 0.001
    ) -> NormalizedCropRect? {
        guard raw.width >= 16, raw.height >= 16 else { return nil }

        let analysis = (max(raw.width, raw.height) > 720)
            ? makeProxyBuffer(from: raw, maxDimension: 720)
            : raw

        let w = analysis.width
        let h = analysis.height
        let bpp = analysis.colorMode.bytesPerPixel
        let rowBytes = analysis.bytesPerRow
        guard w >= 16, h >= 16 else { return nil }

        return analysis.data.withUnsafeBytes { rawBytes -> NormalizedCropRect? in
            guard let ptr = rawBytes.bindMemory(to: UInt8.self).baseAddress else { return nil }

            struct PatchStats {
                let r: Int
                let g: Int
                let b: Int
                let luma: Double
                let chroma: Int
                let spread: Int
            }

            func samplePatch(x0: Int, y0: Int, pw: Int, ph: Int) -> PatchStats? {
                let sx0 = max(0, min(w - 1, x0))
                let sy0 = max(0, min(h - 1, y0))
                let sx1 = max(sx0 + 1, min(w, sx0 + pw))
                let sy1 = max(sy0 + 1, min(h, sy0 + ph))

                var rs: [Int] = []
                var gs: [Int] = []
                var bs: [Int] = []
                let cap = (sx1 - sx0) * (sy1 - sy0)
                rs.reserveCapacity(cap)
                if bpp == 3 {
                    gs.reserveCapacity(cap)
                    bs.reserveCapacity(cap)
                }

                for y in sy0..<sy1 {
                    let row = ptr + y * rowBytes
                    for x in sx0..<sx1 {
                        if bpp == 3 {
                            let p = row + x * 3
                            rs.append(Int(p[0]))
                            gs.append(Int(p[1]))
                            bs.append(Int(p[2]))
                        } else {
                            rs.append(Int(row[x]))
                        }
                    }
                }
                guard !rs.isEmpty else { return nil }

                rs.sort()
                let mid = rs.count / 2
                let medR = rs[mid]
                let medG: Int
                let medB: Int
                if bpp == 3 {
                    gs.sort()
                    bs.sort()
                    medG = gs[mid]
                    medB = bs[mid]
                } else {
                    medG = medR
                    medB = medR
                }

                var devs: [Int] = []
                devs.reserveCapacity(rs.count)
                for y in sy0..<sy1 {
                    let row = ptr + y * rowBytes
                    for x in sx0..<sx1 {
                        if bpp == 3 {
                            let p = row + x * 3
                            let d = max(abs(Int(p[0]) - medR), max(abs(Int(p[1]) - medG), abs(Int(p[2]) - medB)))
                            devs.append(d)
                        } else {
                            devs.append(abs(Int(row[x]) - medR))
                        }
                    }
                }
                devs.sort()
                let p90 = devs[min(devs.count - 1, Int(Double(devs.count) * 0.90))]
                let luma = 0.299 * Double(medR) + 0.587 * Double(medG) + 0.114 * Double(medB)
                let chroma = max(medR, max(medG, medB)) - min(medR, min(medG, medB))
                return PatchStats(r: medR, g: medG, b: medB, luma: luma, chroma: chroma, spread: p90)
            }

            // 1. Sample 4 corners + 4 edge midpoints (inset past up to ~2.5% platen mechanical bezel on large images)
            let patchW = max(2, min(18, w / 18))
            let patchH = max(2, min(18, h / 18))
            let insetX = w >= 100 ? max(2, Int((Double(w) * 0.025).rounded())) : 0
            let insetY = h >= 100 ? max(2, Int((Double(h) * 0.025).rounded())) : 0

            let origins: [(Int, Int)] = [
                (insetX, insetY),                                           // top-left
                (w - insetX - patchW, insetY),                              // top-right
                (insetX, h - insetY - patchH),                              // bottom-left
                (w - insetX - patchW, h - insetY - patchH),                 // bottom-right
                ((w - patchW) / 2, insetY),                                 // top-center
                ((w - patchW) / 2, h - insetY - patchH),                    // bottom-center
                (insetX, (h - patchH) / 2),                                 // left-center
                (w - insetX - patchW, (h - patchH) / 2)                     // right-center
            ]

            let lightUniformCandidates = origins
                .compactMap { samplePatch(x0: $0.0, y0: $0.1, pw: patchW, ph: patchH) }
                .filter { $0.spread <= 18 && $0.luma >= 185.0 && $0.chroma <= 36 }

            guard let brightest = lightUniformCandidates.max(by: { $0.luma < $1.luma }) else {
                return nil
            }

            let cluster = lightUniformCandidates.filter { cand in
                max(abs(cand.r - brightest.r), max(abs(cand.g - brightest.g), abs(cand.b - brightest.b))) <= 24
            }
            let bgR = cluster.map(\.r).reduce(0, +) / cluster.count
            let bgG = cluster.map(\.g).reduce(0, +) / cluster.count
            let bgB = cluster.map(\.b).reduce(0, +) / cluster.count

            var maxSpread = 0
            for c in cluster {
                let clusterDiff = max(abs(c.r - bgR), max(abs(c.g - bgG), abs(c.b - bgB)))
                maxSpread = max(maxSpread, c.spread + clusterDiff)
            }
            let tolerance = max(18, min(42, maxSpread + 16))

            @inline(__always)
            func isContentPixel(x: Int, y: Int) -> Bool {
                let row = ptr + y * rowBytes
                if bpp == 3 {
                    let p = row + x * 3
                    let diff = max(abs(Int(p[0]) - bgR), max(abs(Int(p[1]) - bgG), abs(Int(p[2]) - bgB)))
                    return diff > tolerance
                } else {
                    return abs(Int(row[x]) - bgR) > tolerance
                }
            }

            // 2. Two-pass row/column content classification with dynamic bezel & speck filtering
            func scanRows(x0: Int, x1: Int) -> (flags: [Bool], counts: [Int]) {
                let span = max(1, x1 - x0)
                let minCount = max(4, Int(Double(span) * 0.015))
                let minRun = max(5, Int(Double(span) * 0.012))
                var flags = [Bool](repeating: false, count: h)
                var counts = [Int](repeating: 0, count: h)
                for y in 0..<h {
                    var count = 0
                    var run = 0
                    var maxRun = 0
                    for x in x0..<x1 {
                        if isContentPixel(x: x, y: y) {
                            count += 1
                            run += 1
                            if run > maxRun { maxRun = run }
                        } else {
                            run = 0
                        }
                    }
                    counts[y] = count
                    flags[y] = (count >= minCount || maxRun >= minRun)
                }
                return (flags, counts)
            }

            func scanCols(y0: Int, y1: Int) -> (flags: [Bool], counts: [Int]) {
                let span = max(1, y1 - y0)
                let minCount = max(4, Int(Double(span) * 0.015))
                let minRun = max(5, Int(Double(span) * 0.012))
                var flags = [Bool](repeating: false, count: w)
                var counts = [Int](repeating: 0, count: w)
                for x in 0..<w {
                    var count = 0
                    var run = 0
                    var maxRun = 0
                    for y in y0..<y1 {
                        if isContentPixel(x: x, y: y) {
                            count += 1
                            run += 1
                            if run > maxRun { maxRun = run }
                        } else {
                            run = 0
                        }
                    }
                    counts[x] = count
                    flags[x] = (count >= minCount || maxRun >= minRun)
                }
                return (flags, counts)
            }

            // Skips outer mechanical bezels (up to 3% of dim when followed by a clear blank-lid gap)
            // and drops tiny isolated dust/scuff speck islands separated by blank space from real content.
            func findAxisBounds(flags: [Bool], counts: [Int], otherSpan: Int) -> (Int, Int)? {
                let n = flags.count
                let maxBezel = n >= 100 ? max(4, Int(Double(n) * 0.03)) : 0
                let minBlankGap = n >= 100 ? max(4, Int(Double(n) * 0.012)) : 0

                var startBound = 0
                if maxBezel > 0 {
                    var blankRun = 0
                    let limit = min(n, maxBezel + minBlankGap)
                    for i in 0..<limit {
                        if !flags[i] {
                            blankRun += 1
                            if blankRun >= minBlankGap {
                                startBound = i - blankRun + 1
                                break
                            }
                        } else {
                            blankRun = 0
                        }
                    }
                }

                var endBound = n - 1
                if maxBezel > 0 {
                    var blankRun = 0
                    let limit = max(0, n - maxBezel - minBlankGap)
                    for i in stride(from: n - 1, through: limit, by: -1) {
                        if !flags[i] {
                            blankRun += 1
                            if blankRun >= minBlankGap {
                                endBound = i + blankRun - 1
                                break
                            }
                        } else {
                            blankRun = 0
                        }
                    }
                }

                guard endBound > startBound else { return nil }

                let minIslandPixels = max(16, Int(Double(otherSpan) * 0.05))
                var firstStart: Int?
                var lastEnd: Int?
                var i = startBound
                while i <= endBound {
                    if flags[i] {
                        let s = i
                        var totalPixels = 0
                        while i <= endBound && flags[i] {
                            totalPixels += counts[i]
                            i += 1
                        }
                        let e = i - 1
                        let thickness = e - s + 1
                        if thickness >= 3 || totalPixels >= minIslandPixels {
                            if firstStart == nil { firstStart = s }
                            lastEnd = e
                        }
                    } else {
                        i += 1
                    }
                }

                guard let firstStart, let lastEnd, lastEnd > firstStart else { return nil }
                return (firstStart, lastEnd)
            }

            // Pass 1: exclude outer 3% perpendicular strip so cross-axis platen bezels don't leak into counts
            let marginX = w >= 100 ? max(4, Int(Double(w) * 0.03)) : 0
            let marginY = h >= 100 ? max(4, Int(Double(h) * 0.03)) : 0
            let scanX1 = max(marginX + 1, w - marginX)
            let scanY1 = max(marginY + 1, h - marginY)
            let rows1 = scanRows(x0: marginX, x1: scanX1)
            let cols1 = scanCols(y0: marginY, y1: scanY1)
            guard let (top1, bottom1) = findAxisBounds(flags: rows1.flags, counts: rows1.counts, otherSpan: scanX1 - marginX),
                  let (left1, right1) = findAxisBounds(flags: cols1.flags, counts: cols1.counts, otherSpan: scanY1 - marginY) else {
                return nil
            }

            // Pass 2: refine each axis strictly inside the other axis's detected content bounds
            let rows2 = scanRows(x0: left1, x1: right1 + 1)
            let cols2 = scanCols(y0: top1, y1: bottom1 + 1)
            guard let (top, bottom) = findAxisBounds(flags: rows2.flags, counts: rows2.counts, otherSpan: right1 - left1 + 1),
                  let (left, right) = findAxisBounds(flags: cols2.flags, counts: cols2.counts, otherSpan: bottom1 - top1 + 1),
                  right > left,
                  bottom > top else {
                return nil
            }

            // 3. Convert to normalized coords with subtle protective padding on trimmed edges
            let pad = max(0.0, paddingFraction)
            var nx1 = Double(left) / Double(w)
            var ny1 = Double(top) / Double(h)
            var nx2 = Double(right + 1) / Double(w)
            var ny2 = Double(bottom + 1) / Double(h)

            if left > 0 { nx1 = max(0.0, nx1 - pad) }
            if top > 0 { ny1 = max(0.0, ny1 - pad) }
            if right < w - 1 { nx2 = min(1.0, nx2 + pad) }
            if bottom < h - 1 { ny2 = min(1.0, ny2 + pad) }

            let nw = nx2 - nx1
            let nh = ny2 - ny1
            guard nw >= 0.04, nh >= 0.04 else { return nil }

            // Skip negligible (< ~1.5% total) trims
            if nx1 < 0.008 && ny1 < 0.008 && nw > 0.984 && nh > 0.984 {
                return nil
            }

            return NormalizedCropRect(x: nx1, y: ny1, width: nw, height: nh).clamped()
        }
    }
}
