import Foundation
import SwiftUI

enum ScanKind: String, Codable, CaseIterable, Identifiable {
    case object, space, room, photos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .object: return "Object"
        case .space: return "Space"
        case .room: return "Room Plan"
        case .photos: return "Photo Dataset"
        }
    }

    var icon: String {
        switch self {
        case .object: return "cube"
        case .space: return "cube.transparent"
        case .room: return "house"
        case .photos: return "camera.on.rectangle"
        }
    }

    var summary: String {
        switch self {
        case .object:
            return "Guided photo capture of an object, built into a photo-real textured 3D model on your iPhone."
        case .space:
            return "LiDAR scan of rooms, buildings, furniture or anything big. Textured mesh, point cloud, measurements."
        case .room:
            return "Walk through one or more rooms to get a clean 3D floor plan with walls, doors, windows, furniture and area."
        case .photos:
            return "Pose-tracked photos (plus LiDAR points) for Gaussian splats, NeRF or full-detail photogrammetry on a computer."
        }
    }

    var requirement: String {
        switch self {
        case .object, .space, .room: return "Needs a LiDAR iPhone / iPad (Pro models)."
        case .photos: return "Works on any recent iPhone. LiDAR adds a depth point cloud."
        }
    }
}

struct InfoItem: Codable, Hashable {
    var key: String
    var value: String
}

struct ExportItem: Codable, Hashable {
    var label: String
    /// File or folder inside the scan folder. Folders are zipped when shared.
    var path: String
}

struct ScanRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: ScanKind
    var folder: String
    var created = Date()
    /// capturing, processing, ready, needsModel, failed
    var status = "capturing"
    var message: String?
    /// Main 3D file shown in the viewer, relative to the scan folder.
    var model: String?
    var floorPlan: String?
    var info: [InfoItem] = []
    var exports: [ExportItem] = []
}

struct ScanError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Scans live in Documents/Scans/<name>/ with a scan.json next to the files,
/// so they also show up in the Files app (On My iPhone → 3D Scanner).
@MainActor
final class ScanLibrary: ObservableObject {
    @Published private(set) var scans: [ScanRecord] = []
    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func folderURL(_ scan: ScanRecord) -> URL {
        root.appendingPathComponent(scan.folder, isDirectory: true)
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        scans = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("scan.json")) else { return nil }
            return try? JSONDecoder().decode(ScanRecord.self, from: data)
        }
        .sorted { $0.created > $1.created }
    }

    func create(kind: ScanKind) -> ScanRecord {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var folder = "\(kind.title) \(stamp)"
        var n = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path) {
            folder = "\(kind.title) \(stamp) (\(n))"
            n += 1
        }
        let scan = ScanRecord(name: "\(kind.title) \(stamp)", kind: kind, folder: folder)
        try? FileManager.default.createDirectory(at: folderURL(scan), withIntermediateDirectories: true)
        save(scan)
        return scan
    }

    func save(_ scan: ScanRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(scan) {
            try? data.write(to: folderURL(scan).appendingPathComponent("scan.json"), options: .atomic)
        }
        if let i = scans.firstIndex(where: { $0.id == scan.id }) {
            scans[i] = scan
        } else {
            scans.insert(scan, at: 0)
        }
    }

    func delete(_ scan: ScanRecord) {
        try? FileManager.default.removeItem(at: folderURL(scan))
        scans.removeAll { $0.id == scan.id }
    }
}
