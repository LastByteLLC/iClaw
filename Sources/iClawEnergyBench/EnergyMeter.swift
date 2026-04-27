import Foundation

/// Measures per-process energy consumption using Mach `task_info` API.
///
/// Uses `TASK_POWER_INFO_V2` to read cumulative CPU and GPU energy in nanojoules.
/// Take a snapshot before and after work to compute the delta.
actor EnergyMeter {
    struct Sample: Sendable {
        let timestamp: ContinuousClock.Instant
        let cpuEnergyNJ: UInt64
        let gpuEnergyNJ: UInt64
    }

    struct Measurement: Sendable {
        let cpuEnergyMJ: Double
        let gpuEnergyMJ: Double
        let totalEnergyMJ: Double
        let durationMs: Double
        let wattsAverage: Double

        /// Energy per token in millijoules (0 if no tokens).
        func energyPerToken(tokens: Int) -> Double {
            guard tokens > 0 else { return 0 }
            return totalEnergyMJ / Double(tokens)
        }

        /// Watts·hours per million tokens.
        func whPerMillionTokens(tokens: Int) -> Double {
            guard tokens > 0 else { return 0 }
            let joulesPerToken = (totalEnergyMJ / 1000.0) / Double(tokens)
            let whPerToken = joulesPerToken / 3600.0
            return whPerToken * 1_000_000
        }
    }

    /// Takes a snapshot of current process energy counters.
    nonisolated func snapshot() -> Sample {
        var info = task_power_info_v2_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), intPtr, &count)
            }
        }

        let cpuNJ: UInt64
        let gpuNJ: UInt64
        if result == KERN_SUCCESS {
            // task_power_info_v2 provides total_energy (CPU) and gpu_energy (GPU)
            cpuNJ = info.cpu_energy.total_system
            gpuNJ = info.gpu_energy.task_gpu_utilisation
        } else {
            cpuNJ = 0
            gpuNJ = 0
        }

        return Sample(
            timestamp: .now,
            cpuEnergyNJ: cpuNJ,
            gpuEnergyNJ: gpuNJ
        )
    }

    /// Computes the delta between two snapshots.
    nonisolated func measure(from start: Sample, to end: Sample) -> Measurement {
        let cpuDeltaNJ = end.cpuEnergyNJ - start.cpuEnergyNJ
        let gpuDeltaNJ = end.gpuEnergyNJ - start.gpuEnergyNJ

        let cpuMJ = Double(cpuDeltaNJ) / 1_000_000.0
        let gpuMJ = Double(gpuDeltaNJ) / 1_000_000.0
        let totalMJ = cpuMJ + gpuMJ

        let duration = end.timestamp - start.timestamp
        let durationMs = Double(duration.components.seconds) * 1000.0
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000.0

        let durationSec = durationMs / 1000.0
        let totalJoules = totalMJ / 1000.0
        let watts = durationSec > 0 ? totalJoules / durationSec : 0

        return Measurement(
            cpuEnergyMJ: cpuMJ,
            gpuEnergyMJ: gpuMJ,
            totalEnergyMJ: totalMJ,
            durationMs: durationMs,
            wattsAverage: watts
        )
    }
}
