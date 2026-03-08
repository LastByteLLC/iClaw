import Foundation
import Contacts
import EventKit
import FoundationModels
import SwiftSoup
import AppKit
import MapKit
import CoreLocation
import Vision
import PDFKit
import UniformTypeIdentifiers
import HealthKit
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
            _ = await AVCaptureDevice.requestAccess(for: .video)
        } else if status == .denied || status == .restricted {
            throw NSError(domain: "CameraManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera access denied."])
        }

        return try await withCheckedThrowingContinuation { continuation in
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
        // photo.fileDataRepresentation() is nonisolated and can be called on the background thread where the delegate is called.
        // Data is Sendable.
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

@MainActor
class LocationManager: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = LocationManager()
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    private override init() {
        super.init()
        manager.delegate = self
    }

    func getCurrentLocation() async throws -> CLLocation {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // In a real app, you'd wait for the delegate to signal authorization change.
            // For now, let's wait a moment and check again or just proceed to requestLocation
            // which will trigger the system prompt if not yet determined.
        } else if status == .denied || status == .restricted {
            throw NSError(domain: "LocationManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Location access denied."])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            continuation?.resume(returning: location)
            continuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
class MeCardManager {
    static let shared = MeCardManager()

    var userName: String = NSFullUserName()
    var userEmail: String?
    var userPhone: String?

    private init() {
        fetchMeCardIfAuthorized()
    }

    func fetchMeCardIfAuthorized() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return }

        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]

        do {
            let me = try store.unifiedMeContactWithKeys(toFetch: keys)
            self.userName = "\(me.givenName) \(me.familyName)".trimmingCharacters(in: .whitespaces)
            self.userEmail = me.emailAddresses.first?.value as String?
            self.userPhone = me.phoneNumbers.first?.value.stringValue
        } catch {
            // Silently fail — Me Card may not exist
        }
    }
}

// MARK: - Foundation Models Tool Definitions

@Generable
struct WebSearchInput: ConvertibleFromGeneratedContent {
    @Guide(description: "The search query")
    var query: String
}

struct WebSearchTool: Tool {
    typealias Arguments = WebSearchInput
    typealias Output = String
    
    let name = "web_search"
    let description = "Search the web using Google. Use for current events, facts, or anything not in your training data."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: WebSearchInput) async throws -> String {
        let encoded = input.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = URL(string: "https://www.google.com/search?q=\(encoded)")!
        var request = URLRequest(url: url)
        request.addValue("iClaw-macOS-Agent", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""
        let doc = try SwiftSoup.parse(html)
        let results = try doc.select("h3").map { try $0.text() }.prefix(5).joined(separator: "\n")
        return results.isEmpty ? "No results found for '\(input.query)'." : "Search results:\n\(results)"
    }
}

@Generable
struct WikipediaInput: ConvertibleFromGeneratedContent {
    @Guide(description: "The topic to look up on Wikipedia")
    var topic: String
}

struct WikipediaSearchTool: Tool {
    typealias Arguments = WikipediaInput
    typealias Output = String
    
    let name = "wikipedia"
    let description = "Look up a topic on Wikipedia. Returns the article summary. Use for factual questions about people, places, history, science, etc."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: WikipediaInput) async throws -> String {
        let encoded = input.topic.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        // Search for the best matching article
        let searchURL = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(encoded)&limit=1&format=json")!
        let (searchData, _) = try await URLSession.shared.data(from: searchURL)
        guard let json = try JSONSerialization.jsonObject(with: searchData) as? [Any],
              json.count > 1,
              let titles = json[1] as? [String],
              let title = titles.first else {
            return "No Wikipedia article found for '\(input.topic)'."
        }

        // Fetch the article extract
        let titleEncoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let fetchURL = URL(string: "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&exintro=1&titles=\(titleEncoded)&format=json")!
        let (fetchData, _) = try await URLSession.shared.data(from: fetchURL)
        guard let fetchJSON = try JSONSerialization.jsonObject(with: fetchData) as? [String: Any],
              let query = fetchJSON["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any],
              let pageId = pages.keys.first,
              let page = pages[pageId] as? [String: Any],
              let extract = page["extract"] as? String else {
            return "Found '\(title)' but could not fetch content."
        }

        let trimmed = extract.count > 2000 ? String(extract.prefix(2000)) + "..." : extract
        return "\(title):\n\(trimmed)"
    }
}

@Generable
struct CalendarQueryInput: ConvertibleFromGeneratedContent {
    @Guide(description: "What to do: 'list' to see upcoming events, or 'add' to create a new event")
    var action: String
    @Guide(description: "Event title (for 'add' action)")
    var title: String?
    @Guide(description: "Number of days ahead to look (for 'list' action, default 7)")
    var days: Int?
}

struct CalendarTool: Tool {
    typealias Arguments = CalendarQueryInput
    typealias Output = String
    
    let name = "calendar"
    let description = "Manage the user's calendar. List upcoming events or add new ones."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: CalendarQueryInput) async throws -> String {
        let store = EKEventStore()

        // Request access if needed
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            let granted = try await store.requestFullAccessToEvents()
            if !granted {
                return "Calendar access denied by user."
            }
        } else if status != .fullAccess {
            return "Calendar access not authorized. Grant permission in System Settings > Privacy > Calendars."
        }

        if input.action == "add" {
            let event = EKEvent(eventStore: store)
            event.title = input.title ?? "New Event"
            event.startDate = Date().addingTimeInterval(3600)
            event.endDate = event.startDate.addingTimeInterval(3600)
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            return "Event '\(event.title!)' created for \(event.startDate!.formatted())."
        }

        // Default: list upcoming events
        let days = input.days ?? 7
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).prefix(10)

        if events.isEmpty {
            return "No events in the next \(days) days."
        }

        let lines = events.map { "\($0.title ?? "Untitled") — \($0.startDate.formatted(date: .abbreviated, time: .shortened))" }
        return "Upcoming events:\n" + lines.joined(separator: "\n")
    }
}

