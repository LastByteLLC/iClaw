import Foundation
import NaturalLanguage
import os
import XCTest
import Testing
import CoreLocation
@preconcurrency import Speech
import FoundationModels
@testable import iClawCore

// MARK: - Capability Enum

/// Runtime capabilities that tests can require. Each case maps to a feature-detection
/// check that runs once and is cached for the lifetime of the test process.
enum TestCapability: String, CaseIterable, CustomStringConvertible, Sendable {
    /// On-device Apple Intelligence / Foundation Models are available and responding.
    case appleIntelligence

    /// Speech recognition (SpeechTranscriber) is available on this device.
    case speechRecognition

    /// Location services are authorized (CLLocationManager).
    case locationServices

    /// ImageCreator (ImagePlayground) is available on this device.
    case imagePlayground

    /// Not running in CI — tests gated by this are non-deterministic stress/ML tests
    /// intended for local validation only (e.g., generative routing accuracy thresholds).
    case localValidation

    /// Expensive audit/stress tests that can hang or run for minutes.
    /// Only run when explicitly opted in via `RUN_AUDIT_TESTS=1`.
    case auditTests

    var description: String { rawValue }
}

// MARK: - Runtime Detection

/// Cached, thread-safe capability detection. Each check runs at most once per process.
enum TestCapabilities {
    private static let cache = OSAllocatedUnfairLock(initialState: [TestCapability: Bool]())

    /// Returns `true` if the given capability is available at runtime.
    static func isAvailable(_ capability: TestCapability) -> Bool {
        if let cached = cache.withLock({ $0[capability] }) {
            return cached
        }
        let result = probe(capability)
        cache.withLock { $0[capability] = result }
        return result
    }

    private static func probe(_ capability: TestCapability) -> Bool {
        switch capability {
        case .appleIntelligence:
            return probeAppleIntelligence()
        case .speechRecognition:
            return probeSpeechRecognition()
        case .locationServices:
            return probeLocationServices()
        case .imagePlayground:
            return probeImagePlayground()
        case .localValidation:
            return probeLocalValidation()
        case .auditTests:
            return probeAuditTests()
        }
    }

    // -- Probes ----------------------------------------------------------

    private static func probeAppleIntelligence() -> Bool {
        let availability = SystemLanguageModel.default.availability
        return availability == .available
    }

    private static func probeSpeechRecognition() -> Bool {
        SpeechTranscriber.isAvailable
    }

    private static func probeLocationServices() -> Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedAlways
    }

    private static func probeImagePlayground() -> Bool {
        // ImageCreator requires Apple Intelligence + macOS 15.4 / iOS 18.4
        guard #available(macOS 15.4, iOS 18.4, *) else { return false }
        return probeAppleIntelligence()
    }

    private static func probeLocalValidation() -> Bool {
        // GitHub Actions sets CI=true; skip non-deterministic stress tests in CI
        ProcessInfo.processInfo.environment["CI"] == nil
    }

    private static func probeAuditTests() -> Bool {
        ProcessInfo.processInfo.environment["RUN_AUDIT_TESTS"] == "1"
    }
}

// MARK: - Global Test Location Mock

/// Sets a deterministic test location so tools that call LocationManager.shared.resolveCurrentLocation()
/// return immediately instead of hanging on CoreLocation authorization dialogs.
/// Called once per process via the static initializer pattern.
enum TestLocationSetup {
    /// Installs a deterministic mock location. Synchronous, idempotent, safe from any context.
    /// Call from test setUp or test helpers before any tool execution.
    static func install() {
        guard LocationManager.testLocationOverride == nil else { return }
        LocationManager.testLocationOverride = ResolvedLocation(
            coordinate: CLLocation(latitude: 37.7749, longitude: -122.4194),
            cityName: "San Francisco",
            source: .userFallback
        )
        // Pre-warm NLEmbedding to avoid ~5-10s cold start during first routing call.
        _ = NLEmbedding.sentenceEmbedding(for: .english)
    }
}

/// Auto-installs mock location for all XCTest runs.
/// Each test class that uses location-dependent tools should call this in setUp.
/// TestLocationSetup.installMockLocation() is idempotent (safe to call multiple times).

// MARK: - XCTest Integration

extension XCTestCase {
    /// Skip this test if the given capability is not available at runtime.
    ///
    ///     func testTranslation() throws {
    ///         try require(.appleIntelligence)
    ///         // ... test that needs on-device model ...
    ///     }
    func require(_ capability: TestCapability) throws {
        guard TestCapabilities.isAvailable(capability) else {
            throw XCTSkip("\(capability) is not available in this environment")
        }
    }
}

// MARK: - Swift Testing Integration

/// Use with `@Test` or `@Suite` to skip when a capability is absent:
///
///     @Test(.requires(.appleIntelligence))
///     func testTranslation() async { ... }
///
///     @Suite(.requires(.appleIntelligence))
///     struct ModelTests { ... }
extension Trait where Self == Testing.ConditionTrait {
    static func requires(_ capability: TestCapability) -> Self {
        .enabled(if: TestCapabilities.isAvailable(capability),
                 "\(capability) is not available in this environment")
    }
}
