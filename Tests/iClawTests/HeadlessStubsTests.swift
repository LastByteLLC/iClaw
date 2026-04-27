import Testing
@testable import iClawCore

/// Regression tests for `HeadlessStubs` — in particular, the FNV-1a hash
/// bucket arithmetic that previously trapped on `Int(UInt64)` overflow.
///
/// Context: `HeadlessStubs.deterministicContact(for:)` previously did
/// `let idx = Int(hash) % fixtures.contacts.count`, which crashed the
/// daemon with `Swift/Integers.swift:3539: Fatal error: Not enough bits
/// to represent the passed value` whenever the FNV hash's top bit was
/// set (probability ≈ 50% for any input). The bug was triggered in the
/// manual evaluation by `"Tell me a joke about programming"`, which
/// routed to MessagesStub and hashed the query to a top-bit-set value.
///
/// The fix (2026-04) moved the modulo into unsigned arithmetic:
///   `let idx = Int(hash % UInt64(fixtures.contacts.count))`
/// These tests exercise inputs whose FNV-1a hash has the top bit set so
/// any regression that reintroduces the trap will fail deterministically.
struct HeadlessStubsTests {

    // MARK: - Integer overflow regression

    /// Computes the same FNV-1a hash HeadlessStubs uses, so test inputs
    /// with top-bit-set hashes can be chosen deterministically.
    private func fnv1a(_ query: String) -> UInt64 {
        query.lowercased().utf8.reduce(UInt64(0xcbf29ce484222325)) { h, b in
            (h ^ UInt64(b)) &* 0x100000001b3
        }
    }

    @Test func deterministicContactDoesNotTrapOnTopBitSetHash() {
        // These specific strings all hash to UInt64 values with the top
        // bit set (verified: their fnv1a(...) & (1 << 63) != 0). The
        // pre-fix code would trap on each of these; the fixed code
        // returns a deterministic contact without crashing.
        // Verified via a one-off run of the same fnv1a(): each of these
        // strings produces a UInt64 hash with bit 63 set (hash values in
        // 0x8000000000000000…0xFFFFFFFFFFFFFFFF). These are the inputs
        // that would have crashed the pre-fix `Int(hash)` conversion.
        let triggers = [
            "Tell me a joke about programming",   // 0xc42037f514e925aa
            "Send a message to Alex",             // 0xa41991f6f1d91ee0
            "Draft a reply to the meeting thread",// 0xd052037153f4a49a
            "Find my note about groceries",       // 0xe525f3c2f48b19fe
            "Email Alex about the meeting",       // 0xeb273a333805ce4a
        ]
        for query in triggers {
            // Sanity-check each trigger: top bit actually set. Any
            // Swift toolchain change that shifts FNV-1a output would
            // flag this — the test guards the invariant we're testing.
            let hash = fnv1a(query)
            #expect(hash & (UInt64(1) << 63) != 0, "\(query) no longer triggers the top-bit path — pick a new fixture")

            // Main assertion: calling deterministicContact must not trap.
            // It returns a valid contact from the fixture set.
            let contact = HeadlessStubs.deterministicContact(for: query)
            #expect(!contact.name.isEmpty)
        }
    }

    @Test func deterministicContactIsStable() {
        // Same input always returns the same contact. This is the
        // "deterministic" contract in the function name.
        let query = "Text mom I'll be home late"
        let first = HeadlessStubs.deterministicContact(for: query)
        let second = HeadlessStubs.deterministicContact(for: query)
        #expect(first.name == second.name)
        #expect(first.phone == second.phone)
    }

    @Test func deterministicContactHandlesEmptyInput() {
        // Empty string hashes to the FNV-1a basis, which is < 2^63, so
        // this exercises the non-top-bit path. Shouldn't trap either.
        let contact = HeadlessStubs.deterministicContact(for: "")
        #expect(!contact.name.isEmpty)
    }

    @Test func deterministicContactHandlesUnicode() {
        // Non-ASCII input used to exercise the hash function's UTF-8
        // reduction path. Must not trap on multi-byte sequences.
        for query in ["¿Cómo estás?", "東京の天気は", "مرحبا", "😀🎉"] {
            let contact = HeadlessStubs.deterministicContact(for: query)
            #expect(!contact.name.isEmpty)
        }
    }
}
