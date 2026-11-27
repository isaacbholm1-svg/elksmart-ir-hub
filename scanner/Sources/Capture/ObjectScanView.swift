import RealityKit
import SwiftUI

/// Builds a textured model from the photos in a folder, on the device.
enum PhotogrammetryRunner {
    @MainActor
    static func run(images: URL, checkpoint: URL?, output: URL, progress: @escaping (Double) -> Void) async throws {
        guard PhotogrammetrySession.isSupported else {
            throw ScanError("This device can't build models itself. Export the photos and build the model on a computer (for example Reality Composer Pro, RealityScan or Meshroom).")
        }
        var config = PhotogrammetrySession.Configuration()
        if let checkpoint {
            try? FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
            config.checkpointDirectory = checkpoint
        }
        let session = try PhotogrammetrySession(input: images, configuration: config)
        try session.process(requests: [.modelFile(url: output, detail: .reduced)])
        for try await output in session.outputs {
            switch output {
            case .requestProgress(_, let fraction):
                progress(fraction)
            case .requestError(_, let error):
                throw error
            case .processingCancelled:
                throw ScanError("Model building was cancelled.")
            case .processingComplete:
                return
            default:
                break
            }
        }
    }

    @MainActor
    static func buildModel(for scan: ScanRecord, library: ScanLibrary, progress: @escaping (Double) -> Void) async throws -> ScanRecord {
        var s = scan
        let folder = library.folderURL(s)
        let images = folder.appendingPathComponent("Images", isDirectory: true)
        let output = folder.appendingPathComponent("model.usdz")
        s.status = "processing"
        library.save(s)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            try await run(images: images, checkpoint: folder.appendingPathComponent("Checkpoint"), output: output, progress: progress)
        } catch {
            s.status = "needsModel"
            s.message = error.localizedDescription
            library.save(s)
            throw error
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("Checkpoint"))
        s.status = "ready"
        s.message = nil
        s.model = "model.usdz"
        s.exports.removeAll { $0.path == "model.usdz" }
        s.exports.insert(ExportItem(label: "3D model (USDZ, textured)", path: "model.usdz"), at: 0)
        s.info.removeAll { $0.key == "Storage" }
        s.info.append(InfoItem(key: "Storage", value: folderSize(folder)))
        library.save(s)
        return s
    }
}

@MainActor
final class ObjectScanModel: ObservableObject {
    enum Phase: Equatable {
        case initializing, ready, detecting, capturing, finishing, completed
        case failed(String)
    }

    @Published var session: ObjectCaptureSession?
    @Published var phase = Phase.initializing
    @Published var shots = 0
    @Published var maxShots = 0
    @Published var passDone = false
    @Published var passes = 1
    @Published var feedback: [String] = []

    var onCompleted: (() -> Void)?
    private var timer: Timer?
    private var stateTask: Task<Void, Never>?

