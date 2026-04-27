import Foundation
import WebKit

/// WKWebView-based fetch backend for JavaScript-rendered pages.
/// Loads the page in an offscreen WebView, waits for JS to execute, then extracts text.
///
/// NOTE: The WKWebView WebContent subprocess generates sandbox noise in the console
/// (pasteboard, launchservicesd, audio, image codec errors). These are cosmetic and do not
/// affect content extraction. The entitlement `com.apple.runningboard.assertions.webkit`
/// would suppress some of these but is restricted to Apple-signed apps.
///
/// WebCrypto: Uses `.nonPersistent()` data store so WebKit does not access any
/// "WebCrypto Master Key" keychain items from prior signing identities.
public struct BrowserFetchBackend: FetchBackend {
    private let timeout: TimeInterval
    private let renderDelay: TimeInterval

    public init(timeout: TimeInterval = 15, renderDelay: TimeInterval = 1.0) {
        self.timeout = timeout
        self.renderDelay = renderDelay
    }

    public func fetch(url: URL) async throws -> FetchResult {
        try await PageLoader.load(url: url, timeout: timeout, renderDelay: renderDelay)
    }
}

// MARK: - PageLoader

/// Manages a single offscreen WKWebView load cycle.
/// Lives entirely on MainActor since WKWebView requires it.
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private let url: URL
    private let timeout: TimeInterval
    private let renderDelay: TimeInterval
    private var continuation: CheckedContinuation<FetchResult, Error>?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var statusCode: Int = 200
    private var finished = false

    /// Strong references to active loaders so they aren't deallocated mid-navigation.
    private static var active: [PageLoader] = []

    private init(url: URL, timeout: TimeInterval, renderDelay: TimeInterval) {
        self.url = url
        self.timeout = timeout
        self.renderDelay = renderDelay
    }

    static func load(url: URL, timeout: TimeInterval, renderDelay: TimeInterval) async throws -> FetchResult {
        try await withCheckedThrowingContinuation { continuation in
            let loader = PageLoader(url: url, timeout: timeout, renderDelay: renderDelay)
            loader.start(continuation: continuation)
        }
    }

    private func start(continuation: CheckedContinuation<FetchResult, Error>) {
        self.continuation = continuation
        Self.active.append(self)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        #if os(macOS)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        #else
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        #endif
        self.webView = wv

        wv.load(URLRequest(url: url))

        // Timeout fallback
        let timeoutSeconds = timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard let self, !self.finished else { return }
            // Timeout: extract whatever we have so far rather than failing
            await self.extractContent()
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        await MainActor.run {
            if let http = navigationResponse.response as? HTTPURLResponse {
                self.statusCode = http.statusCode
            }
        }
        return .allow
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            // Brief delay for JS frameworks to render after DOMContentLoaded
            try? await Task.sleep(for: .seconds(self.renderDelay))
            guard !self.finished else { return }
            await self.extractContent()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.complete(with: .failure(error))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.complete(with: .failure(error))
        }
    }

    // MARK: - Content extraction

    private func extractContent() async {
        guard let webView, !finished else { return }

        let js = """
        (function() {
            var title = document.title || '';
            // Prefer semantic content containers over full body
            var el = document.querySelector('article')
                  || document.querySelector('main')
                  || document.querySelector('[role="main"]')
                  || document.querySelector('#content')
                  || document.querySelector('.content')
                  || document.body;
            if (!el) return JSON.stringify({t: title, b: ''});
            // Remove noise elements within the content container
            ['nav','header','footer','aside','.sidebar','.ad','.advertisement',
             '.cookie-banner','.cookie-notice','[role="navigation"]',
             '[role="banner"]','[role="contentinfo"]','script','style','noscript',
             'iframe','svg'].forEach(function(sel) {
                el.querySelectorAll(sel).forEach(function(n) { n.remove(); });
            });
            var text = el.innerText || '';
            return JSON.stringify({t: title, b: text});
        })()
        """

        do {
            let result = try await webView.evaluateJavaScript(js)
            if let jsonString = result as? String,
               let data = jsonString.data(using: .utf8),
               let json = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                complete(with: .success(FetchResult(
                    text: json["b"] ?? "",
                    title: json["t"],
                    statusCode: statusCode
                )))
            } else {
                complete(with: .success(FetchResult(text: "Unable to extract page content.", statusCode: statusCode)))
            }
        } catch {
            complete(with: .failure(error))
        }
    }

    // MARK: - Lifecycle

    private func complete(with result: Result<FetchResult, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        switch result {
        case .success(let fetchResult): continuation?.resume(returning: fetchResult)
        case .failure(let error): continuation?.resume(throwing: error)
        }
        continuation = nil
        Self.active.removeAll { $0 === self }
    }
}
