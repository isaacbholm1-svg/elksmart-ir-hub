import ARKit
import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// LiDAR "space" scan: rooms, buildings, furniture, cars, anything bigger than a shoebox.
struct SpaceScanView: View {
    @EnvironmentObject var library: ScanLibrary
    let done: (Bool) -> Void

    @StateObject private var capture = MeshCapture()
    @State private var stage = Stage.setup
    @State private var ultra = false
    @State private var removeUntextured = false
    @State private var scan: ScanRecord?
    @State private var errorText: String?

    enum Stage { case setup, scanning, processing }

    var body: some View {
        ZStack {
            switch stage {
            case .setup:
                setup
            case .scanning, .processing:
                ARViewContainer(arView: capture.arView).ignoresSafeArea()
                if stage == .scanning { scanningHUD }
                if stage == .processing {
                    ProcessingOverlay(title: "Building textured model", detail: "\(capture.stage)\nKeep the app open.",
                                      progress: capture.progress)
                }
            }
        }
        .alert("Scan problem", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { done(true) }
        } message: {
            Text(errorText ?? "")
        }
    }

    private var setup: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Walk slowly around the space. The mesh appears as you go; photos for the texture are taken automatically whenever you've moved and the phone is steady.")
                    Text("Stay 0.5–4 m from surfaces and look at everything from a couple of angles, including the floor and ceiling.")
                        .foregroundStyle(.secondary)
                }
                Section("Quality") {
                    Toggle("Ultra textures (high-res stills)", isOn: $ultra)
                        .disabled(!MeshCapture.supportsHighRes)
                    Text(MeshCapture.supportsHighRes
                         ? "Uses full-resolution photos for much sharper textures. Takes more storage and the preview may stutter."
                         : "This device can't take high-resolution stills during a scan.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Remove untextured surfaces", isOn: $removeUntextured)
                    Text("Drops bits of mesh no photo saw clearly (often noise at the edges).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        start()
                    } label: {
                        Label("Start scanning", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Space scan")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { done(false) } } }
        }
    }

    private var scanningHUD: some View {
        CaptureChrome {
            HStack {
                Button("Cancel") { cancel() }
                Spacer()
                Text(capture.message).font(.subheadline).multilineTextAlignment(.trailing)
            }
        } bottom: {
            VStack(spacing: 10) {
                if capture.tooFast {
                    Label("Slow down for sharper textures", systemImage: "tortoise.fill").foregroundStyle(.orange)
                }
                HStack(spacing: 18) {
                    Label("\(capture.keyframeCount)", systemImage: "photo")
                    Label(capture.triangleCount.formatted(), systemImage: "triangle")
                }
                .font(.subheadline.monospacedDigit())
                Button {
                    finish()
                } label: {
                    Text("Finish").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(capture.keyframeCount < 3)
            }
        }
    }

    private func start() {
        let s = library.create(kind: .space)
        scan = s
        capture.start(datasetFolder: library.folderURL(s).appendingPathComponent("dataset"), highRes: ultra)
        stage = .scanning
    }

    private func cancel() {
        capture.cancel()
        if let scan { library.delete(scan) }
        done(false)
    }

    private func finish() {
        guard var s = scan else { return }
        stage = .processing
        s.status = "processing"
        library.save(s)
        let folder = library.folderURL(s)
        let cap = capture
        let options = MeshProcessingOptions(removeUntextured: removeUntextured)
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            let (mesh, keyframes) = await cap.finish()
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try MeshProcessor.run(mesh: mesh, keyframes: keyframes, folder: folder, datasetName: "dataset",
                                          options: options) { stage, value in
                        DispatchQueue.main.async {
                            cap.stage = stage
                            cap.progress = value
                        }
                    }
                }.value
                s.status = "ready"
                s.model = result.model
                s.exports = result.exports
                s.info = result.info
                library.save(s)
                UIApplication.shared.isIdleTimerDisabled = false
                done(true)
            } catch {
                s.status = "failed"
                s.message = error.localizedDescription
                library.save(s)
                UIApplication.shared.isIdleTimerDisabled = false
                errorText = error.localizedDescription
            }
        }
    }
}
