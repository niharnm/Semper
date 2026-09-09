#if !APP_STORE

import Foundation
import Testing
@testable import Semper

@Suite("DDC capabilities packets")
struct DDCCapabilitiesPacketTests {
    @Test("Request encodes the offset and checksum")
    func requestPacket() {
        #expect(DDCCapabilitiesPacket.request(offset: 0x1234) == [0x83, 0xF3, 0x12, 0x34, 0x69])
    }

    @Test("Response accepts a maximum payload and ignores read-buffer padding")
    func maximumResponse() throws {
        let payload = Array(UInt8(0)..<UInt8(32))
        let reply = makeResponse(offset: 0x0102, payload: payload) + [0xA5, 0x5A]

        #expect(
            try DDCCapabilitiesPacket.responsePayload(from: reply, expectedOffset: 0x0102)
                == payload
        )
    }

    @Test("Response accepts the explicit zero-payload terminator")
    func terminalResponse() throws {
        #expect(
            try DDCCapabilitiesPacket.responsePayload(
                from: makeResponse(offset: 19, payload: []),
                expectedOffset: 19
            ).isEmpty
        )
    }

    @Test(
        "Malformed response is rejected",
        arguments: [
            MalformedCase(
                reply: [UInt8](repeating: 0, count: 38),
                expected: .allZeroResponse
            ),
            MalformedCase(
                reply: [0x6E, 0x80] + [UInt8](repeating: 0, count: 36),
                expected: .nullResponse
            ),
            MalformedCase(reply: [0x6E], expected: .responseTooShort(actual: 1)),
            MalformedCase(
                reply: makeResponse(offset: 0, payload: [], source: 0x50),
                expected: .unexpectedSource(0x50)
            ),
            MalformedCase(
                reply: makeResponse(offset: 0, payload: [], lengthByte: 0x03),
                expected: .invalidLengthByte(0x03)
            ),
            MalformedCase(
                reply: makeResponse(offset: 0, payload: [], lengthByte: 0x82),
                expected: .invalidPayloadLength(2)
            ),
            MalformedCase(
                reply: makeResponse(offset: 0, payload: []) + [0],
                mutate: { $0[1] = 0xA4 },
                expected: .invalidPayloadLength(36)
            ),
            MalformedCase(
                reply: Array(makeResponse(offset: 0, payload: [0x41]).dropLast()),
                expected: .truncatedResponse(expected: 7, actual: 6)
            ),
            MalformedCase(
                reply: makeResponse(offset: 0, payload: [], opcode: 0x02),
                expected: .unexpectedOpcode(0x02)
            ),
            MalformedCase(
                reply: makeResponse(offset: 9, payload: []),
                expectedOffset: 8,
                expected: .unexpectedOffset(expected: 8, actual: 9)
            ),
            MalformedCase(
                reply: makeResponse(offset: 0, payload: []),
                mutate: { $0[5] ^= 0x01 },
                expected: .checksumMismatch
            ),
        ]
    )
    func malformedResponse(testCase: MalformedCase) {
        var reply = testCase.reply
        testCase.mutate(&reply)

        #expect(throws: testCase.expected) {
            try DDCCapabilitiesPacket.responsePayload(
                from: reply,
                expectedOffset: testCase.expectedOffset
            )
        }
    }

    struct MalformedCase: CustomTestStringConvertible, Sendable {
        let reply: [UInt8]
        let expectedOffset: UInt16
        let mutate: @Sendable (inout [UInt8]) -> Void
        let expected: DDCCapabilitiesResponseFailure

        var testDescription: String { String(describing: expected) }

        init(
            reply: [UInt8],
            expectedOffset: UInt16 = 0,
            mutate: @escaping @Sendable (inout [UInt8]) -> Void = { _ in },
            expected: DDCCapabilitiesResponseFailure
        ) {
            self.reply = reply
            self.expectedOffset = expectedOffset
            self.mutate = mutate
            self.expected = expected
        }
    }
}

@Suite("DDC capabilities multipart transport")
struct DDCCapabilitiesTransportTests {
    @Test("Multipart read advances from accepted payloads and ends on an empty response")
    func multipartRead() throws {
        let recorder = RequestRecorder(
            replies: [
                makeResponse(offset: 0, payload: Array("cap".utf8)),
                makeResponse(offset: 3, payload: Array("s()".utf8)),
                makeResponse(offset: 6, payload: []),
            ]
        )

        let result = try makeTransport(transaction: recorder.transaction).read()

        #expect(String(decoding: result, as: UTF8.self) == "caps()")
        #expect(recorder.offsets == [0, 3, 6])
    }

