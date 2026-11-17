import ARKit
import AVFoundation
import PhotosUI
import SceneKit
import SwiftUI
import UIKit

struct ModernCameraView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        picker.navigationBar.tintColor = .systemBlue
        picker.view.tintColor = .systemBlue

        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context _: Context) {
        uiViewController.navigationBar.tintColor = .systemBlue
        uiViewController.view.tintColor = .systemBlue
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ModernCameraView

        init(_ parent: ModernCameraView) {
            self.parent = parent
        }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.onImageCaptured(uiImage)
            } else {
                parent.dismiss()
            }
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Geführter Multi-Winkel-Flow: bis zu drei Fotos derselben Mahlzeit aus
/// verschiedenen Winkeln (von oben, ~45°, seitlich), die zusammen in EINE
/// KI-Anfrage gehen — die Winkel-Semantik liefert der Prompt (5a0_multi_view).
///
/// Eigene AVCapture-Session mit Overlay statt UIImagePickerController:
/// die Anleitung liegt direkt auf dem Sucherbild und zwischen den Fotos
/// gibt es keinerlei Präsentationswechsel — verschachtelte fullScreenCover
/// (Kamera auf/zu je Foto) froren den Flow ein.
struct MultiAngleCaptureView: View {
    let onFinish: ([AuroraMealCapture]) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = MultiAngleCameraController()
    @StateObject private var depthCamera = AuroraDepthProbeModel()

    @State private var images: [UIImage] = []
    @State private var mealCaptures: [AuroraMealCapture] = []

    private struct AngleStep {
        let icon: String
        let title: String
        let subtitle: String
    }

    private let steps: [AngleStep] = [
        AngleStep(
            icon: "arrow.down.circle",
            title: NSLocalizedString("Draufsicht", comment: "multi-angle capture step 1"),
            subtitle: NSLocalizedString(
                "Halte das iPhone senkrecht über den Teller.",
                comment: "multi-angle capture step 1 hint"
            )
        ),
        AngleStep(
            icon: "arrow.down.right.circle",
            title: NSLocalizedString("Schrägansicht (45°)", comment: "multi-angle capture step 2"),
            subtitle: NSLocalizedString(
                "Fotografiere die Mahlzeit schräg, damit Tiefe und Höhe erkennbar sind.",
                comment: "multi-angle capture step 2 hint"
            )
        ),
        AngleStep(
            icon: "arrow.right.circle",
            title: NSLocalizedString("Seitenansicht", comment: "multi-angle capture step 3"),
            subtitle: NSLocalizedString(
                "Fotografiere die Mahlzeit seitlich, damit Schichten und Höhe sichtbar sind.",
                comment: "multi-angle capture step 3 hint"
            )
        )
    ]

    private var allCaptured: Bool { images.count >= steps.count }

