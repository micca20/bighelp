@preconcurrency import AVFoundation
import SwiftUI

@MainActor
struct LoopdyLinkQRScannerView: View {
    let permissionCenter: PermissionCenter
    let onPayload: (String) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            if cameraAuthorization == .authorized {
                LoopdyLinkCameraPreview(onPayload: onPayload)
                    .ignoresSafeArea()
                VStack(spacing: LoopdyTokens.space8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 34, weight: .semibold))
                    Text("Point the camera at the Loopdy Link QR code")
                        .loopdyFont(.label)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(LoopdyTokens.space16)
                .background(.black.opacity(0.72), in: .rect(cornerRadius: LoopdyTokens.radius16))
                .padding(LoopdyTokens.space20)
            } else if cameraAuthorization == .denied || cameraAuthorization == .restricted {
                ContextualPermissionRecoveryView(center: permissionCenter, kind: .camera)
            } else {
                VStack(spacing: LoopdyTokens.space8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 34, weight: .semibold))
                    LoopdyThinkingOrb(scenario: .connecting, scale: .inline)
                    Text("Preparing camera access")
                        .loopdyFont(.label)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(LoopdyTokens.space16)
                .background(.black.opacity(0.72), in: .rect(cornerRadius: LoopdyTokens.radius16))
                .padding(LoopdyTokens.space20)
            }
        }
        .background(.black)
        .navigationTitle("Scan Pairing Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(.white)
            }
        }
        .accessibilityIdentifier("link.pairing.scanner")
        .task { await permissionCenter.authorizeContextualAccess(.camera) }
    }

    @Environment(\.dismiss) private var dismiss

    private var cameraAuthorization: PermissionAuthorizationState {
        permissionCenter.status(for: .camera).authorization
    }
}

private struct LoopdyLinkCameraPreview: UIViewRepresentable {
    let onPayload: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    func makeUIView(context: Context) -> CameraPreview {
        let view = CameraPreview()
        context.coordinator.start(in: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreview, context: Context) { }

    static func dismantleUIView(_ uiView: CameraPreview, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let onPayload: (String) -> Void
        private var hasDeliveredPayload = false

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func start(in preview: CameraPreview) {
            preview.previewLayer.session = session
            preview.previewLayer.videoGravity = .resizeAspectFill
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureAndStart()
            case .notDetermined, .denied, .restricted:
                break
            @unknown default:
                break
            }
        }

        func stop() {
            if session.isRunning {
                session.stopRunning()
            }
        }

        private func configureAndStart() {
            guard session.inputs.isEmpty else {
                if !session.isRunning { session.startRunning() }
                return
            }
            guard
                let camera = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: camera),
                session.canAddInput(input)
            else { return }

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.beginConfiguration()
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            session.startRunning()
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard
                let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                let payload = object.stringValue
            else { return }
            Task { @MainActor [weak self] in
                guard let self, !hasDeliveredPayload else { return }
                hasDeliveredPayload = true
                stop()
                onPayload(payload)
            }
        }
    }

    final class CameraPreview: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
