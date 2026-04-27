#if os(macOS)
import Foundation
import ScreenCaptureKit
import Vision
import AppKit

public struct ScreenshotTool: CoreTool, Sendable {
    public let name = "Screenshot"
    public let schema = "screenshot screen capture OCR read screen analyze error what on screen"
    public let isInternal = false
    public let category = CategoryEnum.offline

    public init() {}

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            do {
                // Hide iClaw's HUD so it doesn't appear in the screenshot
                await hideHUD()

                // Brief pause so the window fully disappears before capture
                try await Task.sleep(for: .milliseconds(300))

                let image: CGImage
                do {
                    image = try await captureScreen()
                } catch {
                    // Re-show HUD before returning on error
                    await showHUD()
                    throw error
                }

                // Re-show the HUD now that capture is done
                await showHUD()

                // Run OCR on the captured image
                let ocrText = try await performOCR(on: image)

                // Save screenshot to temp file
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("png")

                let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                if let tiffData = nsImage.tiffRepresentation,
                   let bitmapRep = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                    try pngData.write(to: tempURL)
                }

                // Truncate OCR text to fit token budget
                var truncatedOCR = ocrText
                if truncatedOCR.count > 1500 {
                    truncatedOCR = String(truncatedOCR.prefix(1497)) + "..."
                }

                let result = truncatedOCR.isEmpty
                    ? "Screenshot captured but no text detected on screen."
                    : "Screen text:\n\(truncatedOCR)"

                return ToolIO(
                    text: result,
                    attachments: [tempURL],
                    status: .ok,
                    outputWidget: "ScreenshotWidget",
                    widgetData: ["path": tempURL.path, "ocrText": truncatedOCR] as [String: String] as any Sendable
                )
            } catch let error as ScreenshotError {
                return ToolIO(
                    text: error.errorDescription ?? "Screenshot failed.",
                    status: .error
                )
            } catch {
                return ToolIO(
                    text: friendlyErrorMessage(for: error),
                    status: .error
                )
            }
        }
    }

    // MARK: - HUD Visibility

    @MainActor
    private func hideHUD() {
        for window in NSApp.windows where window is NSPanel {
            window.orderOut(nil)
        }
    }

    @MainActor
    private func showHUD() {
        for window in NSApp.windows where window is NSPanel {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Screen Capture

    private func captureScreen() async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw mapSCError(error)
        }

        guard let display = content.displays.first else {
            throw ScreenshotError.noDisplay
        }

        // Exclude iClaw's own windows from the capture
        let iClawWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        let filter = SCContentFilter(display: display, excludingWindows: iClawWindows)
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw mapSCError(error)
        }
    }

    // MARK: - OCR

    private func performOCR(on image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
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
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Error Handling

    private func mapSCError(_ error: Error) -> ScreenshotError {
        let nsError = error as NSError

        // SCStreamError codes (ScreenCaptureKit domain)
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
            || nsError.domain == "SCStreamErrorDomain" {
            switch nsError.code {
            case 1: // userDeclined
                return .permissionDenied
            case 2: // failedApplicationConsent
                return .permissionDenied
            case 3: // missingEntitlements
                return .permissionDenied
            default:
                return .captureFailed(nsError.localizedDescription)
            }
        }

        // Catch-all for TCC / authorization errors
        let desc = nsError.localizedDescription.lowercased()
        if desc.contains("tcc") || desc.contains("declined") || desc.contains("consent")
            || desc.contains("not authorized") || desc.contains("permission") {
            return .permissionDenied
        }

        return .captureFailed(nsError.localizedDescription)
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        let mapped = mapSCError(error)
        return mapped.errorDescription ?? "Screenshot failed: \(error.localizedDescription)"
    }

    // MARK: - Error Types

    enum ScreenshotError: Error, LocalizedError {
        case noDisplay
        case permissionDenied
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No display found. Is this Mac headless?"
            case .permissionDenied:
                return "Screen Recording permission required. Open System Settings > Privacy & Security > Screen Recording and enable iClaw."
            case .captureFailed(let detail):
                return "Screen capture failed: \(detail)"
            }
        }
    }
}
#endif
