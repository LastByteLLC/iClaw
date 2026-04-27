import Foundation
import WebKit
import os

/// Sandboxed JavaScript execution engine via offscreen WKWebView.
///
/// Each invocation creates a fresh WKWebView with non-persistent storage.
/// The WebContent process runs in isolation — crashes don't affect iClaw.
/// Network access is blocked via JavaScript API neutering.
public actor JSExecutor {
    public static let shared = JSExecutor()

    public enum Mode: Sendable {
        /// Evaluate a single expression and return its stringified result.
        case eval
        /// Execute a script; capture console.log output.
        case script
    }

    public struct Result: Sendable {
        public let output: String
        public let truncated: Bool
    }

    /// Maximum output size in characters.
    static let maxOutputLength = 10_000

    /// Execution timeout in seconds.
    static let timeoutSeconds: TimeInterval = 5

    /// Executes JavaScript in a sandboxed WKWebView.
    /// - Parameters:
    ///   - code: The JavaScript code to execute.
    ///   - mode: `.eval` for expression evaluation, `.script` for full program.
    /// - Returns: The execution result.
    /// - Throws: `ToolError.timeout` on timeout, other errors on failure.
    public func execute(code: String, mode: Mode) async throws -> Result {
        try await JSRunner.run(code: code, mode: mode)
    }
}

// MARK: - JSRunner

/// @MainActor inner class that manages WKWebView lifecycle.
/// Mirrors the PageLoader pattern from BrowserFetchBackend.
@MainActor
private final class JSRunner: NSObject, WKNavigationDelegate {

    /// Prevent premature deallocation while execution is in-flight.
    private static var active: [JSRunner] = []

    private let webView: WKWebView
    private var continuation: CheckedContinuation<JSExecutor.Result, any Error>?
    private var didComplete = false

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Suppress media autoplay and other unnecessary features
        config.suppressesIncrementalRendering = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
    }

    static func run(code: String, mode: JSExecutor.Mode) async throws -> JSExecutor.Result {
        try await withCheckedThrowingContinuation { continuation in
            let runner = JSRunner()
            runner.continuation = continuation
            Self.active.append(runner)
            runner.executeCode(code, mode: mode)
        }
    }

    private func executeCode(_ code: String, mode: JSExecutor.Mode) {
        // Sandbox preamble: neuter network & storage APIs
        let preamble = """
        (function() {
            Object.defineProperty(window, 'fetch', {value: undefined, configurable: false, writable: false});
            Object.defineProperty(window, 'XMLHttpRequest', {value: undefined, configurable: false, writable: false});
            Object.defineProperty(window, 'WebSocket', {value: undefined, configurable: false, writable: false});
            Object.defineProperty(window, 'EventSource', {value: undefined, configurable: false, writable: false});
            if (navigator) Object.defineProperty(navigator, 'sendBeacon', {value: undefined, configurable: false, writable: false});
            Object.defineProperty(window, 'localStorage', {value: undefined, configurable: false, writable: false});
            Object.defineProperty(window, 'sessionStorage', {value: undefined, configurable: false, writable: false});
            Object.defineProperty(window, 'indexedDB', {value: undefined, configurable: false, writable: false});
            Object.defineProperty(window, 'caches', {value: undefined, configurable: false, writable: false});
            try { document.cookie = ''; } catch(e) {}
        })();
        """

        let wrappedCode: String
        switch mode {
        case .eval:
            wrappedCode = """
            \(preamble)
            try {
                String((\(code)));
            } catch(e) {
                'Error: ' + e.message;
            }
            """
        case .script:
            wrappedCode = """
            \(preamble)
            (function() {
                var __output = [];
                var __origLog = console.log;
                console.log = function() {
                    __output.push(Array.from(arguments).map(String).join(' '));
                };
                console.warn = console.log;
                console.error = console.log;
                try {
                    \(code)
                } catch(e) {
                    __output.push('Error: ' + e.message);
                }
                console.log = __origLog;
                return __output.join('\\n');
            })();
            """
        }

        // Set up timeout
        let timeoutTask = Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(JSExecutor.timeoutSeconds))
            guard let self, !self.didComplete else { return }
            self.complete(with: .failure(ToolError.timeout(duration: JSExecutor.timeoutSeconds)))
        }

        webView.evaluateJavaScript(wrappedCode) { [weak self] result, error in
            timeoutTask.cancel()
            guard let self, !self.didComplete else { return }

            if let error {
                self.complete(with: .failure(error))
                return
            }

            let output = (result as? String) ?? String(describing: result ?? "undefined")
            let truncated = output.count > JSExecutor.maxOutputLength
            let finalOutput = truncated ? String(output.prefix(JSExecutor.maxOutputLength)) : output
            self.complete(with: .success(JSExecutor.Result(output: finalOutput, truncated: truncated)))
        }
    }

    private func complete(with result: Swift.Result<JSExecutor.Result, any Error>) {
        guard !didComplete else { return }
        didComplete = true
        webView.stopLoading()
        let cont = continuation
        continuation = nil
        Self.active.removeAll { $0 === self }

        switch result {
        case .success(let value): cont?.resume(returning: value)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    /// Handle WebContent process crash.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        complete(with: .failure(ToolError.apiError(service: "JSExecutor", code: nil, message: "JavaScript execution process terminated unexpectedly.")))
    }
}
