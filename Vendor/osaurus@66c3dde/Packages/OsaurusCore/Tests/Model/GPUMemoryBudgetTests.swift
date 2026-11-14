//
//  GPUMemoryBudgetTests.swift
//  OsaurusCoreTests
//
//  Model fit is judged against the GPU working set, not physical RAM.
//

import Testing

// ANTICHAT-PATCH: UP-OS-034 ported test imports the OsaurusVendored target
@testable import OsaurusVendored
// ANTICHAT-PATCH-END

@Suite("GPU memory budget")
struct GPUMemoryBudgetTests {

    private static let bytesPerGB: Double = 1024 * 1024 * 1024

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END

    // MARK: - Budget

    @Test("Machines at or below 36 GB hold back proportionally more for the OS")
    func smallMachinesReserveMore() {
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 16) == 16 * (2.0 / 3.0))
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 36) == 36 * (2.0 / 3.0))
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 48) == 36.0)
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 128) == 96.0)
    }

    @Test("No physical memory yields no budget")
    func zeroMemoryYieldsZeroBudget() {
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 0) == 0)
        #expect(GPUMemoryBudget.budgetGB(physicalMemoryGB: 0) == 0)
    }

    /// Metal is consulted only for the host, and only ever to lower the
    /// budget. Whatever machine this runs on, the verdict can never be more
    /// optimistic than the conservative default split.
    @Test("Metal can only tighten the host budget, never loosen it")
    func metalOnlyTightens() {
        let host = GPUMemoryBudget.hostPhysicalMemoryGB
        #expect(
            GPUMemoryBudget.budgetGB(physicalMemoryGB: host)
                <= GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: host)
        )
    }

    /// A hypothetical RAM size must resolve identically regardless of the
    /// machine the catalog math happens to run on.
    @Test("Hypothetical RAM sizes ignore the host's Metal device")
    func hypotheticalSizesAreHostIndependent() {
        for ram in [8.0, 16.0, 24.0, 32.0, 64.0, 192.0] where abs(ram - GPUMemoryBudget.hostPhysicalMemoryGB) >= 1.0 {
            #expect(
                GPUMemoryBudget.budgetGB(physicalMemoryGB: ram)
                    == GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: ram)
            )
        }
    }

    // MARK: - Fit

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END

    @Test("Selection surfaces share one plain-language verdict vocabulary")
    func sharedVerdictVocabulary() {
        #expect(ModelCompatibility.compatible.displayName == "Runs well")
        #expect(ModelCompatibility.tight.displayName == "Memory may be tight")
        #expect(ModelCompatibility.tooLarge.displayName == "Not recommended")
        #expect(ModelCompatibility.unknown.displayName == "Not enough information")
    }

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that build Osaurus MLXModel/ModelRuntime values (not vendored)
    // ANTICHAT-PATCH-END
}