@Generable
struct ContactsInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Name to search for in contacts")
    var name: String
}

struct ContactsTool: Tool {
    typealias Arguments = ContactsInput
    typealias Output = String
    
    let name = "contacts"
    let description = "Search the user's contacts by name. Returns name, email, and phone number."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: ContactsInput) async throws -> String {
        let store = CNContactStore()

        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            let granted = try await store.requestAccess(for: .contacts)
            if !granted {
                return "Contacts access denied by user."
            }
        } else if status != .authorized {
            return "Contacts access not authorized. Grant permission in System Settings > Privacy > Contacts."
        }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: input.name)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)

        if contacts.isEmpty {
            return "No contacts found matching '\(input.name)'."
        }

        let lines = contacts.prefix(5).map { contact in
            var parts = ["\(contact.givenName) \(contact.familyName)"]
            if let email = contact.emailAddresses.first?.value as String? {
                parts.append(email)
            }
            if let phone = contact.phoneNumbers.first?.value.stringValue {
                parts.append(phone)
            }
            return parts.joined(separator: " — ")
        }
        return lines.joined(separator: "\n")
    }
}

@Generable
struct SpotlightInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Search query for finding files on the Mac")
    var query: String
}

struct SpotlightTool: Tool {
    typealias Arguments = SpotlightInput
    typealias Output = String
    
    let name = "spotlight"
    let description = "Search for files on the user's Mac using Spotlight. Use when the user asks about local files or documents."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: SpotlightInput) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = [input.query]

        let pipe = Pipe()
        task.standardOutput = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let files = output.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(10)

        if files.isEmpty {
            return "No files found matching '\(input.query)'."
        }
        return "Files found:\n" + files.joined(separator: "\n")
    }
}

@Generable
struct ClipboardInput: ConvertibleFromGeneratedContent {
    @Guide(description: "'read' to get clipboard contents, 'write' to set clipboard contents")
    var action: String
    @Guide(description: "Text to copy to clipboard (for 'write' action)")
    var text: String?
}

struct ClipboardTool: Tool {
    typealias Arguments = ClipboardInput
    typealias Output = String
    
    let name = "clipboard"
    let description = "Read or write the system clipboard."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: ClipboardInput) async throws -> String {
        let pasteboard = NSPasteboard.general
        if input.action == "write", let text = input.text {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return "Copied to clipboard."
        }
        return pasteboard.string(forType: .string) ?? "Clipboard is empty."
    }
}

@Generable
struct RemindersInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Action to perform: 'add' to create a reminder")
    var action: String
    @Guide(description: "Title of the reminder")
    var title: String?
}

struct RemindersTool: Tool {
    typealias Arguments = RemindersInput
    typealias Output = String
    
    let name = "reminders"
    let description = "Manage the user's reminders."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: RemindersInput) async throws -> String {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            let granted = try await store.requestFullAccessToReminders()
            if !granted { return "Reminders access denied." }
        } else if status != .fullAccess {
            return "Reminders access not authorized."
        }
        
        if input.action == "add" {
            let reminder = EKReminder(eventStore: store)
            reminder.title = input.title ?? "New Reminder"
            reminder.calendar = store.defaultCalendarForNewReminders()
            try store.save(reminder, commit: true)
            return "Reminder '\(reminder.title!)' added."
        }
        return "Unsupported reminders action."
    }
}

@Generable
struct SystemControlInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Action: 'toggleDarkMode', 'setVolume', 'mute', 'unmute'")
    var action: String
    @Guide(description: "Volume level (0-100)")
    var volumeValue: Int?
}

struct SystemControlTool: Tool {
    typealias Arguments = SystemControlInput
    typealias Output = String
    
    let name = "system_control"
    let description = "Control system settings like volume and appearance."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: SystemControlInput) async throws -> String {
        switch input.action {
        case "toggleDarkMode":
            return executeAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case "setVolume":
            return executeAppleScript("set volume output volume \(input.volumeValue ?? 50)")
        case "mute":
            return executeAppleScript("set volume with output muted")
        case "unmute":
            return executeAppleScript("set volume without output muted")
        default:
            return "Unknown action."
        }
    }
    
    private func executeAppleScript(_ source: String) -> String {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            return error == nil ? "Success." : "Error: \(error!)"
        }
        return "Failed to init script."
    }
}

@Generable
struct AppManagerInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Action: 'launch' or 'quit'")
    var action: String
    @Guide(description: "Name of the application (e.g. 'Safari', 'Notes')")
    var appName: String
}

struct AppManagerTool: Tool {
    typealias Arguments = AppManagerInput
    typealias Output = String
    
