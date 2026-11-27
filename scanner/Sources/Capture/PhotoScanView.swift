import ARKit
import RealityKit
import SwiftUI

/// Takes pose-tracked photos (auto or manual) and writes a ready-to-train dataset:
/// images + transforms.json (nerfstudio format) + points3D.ply from LiDAR.
final class PhotoCapture: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published var count = 0
    @Published var auto = true
    @Published var message = "Starting…"
    @Published var flash = false
    @Published var resolution = ""
    @Published var hasDepth = false

    private(set) var frames: [CameraFrame] = []
    let points = PointAccumulator(voxel: 0.01)
    private let writer = JPEGWriter()
    private var folder: URL!
    private var highRes = false
    private var pending = false
    private var accepting = false
    private var shutter = false
    private var lastPose: simd_float4x4?
    private var lastTime: TimeInterval = 0
    private var prevPose: simd_float4x4?
    private var prevTime: TimeInterval = 0
    private var lastStats: TimeInterval = 0

    static var supportsHighRes: Bool { MeshCapture.supportsHighRes }

    override init() {
        super.init()
        arView.session.delegate = self
        arView.renderOptions.insert(.disableMotionBlur)
    }

    func start(folder: URL, highRes: Bool) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            hasDepth = true
        }
        if highRes, let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
            self.highRes = true
        }
        accepting = true
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func takePhoto() { shutter = true }

    func cancel() {
        accepting = false
        arView.session.pause()
    }

    @MainActor
    func finish() async -> [CameraFrame] {
        accepting = false
        var waited = 0
        while pending && waited < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        arView.session.pause()
        await writer.drain()
        return frames
    }

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

        let tracking = trackingMessage(frame.camera.trackingState)
        if now - lastStats > 0.4 {
            lastStats = now
            if !tracking.isEmpty {
                message = tracking
            } else if linear > 0.4 || angular > 0.6 {
                message = "Slow down for sharp photos"
            } else {
                message = auto ? "Move around the subject. Photos are taken automatically." : "Tap the shutter for each photo."
            }
        }

        guard accepting, !pending, case .normal = frame.camera.trackingState else { return }
        var take = false
        if shutter {
            take = true
            shutter = false
        } else if auto, now - lastTime > 0.35, linear < 0.35, angular < 0.5 {
            if let last = lastPose {
                take = simd_distance(last.position, pose.position) > 0.08 || rotationAngle(last, pose) > 0.12
            } else {
                take = true
            }
        }
        guard take else { return }
        lastPose = pose
        lastTime = now
        capture(frame)
    }

    private func capture(_ frame: ARFrame) {
        let index = frames.count
        let name = String(format: "frame_%05d.jpg", index)
        let url = folder.appendingPathComponent(name)

        // LiDAR points for this view, coloured from the same frame.
        if let depthData = frame.sceneDepth {
            let depth = DepthSnapshot(depthData)
            let cam = frame.camera
            let w = Int(cam.imageResolution.width), h = Int(cam.imageResolution.height)
            let dk = scaledIntrinsics(cam.intrinsics, sx: Float(depth.width) / Float(w), sy: Float(depth.height) / Float(h))
            let dcam = PinholeCamera(transform: cam.transform, intrinsics: dk, width: depth.width, height: depth.height)
            let points = self.points
            _ = YCbCrImage.with(frame.capturedImage) { image in
                let sx = Float(image.width) / Float(depth.width), sy = Float(image.height) / Float(depth.height)
                var y = 0
                while y < depth.height {
                    var x = 0
                    while x < depth.width {
                        let i = y * depth.width + x
                        let d = depth.depth[i]
                        if depth.confidence[i] >= 2, d > 0.1, d < 5 {
                            let pc = dcam.unprojectToCamera(px: Float(x) + 0.5, py: Float(y) + 0.5, depth: d)
                            let world = (cam.transform * pc).xyz
                            let color = image.rgb(x: Int((Float(x) + 0.5) * sx), y: Int((Float(y) + 0.5) * sy))
                            points.add(world, color: color)
                        }
                        x += 3
                    }
                    y += 3
                }
            }
        }

        func record(_ cam: ARCamera) {
            let w = Int(cam.imageResolution.width), h = Int(cam.imageResolution.height)
            frames.append(CameraFrame(file: name, transform: cam.transform, intrinsics: cam.intrinsics, width: w, height: h))
            count = frames.count
            resolution = "\(w)×\(h)"
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.flash = false }
        }

        if highRes {
            pending = true
            let fallback = frame.capturedImage
            let fallbackCamera = frame.camera
            arView.session.captureHighResolutionFrame { [weak self] hi, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let hi {
                        self.writer.write(hi.capturedImage, to: url, quality: 0.93)
                        record(hi.camera)
                    } else {
                        self.writer.write(fallback, to: url, quality: 0.93)
                        record(fallbackCamera)
                    }
                    self.pending = false
                }
            }
        } else {
            writer.write(frame.capturedImage, to: url, quality: 0.93)
            record(frame.camera)
        }
    }
}

