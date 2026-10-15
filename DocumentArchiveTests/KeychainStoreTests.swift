import Testing
@testable import DocumentArchive

/// Uses its own service name, so the real Mistral key is never read or changed.
@Suite(.serialized) struct KeychainStoreTests {
    static let service = "de.patrickklein.DocumentArchive.tests"
    static let account = "test-account"

    init() { KeychainStore.delete(Self.account, service: Self.service) }

    @Test func roundTrip() {
        defer { KeychainStore.delete(Self.account, service: Self.service) }
        let secret = TestSupport.fakeKey()
        #expect(KeychainStore.read(Self.account, service: Self.service) == nil)

        KeychainStore.save(secret, for: Self.account, service: Self.service)
        #expect(KeychainStore.read(Self.account, service: Self.service) == secret)

        let replacement = TestSupport.fakeKey()
        KeychainStore.save(replacement, for: Self.account, service: Self.service)
        #expect(KeychainStore.read(Self.account, service: Self.service) == replacement)

        KeychainStore.delete(Self.account, service: Self.service)
        #expect(KeychainStore.read(Self.account, service: Self.service) == nil)
    }

    @Test func savingAnEmptyValueDeletes() {
        KeychainStore.save(TestSupport.fakeKey(), for: Self.account, service: Self.service)
        KeychainStore.save("", for: Self.account, service: Self.service)
        #expect(KeychainStore.read(Self.account, service: Self.service) == nil)
    }
}