    let name = "app_manager"
    let description = "Launch or quit applications."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: AppManagerInput) async throws -> String {
        let workspace = NSWorkspace.shared
        if input.action == "launch" {
            // Attempt to find the app by name in common locations
            let searchPaths = ["/Applications", "/System/Applications", "/System/Cryptexes/App/Applications"]
            var appURL: URL?
            
            for path in searchPaths {
                let url = URL(filePath: "\(path)/\(input.appName).app")
                if FileManager.default.fileExists(atPath: url.path) {
                    appURL = url
                    break
                }
            }
            
            if let targetURL = appURL {
                let config = NSWorkspace.OpenConfiguration()
                try await workspace.openApplication(at: targetURL, configuration: config)
                return "Launched \(input.appName)."
            }
            
            return "Could not find application '\(input.appName)' in standard folders."
        } else if input.action == "quit" {
            let apps = workspace.runningApplications.filter { 
                $0.localizedName?.lowercased() == input.appName.lowercased() 
            }
            for app in apps { app.terminate() }
            return apps.isEmpty ? "'\(input.appName)' is not running." : "Terminated \(input.appName)."
        }
        return "Unknown action."
    }
}

@Generable
struct ReadFileInput: ConvertibleFromGeneratedContent {
    @Guide(description: "The absolute path or tilde-path (e.g. '~/Desktop/file.txt')")
    var path: String
}

struct ReadFileTool: Tool {
    typealias Arguments = ReadFileInput
    typealias Output = String
    
    let name = "read_file"
    let description = "Get a smart summary of a local file or directory. Uses metadata, Neural Engine analysis (for images), and content snippets."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: ReadFileInput) async throws -> String {
        let expandedPath = (input.path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return "Error: File or directory not found at \(input.path)."
        }
        
        if isDir.boolValue {
            return try await summarizeDirectory(at: url)
        }
        
        var report = "--- Smart File Report ---\n"
        report += "Name: \(url.lastPathComponent)\n"
        
        // 1. Basic Metadata & Extended Attributes
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            let size = attributes[.size] as? Int64 ?? 0
            report += "Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))\n"
            if let date = attributes[.creationDate] as? Date {
                report += "Created: \(date.formatted())\n"
            }
        }
        
        // Extended Attributes (xattrs)
        let xattrs = listXattrs(at: url.path)
        if !xattrs.isEmpty {
            report += "Tags/Xattrs: \(xattrs.joined(separator: ", "))\n"
        }
        
        // 2. Spotlight Metadata (MDItem)
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            let interestingKeys: [CFString] = [
                kMDItemWhereFroms, kMDItemTitle, kMDItemDescription, 
                kMDItemAuthors, kMDItemComment, kMDItemKeywords,
                kMDItemCreator, kMDItemVersion
            ]
            for key in interestingKeys {
                if let val = MDItemCopyAttribute(item, key) {
                    let formattedVal = formatMDValue(val)
                    let keyName = key as String
                    report += "\(keyName): \(formattedVal)\n"
                }
            }
        }
        
        // 3. Type-Specific Analysis (Neural Engine & Snippets)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        
        if type.conforms(to: .image) {
            report += "Type: Image\n"
            let imageAnalysis = await analyzeImage(at: url)
            report += "Visual Analysis: \(imageAnalysis)\n"
        } else if type.conforms(to: .pdf) {
            report += "Type: PDF Document\n"
            if let pdf = PDFDocument(url: url) {
                report += "Pages: \(pdf.pageCount)\n"
                if let firstPage = pdf.page(at: 0)?.string {
                    report += "Snippet: \(firstPage.prefix(1500))\n"
                }
            }
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode) || url.pathExtension == "md" {
            report += "Type: Text/Source\n"
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                report += "Snippet: \(content.prefix(2000))\n"
            }
        } else {
            report += "Type: \(type.description)\n"
        }
        
        // 4. Summarize the findings using the internal agent logic
        let finalSummary = await SummarizationManager.shared.summarize(text: report)
        return "Analysis for \(url.lastPathComponent):\n\(finalSummary)"
    }
    
    private func summarizeDirectory(at url: URL) async throws -> String {
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.nameKey, .fileSizeKey], options: .skipsHiddenFiles)
        let fileList = contents.prefix(20).map { $0.lastPathComponent }.joined(separator: ", ")
        let report = "Directory: \(url.lastPathComponent)\nContains \(contents.count) items. \nFirst few: \(fileList)"
        return await SummarizationManager.shared.summarize(text: report)
    }
    
    private func listXattrs(at path: String) -> [String] {
        let size = listxattr(path, nil, 0, 0)
        if size <= 0 { return [] }
        var data = Data(count: size)
        data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            _ = listxattr(path, ptr.baseAddress, size, 0)
        }
        let names = String(data: data, encoding: .utf8)?.split(separator: "\0").map(String.init) ?? []
        return names.filter { !$0.starts(with: "com.apple.lastuseddate") && !$0.starts(with: "com.apple.quarantine") }
    }
    
    private func formatMDValue(_ value: CFTypeRef) -> String {
        if let str = value as? String { return str }
        if let arr = value as? [String] { return arr.joined(separator: ", ") }
        if let date = value as? Date { return date.formatted() }
        if let num = value as? NSNumber { return num.stringValue }
        return "\(value)"
    }
    
    private func analyzeImage(at url: URL) async -> String {
        guard let data = try? Data(contentsOf: url) else { return "Could not read image data." }
        let requestHandler = VNImageRequestHandler(data: data)
        
        let classifyRequest = VNClassifyImageRequest()
        let ocrRequest = VNRecognizeTextRequest()
        ocrRequest.recognitionLevel = .accurate
        
        do {
            // VN Requests automatically leverage the Neural Engine on Apple Silicon
            try requestHandler.perform([classifyRequest, ocrRequest])
            
            var results: [String] = []
            
            // 1. Classification
            if let observations = classifyRequest.results {
                let labels = observations.prefix(3)
                    .filter { $0.confidence > 0.8 }
                    .map { $0.identifier }
                if !labels.isEmpty {
                    results.append("Objects: \(labels.joined(separator: ", "))")
                }
            }
            
            // 2. OCR
            if let ocrResults = ocrRequest.results {
                let topOCR = ocrResults.prefix(15)
                    .compactMap { $0.topCandidates(1).first?.string }
                if !topOCR.isEmpty {
                    results.append("Text found: \(topOCR.joined(separator: " ").prefix(300))")
                }
            }
            
            return results.isEmpty ? "No high-confidence visual data." : results.joined(separator: " | ")
        } catch {
            return "Vision analysis failed: \(error.localizedDescription)"
        }
    }
}

