#if os(macOS)
import Foundation
import CryptoKit
import Security

/// Caches validated AppleScript procedures to avoid regenerating them via the LLM
/// ReAct loop on repeated requests. Keyed by a normalized hash of the user's request.
///
/// Storage: App Group container → `scripts/` directory, one JSON file per entry.
/// Entries expire after 30 days (scripts reference app objects that may change across OS updates).
/// Each entry carries an HMAC-SHA256 digest over the script source to detect tampering.
public actor ScriptCache {

    public static let shared = ScriptCache()

    /// Maximum cached entries before LRU eviction.
    private static let maxEntries = 50

    /// Entries older than this are treated as stale.
    private static let ttl: TimeInterval = 30 * 24 * 3600 // 30 days

    private var index: [String: CacheEntry] = [:]
    private var loaded = false

    /// On-disk representation of a cached script.
    public struct CacheEntry: Codable, Sendable {
        let script: String
        let description: String
        let apps: [String]
        let normalizedRequest: String
        let createdAt: Date
        var lastUsedAt: Date
        /// HMAC-SHA256 hex digest over `script`. Nil for legacy entries (treated as untrusted).
        var hmac: String?
    }

    // MARK: - HMAC Integrity

    /// File-based HMAC key stored alongside the cache in Application Support.
    /// Previous versions used the Keychain, which triggered macOS permission
    /// dialogs on every dev rebuild (code signature change → access denied).
    private static let hmacKeyFilename = ".hmac_key"

    /// Returns the per-install HMAC key, creating and storing it on first use.
    /// Stored as a 32-byte file in the cache directory (Application Support).
    private static func hmacKey() -> SymmetricKey? {
        guard let dir = cacheDirectory else { return nil }
        let keyFile = dir.appendingPathComponent(hmacKeyFilename)

        // Try to load existing key.
        if let data = try? Data(contentsOf: keyFile), data.count == 32 {
            return SymmetricKey(data: data)
        }

        // Generate a new 32-byte key.
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        guard status == errSecSuccess else {
            Log.tools.error("ScriptCache: failed to generate HMAC key (SecRandomCopyBytes: \(status))")
            return nil
        }

        let keyData = Data(keyBytes)
        do {
            try keyData.write(to: keyFile, options: [.atomic, .completeFileProtection])
        } catch {
            Log.tools.error("ScriptCache: failed to write HMAC key file: \(error.localizedDescription)")
            return nil
        }

        Log.tools.debug("ScriptCache: generated and stored new HMAC key")
        return SymmetricKey(data: keyData)
    }

    /// Computes HMAC-SHA256 over the script source and returns the hex digest.
    private static func computeHMAC(for source: String, using key: SymmetricKey) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(source.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the HMAC of a cache entry. Returns false for missing or mismatched HMACs.
    private static func verifyHMAC(of entry: CacheEntry) -> Bool {
        guard let storedHMAC = entry.hmac else { return false }
        guard let key = hmacKey() else { return false }
        let expected = computeHMAC(for: entry.script, using: key)
        return storedHMAC == expected
    }

    // MARK: - Public API

    /// Look up a cached script for a request. Returns nil on miss.
    public func lookup(_ request: String) -> CacheEntry? {
        loadIfNeeded()
        let key = Self.cacheKey(for: request)
        guard var entry = index[key] else { return nil }

        // Check TTL
        if Date().timeIntervalSince(entry.createdAt) > Self.ttl {
            index.removeValue(forKey: key)
            removeFile(for: key)
            return nil
        }

        // Verify HMAC integrity — discard tampered or legacy entries without HMAC
        if !Self.verifyHMAC(of: entry) {
            Log.tools.warning("ScriptCache: HMAC verification failed for key \(key), discarding entry")
            index.removeValue(forKey: key)
            removeFile(for: key)
            return nil
        }

        // Update last-used timestamp
        entry.lastUsedAt = Date()
        index[key] = entry
        writeEntry(entry, key: key)
        return entry
    }

    /// Store a validated script after a successful AutomateTool execution.
    public func store(request: String, script: String, description: String, apps: [String]) {
        loadIfNeeded()
        let key = Self.cacheKey(for: request)

        let hmacHex: String?
        if let hmacKey = Self.hmacKey() {
            hmacHex = Self.computeHMAC(for: script, using: hmacKey)
        } else {
            Log.tools.warning("ScriptCache: unable to compute HMAC, storing entry without integrity tag")
            hmacHex = nil
        }

        let entry = CacheEntry(
            script: script,
            description: description,
            apps: apps,
            normalizedRequest: Self.normalize(request),
            createdAt: Date(),
            lastUsedAt: Date(),
            hmac: hmacHex
        )
        index[key] = entry
        writeEntry(entry, key: key)
        evictIfNeeded()
    }

    /// Number of cached entries (for testing/diagnostics).
    public var count: Int {
        loadIfNeeded()
        return index.count
    }

    /// Remove all cached scripts.
    public func clear() {
        index.removeAll()
        if let dir = Self.cacheDirectory {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Key Generation

    /// Normalizes a request string for consistent cache keys.
    /// Strips chips, lowercases, collapses whitespace, removes punctuation.
    static func normalize(_ request: String) -> String {
        let stripped = InputParsingUtilities.stripToolChips(from: request)
        return stripped
            .lowercased()
            .components(separatedBy: .punctuationCharacters).joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// SHA-256 hash of the normalized request, truncated to 16 hex chars.
    static func cacheKey(for request: String) -> String {
        let normalized = normalize(request)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    private static let cacheDirectory: URL? = {
        // Stay inside the sandbox — no App Group needed (only the main app uses ScriptCache)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.geticlaw.iClaw/script_cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let dir = Self.cacheDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil
              ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(CacheEntry.self, from: data) else { continue }
            let key = file.deletingPathExtension().lastPathComponent
            // Skip expired entries
            guard Date().timeIntervalSince(entry.createdAt) < Self.ttl else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            // Verify HMAC integrity — discard tampered or legacy entries
            guard Self.verifyHMAC(of: entry) else {
                Log.tools.warning("ScriptCache: discarding entry \(key) with invalid or missing HMAC")
                try? FileManager.default.removeItem(at: file)
                continue
            }
            index[key] = entry
        }
        Log.tools.debug("ScriptCache: loaded \(self.index.count) cached scripts")
    }

    private func writeEntry(_ entry: CacheEntry, key: String) {
        guard let dir = Self.cacheDirectory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entry) else { return }
        let file = dir.appendingPathComponent("\(key).json")
        try? data.write(to: file, options: .atomic)
    }

    private func removeFile(for key: String) {
        guard let dir = Self.cacheDirectory else { return }
        let file = dir.appendingPathComponent("\(key).json")
        try? FileManager.default.removeItem(at: file)
    }

    private func evictIfNeeded() {
        guard index.count > Self.maxEntries else { return }
        // Evict least recently used
        let sorted = index.sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }
        let toEvict = sorted.prefix(index.count - Self.maxEntries)
        for (key, _) in toEvict {
            index.removeValue(forKey: key)
            removeFile(for: key)
        }
    }
}
#endif
