import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import libwebp

/// Synchronous codec work. Callers must run preparation in cancellable detached work.
nonisolated enum StillImagePreparation {
    enum PreparationError: LocalizedError {
        case invalidImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: "The photo could not be read."
            case .encodingFailed: "The photo could not be prepared."
            }
        }
    }

    struct Output: Sendable {
        let url: URL
        let extensionName: String
        let mimeType: String
        let width: Int
        let height: Int
        let byteCount: Int64
    }

    static func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = Double(width)
        let h = Double(height)
        let scale = min(1, 1400 / min(w, h), sqrt(8_000_000 / (w * h)), 16000 / max(w, h))
        return (max(1, Int(floor(w * scale))), max(1, Int(floor(h * scale))))
    }

    /// Returns nil when animation or the savings threshold requires retaining provider bytes.
    static func prepare(source: CGImageSource, originalByteCount: Int64, directory: URL) throws
        -> Output?
    {
        try Task.checkCancellation()
        guard CGImageSourceGetCount(source) == 1 else { return nil }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else { throw PreparationError.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapped = (5...8).contains(orientation)
        let size = dimensions(width: swapped ? height : width, height: swapped ? width : height)
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw PreparationError.invalidImage }
        // ImageIO can round the short edge up. Render to the exact floored policy dimensions.
        let bitmap = try rgbaBitmap(width: size.width, height: size.height)
        bitmap.interpolationQuality = .high
        bitmap.draw(thumbnail, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let transparent = try hasTransparency(bitmap)
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        let format: (extensionName: String, mimeType: String)
        if try encodeWebP(bitmap, to: staging, hasTransparency: transparent) {
            format = ("webp", "image/webp")
        } else {
            guard let image = bitmap.makeImage() else { throw PreparationError.invalidImage }
            let type: UTType = transparent ? .png : .jpeg
            guard
                try encodeNative(image, identifier: type.identifier, to: staging)
            else { throw PreparationError.encodingFailed }
            format = (type.preferredFilenameExtension!, type.preferredMIMEType!)
        }
        let values = try staging.resourceValues(forKeys: [.fileSizeKey])
        guard let bytes = values.fileSize, bytes > 0 else { throw PreparationError.encodingFailed }
        try Task.checkCancellation()
        guard Double(bytes) < Double(originalByteCount) * 0.75 else { return nil }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.synchronize()
        let output = directory.appendingPathComponent(
            "prepared.\(UUID().uuidString).\(format.extensionName)")
        try FileManager.default.moveItem(at: staging, to: output)
        return Output(
            url: output, extensionName: format.extensionName, mimeType: format.mimeType,
            width: size.width, height: size.height, byteCount: Int64(bytes))
    }

    static func rgbaBitmap(width: Int, height: Int) throws -> CGContext {
        guard
            let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PreparationError.invalidImage }
        return bitmap
    }

    static func hasTransparency(_ bitmap: CGContext) throws -> Bool {
        guard let data = bitmap.data?.assumingMemoryBound(to: UInt8.self) else {
            throw PreparationError.invalidImage
        }
        for y in 0..<bitmap.height {
            try Task.checkCancellation()
            for x in 0..<bitmap.width where data[y * bitmap.bytesPerRow + x * 4 + 3] < 255 {
                return true
            }
        }
        return false
    }

    static func encodeNative(
        _ image: CGImage, identifier: String, to url: URL
    ) throws -> Bool {
        try Task.checkCancellation()
        guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(identifier),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, identifier as CFString, 1, nil)
        else { return false }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if identifier == UTType.jpeg.identifier {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.8
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return false }
        try Task.checkCancellation()
        return true
    }

    static func encodeWebP(_ bitmap: CGContext, to url: URL, hasTransparency: Bool) throws -> Bool {
        try Task.checkCancellation()
        guard let data = bitmap.data else { throw PreparationError.invalidImage }
        func encode(_ pixels: UnsafePointer<UInt8>) throws -> Bool {
            var encoded: UnsafeMutablePointer<UInt8>?
            let count = WebPEncodeRGBA(
                pixels, Int32(bitmap.width), Int32(bitmap.height), Int32(bitmap.bytesPerRow),
                60, &encoded)
            guard let encoded else { return false }
            defer { WebPFree(encoded) }
            guard count > 0 else { return false }
            try Task.checkCancellation()
            try Data(bytesNoCopy: encoded, count: count, deallocator: .none).write(to: url)
            return true
        }
        if !hasTransparency {
            return try encode(data.assumingMemoryBound(to: UInt8.self))
        }
        // A separate straight-alpha buffer is necessary: native fallback must retain its
        // premultiplied pixels. Reuse the rendered bitmap instead of drawing the image again.
        var rgba = Data(bytes: data, count: bitmap.bytesPerRow * bitmap.height)
        return try rgba.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<bitmap.height {
                try Task.checkCancellation()
                for x in 0..<bitmap.width {
                    let offset = y * bitmap.bytesPerRow + x * 4
                    let alpha = Int(pixels[offset + 3])
                    if alpha > 0 && alpha < 255 {
                        for channel in 0..<3 {
                            pixels[offset + channel] = UInt8(
                                min(255, (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha))
                        }
                    }
                }
            }
            return try encode(pixels)
        }
    }
}