@Generable
struct FetchInput: ConvertibleFromGeneratedContent {
    @Guide(description: "The URL to fetch")
    var url: String
}

struct FetchTool: Tool {
    typealias Arguments = FetchInput
    typealias Output = String
    
    let name = "fetch"
    let description = "Perform a browser-like HTTP GET request to a URL."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: FetchInput) async throws -> String {
        guard let url = URL(string: input.url) else { return "Invalid URL." }
        var request = URLRequest(url: url)
        request.addValue("iClaw-macOS-Agent", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""
        
        if html.count > 3000 {
            let summary = await SummarizationManager.shared.summarize(text: html)
            return "Fetched data (Summarized):\n\(summary)"
        }
        
        return html
    }
}

@Generable
struct SummarizeInput: ConvertibleFromGeneratedContent {
    @Guide(description: "The text to summarize")
    var text: String
}

struct SummarizeTool: Tool {
    typealias Arguments = SummarizeInput
    typealias Output = String
    
    let name = "summarize"
    let description = "Summarize long text into a shorter version using NER and extraction."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: SummarizeInput) async throws -> String {
        return await SummarizationManager.shared.summarize(text: input.text)
    }
}

@Generable
struct WeatherInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Optional city or location name. If omitted, uses the current location.")
    var locationName: String?
}

struct WeatherTool: Tool {
    typealias Arguments = WeatherInput
    typealias Output = String
    
    let name = "weather"
    let description = "Get the current weather for a specific location or the user's current location."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: WeatherInput) async throws -> String {
        var lat: Double
        var lon: Double
        var resolvedName: String

        let useFahrenheit = Locale.current.measurementSystem == .us || Locale.current.region?.identifier == "US"
        let unitParam = useFahrenheit ? "&temperature_unit=fahrenheit" : ""
        let unitLabel = useFahrenheit ? "°F" : "°C"

        if let name = input.locationName, !name.isEmpty {
            // Use Nominatim for geocoding
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let nominatimURL = URL(string: "https://nominatim.openstreetmap.org/search?q=\(encodedName)&format=json&limit=1")!
            
            var request = URLRequest(url: nominatimURL)
            request.addValue("iClaw-macOS-Agent", forHTTPHeaderField: "User-Agent")
            
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = json.first,
                  let latStr = first["lat"] as? String,
                  let lonStr = first["lon"] as? String,
                  let l = Double(latStr),
                  let o = Double(lonStr) else {
                return "Could not find coordinates for '\(name)' using Nominatim."
            }
            lat = l
            lon = o
            resolvedName = first["display_name"] as? String ?? name
        } else {
            // Use current location
            do {
                let location = try await LocationManager.shared.getCurrentLocation()
                lat = location.coordinate.latitude
                lon = location.coordinate.longitude
                resolvedName = "your current location"
            } catch {
                return "Failed to get current location: \(error.localizedDescription)"
            }
        }

        // Fetch weather from Open-Meteo
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current_weather=true\(unitParam)"
        guard let url = URL(string: urlString) else { return "Invalid weather URL." }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current_weather"] as? [String: Any],
              let temp = current["temperature"] as? Double,
              let windspeed = current["windspeed"] else {
            return "Could not parse weather data for \(resolvedName)."
        }
        
        let roundedTemp = Int(temp.rounded())
        return "Current weather for \(resolvedName):\n- Temperature: \(roundedTemp)\(unitLabel)\n- Wind Speed: \(windspeed) km/h"
    }
}

@Generable
struct NotesInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Action: 'create' to make a new note, 'append' to add to an existing note, 'search' to find notes")
    var action: String
    @Guide(description: "Title of the note (used for search or when creating)")
    var title: String
    @Guide(description: "Content of the note (for 'create' or 'append' actions)")
    var body: String?
}

struct NotesTool: Tool {
    typealias Arguments = NotesInput
    typealias Output = String
    
    let name = "notes"
    let description = "Create, search, or append to notes in the macOS Notes app."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: NotesInput) async throws -> String {
        let escapedTitle = input.title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = (input.body ?? "").replacingOccurrences(of: "\"", with: "\\\"")

        switch input.action {
        case "create":
            let script = """
            tell application "Notes"
                tell account "iCloud"
                    make new note at folder "Notes" with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
                end tell
            end tell
            """
            return executeAppleScript(script)
            
        case "search":
            return executeAppleScript("tell application \"Notes\" to get name of every note whose name contains \"\(escapedTitle)\"")
            
        case "append":
            guard !escapedBody.isEmpty else { return "Body required for append." }
            let script = """
            tell application "Notes"
                set theNotes to notes whose name is "\(escapedTitle)"
                if (count of theNotes) is 0 then
                    return "Note '\(escapedTitle)' not found."
                else
                    set theNote to item 1 of theNotes
                    set oldBody to body of theNote
                    set body of theNote to oldBody & "<br><br>" & "\(escapedBody)"
                    return "Appended to '\(escapedTitle)'."
                end if
            end tell
            """
            return executeAppleScript(script)
            
        default:
            return "Unknown action."
        }
    }
    
    private func executeAppleScript(_ source: String) -> String {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let err = error {
                return "Notes Error: \(err)"
            }
            return result.stringValue ?? "Success."
        }
        return "Failed to init AppleScript."
    }
}