    private var lidarDepthAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if lidarDepthAvailable {
                AuroraDepthARView(model: depthCamera)
                    .ignoresSafeArea()
            } else if camera.isAuthorized {
                MultiAngleCameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else {
                cameraDeniedView
            }

            VStack(spacing: 0) {
                instructionBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()

                thumbnailRow
                    .padding(.bottom, 16)

                controlsBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .statusBarHidden()
        .onAppear {
            guard !lidarDepthAvailable else { return }

            camera.start { image in
                guard images.count < steps.count else { return }

                images.append(image)
                mealCaptures.append(
                    AuroraMealCapture(
                        image: image,
                        depthSnapshot: nil
                    )
                )
            }
        }
        .onDisappear {
            camera.stop()
        }
    }

    private var instructionBanner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(
                    systemName: lidarDepthAvailable
                        ? "viewfinder.circle.fill"
                        : "camera.fill"
                )

                Text(
                    lidarDepthAvailable
                        ? (
                            depthCamera.latestMealCapture != nil
                                ? "LiDAR-Tiefenerfassung aktiv"
                                : "LiDAR wird initialisiert …"
                        )
                        : "Fotoanalyse ohne LiDAR"
                )
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(
                lidarDepthAvailable
                    ? (
                        depthCamera.latestMealCapture != nil
                            ? Color.cyan
                            : Color.yellow
                    )
                    : Color.white.opacity(0.65)
            )

            if allCaptured {
                Label(
                    NSLocalizedString("Alle Ansichten aufgenommen", comment: "multi-angle capture done"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: steps[images.count].icon)
                        .font(.system(size: 22, weight: .semibold))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(images.count + 1) von \(steps.count)")
                            .font(.headline.weight(.bold))

                        Text(steps[images.count].title)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)

                Text(steps[images.count].subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }

            if images.isEmpty {
                Label(
                    "Referenz: Löffel, Gabel oder Glas mit fotografieren.",
                    systemImage: "ruler"
                )
                .font(.caption)
                .foregroundStyle(.yellow.opacity(0.95))
                .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.55))
        )
    }

    private var thumbnailRow: some View {
        HStack(spacing: 10) {
            ForEach(steps.indices, id: \.self) { index in
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.4))
                        .frame(width: 48, height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    index == images.count ? Color.white : Color.white.opacity(0.3),
                                    lineWidth: index == images.count ? 2 : 1
                                )
                        )

                    if index < images.count {
                        Image(uiImage: images[index])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            // Antippen entfernt das Foto — der Schritt wird erneut aufgenommen
                            .onTapGesture {
                                images.remove(at: index)

                                if index < mealCaptures.count {
                                    mealCaptures.remove(at: index)
                                }
                            }

                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .offset(x: 5, y: -5)
                    } else {
                        Image(systemName: steps[index].icon)
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(index == images.count ? 0.9 : 0.4))
                            .frame(width: 48, height: 48)
                    }
                }
            }
        }
    }

    private var controlsBar: some View {
        HStack {
            Button {
                onCancel()
            } label: {
                Text("Abbrechen")
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(width: 72, alignment: .leading)
            }

            Spacer()

            Button {
                if lidarDepthAvailable {
                    guard images.count < steps.count,
                          let capture =
                          depthCamera.captureCurrentMealCaptureWithForegroundMask()
                    else {
                        return
                    }

                    mealCaptures.append(capture)
                    images.append(capture.image)

                    #if DEBUG
                        if let geometry = capture.cameraGeometry {
                            print(
                                String(
                                    format:
                                    "AURORA CAMERA POSE: capture=%d downwardAngle=%.1f deg",
                                    mealCaptures.count,
                                    geometry.downwardViewAngleDegrees
                                )
                            )
                        }

                        for item in auroraClassifyCaptures(mealCaptures) {
                            print(
                                String(
                                    format:
                                    "AURORA VIEW ROLE: capture=%d role=%@ angle=%.1f deg",
                                    item.captureIndex + 1,
                                    item.role.rawValue,
                                    item.downwardAngleDegrees
                                )
                            )
                        }

                        if let topVolume =
                            auroraTopViewVolume(
                                from: mealCaptures
                            )
                        {
                            print(
                                String(
                                    format:
                                    "AURORA TOP VOLUME: capture=%d angle=%.1f deg points=%d | 5mm=%.0f ml 7.5mm=%.0f ml 10mm=%.0f ml | inner10=%.0f ml inner15=%.0f ml",
                                    topVolume.captureIndex + 1,
                                    topVolume.downwardAngleDegrees,
                                    topVolume.pointCount,
                                    topVolume.volume5mmMilliliters,
                                    topVolume.volume7_5mmMilliliters,
                                    topVolume.volume10mmMilliliters,
                                    topVolume.inner10mmVolume5mmMilliliters,
                                    topVolume.inner15mmVolume5mmMilliliters
                                )
                            )

                            print(
                                String(
                                    format:
                                    "AURORA SHAPE: points=%d major=%.1f cm minor=%.1f cm area=%.1f cm2 eqDiameter=%.1f cm ratio=%.3f",
                                    topVolume.shapePointCount,
                                    topVolume.shapeMajorAxisCentimeters,
                                    topVolume.shapeMinorAxisCentimeters,
                                    topVolume.shapeFootprintSquareCentimeters,
                                    topVolume.shapeEquivalentDiameterCentimeters,
                                    topVolume.shapeAxisRatio
                                )
                            )

                            print(
                                String(
                                    format:
                                    "AURORA HEIGHT PROFILE: P02=%.1f cm P10=%.1f cm P25=%.1f cm P50=%.1f cm P75=%.1f cm P90=%.1f cm P98=%.1f cm",
                                    topVolume.heightP02Meters * 100,
                                    topVolume.heightP10Meters * 100,
                                    topVolume.heightP25Meters * 100,
                                    topVolume.heightP50Meters * 100,
                                    topVolume.heightP75Meters * 100,
                                    topVolume.heightP90Meters * 100,
                                    topVolume.heightP98Meters * 100
                                )
                            )
                        }

                        if let fused = auroraFusedGeometry(from: mealCaptures) {
                            print(
                                String(
                                    format:
                                    "AURORA ORIENTED 3D: n=%d length=%.1f cm width=%.1f cm height=%.1f cm",
                                    fused.orientedPointCount,
                                    fused.orientedLength * 100,
                                    fused.orientedWidth * 100,
                                    fused.objectHeight * 100
                                )
                            )

                            print(
                                String(
                                    format:
                                    "AURORA VOLUME: 5mm=%.0f ml 7.5mm=%.0f ml 10mm=%.0f ml",
                                    fused.volume5mmMilliliters,
                                    fused.volume7_5mmMilliliters,
                                    fused.volume10mmMilliliters
                                )
                            )
                        }
                    #endif
                } else {
                    camera.capture()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 68, height: 68)
                    Circle()
                        .fill(allCaptured ? Color.white.opacity(0.3) : Color.white)
                        .frame(width: 56, height: 56)
                }
            }
            .disabled(
                allCaptured
                    || (
                        lidarDepthAvailable
                            ? depthCamera.latestMealCapture == nil
                            : !camera.isReady
                    )
            )

            Spacer()

            Button {
                #if DEBUG
                    if lidarDepthAvailable {
                        print(
                            "AURORA LIDAR: \(mealCaptures.count) "
                                + "gekoppelte Aufnahme(n) für "
                                + "\(images.count) Bild(er)"
                        )
                    }
                #endif

                onFinish(mealCaptures)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                    Text("Analysieren")
                        .font(.caption2)
                }
                .foregroundStyle(allCaptured ? .green : .white.opacity(0.3))
                .frame(width: 88, alignment: .trailing)
            }
            .disabled(!allCaptured)
        }
    }

    private var cameraDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.5))

            Text("Für die Mehrwinkelaufnahme wird der Kamerazugriff benötigt.")
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Button("Einstellungen öffnen") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