struct PhotoScanView: View {
    @EnvironmentObject var library: ScanLibrary
    let done: (Bool) -> Void

    @StateObject private var capture = PhotoCapture()
    @State private var stage = Stage.setup
    @State private var highRes = PhotoCapture.supportsHighRes
    @State private var scan: ScanRecord?

    enum Stage { case setup, scanning, saving }

    var body: some View {
        ZStack {
            switch stage {
            case .setup:
                setup
            case .scanning, .saving:
                ARViewContainer(arView: capture.arView).ignoresSafeArea()
                if capture.flash { Color.white.opacity(0.35).ignoresSafeArea().allowsHitTesting(false) }
                if stage == .scanning { hud }
                if stage == .saving { ProcessingOverlay(title: "Saving dataset", detail: "Writing photos, poses and point cloud…", progress: nil) }
            }
        }
    }

    private var setup: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Captures sharp, overlapping photos with the exact camera position of each one, plus a LiDAR point cloud when available.")
                    Text("Use it to train a Gaussian splat or NeRF (nerfstudio, Brush, gsplat, Postshot…) or for full-detail photogrammetry on a computer.")
                        .foregroundStyle(.secondary)
                }
                Section("Quality") {
                    Toggle("High-resolution stills", isOn: $highRes).disabled(!PhotoCapture.supportsHighRes)
                    Text("For objects: circle them at 2–3 heights. For rooms: walk the edges, facing inward and outward. Aim for 100–300 photos.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        let s = library.create(kind: .photos)
                        scan = s
                        capture.start(folder: library.folderURL(s).appendingPathComponent("dataset"), highRes: highRes)
                        stage = .scanning
                    } label: {
                        Label("Start", systemImage: "camera").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Photo dataset")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { done(false) } } }
        }
    }

    private var hud: some View {
        CaptureChrome {
            HStack {
                Button("Cancel") {
                    capture.cancel()
                    if let scan { library.delete(scan) }
                    done(false)
                }
                Spacer()
                Text(capture.message).font(.subheadline).multilineTextAlignment(.trailing)
            }
        } bottom: {
            VStack(spacing: 12) {
                HStack {
                    Label("\(capture.count) photos", systemImage: "photo.stack").monospacedDigit()
                    Spacer()
                    Toggle("Auto", isOn: $capture.auto).fixedSize()
                }
                HStack(spacing: 30) {
                    Spacer()
                    Button {
                        capture.takePhoto()
                    } label: {
                        Circle().strokeBorder(.white, lineWidth: 4)
                            .background(Circle().fill(.white.opacity(0.85)).padding(7))
                            .frame(width: 72, height: 72)
                    }
                    Button("Finish") { finish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(capture.count < 5)
                    Spacer()
                }
            }
        }
    }

    private func finish() {
        guard var s = scan else { return }
        stage = .saving
        let folder = library.folderURL(s)
        let dataset = folder.appendingPathComponent("dataset")
        let cap = capture
        Task {
            let frames = await cap.finish()
            let pointCount = await Task.detached { () -> Int in
                let n = (try? cap.points.writePLY(to: dataset.appendingPathComponent("points3D.ply"))) ?? 0
                try? DatasetWriter.writeTransforms(frames: frames, plyFile: n > 0 ? "points3D.ply" : nil,
                                                   to: dataset.appendingPathComponent("transforms.json"))
                return n
            }.value
            s.status = "ready"
            s.model = pointCount > 0 ? "dataset/points3D.ply" : nil
            s.info = [
                InfoItem(key: "Photos", value: "\(frames.count) at \(cap.resolution)"),
                InfoItem(key: "LiDAR points", value: pointCount > 0 ? pointCount.formatted() : "none (no LiDAR)"),
                InfoItem(key: "Format", value: "nerfstudio transforms.json (OpenGL camera axes, metres)"),
                InfoItem(key: "Storage", value: folderSize(folder)),
            ]
            s.exports = [
                ExportItem(label: "Dataset: photos + poses + points (zip)", path: "dataset"),
                ExportItem(label: "Camera poses (transforms.json)", path: "dataset/transforms.json"),
            ]
            if pointCount > 0 {
                s.exports.append(ExportItem(label: "LiDAR point cloud (PLY)", path: "dataset/points3D.ply"))
            }
            library.save(s)
            done(true)
        }
    }
}
