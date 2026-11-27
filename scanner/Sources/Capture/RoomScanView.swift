import RoomPlan
import SwiftUI

/// Drives RoomPlan. Several rooms can be scanned in one session: the AR session
/// keeps running between rooms so they line up, then StructureBuilder merges them.
final class RoomScanModel: NSObject, ObservableObject, RoomCaptureViewDelegate {
    let captureView = RoomCaptureView(frame: .zero)
    @Published var rooms: [CapturedRoom] = []
    @Published var busy = false
    @Published var status = "Point at the walls and walk slowly around the room. Open doors and look into corners."

    private enum Pending { case none, next, finish }
    private var pending = Pending.none
    var onFinish: (([CapturedRoom]) -> Void)?

    override init() {
        super.init()
        captureView.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func encode(with coder: NSCoder) {}

    func start() {
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func nextRoom() {
        pending = .next
        busy = true
        status = "Saving this room…"
        captureView.captureSession.stop(pauseARSession: false)
    }

    func finish() {
        pending = .finish
        busy = true
        status = "Finishing…"
        captureView.captureSession.stop()
    }

    func cancel() {
        pending = .none
        captureView.captureSession.stop()
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if error == nil {
            rooms.append(processedResult)
        }
        switch pending {
        case .next:
            pending = .none
            busy = false
            status = "Room \(rooms.count) saved. Walk into the next room and keep scanning."
            captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        case .finish:
            pending = .none
            onFinish?(rooms)
        case .none:
            break
        }
    }
}

struct RoomCaptureContainer: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct RoomScanView: View {
    @EnvironmentObject var library: ScanLibrary
    let done: (Bool) -> Void

    @StateObject private var model = RoomScanModel()
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            RoomCaptureContainer(view: model.captureView).ignoresSafeArea()
            if !saving {
                CaptureChrome {
                    HStack {
                        Button("Cancel") {
                            model.cancel()
                            done(false)
                        }
                        Spacer()
                        Text(model.rooms.isEmpty ? "Room 1" : "Room \(model.rooms.count + 1) · \(model.rooms.count) saved")
                            .font(.subheadline.monospacedDigit())
                    }
                } bottom: {
                    VStack(spacing: 10) {
                        Text(model.status).font(.footnote).multilineTextAlignment(.center)
                        HStack {
                            Button {
                                model.nextRoom()
                            } label: {
                                Label("Next room", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Button {
                                model.finish()
                            } label: {
                                Text("Finish").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .disabled(model.busy)
                    }
                }
            }
            if saving {
                ProcessingOverlay(title: "Building floor plan", detail: "Merging rooms and exporting the model…", progress: nil)
            }
        }
        .onAppear {
            model.onFinish = { rooms in save(rooms) }
            model.start()
        }
        .alert("Room scan problem", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { done(false) }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func save(_ rooms: [CapturedRoom]) {
        guard !rooms.isEmpty else {
            errorText = "Nothing was captured. Try again with more light and move more slowly."
            return
        }
        saving = true
        var scan = library.create(kind: .room)
        let folder = library.folderURL(scan)
        Task {
            do {
                let result = try await RoomExporter.export(rooms: rooms, to: folder)
                scan.status = "ready"
                scan.model = result.model
                scan.floorPlan = result.floorPlan
                scan.info = result.info
                scan.exports = result.exports
                library.save(scan)
                done(true)
            } catch {
                library.delete(scan)
                saving = false
                errorText = error.localizedDescription
            }
        }
    }
}
