import SwiftUI
import AppKit
import AVFoundation

@main
struct iClawApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem?
    var hudWindow: FloatingPanel?
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
            button.image = NSImage.clawApple
            button.action = #selector(toggleWindow)
            button.target = self
        }
    }

    private func setupHUDWindow() {
        hudWindow = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        hudWindow?.isFloatingPanel = true
        hudWindow?.level = .floating
        hudWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hudWindow?.backgroundColor = .clear
        hudWindow?.isOpaque = false
        hudWindow?.hasShadow = false
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
        } catch {
            print("Heartbeat error: \(error)")
        }
    }
}

// MARK: - Thinking Phrases

private let thinkingPhrases: [String] = [
    "Crunching neurons",
    "Consulting the silicon oracle",
    "Rummaging through knowledge",
    "Warming up the tensor cores",
    "Parsing the universe",
    "Asking the matrix",
    "Running inference",
    "Spinning up attention heads",
    "Traversing the latent space",
    "Decoding reality",
    "Collapsing probability waves",
    "Tokenizing thoughts",
    "Sampling from the void",
    "Gradient descending",
    "Attending to your query",
    "Softmaxing possibilities",
    "Embedding your question",
    "Searching the weight space",
    "Propagating forward",
    "Activating layers",
    "Fetching from context",
    "Unrolling sequences",
    "Normalizing batches",
    "Pooling representations",
    "Computing dot products",
    "Interpolating knowledge",
    "Indexing memories",
    "Cross-referencing data",
    "Mining the attention map",
    "Querying the knowledge graph",
    "Scanning local files",
    "Running locally, staying private",
    "No cloud needed",
    "Processing on-device",
    "Calculating response vectors",
    "Synthesizing an answer",
    "Evaluating candidates",
    "Ranking possibilities",
    "Assembling the response",
    "Checking my notes",
    "Sifting through context",
    "Weighing the evidence",
    "Juggling embeddings",
    "Aligning representations",
    "Compressing world knowledge",
    "Bootstrapping reasoning",
    "Iterating on hypotheses",
    "Refining the signal",
    "Filtering the noise",
    "Calibrating confidence",
    "Mapping concepts",
    "Bridging semantics",
    "Resolving ambiguity",
    "Chasing the gradient",
    "Maximizing likelihood",
    "Minimizing perplexity",
    "Optimizing tokens",
    "Backpropagating insight",
    "Fusing attention heads",
    "Distilling knowledge",
    "Pruning dead ends",
    "Exploring the search tree",
    "Skating on the loss surface",
    "Surfing the manifold",
    "Riding the compute wave",
    "Burning through FLOPS",
    "Squeezing the Neural Engine",
    "Waking up the GPU",
    "Flexing the M-series",
    "Vectorizing thoughts",
    "Tiling the matrix multiply",
    "Dispatching work items",
    "Filling the pipeline",
    "Pipelining the fill",
    "Unboxing parameters",
    "Hydrating the model",
    "Warming the KV cache",
    "Prefetching context",
    "Speculatively decoding",
    "Beam searching",
    "Greedy sampling",
    "Temperature scaling",
    "Top-p filtering",
    "Nucleus sampling",
    "Logit processing",
    "Embedding lookup",
    "Position encoding",
    "Masking the future",
    "Causal reasoning",
    "Self-attending",
    "Cross-attending",
    "Feed-forwarding",
    "Layer norming",
    "Residual connecting",
    "Skip connecting",
    "GELU activating",
    "SiLU switching",
    "RoPE rotating",
    "Flash attending",
    "KV caching",
    "Quantizing precision",
    "Searching the dark web",
    "Raging against the machines",
    "Asking the AI overlords",
    "Simulating thought",
    "Calculating the meaning of life",
    "Contemplatizating",
    "Put the key in the ignition",
    "Engaging the neural thrusters",
]

struct ChatView: View {
    @State private var input: String = ""
    @State private var messages: [Message] = [
        Message(role: "agent", content: "I'm your local AI agent. Ready to help.")
    ]
    @State private var t: Float = 0.0
    @State private var isThinking = false
    @State private var thinkingPhrase = thinkingPhrases.randomElement()!
    @ObservedObject private var speechManager = SpeechManager.shared
    @ObservedObject private var podcastPlayer = PodcastPlayerManager.shared

    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    let phraseTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header

            messageList

