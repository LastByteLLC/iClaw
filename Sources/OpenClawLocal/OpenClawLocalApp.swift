import SwiftUI
import AppKit

@main
struct OpenClawLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem?
    var hudWindow: NSPanel?
    var heartbeatTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHUDWindow()
        startHeartbeat()
        
        // Ensure database is initialized
        _ = DatabaseManager.shared
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "OpenClaw Local")
            button.action = #selector(toggleWindow)
            button.target = self
        }
    }

    private func setupHUDWindow() {
        hudWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.nonactivatingPanel, .hudWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hudWindow?.isFloatingPanel = true
        hudWindow?.level = .floating
        hudWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hudWindow?.backgroundColor = .clear
        hudWindow?.contentView = NSHostingView(rootView: ChatView())
    }

    @objc func toggleWindow() {
        guard let hudWindow = hudWindow else { return }
        if hudWindow.isVisible {
            hudWindow.orderOut(nil)
        } else {
            // Position near the status item
            if let button = statusItem?.button, let window = button.window {
                let frame = window.frame
                hudWindow.setFrameOrigin(NSPoint(x: frame.minX - hudWindow.frame.width / 2 + frame.width / 2, y: frame.minY - hudWindow.frame.height - 5))
            }
            hudWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    private func startHeartbeat() {
        // 15-minute heartbeat
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.runHeartbeatAction()
            }
        }
    }
    
    private func runHeartbeatAction() async {
        print("Running 15-minute heartbeat...")
        do {
            try await DatabaseManager.shared.compactMemoriesIfNeeded()
            // In a real implementation, the agent would "think" here
        } catch {
            print("Heartbeat error: \(error)")
        }
    }
}

struct ChatView: View {
    @State private var input: String = ""
    @State private var messages: [Message] = [
        Message(role: "agent", content: "I'm your local AI agent. Ready to help.")
    ]
    @State private var t: Float = 0.0

    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            
            messageList
            
            inputField
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                
                if #available(macOS 15.0, *) {
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: [
                            [0, 0], [0.5, 0], [1, 0],
                            [0, 0.5], [0.5 + 0.1 * sin(t), 0.5 + 0.1 * cos(t)], [1, 0.5],
                            [0, 1], [0.5, 1], [1, 1]
                        ],
                        colors: [
                            .blue.opacity(0.1), .purple.opacity(0.1), .blue.opacity(0.1),
                            .indigo.opacity(0.1), .clear, .indigo.opacity(0.1),
                            .blue.opacity(0.1), .purple.opacity(0.1), .blue.opacity(0.1)
                        ]
                    )
                    .onReceive(timer) { _ in
                        t += 0.1
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .padding(10)
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
    }

    private var header: some View {
        HStack {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.primary)
            
            Text("OpenClaw Local")
                .font(.headline)
                .foregroundStyle(.primary)
            
            Spacer()
            
            Button {
                // Action
            } label: {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var messageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(messages) { message in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(.primary.opacity(0.1))
                            .frame(width: 32, height: 32)
                            .overlay {
                                Image(systemName: message.role == "user" ? "person.fill" : "sparkles")
                                    .font(.caption2)
                            }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == "user" ? "You" : "OpenClaw")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Text(message.content)
                                .padding(12)
                                .background(message.role == "user" ? .blue.opacity(0.2) : .white.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var inputField: some View {
        VStack(spacing: 0) {
            Divider()
                .background(.white.opacity(0.1))
            
            HStack(spacing: 12) {
                TextField("Message OpenClaw...", text: $input)
                    .textFieldStyle(.plain)
                    .font(.body)
                
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                
                Button {
                    // STT action via SpeechManager
                    if SpeechManager.shared.isRecording {
                        SpeechManager.shared.stopRecording()
                        input = SpeechManager.shared.transcription
                    } else {
                        SpeechManager.shared.startRecording()
                    }
                } label: {
                    Image(systemName: SpeechManager.shared.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.title2)
                        .foregroundStyle(SpeechManager.shared.isRecording ? .red : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.black.opacity(0.2))
        }
    }
    
    private func sendMessage() {
        guard !input.isEmpty else { return }
        let userContent = input
        messages.append(Message(role: "user", content: userContent))
        input = ""
        
        Task {
            do {
                let response = try await ModelManager.shared.generateResponse(prompt: userContent, history: [])
                messages.append(Message(role: "agent", content: response))
                
                // Save to database
                let userMemory = Memory(id: nil, role: "user", content: userContent, embedding: nil, created_at: Date(), is_important: false)
                _ = try await DatabaseManager.shared.saveMemory(userMemory)
                
                let agentMemory = Memory(id: nil, role: "agent", content: response, embedding: nil, created_at: Date(), is_important: false)
                _ = try await DatabaseManager.shared.saveMemory(agentMemory)
            } catch {
                print("Error: \(error)")
            }
        }
    }
}

struct Message: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
