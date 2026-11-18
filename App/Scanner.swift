import AVFoundation
import SwiftUI

struct Scanner: UIViewControllerRepresentable {
    let complete: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> CameraController { CameraController(complete) }
    func updateUIViewController(_ controller: CameraController, context: Context) {}
    static func dismantleUIViewController(_ controller: CameraController, coordinator: ()) { controller.stop() }
}

final class CameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "stockresearch.qr")
    private let complete: (Result<String, Error>) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    init(_ callback: @escaping (Result<String, Error>) -> Void) { complete = callback; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async { self?.configure(allowed) }
        }
    }
    private func configure(_ allowed: Bool) {
        guard !delivered else { return }
        let output = AVCaptureMetadataOutput()
        guard allowed, let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), capture.canAddInput(input), capture.canAddOutput(output) else {
            finish(.failure(NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "相机不可用，请输入电脑配对码。"])))
            return
        }
        capture.addInput(input)
        capture.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: capture)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        queue.async { [capture] in capture.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue { finish(.success(code)) }
    }
    private func finish(_ result: Result<String, Error>) {
        guard !delivered else { return }
        stop()
        complete(result)
    }
    func stop() {
        delivered = true
        queue.async { [capture] in if capture.isRunning { capture.stopRunning() } }
    }
}
