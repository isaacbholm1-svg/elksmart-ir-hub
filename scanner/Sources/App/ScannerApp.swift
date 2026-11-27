import ARKit
import RealityKit
import RoomPlan
import SwiftUI

@main
struct ScannerApp: App {
    @StateObject private var library = ScanLibrary()

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
    }
}

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            CaptureHomeView(onSaved: { tab = 1 })
                .tabItem { Label("Scan", systemImage: "viewfinder") }
                .tag(0)
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.3d.up") }
                .tag(1)
        }
    }
}

extension ScanKind {
    @MainActor
    var isAvailable: Bool {
        switch self {
        case .object: return ObjectCaptureSession.isSupported
        case .space: return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        case .room: return RoomCaptureSession.isSupported
        case .photos: return ARWorldTrackingConfiguration.isSupported
        }
    }
}

struct CaptureHomeView: View {
    var onSaved: () -> Void
    @State private var active: ScanKind?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(ScanKind.allCases) { kind in
                        ModeCard(kind: kind) { active = kind }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tips for great scans").font(.headline)
                        Text("• Bright, even light. Avoid harsh shadows and direct sun.")
                        Text("• Move slowly and steadily. Overlap each view with the last one.")
                        Text("• Shiny, glass, black or see-through things scan badly. A little matte spray or powder helps.")
                        Text("• For objects, use a plain surface you can walk all the way around.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .navigationTitle("3D Scanner")
        }
        .fullScreenCover(item: $active) { kind in
            let finish: (Bool) -> Void = { saved in
                active = nil
                if saved { onSaved() }
            }
            switch kind {
            case .object: ObjectScanView(done: finish)
            case .space: SpaceScanView(done: finish)
            case .room: RoomScanView(done: finish)
            case .photos: PhotoScanView(done: finish)
            }
        }
    }
}

struct ModeCard: View {
    let kind: ScanKind
    let action: () -> Void

    var body: some View {
        let available = kind.isAvailable
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: kind.icon)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(.headline)
                    Text(kind.summary).font(.subheadline).foregroundStyle(.secondary)
                    Text(available ? kind.requirement : "Not supported on this device. \(kind.requirement)")
                        .font(.caption)
                        .foregroundStyle(available ? Color.secondary : Color.orange)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.6)
    }
}

/// Shared top bar + bottom panel styling for the capture screens.
struct CaptureChrome<Top: View, Bottom: View>: View {
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack {
            top
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            Spacer()
            bottom
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .padding()
    }
}

struct ProcessingOverlay: View {
    let title: String
    let detail: String
    let progress: Double?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(title).font(.headline)
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                    Text("\(Int(progress * 100))%").monospacedDigit()
                } else {
                    ProgressView()
                }
                Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
