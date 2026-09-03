import XCTest
@testable import TunnelApp

final class EdgeLogInterpreterTests: XCTestCase {
    func testSingleConnectionRegisterAndServeFailure() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(
            interpreter.consume("INF Registered tunnel connection connIndex=0 location=sjc"),
            .connected
        )
        XCTAssertEqual(
            interpreter.consume("ERR failed to serve tunnel connection error=\"timeout\" connIndex=0"),
            .degraded
        )
        XCTAssertEqual(
            interpreter.consume("INF Registered tunnel connection connIndex=0 location=sjc"),
            .connected
        )
    }

    func testOneOfFourConnectionsDroppingDoesNotMarkTunnelDown() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(interpreter.consume(#"{"msg":"Registered tunnel connection","connIndex":0}"#), .connected)
        XCTAssertEqual(interpreter.consume("Registered tunnel connection connIndex=1 protocol=quic"), .connected)
        XCTAssertEqual(interpreter.consume("Registered tunnel connection connIndex=2"), .connected)
        XCTAssertEqual(interpreter.consume("Registered tunnel connection connIndex=3"), .connected)

        XCTAssertEqual(
            interpreter.consume("ERR failed to serve tunnel connection connIndex=1 error=\"connection reset\""),
            .connected
        )
        XCTAssertEqual(
            interpreter.consume("INF Retrying connection in up to 1s connIndex=1"),
            .connected
        )
        XCTAssertEqual(
            interpreter.consume("ERR origin connection error dial tcp 127.0.0.1:3000: connect: connection refused"),
            .connected
        )
    }

    func testGenericConnectionErrorDoesNotDegradeEdge() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(interpreter.consume("Registered tunnel connection connIndex=0"), .connected)
        XCTAssertEqual(interpreter.consume("WRN request failed: connection error from origin"), .connected)
        XCTAssertEqual(interpreter.consume("unable to reach the origin service"), .connected)
    }

    func testGlobalCloudflareEstablishFailureClearsConnections() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(interpreter.consume("Registered tunnel connection connIndex=0"), .connected)
        XCTAssertEqual(
            interpreter.consume("ERR Unable to establish connection with Cloudflare edge"),
            .degraded
        )
    }

    func testResetReturnsToConnecting() {
        var interpreter = EdgeLogInterpreter()
        _ = interpreter.consume("Registered tunnel connection connIndex=0")
        interpreter.reset()
        XCTAssertEqual(interpreter.consume("starting cloudflared"), .connecting)
    }
}
