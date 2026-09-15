import AppKit

public enum ChatNotificationSound: String, CaseIterable, Sendable {
    case none = "None"
    case pop = "Pop"
    case glass = "Glass"
    case ping = "Ping"
    case purr = "Purr"
    case tink = "Tink"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case basso = "Basso"
    case blow = "Blow"
    case hero = "Hero"
    case morse = "Morse"
    case sosumi = "Sosumi"
    case submarine = "Submarine"

    @MainActor func play() {
        guard self != .none else { return }
        NSSound(named: NSSound.Name(rawValue))?.play()
    }
}
