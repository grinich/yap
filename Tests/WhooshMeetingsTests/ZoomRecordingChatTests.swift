import Foundation
import Testing
@testable import WhooshMeetings

@Suite("Zoom recording chat parser")
struct ZoomRecordingChatTests {
    @Test func parsesCanonicalCloudExportAndPreservesMeetingRelativeTimes() {
        let messages = ZoomRecordingChatParser.parse("00:47:53\tCTaly: Hi\n00:47:56\tWitch Hunt:\tSUD\n00:47:59\tMitch Wildly: Yes")
        #expect(messages.map(\.offset) == [2_873, 2_876, 2_879])
        #expect(messages.map(\.sender) == ["CTaly", "Witch Hunt", "Mitch Wildly"])
        #expect(messages.map(\.text) == ["Hi", "SUD", "Yes"])
        #expect(messages.allSatisfy { $0.recipient == nil })
    }

    @Test func keepsMultilineMessagesAndNormalizesBOMAndLineEndings() {
        let messages = ZoomRecordingChatParser.parse("\u{FEFF}Zoom meeting chat\r\n00:00:12\tAda:\tFirst line\r\nSecond line\r\n\r\nFourth line\r\n00:00:15\tLin:\tHello 👋\r\n")
        #expect(messages.count == 2)
        #expect(messages.first?.text == "First line\nSecond line\n\nFourth line")
        #expect(messages.last?.text == "Hello 👋")
    }

    @Test func acceptsLegacyRecipientsAndMessagesOnTheFollowingLine() {
        let messages = ZoomRecordingChatParser.parse("00:01:02 From Alex Chen to Everyone:\nHello all\n00:01:05\tFrom Priya Shah to Alex Chen (Privately):\tCan you check this?")
        #expect(messages.count == 2)
        #expect(messages[0].sender == "Alex Chen")
        #expect(messages[0].recipient == "Everyone")
        #expect(messages[0].text == "Hello all")
        #expect(messages[1].sender == "Priya Shah")
        #expect(messages[1].recipient == "Alex Chen (Privately)")
        #expect(messages[1].text == "Can you check this?")
    }

    @Test func retainsColonsTabsAndURLsInMessageTextAndCanonicalDisplayNames() {
        let messages = ZoomRecordingChatParser.parse("00:02:03\tAda: Design:\tSee https://example.com:8443/path\twith tabs\nCode: value")
        #expect(messages.first?.sender == "Ada: Design")
        #expect(messages.first?.text == "See https://example.com:8443/path\twith tabs\nCode: value")
    }

    @Test func acceptsSpaceDelimitedFractionalAndLongMeetingTimestamps() {
        let messages = ZoomRecordingChatParser.parse("0:00:01.125 Ada: hello\n25:01:02,500 Lin: long meeting")
        #expect(messages.map(\.offset) == [1.125, 90_062.5])
        #expect(messages.map(\.text) == ["hello", "long meeting"])
    }

    @Test func identitiesAreStableAndIdenticalMessagesRemainDistinct() {
        let source = "00:00:01\tAda:\tYes\n00:00:01\tAda:\tYes\n00:00:01\tLin:\tYes"
        let messages = ZoomRecordingChatParser.parse(source)
        #expect(messages == ZoomRecordingChatParser.parse(source))
        #expect(Set(messages.map(\.id)).count == 3)
        let prefixed = ZoomRecordingChatParser.parse("00:00:00\tSam:\tWelcome\n" + source)
        #expect(Array(prefixed.dropFirst()) == messages)
    }

    @Test func ignoresUnknownPreamblesEmptyMessagesAndMalformedStandaloneHeaders() {
        let source = "Zoom meeting chat\n-01:00:00\tAda: invalid\n00:70:00\tAda: invalid\n00:00:70\tAda: invalid\n00:00:01\t:\tmissing sender"
        #expect(ZoomRecordingChatParser.parse(source).isEmpty)
        #expect(ZoomRecordingChatParser.parse("00:00:01\tAda:\t\n\n00:00:02\tLin: Hello").map(\.text) == ["Hello"])
        #expect(ZoomRecordingChatParser.parse("").isEmpty)
        #expect(ZoomRecordingChatParser.parse(#"{"timestamp":"00:00:01","sender":"Ada","message":"Hello"}"#).isEmpty)
    }

    @Test func preservesSourceOrderForMessagesAtTheSameTime() {
        let messages = ZoomRecordingChatParser.parse("00:00:02\tLin: Second\n00:00:02\tAda: Third\n00:00:01\tSam: Export order")
        #expect(messages.map(\.sender) == ["Lin", "Ada", "Sam"])
        #expect(messages.map(\.offset) == [2, 2, 1])
    }
}
