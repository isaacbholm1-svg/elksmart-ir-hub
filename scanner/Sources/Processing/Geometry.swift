import ARKit
import CoreImage
import Foundation
import ImageIO
import simd

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

extension simd_float4x4 {
    var position: SIMD3<Float> { columns.3.xyz }
    var rotation3x3: simd_float3x3 { simd_float3x3(columns.0.xyz, columns.1.xyz, columns.2.xyz) }

    /// Row-major nested array, as used by transforms.json.
    var rows: [[Double]] {
        (0..<4).map { r in [Double(columns.0[r]), Double(columns.1[r]), Double(columns.2[r]), Double(columns.3[r])] }
    }
}

/// Angle in radians between the orientations of two poses.
func rotationAngle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    let qa = simd_quatf(a.rotation3x3), qb = simd_quatf(b.rotation3x3)
    let angle = (qa.inverse * qb).angle
    return min(angle, 2 * .pi - angle)
}

/// Camera intrinsics scaled to another image size (same field of view).
func scaledIntrinsics(_ k: simd_float3x3, sx: Float, sy: Float) -> simd_float3x3 {
    var m = k
    m.columns.0.x *= sx
    m.columns.1.y *= sy
    m.columns.2.x *= sx
    m.columns.2.y *= sy
    return m
}

/// A pinhole camera in ARKit's convention: x right, y up, looking down -z,
/// image pixels with y pointing down (sensor / landscape orientation).
struct PinholeCamera {
    let worldToCamera: simd_float4x4
    let fx: Float, fy: Float, cx: Float, cy: Float
    let width: Float, height: Float

    init(transform: simd_float4x4, intrinsics k: simd_float3x3, width: Int, height: Int) {
        worldToCamera = transform.inverse
        fx = k.columns.0.x
        fy = k.columns.1.y
        cx = k.columns.2.x
        cy = k.columns.2.y
        self.width = Float(width)
        self.height = Float(height)
    }

    /// Returns pixel position and depth (distance along the view axis).
    @inline(__always)
    func project(_ p: SIMD3<Float>) -> (pixel: SIMD2<Float>, depth: Float) {
        let c = worldToCamera * SIMD4(p, 1)
        let d = -c.z
        guard d > 1e-4 else { return (SIMD2(-1, -1), d) }
        return (SIMD2(fx * c.x / d + cx, cy - fy * c.y / d), d)
    }

    /// Camera-space point for a pixel at a given depth.
    @inline(__always)
    func unprojectToCamera(px: Float, py: Float, depth d: Float) -> SIMD4<Float> {
        SIMD4((px - cx) * d / fx, -(py - cy) * d / fy, -d, 1)
    }
}

/// Small decoded RGB image used for colouring points and vertices.
struct RGBImage {
    let width: Int
    let height: Int
    let pixels: [UInt8] // RGBA

    static func load(_ url: URL, maxSize: Int) -> RGBImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? RGBImage(width: w, height: h, pixels: pixels) : nil
    }

    /// uv in 0...1, origin top-left.
    @inline(__always)
    func sample(_ uv: SIMD2<Float>) -> SIMD3<Float> {
        let x = min(width - 1, max(0, Int(uv.x * Float(width))))
        let y = min(height - 1, max(0, Int(uv.y * Float(height))))
        let i = (y * width + x) * 4
        return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
    }
}

/// Reads colours straight from ARKit's YCbCr camera image.
struct YCbCrImage {
    let luma: UnsafePointer<UInt8>
    let lumaStride: Int
    let chroma: UnsafePointer<UInt8>
    let chromaStride: Int
    let width: Int
    let height: Int

    static func with<R>(_ buffer: CVPixelBuffer, _ body: (YCbCrImage) -> R) -> R? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let image = YCbCrImage(
            luma: UnsafePointer(y.assumingMemoryBound(to: UInt8.self)),
            lumaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
            chroma: UnsafePointer(c.assumingMemoryBound(to: UInt8.self)),
            chromaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
            width: CVPixelBufferGetWidthOfPlane(buffer, 0),
            height: CVPixelBufferGetHeightOfPlane(buffer, 0))
        return body(image)
    }

    @inline(__always)
    func rgb(x: Int, y: Int) -> SIMD3<Float> {
        let xx = min(width - 1, max(0, x)), yy = min(height - 1, max(0, y))
        let lum = Float(luma[yy * lumaStride + xx])
        let ci = (yy / 2) * chromaStride + (xx / 2) * 2
        let cb = Float(chroma[ci]) - 128, cr = Float(chroma[ci + 1]) - 128
        let rgb = SIMD3<Float>(lum + 1.402 * cr, lum - 0.344136 * cb - 0.714136 * cr, lum + 1.772 * cb) / 255
        return rgb.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
    }
}

/// Copies an ARKit depth frame out of its pixel buffers.
struct DepthSnapshot {
    var depth: [Float]
    var confidence: [UInt8]
    var width: Int
    var height: Int

    init(_ data: ARDepthData) {
        let map = data.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        width = CVPixelBufferGetWidth(map)
        height = CVPixelBufferGetHeight(map)
        depth = [Float](repeating: 0, count: width * height)
        confidence = [UInt8](repeating: 2, count: width * height)
        if let base = CVPixelBufferGetBaseAddress(map) {
            let rowBytes = CVPixelBufferGetBytesPerRow(map)
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
                for x in 0..<width { depth[y * width + x] = row[x] }
            }
        }
        if let conf = data.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(conf, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(conf), CVPixelBufferGetWidth(conf) == width {
                let rowBytes = CVPixelBufferGetBytesPerRow(conf)
                for y in 0..<height {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { confidence[y * width + x] = row[x] }
                }
            }
        }
    }
}

/// Writes camera frames to JPEG on a background queue.
final class JPEGWriter {
    private let queue = DispatchQueue(label: "scanner.jpeg", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    func write(_ buffer: CVPixelBuffer, to url: URL, quality: Double = 0.9) {
        queue.async { [context, colorSpace] in
            let image = CIImage(cvPixelBuffer: buffer)
            let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            try? context.writeJPEGRepresentation(of: image, to: url, colorSpace: colorSpace, options: [key: quality])
        }
    }

    /// Waits until every queued image is on disk.
    func drain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { c.resume() }
        }
    }
}

func trackingMessage(_ state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal: return ""
    case .notAvailable: return "Tracking unavailable"
    case .limited(let reason):
        switch reason {
        case .initializing: return "Starting up… move the phone slowly"
        case .excessiveMotion: return "Slow down"
        case .insufficientFeatures: return "Not enough detail here. Add light or aim at textured areas"
        case .relocalizing: return "Relocalizing… go back to where you were"
        @unknown default: return "Tracking limited"
        }
    }
}

func formatMeters(_ m: Float) -> String {
    String(format: "%.2f m (%.1f ft)", m, m * 3.28084)
}

/// "objectTooFar" -> "Object too far"
func prettyName(_ raw: String) -> String {
    var out = ""
    for ch in raw {
        if ch.isUppercase { out += " " + ch.lowercased() } else { out.append(ch) }
    }
    return out.prefix(1).uppercased() + out.dropFirst()
}
