import Foundation
import FoundationModels

/// Backend-agnostic typed system instructions for LLM calls.
///
/// Wraps labelled segments (SOUL, BRAIN, user profile, per-turn directives)
/// in a `Sendable` value type. Renders to `FoundationModels.Instructions` on the
/// AFM path via `asAppleInstructions()` and to a joined system-message string
/// for non-AFM backends via `renderAsSystemString()`.
///
/// Labelled segments let tests assert on segment identity (not substring) and
/// keep the AFM `Instructions` builder call structured instead of passing a
/// pre-joined string.
///
/// `ExpressibleByStringLiteral` keeps pre-migration String call sites compiling
/// against new typed overloads — every existing literal `"..."` at an
/// `instructions:` argument continues to work as a `.raw` segment.
public struct iClawInstructions: Sendable, Equatable, ExpressibleByStringLiteral {

    public enum Segment: Sendable, Equatable {
        /// Personality guidance from SOUL.md.
        case soul(String)
        /// Operational rules from BRAIN.md.
        case brain(String)
        /// User profile facts.
        case userProfile(String)
        /// Per-turn directives (conciseness, math formatting, language hint, etc.).
        case directive(String)
        /// Unlabelled content. Used by the `ExpressibleByStringLiteral` bridge
        /// and by callers not yet migrated to the typed helpers.
        case raw(String)

        public var text: String {
            switch self {
            case .soul(let s), .brain(let s), .userProfile(let s),
                 .directive(let s), .raw(let s):
                return s
            }
        }
    }

    public let segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments.filter { !$0.text.isEmpty }
    }

    public init(stringLiteral value: String) {
        self.init(segments: value.isEmpty ? [] : [.raw(value)])
    }

    public init(_ value: String) {
        self.init(segments: value.isEmpty ? [] : [.raw(value)])
    }

    public static let empty = iClawInstructions(segments: [])

    public var isEmpty: Bool { segments.isEmpty }

    /// Renders all segments as a newline-separated system message string.
    /// Used by non-AFM backends (Ollama) and by back-compat shims that forward
    /// to `String?`-based backend APIs.
    public func renderAsSystemString() -> String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// Materializes into an Apple `FoundationModels.Instructions` for
    /// `LanguageModelSession`. Only called from the AFM backend.
    ///
    /// Uses `@InstructionsBuilder` string-stacking rather than pre-joining,
    /// which is ~2 tokens more efficient per call at typical iClaw sizes
    /// (probed on macOS 26.4: joined=35t, built=33t for identical content).
    public func asAppleInstructions() -> Instructions {
        Instructions {
            for segment in segments {
                segment.text
            }
        }
    }

    /// Returns a copy with an additional segment appended.
    public func appending(_ segment: Segment) -> iClawInstructions {
        iClawInstructions(segments: segments + [segment])
    }

    /// Returns a copy with the segments of another `iClawInstructions` appended.
    public func appending(_ other: iClawInstructions) -> iClawInstructions {
        iClawInstructions(segments: segments + other.segments)
    }
}

// MARK: - Builder

/// Result builder for `makeInstructions { ... }`.
///
/// Accepts `Segment?` components so helper functions (`Soul`, `Brain`,
/// `UserProfile`, `Directive`) can return `nil` for empty guidance and have
/// the empty branch drop out cleanly.
@resultBuilder
public struct iClawInstructionsBuilder {
    public static func buildBlock(_ components: iClawInstructions.Segment?...) -> iClawInstructions {
        iClawInstructions(segments: components.compactMap { $0 })
    }

    public static func buildOptional(_ component: iClawInstructions.Segment?) -> iClawInstructions.Segment? {
        component ?? nil
    }

    public static func buildEither(first component: iClawInstructions.Segment?) -> iClawInstructions.Segment? {
        component
    }

    public static func buildEither(second component: iClawInstructions.Segment?) -> iClawInstructions.Segment? {
        component
    }
}

/// Composes labelled instruction segments.
///
/// ```swift
/// let instructions = makeInstructions {
///     Soul(soulContent)          // nil if empty — drops out
///     Directive(conciseness)
///     Directive(mathFormatting)
/// }
/// ```
public func makeInstructions(
    @iClawInstructionsBuilder _ build: () -> iClawInstructions
) -> iClawInstructions {
    build()
}

// MARK: - Segment helper functions

public func Soul(_ text: String) -> iClawInstructions.Segment? {
    text.isEmpty ? nil : .soul(text)
}

public func Brain(_ text: String) -> iClawInstructions.Segment? {
    text.isEmpty ? nil : .brain(text)
}

public func UserProfile(_ text: String) -> iClawInstructions.Segment? {
    text.isEmpty ? nil : .userProfile(text)
}

public func Directive(_ text: String?) -> iClawInstructions.Segment? {
    guard let text, !text.isEmpty else { return nil }
    return .directive(text)
}
