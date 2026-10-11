import XCTest
@testable import AIGlassesLink

final class ConversationProtocolTests: XCTestCase {
    func testEncodesEveryClientCommand() {
        XCTAssertEqual(ConversationCommand.start.text, "START")
        XCTAssertEqual(ConversationCommand.stop.text, "STOP")
        XCTAssertEqual(ConversationCommand.speechStart(turnID: 4).text, "SPEECH_START:4")
        XCTAssertEqual(ConversationCommand.speechEnd(turnID: 4).text, "SPEECH_END:4")
        XCTAssertEqual(ConversationCommand.bargeIn.text, "BARGE_IN")
        XCTAssertEqual(ConversationCommand.micGateTTS.text, "MIC_GATE:TTS")
        XCTAssertEqual(ConversationCommand.micGateOpen.text, "MIC_GATE:OPEN")
        XCTAssertEqual(
            ConversationCommand.deviceLatency(turnID: 4, milliseconds: 321).text,
            "LATENCY:DEVICE:4:321"
        )
    }

    func testDecodesEveryServerEvent() {
        XCTAssertEqual(ConversationServerEvent.decode("TTS:START:7"), .ttsStart(turnID: 7))
        XCTAssertEqual(ConversationServerEvent.decode("TTS:END:7"), .ttsEnd(turnID: 7))
        XCTAssertEqual(ConversationServerEvent.decode("TTS:RESET:7"), .ttsReset(turnID: 7))
        XCTAssertEqual(ConversationServerEvent.decode("OK:STARTED"), .started)
        XCTAssertEqual(ConversationServerEvent.decode("OK:STOPPED"), .stopped)
        XCTAssertEqual(ConversationServerEvent.decode("RESET"), .reset)
        XCTAssertEqual(ConversationServerEvent.decode("OTHER"), .unknown("OTHER"))
    }

    func testRejectsMalformedTurnIDsWithoutGuessing() {
        XCTAssertEqual(
            ConversationServerEvent.decode("TTS:START:not-an-integer"),
            .unknown("TTS:START:not-an-integer")
        )
    }
}
