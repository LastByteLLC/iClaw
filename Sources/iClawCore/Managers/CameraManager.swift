import Foundation
import AVFoundation

@MainActor
class CameraManager: NSObject, AVCapturePhotoCaptureDelegate {
    static let shared = CameraManager()

    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var continuation: CheckedContinuation<URL, Error>?

    func takePhoto() async throws -> URL {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let _ = await PermissionManager.requestPermission(.camera, toolName: "Camera", reason: "to take a photo")
            _ = await AVCaptureDevice.requestAccess(for: .video)
        } else if status == .denied || status == .restricted {
            throw NSError(domain: "CameraManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera access denied."])
        }

        return try await withCheckedThrowingContinuation { continuation in
            if let existing = self.continuation {
                self.continuation = nil
                existing.resume(throwing: CancellationError())
            }
            self.continuation = continuation

            let session = AVCaptureSession()
            session.beginConfiguration()

            guard let videoDevice = AVCaptureDevice.default(for: .video),
                  let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice),
                  session.canAddInput(videoDeviceInput) else {
                continuation.resume(throwing: NSError(domain: "CameraManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not access camera device."]))
                return
            }

            session.addInput(videoDeviceInput)

            let output = AVCapturePhotoOutput()
            guard session.canAddOutput(output) else {
                continuation.resume(throwing: NSError(domain: "CameraManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not add photo output."]))
                return
            }

            session.addOutput(output)
            session.commitConfiguration()

            self.captureSession = session
            self.photoOutput = output

            session.startRunning()

            // Wait a moment for the camera to warm up/adjust exposure
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let settings = AVCapturePhotoSettings()
                output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let photoData = photo.fileDataRepresentation()

        Task { @MainActor in
            self.captureSession?.stopRunning()

            if let error = error {
                self.continuation?.resume(throwing: error)
                self.continuation = nil
                return
            }

            guard let data = photoData else {
                self.continuation?.resume(throwing: NSError(domain: "CameraManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not get photo data."]))
                self.continuation = nil
                return
            }

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            do {
                try data.write(to: tempURL)
                self.continuation?.resume(returning: tempURL)
            } catch {
                self.continuation?.resume(throwing: error)
            }
            self.continuation = nil
        }
    }
}
