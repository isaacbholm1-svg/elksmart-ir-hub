import QuickLook
import SceneKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: ScanLibrary

    var body: some View {
        NavigationStack {
            Group {
                if library.scans.isEmpty {
                    ContentUnavailableView("No scans yet", systemImage: "cube.transparent",
                                           description: Text("Your scans show up here, and in the Files app under On My iPhone → 3D Scanner."))
                } else {
                    List {
                        ForEach(library.scans) { scan in
                            NavigationLink(value: scan.id) { ScanRow(scan: scan) }
                        }
                        .onDelete { offsets in
                            offsets.map { library.scans[$0] }.forEach(library.delete)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: UUID.self) { id in ScanDetailView(scanID: id) }
            .refreshable { library.reload() }
        }
    }
}

struct ScanRow: View {
    let scan: ScanRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: scan.kind.icon)
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name).font(.headline).lineLimit(1)
                Text("\(scan.kind.title) · \(scan.created.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if scan.status != "ready" {
                    Text(statusText(scan)).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

func statusText(_ scan: ScanRecord) -> String {
    switch scan.status {
    case "capturing": return "Unfinished capture"
    case "processing": return "Processing was interrupted"
    case "needsModel": return "Photos saved, model not built yet"
    case "failed": return "Failed: \(scan.message ?? "unknown error")"
    default: return scan.status
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ScanDetailView: View {
    @EnvironmentObject var library: ScanLibrary
    @Environment(\.dismiss) private var dismiss
    let scanID: UUID

    @State private var share: ShareItem?
    @State private var quickLook: URL?
    @State private var preparing = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var building = false
    @State private var buildProgress = 0.0
    @State private var errorText: String?

    private var scan: ScanRecord? { library.scans.first { $0.id == scanID } }

    var body: some View {
        if let scan {
            content(scan)
        } else {
            ContentUnavailableView("Scan deleted", systemImage: "trash")
        }
    }

    private func content(_ scan: ScanRecord) -> some View {
        let folder = library.folderURL(scan)
        return VStack(spacing: 0) {
            if let model = scan.model {
                ModelViewer(url: folder.appendingPathComponent(model))
                    .frame(height: 340)
                    .overlay(alignment: .bottomTrailing) {
                        Text("Drag to orbit · pinch to zoom")
                            .font(.caption2).padding(6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
            }
            List {
                if model3DIsUSDZ(scan) {
                    Button {
                        quickLook = folder.appendingPathComponent(scan.model!)
                    } label: {
                        Label("View in AR", systemImage: "arkit")
                    }
                }
                if let plan = scan.floorPlan, let image = UIImage(contentsOfFile: folder.appendingPathComponent(plan).path) {
                    Section("Floor plan") {
                        Image(uiImage: image).resizable().scaledToFit()
                            .onTapGesture { quickLook = folder.appendingPathComponent(plan) }
                    }
                }
                if scan.status != "ready" {
                    Section { Text(statusText(scan)).foregroundStyle(.orange) }
                }
                if scan.kind == .object && scan.model == nil {
                    Section {
                        if building {
                            ProgressView(value: buildProgress) { Text("Building model… keep the app open") }
                        } else {
                            Button {
                                build(scan)
                            } label: {
                                Label("Build 3D model on this device", systemImage: "cube.fill")
                            }
                        }
                    }
                }
                if !scan.info.isEmpty {
                    Section("Details") {
                        ForEach(scan.info, id: \.self) { item in
                            LabeledContent(item.key, value: item.value)
                        }
                    }
                }
                Section {
                    ForEach(scan.exports, id: \.self) { item in
                        Button {
                            export(item, scan: scan)
                        } label: {
                            Label(item.label, systemImage: "square.and.arrow.up")
                        }
                        .disabled(preparing)
                    }
                    if preparing { ProgressView("Preparing file…") }
                } header: {
                    Text("Export")
                } footer: {
                    Text("Everything is also in the Files app: On My iPhone → 3D Scanner → Scans → \(scan.folder).")
                }
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button {
                    newName = scan.name
                    renaming = true
                } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .sheet(item: $share) { item in ShareSheet(items: [item.url]) }
        .quickLookPreview($quickLook)
        .alert("Rename scan", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                var s = scan
                s.name = newName.trimmingCharacters(in: .whitespaces).isEmpty ? s.name : newName
                library.save(s)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this scan and all its files?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(scan)
                dismiss()
            }
        }
        .alert("Problem", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func model3DIsUSDZ(_ scan: ScanRecord) -> Bool {
        scan.model?.lowercased().hasSuffix(".usdz") ?? false
    }

    private func export(_ item: ExportItem, scan: ScanRecord) {
        let url = library.folderURL(scan).appendingPathComponent(item.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            errorText = "That file is missing."
            return
        }
        if !isDir.boolValue {
            share = ShareItem(url: url)
            return
        }
        preparing = true
        let name = "\(scan.name) - \(url.lastPathComponent)".replacingOccurrences(of: "/", with: "-")
        Task.detached {
            let result = Result { try Zipper.zip(folder: url, named: name) }
            await MainActor.run {
                preparing = false
                switch result {
                case .success(let zip): share = ShareItem(url: zip)
                case .failure(let error): errorText = error.localizedDescription
                }
            }
        }
    }

    private func build(_ scan: ScanRecord) {
        building = true
        Task {
            do {
                _ = try await PhotogrammetryRunner.buildModel(for: scan, library: library) { buildProgress = $0 }
            } catch {
                errorText = error.localizedDescription
            }
            building = false
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
