#if os(macOS)
import Foundation
import AppKit
import FoundationModels
import CoreAudio
import AudioToolbox

@Generable
struct SystemControlInput: ConvertibleFromGeneratedContent {
    #if MAS_BUILD
    @Guide(description: "Action: 'setVolume', 'mute', 'unmute', 'launchApp', 'quitApp'")
    #else
    @Guide(description: "Action: 'toggleDarkMode', 'setVolume', 'mute', 'unmute', 'launchApp', 'quitApp'")
    #endif
    var action: String
    @Guide(description: "Volume level (0-100)")
    var volumeValue: Int?
    @Guide(description: "Name of the application (e.g. 'Safari', 'Notes') — required for launchApp/quitApp")
    var appName: String?
}

struct SystemControlTool: Tool {
    typealias Arguments = SystemControlInput
    typealias Output = String

    let name = "system_control"
    let description = "Control system settings like volume and appearance, and launch or quit applications."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: SystemControlInput) async throws -> String {
        switch input.action {
        #if !MAS_BUILD
        case "toggleDarkMode":
            return await toggleDarkMode()
        #endif
        case "setVolume":
            return await setVolume(level: input.volumeValue ?? 50)
        case "mute":
            return await setMute(true)
        case "unmute":
            return await setMute(false)
        case "launchApp":
            return await launchApp(named: input.appName ?? "")
        case "quitApp":
            return quitApp(named: input.appName ?? "")
        default:
            return "Unknown action."
        }
    }

    // MARK: - App Management

    private func launchApp(named appName: String) async -> String {
        guard !appName.isEmpty else { return "No app name provided." }
        let workspace = NSWorkspace.shared
        let searchPaths = ["/Applications", "/System/Applications", "/System/Cryptexes/App/Applications"]
        var appURL: URL?

        for path in searchPaths {
            let url = URL(filePath: "\(path)/\(appName).app")
            // Validate resolved path stays within the search directory (prevents path traversal via symlinks)
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(path + "/") else { continue }
            if FileManager.default.fileExists(atPath: resolved) {
                appURL = url
                break
            }
        }

        if let targetURL = appURL {
            let config = NSWorkspace.OpenConfiguration()
            do {
                try await workspace.openApplication(at: targetURL, configuration: config)
                return "Launched \(appName)."
            } catch {
                return "Failed to launch \(appName): \(error.localizedDescription)"
            }
        }

        return "Could not find application '\(appName)' in standard folders."
    }

    private func quitApp(named appName: String) -> String {
        guard !appName.isEmpty else { return "No app name provided." }
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications.filter {
            $0.localizedName?.lowercased() == appName.lowercased()
        }
        for app in apps { app.terminate() }
        return apps.isEmpty ? "'\(appName)' is not running." : "Terminated \(appName)."
    }

    // MARK: - System Controls

#if MAS_BUILD

    // MARK: Native APIs (MAS)

    private func setVolume(level: Int) async -> String {
        let clamped = max(0, min(100, level))
        var deviceID = AudioObjectID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return "Error: could not get default audio device." }

        var volume = Float32(clamped) / 100.0
        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        address.mScope = kAudioObjectPropertyScopeOutput
        let setStatus = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume
        )
        return setStatus == noErr ? "Volume set to \(clamped)%." : "Error: could not set volume."
    }

    private func setMute(_ shouldMute: Bool) async -> String {
        var deviceID = AudioObjectID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return "Error: could not get default audio device." }

        var muted: UInt32 = shouldMute ? 1 : 0
        address.mSelector = kAudioDevicePropertyMute
        address.mScope = kAudioObjectPropertyScopeOutput
        let setStatus = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted
        )
        return setStatus == noErr
            ? (shouldMute ? "Audio muted." : "Audio unmuted.")
            : "Error: could not \(shouldMute ? "mute" : "unmute") audio."
    }

#else

    // MARK: AppleScript (Direct Distribution)

    private func setVolume(level: Int) async -> String {
        let clamped = max(0, min(100, level))
        return await executeAppleScript("set volume output volume \(clamped)")
    }

    private func setMute(_ shouldMute: Bool) async -> String {
        await executeAppleScript(shouldMute ? "set volume with output muted" : "set volume without output muted")
    }

    private func toggleDarkMode() async -> String {
        await executeAppleScript(
            "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        )
    }

    private func executeAppleScript(_ source: String) async -> String {
        do {
            return try await UserScriptRunner.run(source)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

#endif
}
#endif
