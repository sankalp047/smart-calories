import SwiftUI
import AVFoundation
import PhotosUI

// MARK: - Barcode scanning

struct BarcodeScannerScreen: View {
    @Environment(\.dismiss) private var dismiss
    let onFound: (Food) -> Void

    @State private var isResolving = false
    @State private var message: String?
    @State private var handled = false

    private let service = OpenFoodFactsService()

    var body: some View {
        NavigationStack {
            ZStack {
                CameraBarcodeView { code in
                    guard !handled else { return }
                    handled = true
                    Task { await resolve(code) }
                }
                .ignoresSafeArea()

                // Framing guide
                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 3)
                        .frame(width: 270, height: 165)
                        .shadow(color: .black.opacity(0.4), radius: 12)
                    Spacer()
                    if isResolving {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("Looking it up…").foregroundStyle(.white)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Capsule().fill(.black.opacity(0.6)))
                    } else {
                        Text(message ?? "Point at a product barcode")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .background(Capsule().fill(.black.opacity(0.6)))
                    }
                    Spacer().frame(height: 50)
                }
                .padding(.horizontal, 24)
            }
            .navigationTitle("Scan barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func resolve(_ code: String) async {
        isResolving = true
        defer { isResolving = false }
        do {
            if let food = try await service.lookup(barcode: code) {
                Haptics.success()
                onFound(food)
                dismiss()
            } else {
                message = "No product found for \(code). Try the label scanner instead."
                handled = false
            }
        } catch {
            message = error.localizedDescription
            handled = false
        }
    }
}

/// Thin AVFoundation wrapper that reports the first barcode it sees.
struct CameraBarcodeView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> BarcodeCaptureController {
        let controller = BarcodeCaptureController()
        controller.onCode = onCode
        return controller
    }
    func updateUIViewController(_ controller: BarcodeCaptureController, context: Context) {}
}

final class BarcodeCaptureController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.ean13, .ean8, .upce, .code128, .code39, .itf14]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        Task.detached { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else { return }
        AudioServicesPlaySystemSoundHelper()
        onCode?(value)
    }
}

private func AudioServicesPlaySystemSoundHelper() {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
}

// MARK: - Nutrition label scanning (on-device OCR → AI structuring)

struct LabelScanScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onFound: (Food) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var stage: Stage = .idle
    @State private var ocrText: String?
    @State private var errorMessage: String?
    @State private var showCamera = false

    private let ocr = OCRService()

    enum Stage { case idle, reading, thinking }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    explainer

                    if let image {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(height: 190)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    }

                    HStack(spacing: 10) {
                        SecondaryButton(title: "Camera", icon: "camera.fill") { showCamera = true }
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle")
                                Text("Library")
                            }
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                                    .fill(Theme.Palette.controlFill)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                                            .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                                    }
                            }
                        }
                    }

                    if stage != .idle {
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.Palette.accent)
                            Text(stage == .reading ? "Reading the label…" : "Structuring the nutrition facts…")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }

                    if let errorMessage {
                        InlineMessage(kind: .error, text: errorMessage)
                    }

                    if let ocrText, !ocrText.isEmpty {
                        DisclosureGroup("Text read from the photo") {
                            Text(ocrText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .glassCard(radius: Theme.Radius.md, padding: 14)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Scan label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { picked in
                    image = picked
                    Task { await process(picked) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let picked = UIImage(data: data) {
                        image = picked
                        await process(picked)
                    }
                }
            }
        }
    }

    private var explainer: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Point at the Nutrition Facts panel")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("The text is read on your device — only the extracted words are sent to be structured into per-100 g values.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }

    private func process(_ picked: UIImage) async {
        errorMessage = nil
        stage = .reading
        do {
            let text = try await ocr.recognizeText(in: picked)
            ocrText = text
            stage = .thinking
            let food = try await env.ai.parseNutritionLabel(ocrText: text)
            stage = .idle
            Haptics.success()
            onFound(food)
            dismiss()
        } catch {
            stage = .idle
            errorMessage = error.localizedDescription
        }
    }
}

/// Minimal camera capture wrapper for label photos.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
