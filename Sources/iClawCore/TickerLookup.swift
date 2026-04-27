// TickerLookup.swift
// iClaw — Comprehensive stock ticker lookup (Russell 1000 + Global Top ~500)
// Letter-only tickers, sorted by symbol, loaded from TickerData.json.

import Foundation
import os

private let logger = Logger(subsystem: "com.geticlaw.iClaw", category: "TickerLookup")

struct TickerEntry: Sendable, Equatable, Codable {
    let symbol: String
    let name: String
}

enum TickerLookup {

    // MARK: - Public API

    /// All tickers sorted alphabetically by symbol.
    static let allTickers: [TickerEntry] = _loadTickers()

    /// Prefix search (case-insensitive), limited to 8 results.
    static func search(prefix: String) -> [TickerEntry] {
        guard !prefix.isEmpty else { return [] }
        let upper = prefix.uppercased()
        var results: [TickerEntry] = []
        results.reserveCapacity(8)
        for entry in allTickers {
            if entry.symbol.hasPrefix(upper) {
                results.append(entry)
                if results.count == 8 { break }
            }
        }
        return results
    }

    /// Exact symbol match (case-insensitive).
    static func lookup(symbol: String) -> TickerEntry? {
        let upper = symbol.uppercased()
        // Binary search since array is sorted
        var lo = 0
        var hi = allTickers.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let midSym = allTickers[mid].symbol
            if midSym == upper { return allTickers[mid] }
            else if midSym < upper { lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return nil
    }

    // MARK: - Data Loading

    private static func _loadTickers() -> [TickerEntry] {
        guard let entries = ConfigLoader.load("TickerData", as: [TickerEntry].self) else {
            logger.error("Failed to load TickerData.json — ticker lookup will be empty")
            return []
        }
        return entries.sorted { $0.symbol < $1.symbol }
    }
}
