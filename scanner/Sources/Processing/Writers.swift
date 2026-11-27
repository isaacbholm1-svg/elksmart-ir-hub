import Foundation
import simd

/// Buffered text output for large OBJ files.
final class TextWriter {
    private let handle: FileHandle
    private var buffer = [UInt8]()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(1 << 22)
    }

    func write(_ s: String) {
        buffer.append(contentsOf: s.utf8)
        if buffer.count > 1 << 22 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }

    func close() {
        flush()
        try? handle.close()
    }
}

/// Binary data builder for PLY files.
struct BinaryBuffer {
    var data = Data()

    mutating func append<T>(_ value: T) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

/// Merges points into a voxel grid (one averaged, coloured point per voxel).
final class PointAccumulator {
    let voxel: Float
    private var index: [Int64: Int32] = [:]
    private(set) var positions: [SIMD3<Float>] = []
    private var colors: [SIMD3<Float>] = []
    private var counts: [Float] = []

    init(voxel: Float) {
        self.voxel = voxel
    }

    var count: Int { positions.count }

    func add(_ p: SIMD3<Float>, color: SIMD3<Float>) {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
              abs(p.x) < 5000, abs(p.y) < 5000, abs(p.z) < 5000 else { return }
        let q = (p / voxel).rounded(.down)
        let mask: Int64 = 0x1FFFFF
        let key = ((Int64(q.x) & mask) << 42) | ((Int64(q.y) & mask) << 21) | (Int64(q.z) & mask)
        if let i = index[key] {
            let j = Int(i)
            positions[j] += p
            colors[j] += color
            counts[j] += 1
        } else {
            index[key] = Int32(positions.count)
            positions.append(p)
            colors.append(color)
            counts.append(1)
        }
    }

    /// Writes a binary PLY (x y z float, red green blue uchar). Returns the point count.
    @discardableResult
    func writePLY(to url: URL) throws -> Int {
        var out = BinaryBuffer()
        out.data.reserveCapacity(positions.count * 15 + 256)
        let header = """
        ply
        format binary_little_endian 1.0
        comment Created by 3D Scanner
        element vertex \(positions.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        out.data.append(header.data(using: .ascii)!)
        for i in 0..<positions.count {
            let n = counts[i]
            let p = positions[i] / n
            let c = (colors[i] / n * 255).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))
            out.append(p.x); out.append(p.y); out.append(p.z)
            out.append(UInt8(c.x)); out.append(UInt8(c.y)); out.append(UInt8(c.z))
        }
        try out.data.write(to: url)
        return positions.count
    }
}

/// One posed photo, for transforms.json (nerfstudio format).
struct CameraFrame {
    var file: String
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    var width: Int
    var height: Int
}

enum DatasetWriter {
    /// Writes a nerfstudio-style transforms.json. ARKit's camera convention
    /// (x right, y up, looking down -z) is the same OpenGL convention nerfstudio uses.
    static func writeTransforms(frames: [CameraFrame], plyFile: String?, to url: URL) throws {
        func intrinsics(_ f: CameraFrame) -> [String: Any] {
            [
                "fl_x": Double(f.intrinsics.columns.0.x),
                "fl_y": Double(f.intrinsics.columns.1.y),
                "cx": Double(f.intrinsics.columns.2.x),
                "cy": Double(f.intrinsics.columns.2.y),
                "w": f.width,
                "h": f.height,
            ]
        }
        var root: [String: Any] = [
            "camera_model": "OPENCV",
            "k1": 0, "k2": 0, "p1": 0, "p2": 0,
            "frames": frames.map { f -> [String: Any] in
                var d = intrinsics(f)
                d["file_path"] = f.file
                d["transform_matrix"] = f.transform.rows
                return d
            },
        ]
        if let first = frames.first {
            root.merge(intrinsics(first)) { a, _ in a }
        }
        if let plyFile { root["ply_file_path"] = plyFile }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}

enum Zipper {
    /// Zips a folder with the system's built-in zip support (NSFileCoordinator .forUploading).
    static func zip(folder: URL, named name: String) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".zip")
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { zipped in
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: zipped, to: dest)
            } catch {
                copyError = error
            }
        }
        if let e = coordError ?? copyError { throw e }
        return dest
    }
}

func fileCount(in folder: URL, extensions: Set<String>) -> Int {
    let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return items.filter { extensions.contains($0.pathExtension.lowercased()) }.count
}

func folderSize(_ url: URL) -> String {
    var total: Int64 = 0
    if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
}
