import ARKit
import Combine
import RealityKit
import SwiftUI

/// Mesh copied out of ARKit's mesh anchors, in world space (metres, y up).
struct MeshData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    var faceClasses: [UInt8] = []
}

/// A photo kept for texturing, with its camera pose and the LiDAR depth seen at that moment.
struct Keyframe {
    var file: String
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    var width: Int
    var height: Int
    var depth: DepthSnapshot
    var depthTransform: simd_float4x4
    /// Intrinsics scaled to the depth map's resolution.
    var depthIntrinsics: simd_float3x3

    var imageCamera: PinholeCamera { PinholeCamera(transform: transform, intrinsics: intrinsics, width: width, height: height) }
    var depthCamera: PinholeCamera { PinholeCamera(transform: depthTransform, intrinsics: depthIntrinsics, width: depth.width, height: depth.height) }
}

/// Runs the LiDAR scan: live mesh, and keyframe photos taken automatically
/// whenever the phone has moved enough and is held steady.
final class MeshCapture: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published var message = "Starting…"
    @Published var keyframeCount = 0
    @Published var triangleCount = 0
    @Published var tooFast = false
    @Published var stage = ""
    @Published var progress = 0.0

    static let maxKeyframes = 400

    private(set) var keyframes: [Keyframe] = []
    private let writer = JPEGWriter()
    private var datasetFolder: URL!
    private var highRes = false
    private var accepting = false
    private var pendingHighRes = false
    private var lastKeyPose: simd_float4x4?
    private var lastKeyTime: TimeInterval = 0
    private var prevPose: simd_float4x4?
    private var prevTime: TimeInterval = 0
    private var lastStats: TimeInterval = 0

    override init() {
        super.init()
        arView.session.delegate = self
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.renderOptions.insert(.disableMotionBlur)
    }

    static var supportsHighRes: Bool {
        ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil
    }

    func start(datasetFolder: URL, highRes: Bool) {
        self.datasetFolder = datasetFolder
        try? FileManager.default.createDirectory(at: datasetFolder, withIntermediateDirectories: true)
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            ? .meshWithClassification : .mesh
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.environmentTexturing = .none
        config.worldAlignment = .gravity
        if highRes, let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
            self.highRes = true
        }
        accepting = true
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func cancel() {
        accepting = false
        arView.session.pause()
    }

    /// Stops scanning and returns the mesh plus every keyframe (all images written to disk).
    @MainActor
    func finish() async -> (MeshData, [Keyframe]) {
        accepting = false
        var waited = 0
        while pendingHighRes && waited < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let mesh = Self.extractMesh(anchors)
        arView.session.pause()
        await writer.drain()
        return (mesh, keyframes)
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        let pose = frame.camera.transform

        var linear: Float = 0, angular: Float = 0
        if let prev = prevPose, now > prevTime {
            let dt = Float(now - prevTime)
            linear = simd_distance(prev.position, pose.position) / dt
            angular = rotationAngle(prev, pose) / dt
        }
        prevPose = pose
        prevTime = now

        if now - lastStats > 0.5 {
            lastStats = now
            let tris = frame.anchors.reduce(0) { sum, anchor in
                sum + ((anchor as? ARMeshAnchor)?.geometry.faces.count ?? 0)
            }
            triangleCount = tris
            let tracking = trackingMessage(frame.camera.trackingState)
            message = tracking.isEmpty
                ? (keyframes.count >= Self.maxKeyframes ? "Photo limit reached. Tap Finish." : "Scanning. Cover every surface.")
                : tracking
        }
        tooFast = linear > 0.6 || angular > 1.0

        guard accepting, !pendingHighRes, keyframes.count < Self.maxKeyframes,
              case .normal = frame.camera.trackingState,
              now - lastKeyTime > 0.3,
              linear < 0.45, angular < 0.7,
              let depthData = frame.sceneDepth else { return }
        if let last = lastKeyPose {
            let moved = simd_distance(last.position, pose.position)
            let turned = rotationAngle(last, pose)
            guard moved > 0.12 || turned > 0.18 else { return }
        }
        lastKeyPose = pose
        lastKeyTime = now
        addKeyframe(frame: frame, depthData: depthData)
    }

    private func addKeyframe(frame: ARFrame, depthData: ARDepthData) {
        let depth = DepthSnapshot(depthData)
        let cam = frame.camera
        let w = Int(cam.imageResolution.width), h = Int(cam.imageResolution.height)
        let depthK = scaledIntrinsics(cam.intrinsics, sx: Float(depth.width) / Float(w), sy: Float(depth.height) / Float(h))
        let name = String(format: "kf_%04d.jpg", keyframes.count)
        let url = datasetFolder.appendingPathComponent(name)
        var keyframe = Keyframe(file: name, transform: cam.transform, intrinsics: cam.intrinsics, width: w, height: h,
                                depth: depth, depthTransform: cam.transform, depthIntrinsics: depthK)

        if highRes {
            pendingHighRes = true
            let fallback = frame.capturedImage
            arView.session.captureHighResolutionFrame { [weak self] hiFrame, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let hi = hiFrame {
                        keyframe.transform = hi.camera.transform
                        keyframe.intrinsics = hi.camera.intrinsics
                        keyframe.width = Int(hi.camera.imageResolution.width)
                        keyframe.height = Int(hi.camera.imageResolution.height)
                        self.writer.write(hi.capturedImage, to: url, quality: 0.92)
                    } else {
                        self.writer.write(fallback, to: url, quality: 0.92)
                    }
                    self.keyframes.append(keyframe)
                    self.keyframeCount = self.keyframes.count
                    self.pendingHighRes = false
                }
            }
        } else {
            writer.write(frame.capturedImage, to: url, quality: 0.92)
            keyframes.append(keyframe)
            keyframeCount = keyframes.count
        }
    }

    // MARK: Mesh extraction

    static func extractMesh(_ anchors: [ARMeshAnchor]) -> MeshData {
        var mesh = MeshData()
        for anchor in anchors {
            let g = anchor.geometry
            let base = UInt32(mesh.positions.count)
            let transform = anchor.transform
            let rotation = transform.rotation3x3

            let verts = g.vertices
            let vptr = verts.buffer.contents()
            let normals = g.normals
            let nptr = normals.buffer.contents()
            for i in 0..<verts.count {
                let v = vptr.advanced(by: verts.offset + verts.stride * i).assumingMemoryBound(to: Float.self)
                let world = transform * SIMD4(v[0], v[1], v[2], 1)
                mesh.positions.append(world.xyz)
                if i < normals.count {
                    let n = nptr.advanced(by: normals.offset + normals.stride * i).assumingMemoryBound(to: Float.self)
                    mesh.normals.append(simd_normalize(rotation * SIMD3(n[0], n[1], n[2])))
                } else {
                    mesh.normals.append(SIMD3(0, 1, 0))
                }
            }

            let faces = g.faces
            let fptr = faces.buffer.contents()
            let perFace = faces.indexCountPerPrimitive
            for f in 0..<faces.count {
                for k in 0..<3 {
                    let offset = (f * perFace + k) * faces.bytesPerIndex
                    let index: UInt32 = faces.bytesPerIndex == 4
                        ? fptr.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
                        : UInt32(fptr.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee)
                    mesh.indices.append(base + index)
                }
            }

            if let classes = g.classification {
                let cptr = classes.buffer.contents()
                for f in 0..<faces.count {
                    mesh.faceClasses.append(cptr.advanced(by: classes.offset + classes.stride * f).assumingMemoryBound(to: UInt8.self).pointee)
                }
            } else {
                mesh.faceClasses.append(contentsOf: repeatElement(0, count: faces.count))
            }
        }
        return mesh
    }
}