/// Durchgehende AVCapture-Session für den Multi-Winkel-Flow — bleibt über
/// alle drei Aufnahmen hinweg aktiv, kein Präsentationswechsel je Foto.
final class MultiAngleCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var isAuthorized = true
    @Published var isReady = false

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "iAPS.multiAngleCamera.session")
    private var isConfigured = false
    private var onPhoto: ((UIImage) -> Void)?

    func start(onPhoto: @escaping (UIImage) -> Void) {
        self.onPhoto = onPhoto
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async { self.isAuthorized = granted }
            guard granted else { return }
            self.sessionQueue.async {
                self.configureIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async { self.isReady = true }
            }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func capture() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input)
        {
            session.addInput(input)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()
        isConfigured = true
    }

    func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onPhoto?(image)
        }
    }
}

private struct MultiAngleCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context _: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_: PreviewView, context _: Context) {}
}

// MARK: - Aurora LiDAR depth diagnostic

private struct AuroraDepthProbeView: View {
    let onClose: () -> Void

    @StateObject private var model = AuroraDepthProbeModel()
    @State private var showHeatmap = false

    var body: some View {
        ZStack {
            AuroraDepthARView(model: model)
                .ignoresSafeArea()

            if showHeatmap, let heatmapImage = model.heatmapImage {
                GeometryReader { geometry in
                    Image(uiImage: heatmapImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                        .clipped()
                        .opacity(0.58)
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    model.roiSampleCount > 0 ? Color.cyan : Color.yellow,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .frame(width: 120, height: 120)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Button {
                        onClose()
                    } label: {
                        Label("Schließen", systemImage: "xmark.circle.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .background(
                                Capsule()
                                    .fill(.black.opacity(0.82))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("LiDAR-Ansicht schließen")

                    Spacer()

                    Button {
                        showHeatmap.toggle()
                    } label: {
                        Image(
                            systemName: showHeatmap
                                ? "square.3.layers.3d.down.right.fill"
                                : "square.3.layers.3d.down.right"
                        )
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(showHeatmap ? .cyan : .white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.6), in: Circle())
                    }
                    .disabled(model.heatmapImage == nil && !showHeatmap)
                    .opacity(
                        model.heatmapImage == nil && !showHeatmap
                            ? 0.4
                            : 1
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 54)
                .frame(maxWidth: .infinity)
                .zIndex(1000)

                Spacer()

                VStack(spacing: 8) {
                    Text("LiDAR-Tiefentest")
                        .font(.headline)

                    if let centerDepth = model.centerDepth {
                        Text(
                            "Tiefe Bildmitte: \(centerDepth, specifier: "%.3f") m"
                        )
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    } else {
                        Text("Warte auf gültige Tiefendaten …")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 18) {
                        depthValue(title: "Minimum", value: model.minimumDepth)
                        depthValue(title: "Maximum", value: model.maximumDepth)
                    }

                    VStack(spacing: 4) {
                        Text("Zentraler Messbereich")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)

                        HStack(spacing: 18) {
                            depthValue(
                                title: "Mittelwert",
                                value: model.roiMeanDepth
                            )

                            depthValue(
                                title: "Streuung",
                                value: model.roiStandardDeviation
                            )
                        }

                        Text(
                            "Gültige Messpunkte: \(model.roiSampleCount)"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Text(
                        "Depth Map: \(model.depthWidth) × \(model.depthHeight)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    VStack(spacing: 3) {
                        Text("AR-Frames: \(model.receivedFrameCount)")
                        Text("Semantik: \(model.activeDepthSemantic)")
                        Text("Status: \(model.depthStatus)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        Text("Nah")
                            .foregroundStyle(.red)

                        LinearGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 150, height: 8)
                        .clipShape(Capsule())

                        Text("Fern")
                            .foregroundStyle(.blue)
                    }
                    .font(.caption2)

                    Text(
                        showHeatmap
                            ? "Heatmap aktiv – Rot ist näher, Blau weiter entfernt."
                            : "Tippe oben rechts, um die Tiefen-Heatmap einzublenden."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    Text("Richte die Bildmitte auf Teller oder Mahlzeit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.72))
            }
        }
        .statusBarHidden()
    }

    @ViewBuilder private func depthValue(title: String, value: Float?) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let value {
                Text("\(value, specifier: "%.3f") m")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text("–")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

private struct AuroraDepthARView: UIViewRepresentable {
    @ObservedObject var model: AuroraDepthProbeModel

    func makeUIView(context _: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.scene = SCNScene()
        view.session.delegate = model
        view.automaticallyUpdatesLighting = false
        model.start(session: view.session)
        return view
    }

    func updateUIView(_: ARSCNView, context _: Context) {}

    static func dismantleUIView(
        _ uiView: ARSCNView,
        coordinator _: ()
    ) {
        uiView.session.pause()
    }
}
