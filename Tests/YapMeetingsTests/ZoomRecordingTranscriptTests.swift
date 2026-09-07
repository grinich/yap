import Foundation
import Testing
@testable import YapMeetings

@Suite("Zoom recording transcript parser")
struct ZoomRecordingTranscriptTests {
    @Test func parsesZoomSpeakerPrefixesAndSegmentRelativeTimes() throws {
        let cues = try ZoomRecordingTranscriptParser.parse("""
        WEBVTT

        1
        00:00:02.125 --> 00:00:05.900
        Ada Chen: Welcome, everyone.

        2
        01:02:03.004 --> 01:02:08.500
        Lin: Let's continue: there is more to discuss.
        This stays on a second line.
        """)
        #expect(cues.map(\.start) == [2.125, 3_723.004])
        #expect(cues.map(\.end) == [5.9, 3_728.5])
        #expect(cues.map(\.speaker) == ["Ada Chen", "Lin"])
        #expect(cues.map(\.text) == ["Welcome, everyone.", "Let's continue: there is more to discuss.\nThis stays on a second line."])
    }

    @Test func normalizesBOMLineEndingsAndReadsShortTimestampsAndSettings() throws {
        let cues = try ZoomRecordingTranscriptParser.parse("\u{FEFF}WEBVTT Zoom transcript\r\nKind: captions\r\nLanguage: en\r\n\r\nintro\r\n00:12.345 --> 00:15.000 align:start position:10%,line-left line:90%\r\n<v Ada>Hello 👋\r\nSecond line\r\n\r\n00:16.000 --> 00:17.250\r\n<v Lin>Hi\r\n")
        #expect(cues.count == 2)
        #expect(cues[0].start == 12.345)
        #expect(cues[0].end == 15)
        #expect(cues[0].speaker == "Ada")
        #expect(cues[0].text == "Hello 👋\nSecond line")
        #expect(cues[1].speaker == "Lin")
        #expect(cues[1].end == 17.25)
        #expect(try ZoomRecordingTranscriptParser.parse("WEBVTT\r\r00:00.000 --> 00:01.000\rHello").first?.text == "Hello")
    }

    @Test func removesFormattingAndInlineTimestampsAndDecodesEntitiesOnlyOnce() throws {
        let cues = try ZoomRecordingTranscriptParser.parse("""
        WEBVTT

        00:00.000 --> 00:04.000
        <v.first.loud Ada &amp; Lin><b>Fish &amp; chips</b> &lt;tag&gt; &amp;lt;
        <i.foreign><lang fr>Oui</lang></i> <00:02.000><u>now</u> &#x1F44B; &#39;yes&#39; &quot;ok&quot;&nbsp;done
        </v>
        """)
        #expect(cues.first?.speaker == "Ada & Lin")
        #expect(cues.first?.text == "Fish & chips <tag> &lt;\nOui now 👋 'yes' \"ok\"\u{00A0}done")
    }

    @Test func preservesLiteralComparisonTextUnknownEntitiesAndURLs() throws {
        let cues = try ZoomRecordingTranscriptParser.parse("""
        WEBVTT

        00:00.000 --> 00:01.000
        https://example.com:8443/path
        2 < 3 and 5 > 4 &unknown; &#xD800; &#0;
        """)
        #expect(cues.first?.speaker == nil)
        #expect(cues.first?.text == "https://example.com:8443/path\n2 < 3 and 5 > 4 &unknown; &#xD800; &#0;")
    }

    @Test func doesNotDuplicateMatchingVoiceAndZoomSpeakerLabels() throws {
        let cues = try ZoomRecordingTranscriptParser.parse("""
        WEBVTT

        00:00.000 --> 00:01.000
        <v Ada><b>Ada:</b> Hello

        00:01.000 --> 00:02.000
        <v Ada>Reminder: keep this colon.
        """)
        #expect(cues.map(\.speaker) == ["Ada", "Ada"])
        #expect(cues.map(\.text) == ["Hello", "Reminder: keep this colon."])
    }

    @Test func keepsDifferentVoicesWithinOneCueAttributedInItsText() throws {
        let cues = try ZoomRecordingTranscriptParser.parse("""
        WEBVTT

        00:00.000 --> 00:04.000
        <v Ada>Hello.</v>
        <v Lin>Hi.</v>
        """)
        #expect(cues.first?.speaker == nil)
        #expect(cues.first?.text == "Ada: Hello.\nLin: Hi.")
    }

    @Test func ignoresNoteStyleAndRegionBlocksAndHeaderMetadata() throws {
        let cues = try ZoomRecordingTranscriptParser.parse("""
        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000

        NOTE export metadata
        99:00:00.000 --> 99:00:01.000
        Not a cue.

        STYLE
        ::cue { color: white; }

        REGION
        id:main
        width:80%

        NOTED
        00:01.000 --> 00:02.000 region:main
        The cue identifier is not a NOTE block.

        NOTE
        End of transcript
        """)
        #expect(cues.count == 1)
        #expect(cues.first?.start == 1)
        #expect(cues.first?.text == "The cue identifier is not a NOTE block.")
    }