@Generable
struct PodcastInput: ConvertibleFromGeneratedContent {
    @Guide(description: "What to do: 'search' for podcasts, 'episodes' to list latest episodes, or 'play' an episode")
    var action: String
    
    @Guide(description: "Search keywords (for 'search' or 'episodes')")
    var query: String?
    
    @Guide(description: "The collection ID of the podcast (for 'episodes')")
    var collectionId: String?
    
    @Guide(description: "The track ID of the episode (for 'play')")
    var episodeId: String?
    
    @Guide(description: "How many items to return (default 5)")
    var limit: Int?
}

struct PodcastTool: Tool {
    typealias Arguments = PodcastInput
    typealias Output = String

    let name = "podcast"
    let description = "Interact with Apple Podcasts: search for shows, list episodes, or play them."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: PodcastInput) async throws -> String {
        let limit = min(input.limit ?? 5, 20)
        let action = input.action.lowercased().trimmingCharacters(in: .whitespaces)

        if action == "search" {
            guard let query = input.query, !query.isEmpty else {
                return "Provide a search query to find podcasts."
            }
            return try await searchPodcasts(query: query, limit: limit)
        } else if action == "episodes" {
            if let collectionId = input.collectionId, let id = Int(collectionId) {
                return try await lookupEpisodes(collectionId: id, limit: limit)
            } else if let query = input.query, !query.isEmpty {
                return try await searchEpisodes(query: query, limit: limit)
            }
            return "Provide a collectionId or podcast name to list episodes."
        } else if action == "play" {
            if let episodeId = input.episodeId, let id = Int(episodeId) {
                return await playEpisode(episodeId: id)
            }
            return "Provide an episodeId to play."
        }
        
        return "Unknown action '\(action)'. Valid actions are 'search', 'episodes', or 'play'."
    }

    private func searchPodcasts(query: String, limit: Int) async throws -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=podcast&limit=\(limit)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty else {
            return "No podcasts found for '\(query)'."
        }

        var lines: [String] = []
        for r in results {
            let name = r["collectionName"] as? String ?? "Unknown"
            let artist = r["artistName"] as? String ?? ""
            let id = r["collectionId"] as? Int ?? 0
            let genre = r["primaryGenreName"] as? String ?? ""
            let count = r["trackCount"] as? Int ?? 0
            lines.append("- \(name) by \(artist) [\(genre), \(count) episodes] (collectionId: \(id))")
        }
        return "Podcasts matching '\(query)':\n" + lines.joined(separator: "\n")
    }

    private func lookupEpisodes(collectionId: Int, limit: Int) async throws -> String {
        let url = URL(string: "https://itunes.apple.com/lookup?id=\(collectionId)&entity=podcastEpisode&limit=\(limit)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return "Could not fetch episodes for collectionId \(collectionId)."
        }

        // First result is the podcast itself; rest are episodes
        let episodes = results.filter { ($0["wrapperType"] as? String) == "podcastEpisode" }
        guard !episodes.isEmpty else {
            return "No episodes found."
        }

        let podcastName = results.first?["collectionName"] as? String ?? "Podcast"
        var lines: [String] = ["Latest episodes of \(podcastName):"]

        for ep in episodes {
            let title = ep["trackName"] as? String ?? "Untitled"
            let epId = ep["trackId"] as? Int ?? 0
            let date = ep["releaseDate"] as? String ?? ""
            let shortDate = String(date.prefix(10))
            let desc = ep["shortDescription"] as? String ?? ""
            let descTrimmed = desc.count > 100 ? String(desc.prefix(100)) + "..." : desc
            lines.append("- [\(shortDate)] \(title) (episodeId: \(epId))")
            if !descTrimmed.isEmpty {
                lines.append("  \(descTrimmed)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func searchEpisodes(query: String, limit: Int) async throws -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=podcastEpisode&limit=\(limit)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty else {
            return "No episodes found for '\(query)'."
        }

        var lines: [String] = ["Episodes matching '\(query)':"]
        for ep in results {
            let title = ep["trackName"] as? String ?? "Untitled"
            let show = ep["collectionName"] as? String ?? ""
            let epId = ep["trackId"] as? Int ?? 0
            let date = ep["releaseDate"] as? String ?? ""
            let shortDate = String(date.prefix(10))
            lines.append("- [\(shortDate)] \(title) — \(show) (episodeId: \(epId))")
        }
        return lines.joined(separator: "\n")
    }

    private func playEpisode(episodeId: Int) async -> String {
        // Look up the ID — could be an episode trackId or a podcast collectionId
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(episodeId)&entity=podcastEpisode&limit=1"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              !results.isEmpty else {
            return "Could not find episode \(episodeId)."
        }

        // Find the episode object — if the ID was a collectionId, the first result is the
        // podcast itself and the second is the latest episode. If it was an episodeId,
        // the first result is the episode directly.
        let ep = results.first(where: { ($0["wrapperType"] as? String) == "podcastEpisode" })
            ?? results.first!

        let title = ep["trackName"] as? String ?? "Unknown Episode"
        let show = ep["collectionName"] as? String ?? ""

        // episodeUrl is the direct audio stream URL from the iTunes API
        guard let streamURLString = ep["episodeUrl"] as? String,
              let streamURL = URL(string: streamURLString) else {
            // Fallback: open in Apple Podcasts if no stream URL
            if let viewURLString = ep["trackViewUrl"] as? String,
               let viewURL = URL(string: viewURLString) {
                NSWorkspace.shared.open(viewURL)
                return "No stream URL available. Opening '\(title)' in Apple Podcasts instead."
            }
            return "No playable URL found for episode \(episodeId)."
        }

        await PodcastPlayerManager.shared.play(url: streamURL, title: title, show: show)
        return "Now playing '\(title)' from \(show). Use the player controls to pause, scrub, or stop."
    }
}

