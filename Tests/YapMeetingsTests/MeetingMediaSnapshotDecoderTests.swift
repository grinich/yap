import Foundation
import Testing
@testable import YapMeetings

@Suite("Native device snapshot decoding")
struct MeetingMediaSnapshotDecoderTests {
    @Test func nativeSchemaPreservesBooleansOptionalVolumesAndDeviceSelection() throws {
        let state = try MeetingMediaSnapshotDecoder.decode(fixtureData())
        #expect(state.isReady && !state.isInMeeting)
        #expect(state.microphones.first?.selected == true)
        #expect(state.cameras.first?.selected == false)
        #expect(state.microphoneVolume == 0 && state.speakerVolume == nil)
        #expect(state.automaticMicrophoneVolume && !state.canSetMicrophoneVolume)
        #expect(state.microphoneTest == "idle" && !state.speakerTestRunning)
    }

    @Test(arguments: ["isReady", "isInMeeting", "automaticMicrophoneVolume", "canSetMicrophoneVolume", "canSetSpeakerVolume", "speakerTestRunning"])
    func numericFlagsProduceSafeFieldDiagnosticAndFriendlyError(field: String) throws {
        var snapshot = try fixtureObject()
        snapshot[field] = 1
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        let diagnostic = rawDiagnostic(data)
        #expect(diagnostic == "typeMismatch expected=Swift.Bool path=$.\(field)")
        #expect(throws: MeetingError.unavailable(MeetingMediaSnapshotDecoder.unavailableMessage)) {
            try MeetingMediaSnapshotDecoder.decode(data)
        }
    }

    @Test func nestedFailureIdentifiesSchemaPathWithoutDeviceValues() throws {
        var snapshot = try fixtureObject()
        snapshot["microphones"] = [["id": "private-device-id", "name": "Private device name", "selected": 1]]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        #expect(rawDiagnostic(data) == "typeMismatch expected=Swift.Bool path=$.microphones[0].selected")
        #expect(!rawDiagnostic(data).contains("private-device-id"))
        #expect(!rawDiagnostic(data).contains("Private device name"))
    }

    @Test func invalidJSONDoesNotExposeItsContents() {
        let data = Data("invalid-json-with-private-device-value".utf8)
        #expect(rawDiagnostic(data) == "dataCorrupted path=$")
        #expect(throws: MeetingError.unavailable(MeetingMediaSnapshotDecoder.unavailableMessage)) {
            try MeetingMediaSnapshotDecoder.decode(data)
        }
    }

    private func rawDiagnostic(_ data: Data) -> String {
        do { _ = try JSONDecoder().decode(MeetingMediaState.self, from: data); return "unexpectedSuccess" }
        catch { return MeetingMediaSnapshotDecoder.diagnostic(for: error) }
    }

    private func fixtureObject() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
    }

    private func fixtureData() -> Data {
        Data(#"{"isReady":true,"isInMeeting":false,"microphones":[{"id":"mic","name":"Microphone","selected":true}],"speakers":[],"cameras":[{"id":"cam","name":"Camera","selected":false}],"microphoneVolume":0,"speakerVolume":null,"automaticMicrophoneVolume":true,"canSetMicrophoneVolume":false,"canSetSpeakerVolume":false,"microphoneTest":"idle","speakerTestRunning":false,"error":null}"#.utf8)
    }
}
