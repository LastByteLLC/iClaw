#if os(macOS)
import Foundation
@preconcurrency import ScreenCaptureKit
import Vision
import os

/// Passive screen context capture — periodically OCRs the frontmost window
/// to provide ambient awareness. Off by default; user must explicitly enable
/// in Settings > General > Screen Context.
public actor ScreenContextManager {
    public static let shared = ScreenContextManager()

    private var captureTask: Task<Void, Never>?
    private var latestScreenText: String?

    /// The most recent OCR text from the screen, or nil if unavailable.
    public var currentScreenContext: String? { latestScreenText }

    public func start() {
        guard captureTask == nil else { return }
        Log.tools.debug("ScreenContextManager: starting passive capture")
        captureTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.captureAndOCR()
                try? await Task.sleep(for: .seconds(AppConfig.screenContextCaptureIntervalSeconds))
            }
        }
    }

    public func stop() {
        captureTask?.cancel()
        captureTask = nil
        latestScreenText = nil
        Log.tools.debug("ScreenContextManager: stopped")
    }

    // MARK: - Capture + OCR

    private func captureAndOCR() async {
        // Check Screen Recording permission before attempting capture
        guard CGPreflightScreenCaptureAccess() else {
            Log.tools.debug("ScreenContextManager: no screen recording permission, skipping")
            return
        }

        do {
            let image = try await captureScreen()
            let ocrText = try await performOCR(on: image)

            if ocrText.isEmpty {
                latestScreenText = nil
            } else {
                var truncated = ocrText
                if truncated.count > AppConfig.screenContextMaxChars {
                    truncated = String(truncated.prefix(AppConfig.screenContextMaxChars - 3)) + "..."
                }
                latestScreenText = truncated
            }
        } catch {
            Log.tools.debug("ScreenContextManager: capture failed — \(error.localizedDescription)")
        }
    }

    private func captureScreen() async throws -> CGImage {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            throw ScreenContextError.noDisplay
        }

        // Exclude iClaw's own windows
        let iClawWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        let filter = SCContentFilter(display: display, excludingWindows: iClawWindows)
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    private func performOCR(on image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let request = VNRecognizeTextRequest { request, error in
                guard !resumed.withLock({ let v = $0; $0 = true; return v }) else { return }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                guard !resumed.withLock({ let v = $0; $0 = true; return v }) else { return }
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Errors

    private enum ScreenContextError: Error {
        case noDisplay
    }
}
#endif