@Generable
struct CameraInput: ConvertibleFromGeneratedContent {
    @Guide(description: "What to do: 'take_photo' to capture an image")
    var action: String
}

struct CameraTool: Tool {
    typealias Arguments = CameraInput
    typealias Output = String
    
    let name = "camera"
    let description = "Take a photo using the Mac's camera and open it in Preview."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: CameraInput) async throws -> String {
        guard input.action == "take_photo" else { return "Unknown camera action." }
        
        do {
            let photoURL = try await CameraManager.shared.takePhoto()
            return "PHOTO_CAPTURED:\(photoURL.path)"
        } catch {
            return "Camera error: \(error.localizedDescription)"
        }
    }
}

@Generable
struct CurrencyInput: ConvertibleFromGeneratedContent {
    @Guide(description: "The source currency code (e.g., 'usd', 'eur', 'gbp')")
    var from: String
    @Guide(description: "The target currency code (e.g., 'eur', 'jpy', 'cad')")
    var to: String
    @Guide(description: "The amount to convert (default 1.0)")
    var amount: Double?
}

struct CurrencyTool: Tool {
    typealias Arguments = CurrencyInput
    typealias Output = String
    
    let name = "currency_converter"
    let description = "Convert between different currencies using real-time exchange rates."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: CurrencyInput) async throws -> String {
        let from = input.from.lowercased().trimmingCharacters(in: .whitespaces)
        let to = input.to.lowercased().trimmingCharacters(in: .whitespaces)
        let amount = input.amount ?? 1.0
        
        // Using the recommended jsdelivr endpoint from the fawazahmed0/exchange-api
        let urlString = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/\(from).json"
        guard let url = URL(string: urlString) else { return "Invalid currency code." }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = json[from] as? [String: Any],
                  let rate = rates[to] as? Double else {
                return "Could not find exchange rate from \(from.uppercased()) to \(to.uppercased())."
            }
            
            let converted = amount * rate
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            
            let formattedAmount = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
            let formattedResult = formatter.string(from: NSNumber(value: converted)) ?? "\(converted)"
            
            return "\(formattedAmount) \(from.uppercased()) is approximately \(formattedResult) \(to.uppercased()) (Rate: \(rate))."
        } catch {
            return "Error fetching exchange rates: \(error.localizedDescription)"
        }
    }
}

// MARK: - HealthKit Tool

@Generable
struct HealthInput: ConvertibleFromGeneratedContent {
    @Guide(description: "What to query: 'steps', 'heart_rate', 'active_energy', 'resting_energy', 'distance', 'flights_climbed', 'exercise_minutes', 'sleep', 'weight', 'body_fat', 'blood_oxygen', 'respiratory_rate', or 'summary' for an overview")
    var metric: String

    @Guide(description: "Time range: 'today', 'week', or 'month' (default 'today')")
    var period: String?
}

struct HealthTool: Tool {
    typealias Arguments = HealthInput
    typealias Output = String

    let name = "health"
    let description = "Query the user's Apple Health data: steps, heart rate, calories, distance, sleep, weight, and more."
    var parameters: GenerationSchema { Arguments.generationSchema }

    private let store = HKHealthStore()

    func call(arguments input: HealthInput) async throws -> String {
        let metric = input.metric.lowercased().trimmingCharacters(in: .whitespaces)
        let period = input.period?.lowercased().trimmingCharacters(in: .whitespaces) ?? "today"

        // Determine date range
        let now = Date()
        let calendar = Calendar.current
        let startDate: Date
        switch period {
        case "week":
            startDate = calendar.date(byAdding: .day, value: -7, to: now)!
        case "month":
            startDate = calendar.date(byAdding: .month, value: -1, to: now)!
        default: // "today"
            startDate = calendar.startOfDay(for: now)
        }

        if metric == "summary" {
            return await fetchSummary(start: startDate, end: now, period: period)
        }

        guard let typeInfo = healthTypeInfo(for: metric) else {
            return "Unknown metric '\(metric)'. Try: steps, heart_rate, active_energy, resting_energy, distance, flights_climbed, exercise_minutes, sleep, weight, body_fat, blood_oxygen, respiratory_rate, or summary."
        }

        // Only request authorization if not already determined
        if let authResult = await ensureAuthorization(for: [typeInfo.sampleType]) {
            return authResult
        }

        if typeInfo.isQuantity, let quantityType = typeInfo.sampleType as? HKQuantityType {
            if typeInfo.useMostRecent {
                return await fetchMostRecent(type: quantityType, unit: typeInfo.unit!, label: typeInfo.label)
            } else {
                return await fetchCumulativeOrAverage(type: quantityType, unit: typeInfo.unit!, label: typeInfo.label, isCumulative: typeInfo.isCumulative, start: startDate, end: now, period: period)
            }
        } else if metric == "sleep", let categoryType = typeInfo.sampleType as? HKCategoryType {
            return await fetchSleep(type: categoryType, start: startDate, end: now, period: period)
        }

        return "Could not fetch \(metric) data."
    }

