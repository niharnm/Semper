import Foundation

enum SemperModule: String, CaseIterable, Identifiable, Sendable {
    case sound
    case awake

    static let initial: SemperModule = .sound

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sound: "Sound"
        case .awake: "Awake"
        }
    }

    var symbolName: String {
        switch self {
        case .sound: "speaker.wave.2.fill"
        case .awake: "sun.max.fill"
        }
    }
}
