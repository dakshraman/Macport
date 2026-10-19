import XCTest
import MacportKit

/// Round-trips for every message the control protocol can carry.
///
/// These are wire-format tests, so they assert on the JSON as well as on the
/// decoded values: a rename of a coding key is a protocol break whether or not
/// both sides of a test still compile.
final class ControlProtocolTests: XCTestCase {
    private let requestID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - Requests

    private func roundTrip(_ request: VMControlRequest) throws -> VMControlRequest {
        let line = try request.encodedLine()
        return try VMControlRequest.decodeLine(line)
    }

    func testEveryCommandRoundTrips() throws {
        let commands: [VMControlCommand] = [
            .status,
            .pause,
            .resume,
            .stop(graceful: true),
            .stop(graceful: false),
            .snapshots,
            .takeSnapshot(name: "Before update"),
            .restoreSnapshot(id: "before-update"),
            .deleteSnapshot(id: "before-update"),
            .shutdownHost,
            .unknown("frobnicate"),
        ]

        for command in commands {
            let request = VMControlRequest(id: requestID, command: command)
            XCTAssertEqual(try roundTrip(request), request, "\(command.name) did not round-trip")
        }
    }

    func testRequestCarriesVersionAndEnvelopeKeys() throws {
        let request = VMControlRequest(id: requestID, command: .status)
        let json = try XCTUnwrap(
            String(data: try request.encodedLine(), encoding: .utf8)
        )
        XCTAssertTrue(json.contains("\"v\":1"), json)
        XCTAssertTrue(json.contains("\"id\":\"\(requestID.uuidString)\""), json)
        XCTAssertTrue(json.contains("\"command\":\"status\""), json)
    }

    func testSnapshotCommandsUseSnapshotIDBecauseTheEnvelopeOwnsID() throws {
        let restore = try XCTUnwrap(
            String(
                data: try VMControlRequest(command: .restoreSnapshot(id: "abc")).encodedLine(),
                encoding: .utf8
            )
        )
        XCTAssertTrue(restore.contains("\"snapshotID\":\"abc\""), restore)

        let delete = try XCTUnwrap(
            String(
                data: try VMControlRequest(command: .deleteSnapshot(id: "abc")).encodedLine(),
                encoding: .utf8
            )
        )
        XCTAssertTrue(delete.contains("\"snapshotID\":\"abc\""), delete)
    }

    func testStopEncodesItsGracefulFlag() throws {
        let json = try XCTUnwrap(
            String(data: try VMControlRequest(command: .stop(graceful: false)).encodedLine(), encoding: .utf8)
        )
        XCTAssertTrue(json.contains("\"graceful\":false"), json)
    }

    func testUnknownCommandDecodesRatherThanFailing() throws {
        let line = Data(
            #"{"v":1,"id":"\#(requestID.uuidString)","command":"frobnicate"}"#.utf8
        )
        let request = try VMControlRequest.decodeLine(line)
        XCTAssertEqual(request.command, .unknown("frobnicate"))

        // And an unknown command survives a re-encode, so the host can answer
        // the very request it did not understand.
        let reencoded = try VMControlRequest.decodeLine(try request.encodedLine())
        XCTAssertEqual(reencoded.command, .unknown("frobnicate"))
    }

    func testAliasesDecodeToTheNamedCommands() throws {
        let snapshot = Data(
            #"{"v":1,"id":"\#(requestID.uuidString)","command":"snapshot","name":"x"}"#.utf8
        )
        XCTAssertEqual(
            try VMControlRequest.decodeLine(snapshot).command,
            .takeSnapshot(name: "x")
        )

        let restore = Data(
            #"{"v":1,"id":"\#(requestID.uuidString)","command":"restore","snapshotID":"x"}"#.utf8
        )
        XCTAssertEqual(
            try VMControlRequest.decodeLine(restore).command,
            .restoreSnapshot(id: "x")
        )
    }

    func testUnsupportedVersionIsRefused() {
        let line = Data(#"{"v":99,"id":"\#(requestID.uuidString)","command":"status"}"#.utf8)
        XCTAssertThrowsError(try VMControlRequest.decodeLine(line)) { error in
            XCTAssertEqual(error as? VMControlError, .unsupportedVersion(99))
        }
    }

    func testMalformedLineIsRefused() {
        XCTAssertThrowsError(try VMControlRequest.decodeLine(Data("not json".utf8))) { error in
            guard case .malformedMessage = error as? VMControlError else {
                return XCTFail("Expected malformedMessage, got \(error)")
            }
        }
    }

    // MARK: - Responses

    private func roundTrip(_ response: VMControlResponse) throws -> VMControlResponse {
        try VMControlResponse.decodeLine(try response.encodedLine())
    }

    func testSuccessAndFailureEnvelopesRoundTrip() throws {
        let success = VMControlResponse.success(id: requestID)
        XCTAssertEqual(try roundTrip(success), success)

        let failure = VMControlResponse.failure(id: requestID, error: "boo")
        XCTAssertEqual(try roundTrip(failure), failure)

        let json = try XCTUnwrap(
            String(data: try failure.encodedLine(), encoding: .utf8)
        )
        XCTAssertTrue(json.contains("\"ok\":false"), json)
        XCTAssertTrue(json.contains("\"v\":1"), json)
    }

    func testStatusPayloadRoundTrips() throws {
        let status = VMControlStatus(
            state: .paused,
            pid: 4321,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            engineIdentifier: QEMUEngine.identifier,
            paused: true
        )
        let response = VMControlResponse.success(id: requestID, payload: .status(status))
        let decoded = try roundTrip(response)

        guard case .status(let decodedStatus)? = decoded.payload else {
            return XCTFail("Expected a status payload")
        }
        XCTAssertEqual(decodedStatus.state, .paused)
        XCTAssertEqual(decodedStatus.pid, 4321)
        XCTAssertEqual(decodedStatus.engineIdentifier, "qemu")
        XCTAssertTrue(decodedStatus.paused)
        XCTAssertEqual(decodedStatus.startedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func testSnapshotListPayloadRoundTrips() throws {
        let snapshots = [
            VMSnapshot(
                id: "before-update",
                name: "Before update",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                includesMemory: true
            ),
            VMSnapshot(
                id: "clean",
                name: "clean",
                createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                includesMemory: false
            ),
        ]
        let response = VMControlResponse.success(id: requestID, payload: .snapshots(snapshots))
        let decoded = try roundTrip(response)

        guard case .snapshots(let decodedSnapshots)? = decoded.payload else {
            return XCTFail("Expected a snapshot list payload")
        }
        XCTAssertEqual(decodedSnapshots.count, 2)
        XCTAssertEqual(decodedSnapshots.map(\.id), ["before-update", "clean"])
        XCTAssertEqual(decodedSnapshots.map(\.includesMemory), [true, false])
        XCTAssertEqual(
            decodedSnapshots[0].createdAt.timeIntervalSince1970,
            1_700_000_000,
            accuracy: 1
        )
    }

    func testSingleSnapshotPayloadRoundTrips() throws {
        let snapshot = VMSnapshot(id: "tag", name: "tag", includesMemory: true)
        let response = VMControlResponse.success(id: requestID, payload: .snapshot(snapshot))
        let decoded = try roundTrip(response)

        guard case .snapshot(let decodedSnapshot)? = decoded.payload else {
            return XCTFail("Expected a snapshot payload")
        }
        XCTAssertEqual(decodedSnapshot.id, "tag")
    }

    func testResponseIDIsPreserved() throws {
        let response = VMControlResponse.success(id: requestID, payload: nil)
        XCTAssertEqual(try roundTrip(response).id, requestID)
    }
}
