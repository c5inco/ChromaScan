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
}
