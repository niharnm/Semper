import Foundation
import Security
import Testing
@testable import Semper

private final class AwayKeychainDataStoreStub: AwayKeychainDataStoring, @unchecked Sendable {
    var data: Data?
    private(set) var saveCount = 0
    private(set) var removeCount = 0

    func loadData() throws -> Data? {
        data
    }

    func saveData(_ data: Data) throws {
        self.data = data
        saveCount += 1
    }

    func removeData() throws {
        data = nil
        removeCount += 1
    }
}

@Suite("Away PIN store", .serialized)
struct AwayPINStoreTests {
    private let fixedSalt = Data((0..<AwayPINCodec.saltLength).map(UInt8.init))

    private func makeStore(
        dataStore: AwayKeychainDataStoreStub = AwayKeychainDataStoreStub(),
        iterations: UInt32 = 1
    ) -> (KeychainAwayPINStore, AwayKeychainDataStoreStub) {
        let codec = AwayPINCodec(
            iterations: iterations,
            randomBytes: { _ in fixedSalt }
        )
        return (
            KeychainAwayPINStore(dataStore: dataStore, codec: codec),
            dataStore
        )
    }

    @Test("Four ASCII digits with a leading zero are accepted")
    func leadingZero() throws {
        let (store, _) = makeStore()

        try store.setPIN("0123")

        #expect(try store.hasPIN())
        #expect(try store.verifyPIN("0123"))
        #expect(try !store.verifyPIN("0124"))
    }

    @Test("PIN format rejects wrong length and non-ASCII digits")
    func formatValidation() throws {
        let (store, _) = makeStore()
        for candidate in ["123", "12345", "12a4", "１２３４", "12\n4"] {
            #expect(throws: AwayPINStoreError.invalidPINFormat) {
                try store.setPIN(candidate)
            }
        }
    }

    @Test("Invalid PBKDF2 iteration counts report a typed error")
    func iterationValidation() {
        for iterations in [UInt32(0), AwayPINCodec.maximumIterations + 1] {
            let codec = AwayPINCodec(iterations: iterations, randomBytes: { _ in self.fixedSalt })

            #expect(throws: AwayPINStoreError.invalidIterationCount) {
                try codec.makeRecord(for: "0123")
            }
        }
    }

    @Test("Stored data is versioned and does not contain the raw PIN")
    func storedRecord() throws {
        let (store, dataStore) = makeStore()

        try store.setPIN("0123")

        let data = try #require(dataStore.data)
        let record = try JSONDecoder().decode(AwayPINRecord.self, from: data)
        #expect(record.version == AwayPINRecord.currentVersion)
        #expect(record.algorithm == AwayPINRecord.algorithm)
        #expect(record.iterations == 1)
        #expect(record.salt == fixedSalt)
        #expect(record.verifier.count == AwayPINCodec.verifierLength)
        #expect(!String(decoding: data, as: UTF8.self).contains("0123"))
    }

    @Test("Preparing a PIN does not write until the prepared record is committed")
    func preparedCommit() throws {
        let (store, dataStore) = makeStore()

        let preparedPIN = try store.preparePIN("0123")

        #expect(dataStore.data == nil)
        #expect(dataStore.saveCount == 0)

        try store.commitPIN(preparedPIN)

        #expect(dataStore.saveCount == 1)
        #expect(try store.verifyPIN("0123"))
    }

    @Test("Committing an invalid prepared record is rejected")
    func invalidPreparedCommit() {
        let (store, dataStore) = makeStore()

        #expect(throws: AwayPINStoreError.invalidStoredRecord) {
            try store.commitPIN(AwayPreparedPIN(data: Data("not-json".utf8)))
        }
        #expect(dataStore.saveCount == 0)
    }

    @Test("Production Keychain attributes are local and device only")
    func productionKeychainAttributes() {
        let attributes = SecurityAwayKeychainDataStore.saveAttributes(for: Data([1]))

        #expect(attributes[kSecClass] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrService] as? String == SecurityAwayKeychainDataStore.service)
        #expect(attributes[kSecAttrAccount] as? String == SecurityAwayKeychainDataStore.account)
        #expect(attributes[kSecAttrSynchronizable] as? Bool == false)
        #expect(
            attributes[kSecAttrAccessible] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    @Test("Setting a second PIN replaces the verifier")
    func replacement() throws {
        let (store, dataStore) = makeStore()

        try store.setPIN("0123")
        let first = dataStore.data
        try store.setPIN("9876")

        #expect(dataStore.saveCount == 2)
        #expect(dataStore.data != first)
        #expect(try store.verifyPIN("9876"))
        #expect(try !store.verifyPIN("0123"))
    }

    @Test("Removing a PIN clears the backing item")
    func removal() throws {
        let (store, dataStore) = makeStore()
        try store.setPIN("0123")

        try store.removePIN()

        #expect(try !store.hasPIN())
        #expect(dataStore.removeCount == 1)
    }

    @Test("Verification without a stored item reports a typed error")
    func noStoredPIN() {
        let (store, _) = makeStore()

        #expect(throws: AwayPINStoreError.noStoredPIN) {
            try store.verifyPIN("0123")
        }
    }

    @Test("Malformed and unsupported records are rejected")
    func malformedRecord() throws {
        let dataStore = AwayKeychainDataStoreStub()
        dataStore.data = Data("not-json".utf8)
        let (store, _) = makeStore(dataStore: dataStore)

        #expect(throws: AwayPINStoreError.invalidStoredRecord) {
            try store.hasPIN()
        }
        #expect(throws: AwayPINStoreError.invalidStoredRecord) {
            try store.verifyPIN("0123")
        }

        let unsupported = AwayPINRecord(
            version: 99,
            algorithm: AwayPINRecord.algorithm,
            iterations: 1,
            salt: fixedSalt,
            verifier: Data(repeating: 0, count: AwayPINCodec.verifierLength)
        )
        dataStore.data = try JSONEncoder().encode(unsupported)
        #expect(throws: AwayPINStoreError.invalidStoredRecord) {
            try store.hasPIN()
        }
        #expect(throws: AwayPINStoreError.invalidStoredRecord) {
            try store.verifyPIN("0123")
        }
    }

    @Test("PBKDF2 HMAC SHA256 output matches a known vector")
    func pbkdf2Vector() throws {
        let salt = Data(repeating: 0, count: AwayPINCodec.saltLength)
        let codec = AwayPINCodec(iterations: 1, randomBytes: { _ in salt })

        let record = try codec.makeRecord(for: "1234")

        #expect(record.verifier.hexString == "350aeccd6a78b15d47657e419a53c652a7ae67c263979080fcbdf4af3dcd10ec")
    }

    @Test("Verifier comparison checks equal and unequal fixed-size values")
    func verifierComparison() {
        let first = Data([0, 1, 2, 3])
        let second = Data([0, 1, 2, 3])
        let third = Data([0, 1, 2, 4])

        #expect(AwayPINCodec.constantTimeEqual(first, second))
        #expect(!AwayPINCodec.constantTimeEqual(first, third))
        #expect(!AwayPINCodec.constantTimeEqual(first, Data([0, 1, 2])))
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