    @Test("A closing parenthesis and NUL payload do not end assembly")
    func payloadContentIsNotTermination() throws {
        let recorder = RequestRecorder(
            replies: [
                makeResponse(offset: 0, payload: [0x29]),
                makeResponse(offset: 1, payload: [0x00]),
                makeResponse(offset: 2, payload: []),
            ]
        )

        let result = try makeTransport(transaction: recorder.transaction).read()

        #expect(result == [0x29, 0x00])
        #expect(recorder.offsets == [0, 1, 2])
    }

    @Test("Standard bounds admit a full sixteen-kibibyte advertisement")
    func maximumAdvertisement() throws {
        let payload = [UInt8](repeating: 0x41, count: 32)
        var replies = stride(from: 0, to: 16_384, by: 32).map {
            makeResponse(offset: UInt16($0), payload: payload)
        }
        replies.append(makeResponse(offset: 16_384, payload: []))
        let recorder = RequestRecorder(replies: replies)

        let result = try makeTransport(transaction: recorder.transaction).read()

        #expect(result.count == 16_384)
        #expect(recorder.offsets.count == 513)
        #expect(recorder.offsets.last == 16_384)
    }

    @Test("A rejected reply retries the same offset without appending twice")
    func retryKeepsOffset() throws {
        let recorder = RequestRecorder(
            replies: [
                makeResponse(offset: 0, payload: Array("abc".utf8)),
                makeResponse(offset: 4, payload: Array("wrong".utf8)),
                makeResponse(offset: 3, payload: Array("de".utf8)),
                makeResponse(offset: 5, payload: []),
            ]
        )

        let result = try makeTransport(transaction: recorder.transaction).read()

        #expect(String(decoding: result, as: UTF8.self) == "abcde")
        #expect(recorder.offsets == [0, 3, 3, 5])
    }

