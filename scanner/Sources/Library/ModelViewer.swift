import SceneKit
import SwiftUI

/// Orbitable 3D preview. Loads USDZ / OBJ through SceneKit, and our PLY point
/// clouds with a small reader (SceneKit doesn't draw PLY points by itself).
struct ModelViewer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .secondarySystemBackground
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        load(into: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    private func load(into view: SCNView) {
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async {
            let scene: SCNScene?
            if url.pathExtension.lowercased() == "ply" {
                scene = PointCloudLoader.scene(from: url)
            } else {
                scene = try? SCNScene(url: url, options: [.checkConsistency: false])
                scene?.rootNode.enumerateHierarchy { node, _ in
                    node.geometry?.materials.forEach { m in
                        m.isDoubleSided = true
                        // Scans already contain real lighting in their photos.
                        if m.diffuse.contents != nil { m.lightingModel = .constant }
                    }
                }
            }
            DispatchQueue.main.async {
                view.scene = scene ?? SCNScene()
                frame(view)
            }
        }
    }

    /// Points the camera at the whole model.
    private func frame(_ view: SCNView) {
        guard let scene = view.scene else { return }
        let (minV, maxV) = scene.rootNode.boundingBox
        let center = SCNVector3((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2)
        let size = max(maxV.x - minV.x, maxV.y - minV.y, maxV.z - minV.z)
        guard size.isFinite, size > 0 else { return }
        let camera = SCNCamera()
        camera.zNear = Double(size) * 0.01
        camera.zFar = Double(size) * 20
        camera.fieldOfView = 50
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(center.x + size * 0.9, center.y + size * 0.7, center.z + size * 1.1)
        node.look(at: center)
        scene.rootNode.addChildNode(node)
        view.pointOfView = node
        view.defaultCameraController.target = center
    }
}

enum PointCloudLoader {
    /// Reads the binary PLY files this app writes (x y z float, red green blue uchar).
    static func scene(from url: URL, maxPoints: Int = 1_500_000) -> SCNScene? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let headerEnd = data.range(of: Data("end_header\n".utf8)) else { return nil }
        let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        guard header.contains("binary_little_endian"),
              let line = header.split(separator: "\n").first(where: { $0.hasPrefix("element vertex") }),
              let count = Int(line.split(separator: " ").last ?? "") else { return nil }
        let stride = 15
        let start = headerEnd.upperBound
        guard data.count >= start + count * stride, count > 0 else { return nil }
        let step = max(1, count / maxPoints)

        var positions: [SCNVector3] = []
        var colors: [Float] = []
        positions.reserveCapacity(count / step)
        colors.reserveCapacity(count / step * 3)
        data.withUnsafeBytes { raw in
            var i = 0
            while i < count {
                let o = start + i * stride
                let x = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                let y = raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self)
                let z = raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)
                positions.append(SCNVector3(x, y, z))
                colors.append(Float(raw[o + 12]) / 255)
                colors.append(Float(raw[o + 13]) / 255)
                colors.append(Float(raw[o + 14]) / 255)
                i += step
            }
        }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: positions.count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                            dataStride: MemoryLayout<Float>.size * 3)
        let indices = (0..<UInt32(positions.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 2
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 4
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.materials = [material]

        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        return scene
    }
}
