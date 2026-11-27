import Foundation
import SceneKit
import simd

struct MeshProcessingOptions {
    var removeUntextured = false
}

struct ProcessedScan {
    var model: String?
    var exports: [ExportItem]
    var info: [InfoItem]
}

/// Turns a LiDAR mesh + keyframe photos into a photo-textured model.
///
/// Every triangle is assigned the keyframe that sees it best (largest on-screen
/// area, facing the camera, not hidden behind other surfaces according to that
/// frame's LiDAR depth, away from the image edges). Its UVs are then simply its
/// projection into that photo, so textures keep the camera's full resolution.
enum MeshProcessor {
    static func run(mesh input: MeshData, keyframes: [Keyframe], folder: URL, datasetName: String,
                    options: MeshProcessingOptions,
                    progress: @escaping (String, Double) -> Void) throws -> ProcessedScan {
        var mesh = input
        let N = mesh.positions.count
        let T = mesh.indices.count / 3
        guard T > 0 else { throw ScanError("No surfaces were captured. Scan again and move around the space more.") }
        guard !keyframes.isEmpty else { throw ScanError("No photos were captured. Move slower and keep the phone steady.") }
        let dataset = folder.appendingPathComponent(datasetName, isDirectory: true)

        // Face normals, made consistent with ARKit's vertex normals (and winding fixed to match).
        progress("Preparing mesh", 0)
        var faceNormal = [SIMD3<Float>](repeating: .zero, count: T)
        var faceCenter = [SIMD3<Float>](repeating: .zero, count: T)
        for t in 0..<T {
            let ia = Int(mesh.indices[3 * t]), ib = Int(mesh.indices[3 * t + 1]), ic = Int(mesh.indices[3 * t + 2])
            let a = mesh.positions[ia], b = mesh.positions[ib], c = mesh.positions[ic]
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            if len > 0 { n /= len }
            if simd_dot(n, mesh.normals[ia] + mesh.normals[ib] + mesh.normals[ic]) < 0 {
                n = -n
                mesh.indices.swapAt(3 * t + 1, 3 * t + 2)
            }
            faceNormal[t] = n
            faceCenter[t] = (a + b + c) / 3
        }

        var bestScore = [Float](repeating: 0, count: T)
        var bestFrame = [Int32](repeating: -1, count: T)
        var vertexColor = [SIMD3<Float>](repeating: SIMD3(repeating: 0.6), count: N)
        var vertexScore = [Float](repeating: 0, count: N)
        var uv = [SIMD2<Float>](repeating: .zero, count: N)
        var visible = [Bool](repeating: false, count: N)
        let points = PointAccumulator(voxel: 0.008)

        for (k, kf) in keyframes.enumerated() {
            progress("Choosing the best photo for each surface", Double(k) / Double(keyframes.count) * 0.65)
            autoreleasepool {
                let thumb = RGBImage.load(dataset.appendingPathComponent(kf.file), maxSize: 720)
                let cam = kf.imageCamera
                let dcam = kf.depthCamera
                let camPos = kf.transform.position
                let depth = kf.depth
                let W = cam.width, H = cam.height
                let margin: Float = 6

                // 1. Which vertices this photo sees.
                for v in 0..<N {
                    visible[v] = false
                    let p = mesh.positions[v]
                    let (px, d) = cam.project(p)
                    if d < 0.08 || d > 7 { continue }
                    if px.x < margin || px.y < margin || px.x > W - margin || px.y > H - margin { continue }
                    let (dp, dd) = dcam.project(p)
                    let dx = Int(dp.x), dy = Int(dp.y)
                    if dx >= 0, dy >= 0, dx < depth.width, dy < depth.height {
                        let measured = depth.depth[dy * depth.width + dx]
                        if measured > 0 && dd > measured + 0.04 + 0.03 * measured { continue } // hidden
                    }
                    visible[v] = true
                    let t = SIMD2<Float>(px.x / W, px.y / H)
                    uv[v] = t
                    if let thumb {
                        let toCam = camPos - p
                        let dist = simd_length(toCam)
                        let s = max(0, simd_dot(mesh.normals[v], toCam / dist)) / (dist * dist)
                        if s > vertexScore[v] {
                            vertexScore[v] = s
                            vertexColor[v] = thumb.sample(t)
                        }
                    }
                }

                // 2. Score each triangle seen completely by this photo.
                for t in 0..<T {
                    let a = Int(mesh.indices[3 * t]), b = Int(mesh.indices[3 * t + 1]), c = Int(mesh.indices[3 * t + 2])
                    guard visible[a], visible[b], visible[c] else { continue }
                    let toCam = camPos - faceCenter[t]
                    let dist = simd_length(toCam)
                    let facing = simd_dot(faceNormal[t], toCam / dist)
                    if facing < 0.15 { continue }
                    let pa = uv[a] * SIMD2(W, H), pb = uv[b] * SIMD2(W, H), pc = uv[c] * SIMD2(W, H)
                    let e1 = pb - pa, e2 = pc - pa
                    let area = abs(e1.x * e2.y - e1.y * e2.x) * 0.5
                    let center = (uv[a] + uv[b] + uv[c]) / 3 - SIMD2(0.5, 0.5)
                    let edgeWeight = 1 - min(0.6, simd_length(center) * 0.9)
                    let score = area * facing * edgeWeight
                    if score > bestScore[t] {
                        bestScore[t] = score
                        bestFrame[t] = Int32(k)
                    }
                }

                // 3. Coloured point cloud from this frame's LiDAR depth.
                if let thumb {
                    let step = 2
                    var y = 0
                    while y < depth.height {
                        var x = 0
                        while x < depth.width {
                            let i = y * depth.width + x
                            let d = depth.depth[i]
                            if depth.confidence[i] >= 2, d > 0.1, d < 5 {
                                let pc = dcam.unprojectToCamera(px: Float(x) + 0.5, py: Float(y) + 0.5, depth: d)
                                let world = (kf.depthTransform * pc).xyz
                                let (px, _) = cam.project(world)
                                if px.x >= 0, px.y >= 0, px.x < W, px.y < H {
                                    points.add(world, color: thumb.sample(SIMD2(px.x / W, px.y / H)))
                                }
                            }
                            x += step
                        }
                        y += step
                    }
                }
            }
        }

        // Group triangles by photo.
        progress("Writing textured model", 0.7)
        var buckets = [[Int32]](repeating: [], count: keyframes.count + 1)
        var textured = 0
        for t in 0..<T {
            let f = Int(bestFrame[t])
            if f >= 0 {
                buckets[f].append(Int32(t))
                textured += 1
            } else if !options.removeUntextured {
                buckets[keyframes.count].append(Int32(t))
            }
        }

        // Textured OBJ next to the photos it uses.
        let objURL = dataset.appendingPathComponent("model.obj")
        try writeOBJ(mesh: mesh, keyframes: keyframes, buckets: buckets, objURL: objURL,
                     mtlURL: dataset.appendingPathComponent("model.mtl"))

        progress("Writing point cloud & PLY", 0.8)
        let pointCount = try points.writePLY(to: dataset.appendingPathComponent("points3D.ply"))
        try writeColoredPLY(mesh: mesh, colors: vertexColor, keep: buckets.flatMap { $0 },
                            to: folder.appendingPathComponent("mesh_colored.ply"))
        try DatasetWriter.writeTransforms(
            frames: keyframes.map { CameraFrame(file: $0.file, transform: $0.transform, intrinsics: $0.intrinsics, width: $0.width, height: $0.height) },
            plyFile: "points3D.ply",
            to: dataset.appendingPathComponent("transforms.json"))

        progress("Packing USDZ", 0.88)
        var model = "\(datasetName)/model.obj"
        var exports: [ExportItem] = []
        let usdzURL = folder.appendingPathComponent("model.usdz")
        if let scene = try? SCNScene(url: objURL, options: nil) {
            scene.rootNode.enumerateHierarchy { node, _ in
                node.geometry?.materials.forEach { $0.isDoubleSided = true }
            }
            if scene.write(to: usdzURL, options: nil, delegate: nil, progressHandler: nil),
               FileManager.default.fileExists(atPath: usdzURL.path) {
                model = "model.usdz"
                exports.append(ExportItem(label: "3D model (USDZ, textured)", path: "model.usdz"))
            }
        }
        exports.append(ExportItem(label: "Textured OBJ + photos + camera poses (zip)", path: datasetName))
        exports.append(ExportItem(label: "Mesh with vertex colours (PLY)", path: "mesh_colored.ply"))
        exports.append(ExportItem(label: "Coloured point cloud (PLY)", path: "\(datasetName)/points3D.ply"))
        exports.append(ExportItem(label: "Camera poses for splats / NeRF (transforms.json)", path: "\(datasetName)/transforms.json"))

        // Stats.
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in mesh.positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let size = hi - lo
        var area: Float = 0
        for t in 0..<T where options.removeUntextured == false || bestFrame[t] >= 0 {
            let a = mesh.positions[Int(mesh.indices[3 * t])], b = mesh.positions[Int(mesh.indices[3 * t + 1])], c = mesh.positions[Int(mesh.indices[3 * t + 2])]
            area += simd_length(simd_cross(b - a, c - a)) / 2
        }
        let photo = keyframes[0]
        let info = [
            InfoItem(key: "Size (W × H × D)", value: String(format: "%.2f × %.2f × %.2f m", size.x, size.y, size.z)),
            InfoItem(key: "Surface area", value: String(format: "%.1f m²", area)),
            InfoItem(key: "Triangles", value: (options.removeUntextured ? textured : T).formatted()),
            InfoItem(key: "Textured", value: String(format: "%.0f%%", Double(textured) / Double(T) * 100)),
            InfoItem(key: "Photos", value: "\(keyframes.count) at \(photo.width)×\(photo.height)"),
            InfoItem(key: "Point cloud", value: "\(pointCount.formatted()) points"),
            InfoItem(key: "Storage", value: folderSize(folder)),
        ]
        progress("Done", 1)
        return ProcessedScan(model: model, exports: exports, info: info)
    }

