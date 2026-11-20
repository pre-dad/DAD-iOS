import SwiftUI
import AVFoundation
import DADFoundation

// QR check-in scanner (E-8). Camera access sits behind the `CameraPermission` seam: the sheet asks
// only when the donor opens the scanner, and every non-allowed state has a typed-code fallback in the
// check-in panel. The capture itself needs a real camera, so it is verified on a device, not in CI.

struct SystemCameraPermission: CameraPermission {
    func status() async -> PermissionState {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return .notRequested
        case .restricted: return .restricted
        default: return .denied
        }
    }

    func request() async -> PermissionState {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        return await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
    }
}

struct QRScanSheet: View {
    let onCode: (String) -> Void
    let onClose: () -> Void
    var permission: any CameraPermission = SystemCameraPermission()
    @State private var state: PermissionState?
    @State private var setupFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("Close", action: onClose).buttonStyle(DADButtonStyle(.tertiary)).accessibilityIdentifier("scan-close")
            Text("Scan check-in code").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            switch state {
            case nil:
                ProgressView()
            case .allowed?:
                QRScannerView(onCode: onCode, onSetupFailure: { setupFailed = true })
                    .frame(minHeight: 280).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("Camera view. Point it at the QR code shown at the venue.")
                    .accessibilityIdentifier("scan-camera")
                if setupFailed {
                    Text("The camera couldn’t be started. Close this and type the code instead.")
                        .foregroundStyle(Color.dad("fail")).accessibilityIdentifier("scan-setup-failed")
                }
            case .denied?:
                Text("Camera access is off for DAD. You can turn it on in Settings, or close this and type the code instead.")
                    .accessibilityIdentifier("scan-denied")
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: settings).accessibilityIdentifier("scan-open-settings")
                }
            case .restricted?:
                Text("Camera access is restricted on this device, so DAD can’t ask for it. Close this and type the code instead.")
                    .accessibilityIdentifier("scan-restricted")
            case .unavailable?:
                Text("This device has no camera available. Close this and type the code instead.")
                    .accessibilityIdentifier("scan-unavailable")
            case .notRequested?:
                Text("DAD needs the camera to read the QR code.")
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .task {
            let current = await permission.status()
            state = current == .notRequested ? await permission.request() : current
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onSetupFailure: () -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode, onSetupFailure: onSetupFailure) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "org.dad.qr-scanner")
    private let onCode: (String) -> Void
    private let onSetupFailure: () -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    init(onCode: @escaping (String) -> Void, onSetupFailure: @escaping () -> Void) {
        self.onCode = onCode
        self.onSetupFailure = onSetupFailure
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return onSetupFailure() }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return onSetupFailure() }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        nonisolated(unsafe) let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        nonisolated(unsafe) let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
        MainActor.assumeIsolated {
            // The delegate queue is main. One delivery per scan: the sheet closes and submits it.
            guard let value, !delivered else { return }
            delivered = true
            onCode(value)
        }
    }
}
