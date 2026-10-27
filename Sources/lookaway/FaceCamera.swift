import AVFoundation
import Foundation

enum CameraError: Error, LocalizedError, Equatable {
    case denied
    case restricted
    case noDevice
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .denied: return "Camera access denied"
        case .restricted: return "Camera access restricted"
        case .noDevice: return "No camera found"
        case .configuration(let why): return "Camera error: \(why)"
        }
    }
}

/// Low-resolution, low-frame-rate capture. Frames are handed to `onFrame` and
/// dropped; nothing is ever written to disk.
final class FaceCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let framesPerSecond = 5.0
    /// Faster while locked and waiting for the owner, so a blink is more likely to land on a frame.
    static let lockedFramesPerSecond = 10.0

    /// Analysis rate; the device is asked for it when capture starts.
    var framesPerSecond = FaceCamera.framesPerSecond

    let session = AVCaptureSession()
    /// Called on the camera queue for every accepted frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called (on an arbitrary queue) when capture dies after it started.
    var onFailure: ((String) -> Void)?

    private let queue = DispatchQueue(label: "lookaway.camera")
    private var lastAccepted: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    static var authorizationStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    /// Starts capture, asking for permission first if needed. `completion` runs on the main queue.
    func start(completion: @escaping (Result<Void, CameraError>) -> Void) {
        switch Self.authorizationStatus {
        case .authorized:
            startConfigured(completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.startConfigured(completion)
                } else {
                    DispatchQueue.main.async { completion(.failure(.denied)) }
                }
            }
        case .restricted:
            DispatchQueue.main.async { completion(.failure(.restricted)) }
        default:
            DispatchQueue.main.async { completion(.failure(.denied)) }
        }
    }

    func stop() {
        queue.async {
            self.removeObservers()
            if self.session.isRunning { self.session.stopRunning() }
            self.teardown()
        }
    }

    private func startConfigured(_ completion: @escaping (Result<Void, CameraError>) -> Void) {
        queue.async {
            let result = self.configureAndRun()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func configureAndRun() -> Result<Void, CameraError> {
        teardown()
        guard let device = Self.pickDevice() else { return .failure(.noDevice) }

        session.beginConfiguration()
        session.sessionPreset = .low
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return .failure(.configuration("cannot use \(device.localizedName)"))
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            return .failure(.configuration(error.localizedDescription))
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return .failure(.configuration("cannot read frames"))
        }
        session.addOutput(output)
        session.commitConfiguration()

        limitFrameRate(of: device)
        lastAccepted = 0
        addObservers(device: device)
        session.startRunning()
        return session.isRunning ? .success(()) : .failure(.configuration("session did not start"))
    }

    /// Prefer the built-in camera; fall back to any other video device.
    private static func pickDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices.filter { !$0.isSuspended }
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
    }

    /// Best effort: some formats refuse custom durations, in which case the
    /// delegate's throttle still keeps analysis at ~5 fps.
    private func limitFrameRate(of device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
            let supports = device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= framesPerSecond && framesPerSecond <= $0.maxFrameRate
            }
            if supports {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            // Throttling in captureOutput covers it.
        }
    }

    private func teardown() {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
    }

    private func addObservers(device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.onFailure?(error?.localizedDescription ?? "Camera runtime error")
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            self?.onFailure?("Camera disconnected")
        })
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastAccepted >= 1.0 / framesPerSecond - 0.02 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAccepted = now
        onFrame?(pixelBuffer)
    }
}