            if podcastPlayer.isActive {
                PodcastPlayerView(player: podcastPlayer)
            }

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
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .padding(10)
        .onReceive(phraseTimer) { _ in
            if isThinking {
                withAnimation(.easeInOut(duration: 0.3)) {
                    thinkingPhrase = thinkingPhrases.randomElement()!
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Image(nsImage: NSImage.clawApple)
                .foregroundStyle(.primary)

            Text("iClaw")
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
                            Text(message.role == "user" ? "You" : "iClaw")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if message.content.starts(with: "PHOTO_CAPTURED:"),
                               let path = message.content.split(separator: ":", maxSplits: 1).last,
                               let image = NSImage(contentsOfFile: String(path)) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .padding(8)
                                    .background(.white.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            } else {
                                Text(markdownAttributed(message.content))
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .background(message.role == "user" ? .blue.opacity(0.2) : .white.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                }

                if isThinking {
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(.primary.opacity(0.1))
                            .frame(width: 32, height: 32)
                            .overlay {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("iClaw")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                ThinkingDotsView(time: t)

                                Text(thinkingPhrase)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                            .padding(12)
                            .background(.white.opacity(0.1))
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

            if speechManager.isRecording {
                VStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        Text(speechManager.transcription)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(3)
                            .truncationMode(.head)

                        if speechManager.transcription.count > 120 {
                            Text("...")
                                .font(.body.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                                .background(.black.opacity(0.4))
                        }
                    }

                    HStack(spacing: 12) {
                        AudioWaveformView(time: t)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)

                        Button {
                            confirmRecording()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(.black.opacity(0.2))
                .onChange(of: speechManager.isRecording) { _, recording in
                    if !recording {
                        confirmRecording()
                    }
                }
            } else {
                HStack(spacing: 12) {
                    TextField("Message iClaw...", text: $input)
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
                    .disabled(isThinking)
                    .keyboardShortcut(.return, modifiers: [])

                    Button {
                        speechManager.startRecording()
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isThinking)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(.black.opacity(0.2))
            }
        }
    }

    private func markdownAttributed(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(string)
    }

    private func confirmRecording() {
        guard speechManager.isRecording || !speechManager.transcription.isEmpty else { return }
        speechManager.stopRecording()
        let transcript = speechManager.transcription
        if !transcript.isEmpty
            && !transcript.starts(with: "Initializing")
            && !transcript.starts(with: "Downloading")
            && !transcript.starts(with: "Listening")
            && !transcript.starts(with: "No compatible") {
            input = transcript
        }
    }

    private func sendMessage() {
        guard !input.isEmpty, !isThinking else { return }
        let userContent = input
        messages.append(Message(role: "user", content: userContent))
        input = ""
        isThinking = true
        thinkingPhrase = thinkingPhrases.randomElement()!

        Task {
            do {
                let recentMemories = try await DatabaseManager.shared.searchMemories(query: userContent, limit: 5)
                let response = try await ModelManager.shared.generateResponse(prompt: userContent, history: recentMemories)
                isThinking = false
                messages.append(Message(role: "agent", content: response))

                // Save to database
                let userMemory = Memory(id: nil, role: "user", content: userContent, embedding: nil, created_at: Date(), is_important: false)
                _ = try await DatabaseManager.shared.saveMemory(userMemory)

                let agentMemory = Memory(id: nil, role: "agent", content: response, embedding: nil, created_at: Date(), is_important: false)
                _ = try await DatabaseManager.shared.saveMemory(agentMemory)
            } catch {
                isThinking = false
                messages.append(Message(role: "agent", content: "Error: \(error.localizedDescription)"))
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

struct ThinkingDotsView: View {
    var time: Float

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                let phase = Float(i) * 0.7
                let scale = 0.5 + 0.5 * abs(sin(Double(time * 2.5 + phase)))
                Circle()
                    .fill(.primary.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(scale)
                    .animation(.easeInOut(duration: 0.2), value: time)
            }
        }
    }
}

struct AudioWaveformView: View {
    var time: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                let phase = Float(i) * 0.8
                let height = 0.3 + 0.7 * abs(sin(Double(time * 3.0 + phase)))
                RoundedRectangle(cornerRadius: 2)
                    .fill(.primary.opacity(0.6))
                    .frame(width: 3, height: 24 * height)
                    .animation(.easeInOut(duration: 0.15), value: time)
            }
        }
    }
}

// MARK: - Podcast Player View

struct PodcastPlayerView: View {
    @ObservedObject var player: PodcastPlayerManager
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            // Episode info
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.episodeTitle)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if !player.showName.isEmpty {
                        Text(player.showName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Stop / close button
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.15))
                        .frame(height: 4)

                    // Fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.6))
                        .frame(width: progressWidth(in: geo.size.width), height: 4)

                    // Scrub handle (visible on hover / drag)
                    Circle()
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .offset(x: progressWidth(in: geo.size.width) - 5)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            scrubValue = fraction * player.duration
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            let target = fraction * player.duration
                            player.seek(to: target)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 10)

            // Time labels + controls
            HStack {
                Text(formatTime(isScrubbing ? scrubValue : player.currentTime))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                // Skip back 15s
                Button {
                    player.skipBackward()
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                // Play / Pause
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                // Skip forward 15s
                Button {
                    player.skipForward()
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("-\(formatTime(max(0, player.duration - (isScrubbing ? scrubValue : player.currentTime))))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.black.opacity(0.25))
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard player.duration > 0 else { return 0 }
        let time = isScrubbing ? scrubValue : player.currentTime
        let fraction = time / player.duration
        return max(0, min(totalWidth, CGFloat(fraction) * totalWidth))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
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