    private static func writeOBJ(mesh: MeshData, keyframes: [Keyframe], buckets: [[Int32]], objURL: URL, mtlURL: URL) throws {
        let N = mesh.positions.count
        let obj = try TextWriter(url: objURL)
        obj.write("# 3D Scanner textured LiDAR mesh. Units: metres, Y up.\nmtllib model.mtl\n")
        for p in mesh.positions { obj.write("v \(p.x) \(p.y) \(p.z)\n") }
        for n in mesh.normals { obj.write("vn \(n.x) \(n.y) \(n.z)\n") }

        var mtl = "# 3D Scanner materials\n"
        var stamp = [Int32](repeating: -1, count: N)
        var vtIndex = [Int32](repeating: 0, count: N)
        var vtCount: Int32 = 0

        for (k, faces) in buckets.enumerated() where !faces.isEmpty {
            if k < keyframes.count {
                let kf = keyframes[k]
                let name = (kf.file as NSString).deletingPathExtension
                mtl += "newmtl \(name)\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nmap_Kd \(kf.file)\n\n"
                let cam = kf.imageCamera
                // Texture coordinates: this photo's projection of each vertex.
                for t in faces {
                    for j in 0..<3 {
                        let v = Int(mesh.indices[3 * Int(t) + j])
                        if stamp[v] == Int32(k) { continue }
                        stamp[v] = Int32(k)
                        vtCount += 1
                        vtIndex[v] = vtCount
                        let (px, _) = cam.project(mesh.positions[v])
                        let u = min(max(px.x / cam.width, 0), 1), w = min(max(px.y / cam.height, 0), 1)
                        obj.write("vt \(u) \(1 - w)\n")
                    }
                }
                obj.write("usemtl \(name)\n")
                for t in faces {
                    let a = Int(mesh.indices[3 * Int(t)]), b = Int(mesh.indices[3 * Int(t) + 1]), c = Int(mesh.indices[3 * Int(t) + 2])
                    obj.write("f \(a + 1)/\(vtIndex[a])/\(a + 1) \(b + 1)/\(vtIndex[b])/\(b + 1) \(c + 1)/\(vtIndex[c])/\(c + 1)\n")
                }
            } else {
                mtl += "newmtl untextured\nKa 1 1 1\nKd 0.7 0.7 0.7\nKs 0 0 0\nillum 1\n\n"
                obj.write("usemtl untextured\n")
                for t in faces {
                    let a = Int(mesh.indices[3 * Int(t)]) + 1, b = Int(mesh.indices[3 * Int(t) + 1]) + 1, c = Int(mesh.indices[3 * Int(t) + 2]) + 1
                    obj.write("f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n")
                }
            }
        }
        obj.close()
        try mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
    }