    /// Returns nil on success, or an error message string if authorization failed.
    private func ensureAuthorization(for types: Set<HKSampleType>) async -> String? {
        // Check if all types are already authorized (sharingDenied means "not determined or denied for read",
        // but HealthKit intentionally hides read denial — so we request if not sharingAuthorized for any type,
        // which is safe because re-requesting for already-authorized types is a no-op).
        let needsRequest = types.contains { type in
            store.authorizationStatus(for: type) != .sharingAuthorized
        }

        if needsRequest {
            do {
                try await store.requestAuthorization(toShare: [], read: types)
            } catch {
                return "Health access denied. Grant permission in System Settings > Privacy > Health."
            }
        }

        return nil
    }

    // MARK: - Type Mapping

    private struct HealthTypeMapping {
        let sampleType: HKSampleType
        let unit: HKUnit?
        let label: String
        let isQuantity: Bool
        let isCumulative: Bool
        let useMostRecent: Bool
    }

    private func healthTypeInfo(for metric: String) -> HealthTypeMapping? {
        switch metric {
        case "steps":
            return HealthTypeMapping(sampleType: HKQuantityType(.stepCount), unit: .count(), label: "Steps", isQuantity: true, isCumulative: true, useMostRecent: false)
        case "heart_rate":
            return HealthTypeMapping(sampleType: HKQuantityType(.heartRate), unit: HKUnit.count().unitDivided(by: .minute()), label: "Heart Rate (bpm)", isQuantity: true, isCumulative: false, useMostRecent: false)
        case "active_energy":
            return HealthTypeMapping(sampleType: HKQuantityType(.activeEnergyBurned), unit: .kilocalorie(), label: "Active Energy (kcal)", isQuantity: true, isCumulative: true, useMostRecent: false)
        case "resting_energy":
            return HealthTypeMapping(sampleType: HKQuantityType(.basalEnergyBurned), unit: .kilocalorie(), label: "Resting Energy (kcal)", isQuantity: true, isCumulative: true, useMostRecent: false)
        case "distance":
            return HealthTypeMapping(sampleType: HKQuantityType(.distanceWalkingRunning), unit: .meterUnit(with: .kilo), label: "Distance (km)", isQuantity: true, isCumulative: true, useMostRecent: false)
        case "flights_climbed":
            return HealthTypeMapping(sampleType: HKQuantityType(.flightsClimbed), unit: .count(), label: "Flights Climbed", isQuantity: true, isCumulative: true, useMostRecent: false)
        case "exercise_minutes":
            return HealthTypeMapping(sampleType: HKQuantityType(.appleExerciseTime), unit: .minute(), label: "Exercise Minutes", isQuantity: true, isCumulative: true, useMostRecent: false)
        case "weight":
            return HealthTypeMapping(sampleType: HKQuantityType(.bodyMass), unit: .gramUnit(with: .kilo), label: "Weight (kg)", isQuantity: true, isCumulative: false, useMostRecent: true)
        case "body_fat":
            return HealthTypeMapping(sampleType: HKQuantityType(.bodyFatPercentage), unit: .percent(), label: "Body Fat (%)", isQuantity: true, isCumulative: false, useMostRecent: true)
        case "blood_oxygen":
            return HealthTypeMapping(sampleType: HKQuantityType(.oxygenSaturation), unit: .percent(), label: "Blood Oxygen (%)", isQuantity: true, isCumulative: false, useMostRecent: true)
        case "respiratory_rate":
            return HealthTypeMapping(sampleType: HKQuantityType(.respiratoryRate), unit: HKUnit.count().unitDivided(by: .minute()), label: "Respiratory Rate (breaths/min)", isQuantity: true, isCumulative: false, useMostRecent: true)
        case "sleep":
            return HealthTypeMapping(sampleType: HKCategoryType(.sleepAnalysis), unit: nil, label: "Sleep", isQuantity: false, isCumulative: false, useMostRecent: false)
        default:
            return nil
        }
    }

    // MARK: - Fetchers

