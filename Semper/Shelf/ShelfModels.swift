import Foundation

nonisolated enum ShelfExpiry: String, Codable, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes, oneHour, endOfDay, quit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .endOfDay: "End of day"
        case .quit: "When Semper quits"
        }
    }
    func deadline(from date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .fifteenMinutes: date.addingTimeInterval(15 * 60)
        case .oneHour: date.addingTimeInterval(60 * 60)
        case .endOfDay: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        case .quit: nil
        }
    }
}

nonisolated enum ShelfPayload: Codable, Equatable, Sendable {
    case file(URL, bookmark: Data?)
    case cachedFile(String)
    case link(URL)
    case text(String)
}

nonisolated struct ShelfItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    var payload: ShelfPayload
    let createdAt: Date
    var expiry: ShelfExpiry
    var expiresAt: Date?

    init(id: UUID = UUID(), name: String, payload: ShelfPayload, now: Date, expiry: ShelfExpiry) {
        self.id = id
        self.name = String(name.prefix(240))
        self.payload = payload
        createdAt = now
        self.expiry = expiry
        expiresAt = expiry.deadline(from: now)
    }

    func hasExpired(at date: Date) -> Bool { expiresAt.map { $0 <= date } ?? false }
}

nonisolated enum ShelfFileState: Equatable, Sendable {
    case available(isDirectory: Bool)
    case missing
    case cloudOnly
    case inaccessible

    var message: String {
        switch self {
        case .available(let directory): directory ? "Folder reference" : "File reference"
        case .missing: "Original file is missing. Locate it in Finder and add it again."
        case .cloudOnly: "Download this item in Finder, then refresh the shelf."
        case .inaccessible: "File access is unavailable. Choose or drop the item again to grant access."
        }
    }
    var isAvailable: Bool {
        if case .available = self { true } else { false }
    }
}

nonisolated enum ShelfFailure: Error, Equatable, LocalizedError, Sendable {
    case stopped, full, tooLarge, unsupported, missing, cloudOnly, inaccessible
    case invalidStore, storeVersion, storeWrite, cancelled, changedDuringRead, invalidImage
    case recoveredCopyNeedsAcknowledgement

    var errorDescription: String? {
        switch self {
        case .stopped: "File Shelf is paused. Start it before adding items."
        case .full: "The shelf holds up to 100 items. Clear an item before adding another."
        case .tooLarge: "This item exceeds the shelf import limit. Drop a file reference instead."
        case .unsupported: "This drop has no supported file, image, link, or plain-text representation."
        case .missing: "The original file is missing."
        case .cloudOnly: "Download this item in Finder before using it."
        case .inaccessible: "The item cannot be read. Check access in Finder, then choose or drop it again."
        case .invalidStore: "Saved shelf data could not be read. It has been left untouched."
        case .storeVersion: "This saved shelf uses a newer format. It has been left untouched."
        case .storeWrite: "The shelf could not save its local data."
        case .cancelled: "Operation cancelled."
        case .changedDuringRead: "The file changed while its checksum was being calculated. Try again."
        case .invalidImage: "This image is invalid or exceeds the image size limit."
        case .recoveredCopyNeedsAcknowledgement: "Review the recovered copy's saved location, then choose Done."
        }
    }
}

nonisolated enum ShelfLimits {
    static let items = 100
    static let textBytes = 64 * 1024
    static let urlBytes = 8 * 1024
    static let importBytes = 32 * 1024 * 1024
    static let cacheBytes = 256 * 1024 * 1024
    static let storeBytes = 12 * 1024 * 1024
    static let chunkBytes = 64 * 1024
    static let imagePixels = 40_000_000
}
