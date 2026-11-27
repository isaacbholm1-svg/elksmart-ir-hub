import RoomPlan
import UIKit
import simd

struct RoomExportResult {
    var model: String?
    var floorPlan: String?
    var info: [InfoItem]
    var exports: [ExportItem]
}

/// Plain copy of the parts of a RoomPlan result the floor plan needs.
private struct PlanInput {
    var walls: [CapturedRoom.Surface]
    var doors: [CapturedRoom.Surface]
    var windows: [CapturedRoom.Surface]
    var openings: [CapturedRoom.Surface]
    var floors: [CapturedRoom.Surface]
    var objects: [CapturedRoom.Object]
}

enum RoomExporter {
    @MainActor
    static func export(rooms: [CapturedRoom], to folder: URL) async throws -> RoomExportResult {
        let usdz = folder.appendingPathComponent("room.usdz")
        var exports: [ExportItem] = []
        var plan: PlanInput
        var roomCount = rooms.count

        do {
            let builder = StructureBuilder(options: [.beautifyObjects])
            let structure = try await builder.capturedStructure(from: rooms)
            try structure.export(to: usdz)
            plan = PlanInput(walls: structure.walls, doors: structure.doors, windows: structure.windows,
                             openings: structure.openings, floors: structure.floors, objects: structure.objects)
            roomCount = structure.rooms.count
            if let json = try? JSONEncoder().encode(structure) {
                try? json.write(to: folder.appendingPathComponent("room.json"))
            }
        } catch {
            // Fall back to the first room on its own.
            let room = rooms[0]
            try room.export(to: usdz)
            plan = PlanInput(walls: room.walls, doors: room.doors, windows: room.windows,
                             openings: room.openings, floors: room.floors, objects: room.objects)
            roomCount = 1
            if let json = try? JSONEncoder().encode(room) {
                try? json.write(to: folder.appendingPathComponent("room.json"))
            }
        }
        exports.append(ExportItem(label: "3D floor plan model (USDZ)", path: "room.usdz"))

        // Measurements.
        var floorArea: Float = 0
        for floor in plan.floors {
            floorArea += polygonArea(worldCorners(floor))
        }
        let heights = plan.walls.map { $0.dimensions.y }.filter { $0 > 0.5 }
        let wallLength = plan.walls.reduce(Float(0)) { $0 + $1.dimensions.x }
        var objectCounts: [String: Int] = [:]
        for o in plan.objects { objectCounts[prettyName("\(o.category)"), default: 0] += 1 }

        var info = [InfoItem(key: "Rooms", value: "\(roomCount)")]
        if floorArea > 0 {
            info.append(InfoItem(key: "Floor area", value: String(format: "%.1f m² (%.0f ft²)", floorArea, floorArea * 10.7639)))
        }
        if !heights.isEmpty {
            info.append(InfoItem(key: "Ceiling height", value: formatMeters(heights.reduce(0, +) / Float(heights.count))))
        }
        info.append(InfoItem(key: "Walls", value: "\(plan.walls.count) (\(String(format: "%.1f", wallLength)) m total)"))
        info.append(InfoItem(key: "Doors / windows / openings", value: "\(plan.doors.count) / \(plan.windows.count) / \(plan.openings.count)"))
        if !objectCounts.isEmpty {
            info.append(InfoItem(key: "Furniture", value: objectCounts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")))
        }

        var floorPlan: String?
        if let png = renderFloorPlan(plan, area: floorArea).pngData() {
            try png.write(to: folder.appendingPathComponent("floorplan.png"))
            floorPlan = "floorplan.png"
            exports.append(ExportItem(label: "Floor plan with measurements (PNG)", path: "floorplan.png"))
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("room.json").path) {
            exports.append(ExportItem(label: "Room data: walls, doors, furniture (JSON)", path: "room.json"))
        }
        return RoomExportResult(model: "room.usdz", floorPlan: floorPlan, info: info, exports: exports)
    }

    // MARK: Geometry helpers

    private static func worldCorners(_ s: CapturedRoom.Surface) -> [SIMD2<Float>] {
        s.polygonCorners.map { c in
            let w = s.transform * SIMD4(c, 1)
            return SIMD2(w.x, w.z)
        }
    }

    private static func polygonArea(_ p: [SIMD2<Float>]) -> Float {
        guard p.count >= 3 else { return 0 }
        var a: Float = 0
        for i in 0..<p.count {
            let j = (i + 1) % p.count
            a += p[i].x * p[j].y - p[j].x * p[i].y
        }
        return abs(a) / 2
    }

    /// The two ends of a wall / door / window seen from above (x, z).
    private static func segment(_ s: CapturedRoom.Surface) -> (SIMD2<Float>, SIMD2<Float>) {
        let c = s.transform.position
        let axis = s.transform.columns.0.xyz
        let h = s.dimensions.x / 2
        let a = c - axis * h, b = c + axis * h
        return (SIMD2(a.x, a.z), SIMD2(b.x, b.z))
    }

    private static func footprint(_ o: CapturedRoom.Object) -> [SIMD2<Float>] {
        let c = o.transform.position
        let ax = o.transform.columns.0.xyz * (o.dimensions.x / 2)
        let az = o.transform.columns.2.xyz * (o.dimensions.z / 2)
        return [c - ax - az, c + ax - az, c + ax + az, c - ax + az].map { SIMD2($0.x, $0.z) }
    }

    // MARK: Drawing

    private static func renderFloorPlan(_ plan: PlanInput, area: Float) -> UIImage {
        var pts: [SIMD2<Float>] = []
        for w in plan.walls { let (a, b) = segment(w); pts += [a, b] }
        for f in plan.floors { pts += worldCorners(f) }
        for o in plan.objects { pts += footprint(o) }
        if pts.isEmpty { pts = [SIMD2(0, 0), SIMD2(1, 1)] }
        let lo = pts.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = pts.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let span = simd_max(hi - lo, SIMD2(repeating: 0.5))

        let margin: CGFloat = 140
        let maxSide: CGFloat = 2200
        let scale = min((maxSide - 2 * margin) / CGFloat(span.x), (maxSide - 2 * margin) / CGFloat(span.y))
        let size = CGSize(width: CGFloat(span.x) * scale + 2 * margin, height: CGFloat(span.y) * scale + 2 * margin + 80)
        func map(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: CGFloat(p.x - lo.x) * scale + margin, y: CGFloat(p.y - lo.y) * scale + margin + 80)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Floors.
            UIColor(white: 0.94, alpha: 1).setFill()
            for f in plan.floors {
                let c = worldCorners(f).map(map)
                guard c.count >= 3 else { continue }
                let path = UIBezierPath()
                path.move(to: c[0])
                c.dropFirst().forEach { path.addLine(to: $0) }
                path.close()
                path.fill()
            }

            // Furniture.
            let labelFont = UIFont.systemFont(ofSize: 22, weight: .medium)
            for o in plan.objects {
                let c = footprint(o).map(map)
                let path = UIBezierPath()
                path.move(to: c[0])
                c.dropFirst().forEach { path.addLine(to: $0) }
                path.close()
                UIColor(red: 0.85, green: 0.9, blue: 1, alpha: 1).setFill()
                path.fill()
                UIColor(red: 0.45, green: 0.55, blue: 0.8, alpha: 1).setStroke()
                path.lineWidth = 2
                path.stroke()
                let center = map(SIMD2(o.transform.position.x, o.transform.position.z))
                drawText(prettyName("\(o.category)"), at: center, font: labelFont, color: UIColor(red: 0.25, green: 0.3, blue: 0.5, alpha: 1))
            }

            // Walls.
            cg.setLineCap(.square)
            for w in plan.walls {
                let (a, b) = segment(w)
                strokeLine(cg, map(a), map(b), width: 10, color: .black)
            }
            // Openings, windows, doors on top of the walls.
            for o in plan.openings {
                let (a, b) = segment(o)
                strokeLine(cg, map(a), map(b), width: 12, color: .white)
                cg.setLineDash(phase: 0, lengths: [10, 8])
                strokeLine(cg, map(a), map(b), width: 2, color: .gray)
                cg.setLineDash(phase: 0, lengths: [])
            }
            for wnd in plan.windows {
                let (a, b) = segment(wnd)
                strokeLine(cg, map(a), map(b), width: 12, color: .white)
                strokeLine(cg, map(a), map(b), width: 5, color: UIColor(red: 0.2, green: 0.6, blue: 0.95, alpha: 1))
            }
            for d in plan.doors {
                let (a, b) = segment(d)
                strokeLine(cg, map(a), map(b), width: 12, color: .white)
                strokeLine(cg, map(a), map(b), width: 5, color: UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1))
                // Door swing arc.
                let pa = map(a), pb = map(b)
                let radius = hypot(pb.x - pa.x, pb.y - pa.y)
                let start = atan2(pb.y - pa.y, pb.x - pa.x)
                let arc = UIBezierPath(arcCenter: pa, radius: radius, startAngle: start, endAngle: start - .pi / 2, clockwise: false)
                UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 0.6).setStroke()
                arc.lineWidth = 2
                arc.stroke()
            }

            // Wall lengths.
            let dimFont = UIFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
            for w in plan.walls where w.dimensions.x >= 0.4 {
                let (a, b) = segment(w)
                let pa = map(a), pb = map(b)
                let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
                let len = hypot(pb.x - pa.x, pb.y - pa.y)
                let normal = CGPoint(x: -(pb.y - pa.y) / len, y: (pb.x - pa.x) / len)
                let offset: CGFloat = 30
                let ft = w.dimensions.x * 3.28084
                let label = String(format: "%.2f m · %d′%d″", w.dimensions.x, Int(ft), Int((ft - Float(Int(ft))) * 12))
                drawText(label, at: CGPoint(x: mid.x + normal.x * offset, y: mid.y + normal.y * offset), font: dimFont, color: UIColor(white: 0.2, alpha: 1))
            }

            // Title and scale bar.
            let title = area > 0 ? String(format: "Floor plan · %.1f m² (%.0f ft²)", area, area * 10.7639) : "Floor plan"
            (title as NSString).draw(at: CGPoint(x: margin, y: 40), withAttributes: [
                .font: UIFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: UIColor.black,
            ])
            let bar = CGFloat(scale)
            let y0 = size.height - 60
            strokeLine(cg, CGPoint(x: margin, y: y0), CGPoint(x: margin + bar, y: y0), width: 6, color: .black)
            drawText("1 m", at: CGPoint(x: margin + bar / 2, y: y0 - 26), font: dimFont, color: .black)
        }
    }

    private static func strokeLine(_ cg: CGContext, _ a: CGPoint, _ b: CGPoint, width: CGFloat, color: UIColor) {
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.move(to: a)
        cg.addLine(to: b)
        cg.strokePath()
    }

    private static func drawText(_ text: String, at center: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .backgroundColor: UIColor.white.withAlphaComponent(0.75)]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }
}
