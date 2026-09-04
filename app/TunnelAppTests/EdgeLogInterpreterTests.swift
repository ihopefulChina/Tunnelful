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

    func testGlobalCloudflareEstablishFailureWithoutIndexKeepsLiveConnections() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(interpreter.consume("Registered tunnel connection connIndex=0"), .connected)
        XCTAssertEqual(
            interpreter.consume("ERR Unable to establish connection with Cloudflare edge"),
            .connected
        )
    }

    func testResetReturnsToConnecting() {
        var interpreter = EdgeLogInterpreter()
        _ = interpreter.consume("Registered tunnel connection connIndex=0")
        interpreter.reset()
        XCTAssertEqual(interpreter.consume("starting cloudflared"), .connecting)
        XCTAssertNil(interpreter.diagnostic)
        XCTAssertFalse(interpreter.suggestsHTTP2Protocol)
        XCTAssertFalse(interpreter.suggestsQUICProtocol)
    }

    func testUnregisteredIsNotTreatedAsRegistered() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(interpreter.consume("INF Unregistered tunnel connection connIndex=0"), .connecting)
        XCTAssertEqual(
            interpreter.consume("INF Registered tunnel connection connIndex=0 location=sjc"),
            .connected
        )
        XCTAssertEqual(interpreter.consume("INF Unregistered tunnel connection connIndex=0"), .degraded)
    }

    func testRegisteringDoesNotMarkConnected() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(interpreter.consume("DBG Registering tunnel connection connIndex=0"), .connecting)
    }

    func testLegacyConnectionUUIDRegisteredMarksConnected() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(
            interpreter.consume(
                "INF Connection 55d8e7e4-aaaa-bbbb-cccc-ddddeeeeffff registered connIndex=0 location=DFW"
            ),
            .connected
        )
        XCTAssertEqual(interpreter.consume("INF Connection registered connIndex=1"), .connected)
    }

    func testPrecheckHardFailMarksUnreachable() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(
            interpreter.consume(
                "2026-09-03T08:51:44Z INF precheck complete hard_fail=true run_id=00000000-0000-4000-8000-000000000000"
            ),
            .unreachable
        )
        XCTAssertEqual(
            interpreter.consume(#"{"message":"precheck complete","hard_fail":true,"run_id":"abc"}"#),
            .unreachable
        )
        XCTAssertNotNil(interpreter.diagnostic)
    }

    func testQUICTimeoutAloneStaysConnectingUntilHTTP2Fails() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(
            interpreter.consume(
                #"ERR Failed to dial a quic connection error="failed to dial to edge with quic: timeout: no recent network activity" connIndex=0 event=0 ip=198.41.192.107"#
            ),
            .connecting
        )
        XCTAssertTrue(interpreter.suggestsHTTP2Protocol)
        XCTAssertNotNil(interpreter.diagnostic)

        XCTAssertEqual(
            interpreter.consume("INF Switching to fallback protocol http2 connIndex=0 event=0 ip=198.41.192.167"),
            .connecting
        )

        XCTAssertEqual(
            interpreter.consume(
                #"ERR Unable to establish connection with Cloudflare edge error="TLS handshake with edge error: EOF" connIndex=0 event=0 ip=198.41.200.53"#
            ),
            .unreachable
        )
        XCTAssertTrue(interpreter.suggestsHTTP2Protocol)
        XCTAssertFalse(interpreter.suggestsQUICProtocol)
        XCTAssertTrue(interpreter.diagnostic?.contains("QUIC") == true)
        XCTAssertTrue(interpreter.diagnostic?.contains("HTTP/2") == true)
    }

    func testUserLogSequenceNeverRegisters() {
        var interpreter = EdgeLogInterpreter()
        let lines = [
            "2026-09-03T08:51:44Z INF precheck complete hard_fail=true run_id=00000000-0000-4000-8000-000000000000",
            #"2026-09-03T08:51:44Z ERR Failed to dial a quic connection error="failed to dial to edge with quic: timeout: no recent network activity" connIndex=0 event=0 ip=198.41.192.107"#,
            "2026-09-03T08:51:44Z INF Retrying connection in up to 4s connIndex=0 event=0 ip=198.41.192.107",
            "2026-09-03T08:53:55Z INF Switching to fallback protocol http2 connIndex=0 event=0 ip=198.41.192.167",
            #"2026-09-03T08:53:56Z ERR Unable to establish connection with Cloudflare edge error="TLS handshake with edge error: EOF" connIndex=0 event=0 ip=198.41.200.53"#,
            #"2026-09-03T08:53:56Z ERR Serve tunnel error error="TLS handshake with edge error: EOF" connIndex=0 event=0 ip=198.41.200.53"#
        ]

        var last: EdgeConnectionState = .unknown
        for line in lines {
            last = interpreter.consume(line)
        }
        XCTAssertEqual(last, .unreachable)
        XCTAssertFalse(lines.contains(where: { $0.localizedCaseInsensitiveContains("Registered tunnel connection") }))
    }

    func testEstablishFailureWithoutConnIndexDoesNotDropLiveHAConnections() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(interpreter.consume("Registered tunnel connection connIndex=0"), .connected)
        XCTAssertEqual(interpreter.consume("Registered tunnel connection connIndex=1"), .connected)
        XCTAssertEqual(
            interpreter.consume(
                #"ERR Unable to establish connection with Cloudflare edge error="TLS handshake with edge error: EOF""#
            ),
            .connected
        )
    }

    func testSuccessfulRegistrationAfterFailuresClearsUnreachable() {
        var interpreter = EdgeLogInterpreter()
        _ = interpreter.consume("INF precheck complete hard_fail=true run_id=abc")
        XCTAssertEqual(interpreter.consume("INF Registered tunnel connection connIndex=0 location=sjc"), .connected)
        XCTAssertNil(interpreter.diagnostic)
    }

    func testInitialProtocolHTTP2LogAloneMakesHandshakeFatal() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(interpreter.consume("INF Initial protocol http2"), .connecting)
        XCTAssertEqual(
            interpreter.consume(
                #"ERR Unable to establish connection with Cloudflare edge error="TLS handshake with edge error: EOF""#
            ),
            .unreachable
        )
        XCTAssertTrue(interpreter.suggestsQUICProtocol)
    }

    func testForcedHTTP2HandshakeFailureSuggestsQUIC() {
        var interpreter = EdgeLogInterpreter()
        interpreter.noteForcedHTTP2(true)
        XCTAssertEqual(
            interpreter.consume("2026-09-04T02:00:34Z INF Initial protocol http2"),
            .connecting
        )
        XCTAssertEqual(
            interpreter.consume(
                #"ERR Unable to establish connection with Cloudflare edge error="TLS handshake with edge error: EOF" connIndex=0 event=0 ip=198.41.200.53"#
            ),
            .unreachable
        )
        XCTAssertTrue(interpreter.suggestsQUICProtocol)
        XCTAssertFalse(interpreter.suggestsHTTP2Protocol)
        XCTAssertTrue(interpreter.diagnostic?.contains("QUIC") == true)
        XCTAssertTrue(interpreter.diagnostic?.contains("命令行") == true)
    }

    func testHTTP2HandshakeLogWithoutForcedProtocolDoesNotMarkUnreachable() {
        var interpreter = EdgeLogInterpreter()
        XCTAssertEqual(
            interpreter.consume(
                #"ERR Unable to establish connection with Cloudflare edge error="TLS handshake with edge error: EOF""#
            ),
            .connecting
        )
        XCTAssertTrue(interpreter.suggestsQUICProtocol)
        XCTAssertTrue(interpreter.diagnostic?.contains("仍在用 QUIC") == true)
        XCTAssertEqual(
            interpreter.consume("INF Registered tunnel connection connIndex=0 protocol=quic location=hkg10"),
            .connected
        )
        XCTAssertNil(interpreter.diagnostic)
        XCTAssertFalse(interpreter.suggestsQUICProtocol)
    }

    func testCLIQUICSuccessWithBlockedHTTP2PrecheckIsConnected() {
        var interpreter = EdgeLogInterpreter()
        let lines = [
            "2026-09-04T02:00:34Z INF Starting tunnel",
            "2026-09-04T02:00:34Z INF Initial protocol quic",
            "2026-09-04T02:00:35Z INF Registered tunnel connection connIndex=0 event=0 ip=198.41.200.113 location=hkg10 protocol=quic",
            "2026-09-04T02:00:35Z INF Registered tunnel connection connIndex=1 event=0 ip=198.41.192.7 location=hkg01 protocol=quic",
            "2026-09-04T02:00:36Z INF Registered tunnel connection connIndex=2 event=0 ip=198.41.192.77 location=hkg01 protocol=quic",
            "2026-09-04T02:00:38Z INF Registered tunnel connection connIndex=3 event=0 ip=198.41.200.53 location=hkg10 protocol=quic",
            "2026-09-04T02:00:44Z INF |  TCP Connectivity  region1.v2.argotunnel.com  FAIL    HTTP/2 connection is blocked or unreachable  |",
            #"2026-09-04T02:00:44Z INF precheck component="TCP Connectivity" details="HTTP/2 connection is blocked or unreachable" status=fail target=region1.v2.argotunnel.com"#,
            "2026-09-04T02:00:44Z INF precheck complete hard_fail=false suggested_protocol=quic"
        ]

        var last: EdgeConnectionState = .unknown
        for line in lines {
            last = interpreter.consume(line)
        }
        XCTAssertEqual(last, .connected)
        XCTAssertNil(interpreter.diagnostic)
        XCTAssertFalse(interpreter.suggestsHTTP2Protocol)
        XCTAssertFalse(interpreter.suggestsQUICProtocol)
    }

    func testResetClearsForcedHTTP2AndQUICSuggestion() {
        var interpreter = EdgeLogInterpreter()
        interpreter.noteForcedHTTP2(true)
        _ = interpreter.consume(
            #"ERR Unable to establish connection with Cloudflare edge error="TLS handshake with edge error: EOF""#
        )
        XCTAssertTrue(interpreter.suggestsQUICProtocol)
        interpreter.reset()
        XCTAssertEqual(interpreter.consume("starting cloudflared"), .connecting)
        XCTAssertFalse(interpreter.suggestsQUICProtocol)
        XCTAssertNil(interpreter.diagnostic)
    }
}