    private static func writeColoredPLY(mesh: MeshData, colors: [SIMD3<Float>], keep: [Int32], to url: URL) throws {
        var out = BinaryBuffer()
        let header = """
        ply
        format binary_little_endian 1.0
        comment Created by 3D Scanner (metres, Y up)
        element vertex \(mesh.positions.count)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        property uchar red
        property uchar green
        property uchar blue
        element face \(keep.count)
        property list uchar int vertex_indices
        end_header

        """
        out.data.append(header.data(using: .ascii)!)
        out.data.reserveCapacity(mesh.positions.count * 27 + keep.count * 13 + 512)
        for i in 0..<mesh.positions.count {
            let p = mesh.positions[i], n = mesh.normals[i]
            let c = (colors[i] * 255).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))
            out.append(p.x); out.append(p.y); out.append(p.z)
            out.append(n.x); out.append(n.y); out.append(n.z)
            out.append(UInt8(c.x)); out.append(UInt8(c.y)); out.append(UInt8(c.z))
        }
        for t in keep {
            out.append(UInt8(3))
            out.append(Int32(mesh.indices[3 * Int(t)]))
            out.append(Int32(mesh.indices[3 * Int(t) + 1]))
            out.append(Int32(mesh.indices[3 * Int(t) + 2]))
        }
        try out.data.write(to: url)
    }
}