    @Test func emptyAndMetadataOnlyFilesHaveNoCues() throws {
        for source in ["", "\u{FEFF}\r\n\t ", "WEBVTT", "WEBVTT\n\nNOTE no speech",
                       "WEBVTT\n\n00:00.000 --> 00:01.000\n<b></b>"] {
            #expect(try ZoomRecordingTranscriptParser.parse(source).isEmpty)
        }
    }

    @Test func stableContentIDsSurviveRenumberingAndKeepDuplicatesDistinct() throws {
        let first = "00:01.000 --> 00:02.000\nAda: Yes"
        let second = "00:01.000 --> 00:02.000\nLin: Yes"
        let source = "WEBVTT\n\n1\n\(first)\n\n2\n\(first)\n\n3\n\(second)"
        let cues = try ZoomRecordingTranscriptParser.parse(source)
        #expect(cues == (try ZoomRecordingTranscriptParser.parse(source)))
        #expect(Set(cues.map(\.id)).count == 3)
        let inserted = "WEBVTT\n\n1\n00:00.000 --> 00:00.500\nSam: Welcome\n\n2\n\(first)\n\n3\n\(first)\n\n4\n\(second)"
        #expect(Array(try ZoomRecordingTranscriptParser.parse(inserted).dropFirst()) == cues)
    }

    @Test func overlappingAndOutOfOrderCuesPreserveSourceOrder() throws {
        let cues = try ZoomRecordingTranscriptParser.parse("""
        WEBVTT

        00:03.000 --> 00:05.000
        Ada: Third second

        00:03.000 --> 00:04.000
        Lin: Overlap

        00:01.000 --> 00:02.000
        Sam: Earlier
        """)
        #expect(cues.map(\.start) == [3, 3, 1])
        #expect(cues.map(\.speaker) == ["Ada", "Lin", "Sam"])
    }

    @Test(arguments: [
        "<html><body>Sign in to Zoom</body></html>",
        #"{"error":"access denied"}"#,
        "00:00.000 --> 00:01.000\nMissing signature",
        "WEBVTTjunk\n\n00:00.000 --> 00:01.000\nText",
        "WEBVTT --> invalid\n\n",
        "WEBVTT\nThis is not transcript metadata",
        "WEBVTT\n\nUnreadable content",
        "WEBVTT\n00:00.000 --> 00:01.000\nMissing header separator",
        "WEBVTT\n\n00:00.000 --> 00:01.000 trailing-garbage\nText",
        "WEBVTT\n\n00:00.000 --> 00:01.000\nFirst\n00:01.000 --> 00:02.000\nMissing cue separator",
        "WEBVTT\n\n00:00.000 --> 00:01.000\nBroken\u{0000}text"
    ]) func rejectsUnreadableNonemptyContent(_ source: String) {
        #expect(throws: ZoomRecordingTranscriptError.invalidFormat) {
            try ZoomRecordingTranscriptParser.parse(source)
        }
    }

    @Test(arguments: [
        "-00:01.000 --> 00:02.000",
        "0:01.000 --> 00:02.000",
        "00:01,000 --> 00:02.000",
        "00:01.1 --> 00:02.000",
        "00:60.000 --> 01:02.000",
        "00:60:00.000 --> 01:02:00.000",
        "00:02.000 --> 00:02.000",
        "00:03.000 --> 00:02.000",
        "168:00:00.000 --> 168:00:00.001",
        "99999999999999999999999999999999:00:00.000 --> 99999999999999999999999999999999:00:01.000",
        "NaN --> Infinity"
    ]) func rejectsInvalidOrUnreasonableTimestamps(_ timing: String) {
        #expect(throws: ZoomRecordingTranscriptError.invalidTimestamp) {
            try ZoomRecordingTranscriptParser.parse("WEBVTT\n\n\(timing)\nAda: Speech")
        }
    }

    @Test func acceptsLongRecordingTimesUpToTheViewingLimit() throws {
        let cues = try ZoomRecordingTranscriptParser.parse("WEBVTT\n\n167:59:59.000 --> 168:00:00.000\nLong recording")
        #expect(cues.first?.start == 604_799)
        #expect(cues.first?.end == 604_800)
    }

    @Test func rejectsOversizedInputAndTooManyCues() {
        #expect(throws: ZoomRecordingTranscriptError.tooLarge) {
            try ZoomRecordingTranscriptParser.parse(String(repeating: "x", count: ZoomRecordingTranscriptParser.maximumByteCount + 1))
        }
        // Empty cues still count toward the bound; no digesting is needed here.
        let tooMany = "WEBVTT\n\n" + String(repeating: "00:00.000 --> 00:01.000\n\n", count: ZoomRecordingTranscriptParser.maximumCueCount + 1)
        #expect(throws: ZoomRecordingTranscriptError.tooLarge) {
            try ZoomRecordingTranscriptParser.parse(tooMany)
        }
    }

    @Test func errorsDescribeTheTranscriptFailure() {
        for error in [ZoomRecordingTranscriptError.invalidFormat, .invalidTimestamp, .tooLarge] {
            #expect(error.localizedDescription.localizedCaseInsensitiveContains("transcript"))
        }
    }

    @Test func cancelledParseDoesNotReturnAnEmptyTranscript() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ZoomRecordingTranscriptParser.parse("WEBVTT")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
