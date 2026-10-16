import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

@Suite struct StoreChoiceTests {
    @Test func testRunsAlwaysUseMemory() {
        #expect(StoreChoice.decide(isRunningTests: true, arguments: [], cloudKitAvailable: false) == .inMemory(seed: false))
        #expect(StoreChoice.decide(isRunningTests: true, arguments: [], cloudKitAvailable: true) == .inMemory(seed: false))
    }

    @Test func uiTestSeedUsesMemoryEvenWithCloudKit() {
        // The tests run in a DEBUG build, where the launch argument is honoured.
        #expect(StoreChoice.decide(isRunningTests: false, arguments: ["app", StoreChoice.uiTestSeedArgument],
                                   cloudKitAvailable: true) == .inMemory(seed: true))
    }

    @Test func diskStoreFollowsTheCloudKitFlag() {
        #expect(StoreChoice.decide(isRunningTests: false, arguments: ["app"], cloudKitAvailable: false) == .local)
        #expect(StoreChoice.decide(isRunningTests: false, arguments: ["app"], cloudKitAvailable: true) == .cloudKit)
    }

    @Test @MainActor func inMemoryStoreSkipsMigrationAndSync() {
        var migrated = false
        let container = ArchiveStore.makeContainer(for: .inMemory(seed: false), migrate: { migrated = true })

        #expect(!migrated)
        let configuration = container.configurations.first
        #expect(configuration?.isStoredInMemoryOnly == true)
        #expect(configuration?.cloudKitContainerIdentifier == nil)
    }

    @Test @MainActor func hostedTestRunChoosesMemory() {
        #expect(ArchiveStore.currentChoice() == .inMemory(seed: false))
    }
}

@Suite struct CloudKitFlagTests {
    private func available(_ value: Any?, entitlement: Bool) -> Bool {
        let info: [String: Any]? = value.map { [SyncMonitor.cloudKitFlagKey: $0] } ?? [:]
        return SyncMonitor.cloudKitAvailable(infoDictionary: info, hasEntitlement: { entitlement })
    }

    @Test(arguments: ["YES", "yes", "1", "true"])
    func flagOnEnablesCloudKitWithEntitlement(value: String) {
        #expect(available(value, entitlement: true))
    }

    @Test(arguments: ["NO", "0", "", "$(DA_CLOUDKIT_ENABLED)"])
    func flagOffOrUnsetDisablesCloudKit(value: String) {
        #expect(!available(value, entitlement: true))
    }

    @Test func missingFlagDisablesCloudKit() {
        #expect(!available(nil, entitlement: true))
        #expect(!SyncMonitor.cloudKitAvailable(infoDictionary: nil, hasEntitlement: { true }))
    }

    @Test func macOSAlsoNeedsTheEntitlement() {
        #if os(macOS)
        #expect(!available("YES", entitlement: false))
        #else
        #expect(available("YES", entitlement: false), "iOS decides by the build flag only")
        #endif
    }

    /// The repository default must stay off, so CI and unsigned builds never open a CloudKit store.
    @Test func thisBuildHasTheFlagOff() {
        #expect(Bundle.main.infoDictionary?[SyncMonitor.cloudKitFlagKey] as? String == "NO")
        #expect(!SyncMonitor.cloudKitAvailable())
    }
}

/// UI test runs (`-UITestSeed`) never see the real Keychain item or Mistral (#21 review, point 2).
@Suite struct UITestIsolationTests {
    @Test func seedArgumentMarksAUITestRun() {
        // The tests run in a DEBUG build, where the launch argument is honoured.
        #expect(TestEnvironment.isUITestSeed(arguments: ["app", StoreChoice.uiTestSeedArgument]))
        #expect(!TestEnvironment.isUITestSeed(arguments: ["app"]))
    }

    @Test func uiTestRunsUseTheirOwnKeychainService() {
        let real = KeychainStore.serviceName(isUITestSeed: false)
        #expect(real == "de.patrickklein.DocumentArchive")
        #expect(KeychainStore.serviceName(isUITestSeed: true) != real)
        // The hosted unit tests are not launched with the seed argument.
        #expect(KeychainStore.service == real)
    }

    @Test func hostedTestRunIsIsolated() {
        #expect(TestEnvironment.isIsolated)
    }
}