    @Test("Thrown transactions retry the same offset up to the configured limit")
    func transactionRetryLimit() {
        let recorder = RequestRecorder(replies: [])
        let transport = makeTransport(
            limits: limits(maximumAttemptsPerOffset: 2),
            transaction: recorder.transaction
        )

        #expect(
            throws: DDCCapabilitiesError.retryLimitExceeded(
                offset: 0,
                lastFailure: .transaction
            )
        ) {
            try transport.read()
        }
        #expect(recorder.offsets == [0, 0])
    }

    @Test("Invalid replies report the last failure at the configured retry limit")
    func responseRetryLimit() {
        let recorder = RequestRecorder(
            replies: [
                makeResponse(offset: 1, payload: []),
                makeResponse(offset: 1, payload: []),
            ]
        )
        let transport = makeTransport(
            limits: limits(maximumAttemptsPerOffset: 2),
            transaction: recorder.transaction
        )

        #expect(
            throws: DDCCapabilitiesError.retryLimitExceeded(
                offset: 0,
                lastFailure: .response(.unexpectedOffset(expected: 0, actual: 1))
            )
        ) {
            try transport.read()
        }
        #expect(recorder.offsets == [0, 0])
    }

    @Test("Requests start at least fifty milliseconds apart")
    func requestSpacing() throws {
        let clock = TestClock()
        let recorder = RequestRecorder(
            replies: [
                makeResponse(offset: 0, payload: [0x41]),
                makeResponse(offset: 1, payload: []),
            ],
            onRequest: { clock.requestTimes.append(clock.now) }
        )
        let transport = makeTransport(
            transaction: recorder.transaction,
            clock: clock
        )

        _ = try transport.read()

        #expect(clock.requestTimes == [0, 50_000_000])
        #expect(clock.delays == [50_000_000])
    }

    @Test("Cancellation before a transaction performs no I/O")
    func preTransactionCancellation() {
        let recorder = RequestRecorder(replies: [])
        let transport = makeTransport(
            transaction: recorder.transaction,
            isCancelled: { true }
        )

        #expect(throws: DDCCapabilitiesError.cancelled) {
            try transport.read()
        }
        #expect(recorder.offsets.isEmpty)
    }

    @Test("Cancellation after the spacing delay prevents the next transaction")
    func postDelayCancellation() {
        let clock = TestClock()
        var cancelled = false
        clock.onDelay = { cancelled = true }
        let recorder = RequestRecorder(
            replies: [makeResponse(offset: 0, payload: [0x41])]
        )
        let transport = makeTransport(
            transaction: recorder.transaction,
            isCancelled: { cancelled },
            clock: clock
        )

        #expect(throws: DDCCapabilitiesError.cancelled) {
            try transport.read()
        }
        #expect(recorder.offsets == [0])
    }

    @Test("Cancellation after a terminal transaction prevents publication")
    func prePublicationCancellation() {
        var cancelled = false
        let transport = makeTransport(
            transaction: { request in
                cancelled = true
                return makeResponse(offset: requestOffset(request), payload: [])
            },
            isCancelled: { cancelled }
        )

        #expect(throws: DDCCapabilitiesError.cancelled) {
            try transport.read()
        }
    }

    @Test("Deadline is checked after a native transaction returns")
    func deadlineAfterTransaction() {
        let clock = TestClock()
        let transport = makeTransport(
            limits: limits(deadlineNanoseconds: 10),
            transaction: { request in
                clock.now = 10
                return makeResponse(offset: requestOffset(request), payload: [])
            },
            clock: clock
        )

        #expect(throws: DDCCapabilitiesError.deadlineExceeded) {
            try transport.read()
        }
    }

    @Test("Response count bounds an unfinished advertisement")
    func responseLimit() {
        let recorder = RequestRecorder(
            replies: [makeResponse(offset: 0, payload: [0x41])]
        )
        let transport = makeTransport(
            limits: limits(maximumResponses: 1),
            transaction: recorder.transaction
        )

        #expect(throws: DDCCapabilitiesError.responseLimitExceeded) {
            try transport.read()
        }
        #expect(recorder.offsets == [0])
    }

    @Test("Capability bytes cannot exceed the configured bound")
    func byteLimit() {
        let recorder = RequestRecorder(
            replies: [makeResponse(offset: 0, payload: [0x41, 0x42])]
        )
        let transport = makeTransport(
            limits: limits(maximumBytes: 1),
            transaction: recorder.transaction
        )

        #expect(throws: DDCCapabilitiesError.capabilityDataTooLarge) {
            try transport.read()
        }
    }

    private func makeTransport(
        limits: DDCCapabilitiesTransport.Limits = .standard,
        transaction: @escaping DDCCapabilitiesTransport.Transaction,
        isCancelled: @escaping DDCCapabilitiesTransport.CancellationCheck = { false },
        clock: TestClock = TestClock()
    ) -> DDCCapabilitiesTransport {
        DDCCapabilitiesTransport(
            limits: limits,
            transaction: transaction,
            isCancelled: isCancelled,
            monotonicTime: { clock.now },
            delay: { nanoseconds in
                clock.delays.append(nanoseconds)
                clock.now += nanoseconds
                clock.onDelay?()
            }
        )
    }

    private func limits(
        maximumBytes: Int = 16_384,
        maximumResponses: Int = 20,
        maximumAttemptsPerOffset: Int = 5,
        minimumRequestIntervalNanoseconds: UInt64 = 50_000_000,
        deadlineNanoseconds: UInt64 = 60_000_000_000
    ) -> DDCCapabilitiesTransport.Limits {
        .init(
            maximumBytes: maximumBytes,
            maximumResponses: maximumResponses,
            maximumAttemptsPerOffset: maximumAttemptsPerOffset,
            minimumRequestIntervalNanoseconds: minimumRequestIntervalNanoseconds,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }
}

private final class RequestRecorder {
    private var replies: [[UInt8]]
    private let onRequest: () -> Void
    private(set) var offsets: [UInt16] = []

    init(replies: [[UInt8]], onRequest: @escaping () -> Void = {}) {
        self.replies = replies
        self.onRequest = onRequest
    }

    func transaction(_ request: [UInt8]) throws -> [UInt8] {
        offsets.append(requestOffset(request))
        onRequest()
        guard !replies.isEmpty else { throw TestTransactionError.failed }
        return replies.removeFirst()
    }
}

private final class TestClock {
    var now: UInt64 = 0
    var delays: [UInt64] = []
    var requestTimes: [UInt64] = []
    var onDelay: (() -> Void)?
}

private enum TestTransactionError: Error {
    case failed
}

private func requestOffset(_ request: [UInt8]) -> UInt16 {
    (UInt16(request[2]) << 8) | UInt16(request[3])
}

private func makeResponse(
    offset: UInt16,
    payload: [UInt8],
    source: UInt8 = 0x6E,
    opcode: UInt8 = 0xE3,
    lengthByte: UInt8? = nil
) -> [UInt8] {
    precondition(payload.count <= DDCCapabilitiesPacket.maximumPayloadBytes)
    var response: [UInt8] = [
        source,
        lengthByte ?? (0x80 | UInt8(payload.count + 3)),
        opcode,
        UInt8(truncatingIfNeeded: offset >> 8),
        UInt8(truncatingIfNeeded: offset),
    ]
    response.append(contentsOf: payload)
    response.append(response.reduce(0x50, ^))
    return response
}

#endif
