import Foundation

public enum MeetingMediaKind: String, Codable, CaseIterable, Sendable {
    case microphone, speaker, camera
}

public struct MeetingMediaDevice: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let selected: Bool
    public init(id: String, name: String, selected: Bool = false) {
        self.id = id; self.name = name; self.selected = selected
    }
}

public struct MeetingMediaState: Codable, Equatable, Sendable {
    public var isReady: Bool
    public var isInMeeting: Bool
    public var microphones: [MeetingMediaDevice]
    public var speakers: [MeetingMediaDevice]
    public var cameras: [MeetingMediaDevice]
    public var microphoneVolume: Int?
    public var speakerVolume: Int?
    public var automaticMicrophoneVolume: Bool
    public var canSetMicrophoneVolume: Bool
    public var canSetSpeakerVolume: Bool
    public var microphoneTest: String
    public var speakerTestRunning: Bool
    public var error: String?

    public init(isReady: Bool = false, isInMeeting: Bool = false,
                microphones: [MeetingMediaDevice] = [], speakers: [MeetingMediaDevice] = [], cameras: [MeetingMediaDevice] = [],
                microphoneVolume: Int? = nil, speakerVolume: Int? = nil, automaticMicrophoneVolume: Bool = true,
                canSetMicrophoneVolume: Bool = false, canSetSpeakerVolume: Bool = false,
                microphoneTest: String = "idle", speakerTestRunning: Bool = false, error: String? = nil) {
        self.isReady = isReady; self.isInMeeting = isInMeeting
        self.microphones = microphones; self.speakers = speakers; self.cameras = cameras
        self.microphoneVolume = microphoneVolume; self.speakerVolume = speakerVolume
        self.automaticMicrophoneVolume = automaticMicrophoneVolume
        self.canSetMicrophoneVolume = canSetMicrophoneVolume; self.canSetSpeakerVolume = canSetSpeakerVolume
        self.microphoneTest = microphoneTest; self.speakerTestRunning = speakerTestRunning
        self.error = error
    }

    public func devices(for kind: MeetingMediaKind) -> [MeetingMediaDevice] {
        switch kind { case .microphone: microphones; case .speaker: speakers; case .camera: cameras }
    }
}

/// Device settings share the process-wide Zoom instance with camera settings and meetings.
/// Preparation enumerates devices; only an explicit test request may capture audio.
@MainActor
public protocol MeetingMediaDriver: AnyObject {
    var onMediaDevicesChanged: (@MainActor (MeetingMediaState) -> Void)? { get set }
    func prepareMediaDevices() async throws -> MeetingMediaState
    func selectMediaDevice(_ deviceID: String, kind: MeetingMediaKind) async throws -> MeetingMediaState
    func setMediaVolume(_ volume: Int, kind: MeetingMediaKind) async throws -> MeetingMediaState
    func setAutomaticMicrophoneVolume(_ enabled: Bool) async throws -> MeetingMediaState
    func setMediaTest(_ kind: MeetingMediaKind, running: Bool) async throws -> MeetingMediaState
    func stopMediaTests()
}
