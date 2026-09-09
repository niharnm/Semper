import CommonCrypto
import Foundation
import Security

enum AwayPINStoreError: Error, Equatable, Sendable {
    case invalidPINFormat
    case invalidIterationCount
    case noStoredPIN
    case invalidStoredRecord
    case randomGenerationFailed(OSStatus)
    case derivationFailed(Int32)
    case keychainFailure(OSStatus)
}

struct AwayPreparedPIN: Equatable, Sendable {
    let data: Data
}

protocol AwayPINStoring: Sendable {
    func hasPIN() throws -> Bool
    func preparePIN(_ pin: String) throws -> AwayPreparedPIN
    func commitPIN(_ preparedPIN: AwayPreparedPIN) throws
    func verifyPIN(_ pin: String) throws -> Bool
    func removePIN() throws
}

extension AwayPINStoring {
    func setPIN(_ pin: String) throws {
        try commitPIN(preparePIN(pin))
    }
}

protocol AwayKeychainDataStoring: Sendable {
    func loadData() throws -> Data?
    func saveData(_ data: Data) throws
    func removeData() throws
}

struct SecurityAwayKeychainDataStore: AwayKeychainDataStoring, Sendable {
    static let service = "systems.semper.Semper.away-mode"
    static let account = "pin"

    func loadData() throws -> Data? {
        var query = Self.baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw AwayPINStoreError.invalidStoredRecord
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw AwayPINStoreError.keychainFailure(status)
        }
    }

    func saveData(_ data: Data) throws {
        let attributes = Self.saveAttributes(for: data)

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw AwayPINStoreError.keychainFailure(addStatus)
        }

        let updateStatus = SecItemUpdate(
            Self.baseQuery as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw AwayPINStoreError.keychainFailure(updateStatus)
        }
    }

    func removeData() throws {
        let status = SecItemDelete(Self.baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AwayPINStoreError.keychainFailure(status)
        }
    }

    static var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    static func saveAttributes(for data: Data) -> [CFString: Any] {
        var attributes = baseQuery
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData] = data
        return attributes
    }
}

struct AwayPINRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let algorithm = "PBKDF2-HMAC-SHA256"

    let version: Int
    let algorithm: String
    let iterations: UInt32
    let salt: Data
    let verifier: Data
}

struct AwayPINCodec: Sendable {
    typealias RandomBytes = @Sendable (Int) throws -> Data

    static let productionIterations: UInt32 = 600_000
    static let saltLength = 16
    static let verifierLength = 32
    static let maximumIterations: UInt32 = 2_000_000

    let iterations: UInt32
    private let randomBytes: RandomBytes

    init(
        iterations: UInt32 = Self.productionIterations,
        randomBytes: @escaping RandomBytes = Self.secureRandomBytes
    ) {
        self.iterations = iterations
        self.randomBytes = randomBytes
    }

    func makeRecord(for pin: String) throws -> AwayPINRecord {
        guard Self.isValidPIN(pin) else {
            throw AwayPINStoreError.invalidPINFormat
        }
        guard iterations > 0, iterations <= Self.maximumIterations else {
            throw AwayPINStoreError.invalidIterationCount
        }
        let salt = try randomBytes(Self.saltLength)
        guard salt.count == Self.saltLength else {
            throw AwayPINStoreError.invalidStoredRecord
        }
        let verifier = try derive(pin: pin, salt: salt, iterations: iterations)
        return AwayPINRecord(
            version: AwayPINRecord.currentVersion,
            algorithm: AwayPINRecord.algorithm,
            iterations: iterations,
            salt: salt,
            verifier: verifier
        )
    }

    func verify(_ pin: String, against record: AwayPINRecord) throws -> Bool {
        guard Self.isValidPIN(pin) else {
            throw AwayPINStoreError.invalidPINFormat
        }
        guard Self.isValidRecord(record) else {
            throw AwayPINStoreError.invalidStoredRecord
        }

        let candidate = try derive(pin: pin, salt: record.salt, iterations: record.iterations)
        return Self.constantTimeEqual(candidate, record.verifier)
    }

    static func isValidPIN(_ pin: String) -> Bool {
        let bytes = Array(pin.utf8)
        return bytes.count == 4 && bytes.allSatisfy { (48...57).contains($0) }
    }

    static func isValidRecord(_ record: AwayPINRecord) -> Bool {
        record.version == AwayPINRecord.currentVersion
            && record.algorithm == AwayPINRecord.algorithm
            && record.iterations > 0
            && record.iterations <= maximumIterations
            && record.salt.count == saltLength
            && record.verifier.count == verifierLength
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { difference, pair in
            difference | (pair.0 ^ pair.1)
        } == 0
    }

    private func derive(pin: String, salt: Data, iterations: UInt32) throws -> Data {
        var output = Data(repeating: 0, count: Self.verifierLength)
        let status = pin.withCString { passwordPointer in
            salt.withUnsafeBytes { saltBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        pin.utf8.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                        Self.verifierLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw AwayPINStoreError.derivationFailed(status)
        }
        return output
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw AwayPINStoreError.randomGenerationFailed(status)
        }
        return data
    }
}

struct KeychainAwayPINStore: AwayPINStoring, Sendable {
    private static let maximumRecordSize = 4_096

    private let dataStore: any AwayKeychainDataStoring
    private let codec: AwayPINCodec

    init(
        dataStore: any AwayKeychainDataStoring = SecurityAwayKeychainDataStore(),
        codec: AwayPINCodec = AwayPINCodec()
    ) {
        self.dataStore = dataStore
        self.codec = codec
    }

    func hasPIN() throws -> Bool {
        guard let data = try dataStore.loadData() else { return false }
        guard data.count <= Self.maximumRecordSize,
              let record = try? JSONDecoder().decode(AwayPINRecord.self, from: data),
              AwayPINCodec.isValidRecord(record) else {
            throw AwayPINStoreError.invalidStoredRecord
        }
        return true
    }

    func preparePIN(_ pin: String) throws -> AwayPreparedPIN {
        let record = try codec.makeRecord(for: pin)
        let data = try JSONEncoder().encode(record)
        return AwayPreparedPIN(data: data)
    }

    func commitPIN(_ preparedPIN: AwayPreparedPIN) throws {
        guard preparedPIN.data.count <= Self.maximumRecordSize,
              let record = try? JSONDecoder().decode(AwayPINRecord.self, from: preparedPIN.data),
              AwayPINCodec.isValidRecord(record) else {
            throw AwayPINStoreError.invalidStoredRecord
        }
        try dataStore.saveData(preparedPIN.data)
    }

    func verifyPIN(_ pin: String) throws -> Bool {
        guard let data = try dataStore.loadData() else {
            throw AwayPINStoreError.noStoredPIN
        }
        guard data.count <= Self.maximumRecordSize,
              let record = try? JSONDecoder().decode(AwayPINRecord.self, from: data) else {
            throw AwayPINStoreError.invalidStoredRecord
        }
        return try codec.verify(pin, against: record)
    }

    func removePIN() throws {
        try dataStore.removeData()
    }
}