    private func fetchCumulativeOrAverage(type: HKQuantityType, unit: HKUnit, label: String, isCumulative: Bool, start: Date, end: Date, period: String) async -> String {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let options: HKStatisticsOptions = isCumulative ? .cumulativeSum : .discreteAverage

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, stats, error in
                if let error {
                    continuation.resume(returning: "Error fetching \(label): \(error.localizedDescription)")
                    return
                }
                guard let stats else {
                    continuation.resume(returning: "No \(label.lowercased()) data for \(period).")
                    return
                }

                let value: Double
                if isCumulative {
                    value = stats.sumQuantity()?.doubleValue(for: unit) ?? 0
                } else {
                    value = stats.averageQuantity()?.doubleValue(for: unit) ?? 0
                }

                let formatted = Self.formatNumber(value)
                let qualifier = isCumulative ? "Total" : "Average"
                continuation.resume(returning: "\(label) (\(period)): \(qualifier) \(formatted)")
            }
            store.execute(query)
        }
    }

    private func fetchMostRecent(type: HKQuantityType, unit: HKUnit, label: String) async -> String {
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sortDescriptor]) { _, samples, error in
                if let error {
                    continuation.resume(returning: "Error fetching \(label): \(error.localizedDescription)")
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: "No \(label.lowercased()) data recorded.")
                    return
                }

                let value = sample.quantity.doubleValue(for: unit)
                let formatted = Self.formatNumber(value)
                let date = sample.startDate.formatted(date: .abbreviated, time: .shortened)
                continuation.resume(returning: "\(label): \(formatted) (recorded \(date))")
            }
            store.execute(query)
        }
    }

    private func fetchSleep(type: HKCategoryType, start: Date, end: Date, period: String) async -> String {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 50, sortDescriptors: [sortDescriptor]) { _, samples, error in
                if let error {
                    continuation.resume(returning: "Error fetching sleep data: \(error.localizedDescription)")
                    return
                }
                guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
                    continuation.resume(returning: "No sleep data for \(period).")
                    return
                }

                // Sum up time in each sleep stage
                var asleepSeconds: TimeInterval = 0
                var inBedSeconds: TimeInterval = 0

                for sample in samples {
                    let duration = sample.endDate.timeIntervalSince(sample.startDate)
                    let value = HKCategoryValueSleepAnalysis(rawValue: sample.value)
                    switch value {
                    case .inBed:
                        inBedSeconds += duration
                    case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM:
                        asleepSeconds += duration
                    default:
                        break
                    }
                }

                let totalAsleep = Self.formatDuration(asleepSeconds)
                let totalInBed = Self.formatDuration(inBedSeconds)
                continuation.resume(returning: "Sleep (\(period)): \(totalAsleep) asleep, \(totalInBed) in bed")
            }
            store.execute(query)
        }
    }

    private func fetchSummary(start: Date, end: Date, period: String) async -> String {
        let summaryTypes: Set<HKSampleType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.heartRate),
            HKCategoryType(.sleepAnalysis),
        ]

        if let authResult = await ensureAuthorization(for: summaryTypes) {
            return authResult
        }

        async let steps = fetchCumulativeOrAverage(type: HKQuantityType(.stepCount), unit: .count(), label: "Steps", isCumulative: true, start: start, end: end, period: period)
        async let energy = fetchCumulativeOrAverage(type: HKQuantityType(.activeEnergyBurned), unit: .kilocalorie(), label: "Active Energy (kcal)", isCumulative: true, start: start, end: end, period: period)
        async let distance = fetchCumulativeOrAverage(type: HKQuantityType(.distanceWalkingRunning), unit: .meterUnit(with: .kilo), label: "Distance (km)", isCumulative: true, start: start, end: end, period: period)
        async let exercise = fetchCumulativeOrAverage(type: HKQuantityType(.appleExerciseTime), unit: .minute(), label: "Exercise Minutes", isCumulative: true, start: start, end: end, period: period)
        async let heartRate = fetchCumulativeOrAverage(type: HKQuantityType(.heartRate), unit: HKUnit.count().unitDivided(by: .minute()), label: "Heart Rate (bpm)", isCumulative: false, start: start, end: end, period: period)
        async let sleep = fetchSleep(type: HKCategoryType(.sleepAnalysis), start: start, end: end, period: period)

        let results = await [steps, energy, distance, exercise, heartRate, sleep]
        return "Health Summary (\(period)):\n" + results.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && value < 100000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - ModelManager

@MainActor
class ModelManager {
    static let shared = ModelManager()

    private var soul: String = ""

    private init() {
        if let soulPath = Bundle.main.path(forResource: "SOUL", ofType: "md"),
           let content = try? String(contentsOfFile: soulPath, encoding: .utf8) {
            self.soul = content
        } else {
            self.soul = "You are a local macOS AI agent. Be terse, sassy, and direct."
        }
    }

    func generateSystemPrompt() -> String {
        let me = MeCardManager.shared
        var parts = [soul]

        var userInfo = "User: \(me.userName)"
        if let email = me.userEmail { userInfo += ", Email: \(email)" }
        if let phone = me.userPhone { userInfo += ", Phone: \(phone)" }
        parts.append(userInfo)

        return parts.joined(separator: "\n\n")
    }

    private var tools: [any Tool] {
        [
            WebSearchTool(),
            WikipediaSearchTool(),
            CalendarTool(),
            ContactsTool(),
            SpotlightTool(),
            ClipboardTool(),
            RemindersTool(),
            SystemControlTool(),
            AppManagerTool(),
            SummarizeTool(),
            WeatherTool(),
            ReadFileTool(),
            FetchTool(),
            PodcastTool(),
            NotesTool(),
            CurrencyTool(),
            CameraTool(),
            HealthTool(),
        ]
    }


    func generateResponse(prompt: String, history: [Memory]) async throws -> String {
        let systemPrompt = generateSystemPrompt()

        // Build a proper Transcript from history to keep turns separated
        var entries: [Transcript.Entry] = []
        
        // 1. Add System Instructions
        let instructions = Transcript.Instructions(segments: [.text(Transcript.TextSegment(content: systemPrompt))], toolDefinitions: [])
        entries.append(.instructions(instructions))
        
        // 2. Add History as individual turns
        for memory in history.suffix(10) {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: memory.content))
            if memory.role == "user" {
                let promptEntry = Transcript.Prompt(segments: [segment])
                entries.append(.prompt(promptEntry))
            } else if memory.role == "agent" {
                let responseEntry = Transcript.Response(assetIDs: [], segments: [segment])
                entries.append(.response(responseEntry))
            }
        }

        let transcript = Transcript(entries: entries)
        let session = LanguageModelSession(model: .default, tools: tools, transcript: transcript)
        
        // 3. Respond to the latest prompt
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