    func start(folder: URL) {
        let images = folder.appendingPathComponent("Images", isDirectory: true)
        let checkpoint = folder.appendingPathComponent("Checkpoint", isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)

        let session = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpoint
        session.start(imagesDirectory: images, configuration: config)
        self.session = session

        stateTask = Task { [weak self] in
            for await state in session.stateUpdates {
                self?.apply(state)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func apply(_ state: ObjectCaptureSession.CaptureState) {
        switch state {
        case .initializing: phase = .initializing
        case .ready: phase = .ready
        case .detecting: phase = .detecting
        case .capturing: phase = .capturing
        case .finishing: phase = .finishing
        case .completed:
            phase = .completed
            stop()
            onCompleted?()
        case .failed(let error):
            phase = .failed(error.localizedDescription)
            stop()
        @unknown default: break
        }
    }

    private func poll() {
        guard let session else { return }
        shots = session.numberOfShotsTaken
        maxShots = session.maximumNumberOfInputImages
        passDone = session.userCompletedScanPass
        feedback = session.feedback.map { prettyName("\($0)") }.sorted()
    }

    func newPass(flip: Bool) {
        guard let session else { return }
        if flip { session.beginNewScanPassAfterFlip() } else { session.beginNewScanPass() }
        passes += 1
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Guided object capture (Apple Object Capture) + on-device photogrammetry.
struct ObjectScanView: View {
    @EnvironmentObject var library: ScanLibrary
    let done: (Bool) -> Void

    @StateObject private var model = ObjectScanModel()
    @State private var scan: ScanRecord?
    @State private var building = false
    @State private var buildProgress = 0.0
    @State private var errorText: String?

    var body: some View {
        ZStack {
            if let session = model.session {
                ObjectCaptureView(session: session).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            if !building {
                CaptureChrome {
                    HStack {
                        Button("Cancel") { cancel() }
                        Spacer()
                        if model.phase == .capturing {
                            Text("Pass \(model.passes) · \(model.shots)/\(max(model.maxShots, model.shots)) photos")
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                } bottom: {
                    controls
                }
            }
            if building {
                ProcessingOverlay(title: "Building 3D model",
                                  detail: "Photogrammetry runs on your iPhone and can take several minutes. Keep the app open.",
                                  progress: buildProgress)
            }
        }
        .onAppear {
            guard scan == nil else { return }
            let s = library.create(kind: .object)
            scan = s
            model.onCompleted = { build() }
            model.start(folder: library.folderURL(s))
        }
        .alert("Couldn't build the model", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { done(true) }
        } message: {
            Text((errorText ?? "") + "\n\nYour photos are saved in the Library. You can try again there, or export them to build the model on a computer.")
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if !model.feedback.isEmpty {
                Text(model.feedback.joined(separator: " · ")).font(.footnote).foregroundStyle(.orange)
            }
            switch model.phase {
            case .initializing:
                ProgressView("Starting camera…")
            case .ready:
                Text("Put the object on a plain surface with room to walk around it, then point at it.")
                    .font(.subheadline).multilineTextAlignment(.center)
                Button("Continue") { _ = model.session?.startDetecting() }
                    .buttonStyle(.borderedProminent)
            case .detecting:
                Text("Drag the box edges so it fits the object snugly.")
                    .font(.subheadline).multilineTextAlignment(.center)
                HStack {
                    Button("Reset box") { model.session?.resetDetection() }
                        .buttonStyle(.bordered)
                    Button("Start capture") { model.session?.startCapturing() }
                        .buttonStyle(.borderedProminent)
                }
            case .capturing:
                if model.passDone {
                    Text("Pass complete! For a full model, flip the object over and scan its other side.")
                        .font(.subheadline).multilineTextAlignment(.center)
                    HStack {
                        Button("Flip & scan") { model.newPass(flip: true) }
                        Button("Scan again") { model.newPass(flip: false) }
                    }
                    .buttonStyle(.bordered)
                    Button("Finish & build model") { model.session?.finish() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Walk slowly all the way around. Go low, at eye level, then high.")
                        .font(.subheadline).multilineTextAlignment(.center)
                    Button("Finish early") { model.session?.finish() }
                        .buttonStyle(.bordered)
                        .disabled(model.shots < 20)
                }
            case .finishing:
                ProgressView("Saving photos…")
            case .completed:
                ProgressView("Preparing…")
            case .failed(let message):
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Close") { cancel() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func cancel() {
        model.stop()
        model.session?.cancel()
        if let scan { library.delete(scan) }
        done(false)
    }

    private func build() {
        guard var s = scan else { return }
        let folder = library.folderURL(s)
        let images = folder.appendingPathComponent("Images", isDirectory: true)
        let count = fileCount(in: images, extensions: ["heic", "jpg", "jpeg", "png"])
        s.status = "needsModel"
        s.info = [
            InfoItem(key: "Photos", value: "\(count)"),
            InfoItem(key: "Scan passes", value: "\(model.passes)"),
        ]
        s.exports = [ExportItem(label: "Photos for desktop photogrammetry (zip)", path: "Images")]
        library.save(s)
        scan = s
        // Free the capture session's memory before reconstruction.
        model.session = nil
        building = true
        Task {
            do {
                _ = try await PhotogrammetryRunner.buildModel(for: s, library: library) { buildProgress = $0 }
                done(true)
            } catch {
                building = false
                errorText = error.localizedDescription
            }
        }
    }
}
