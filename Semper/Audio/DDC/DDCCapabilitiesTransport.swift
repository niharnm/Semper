#if !APP_STORE

import Dispatch
import Foundation

enum DDCCapabilitiesResponseFailure: Error, Equatable, Sendable {
    case allZeroResponse
    case nullResponse
    case responseTooShort(actual: Int)
    case unexpectedSource(UInt8)
    case invalidLengthByte(UInt8)
    case invalidPayloadLength(Int)
    case truncatedResponse(expected: Int, actual: Int)
    case unexpectedOpcode(UInt8)
    case unexpectedOffset(expected: UInt16, actual: UInt16)
    case checksumMismatch
}

enum DDCCapabilitiesAttemptFailure: Equatable, Sendable {
    case transaction
    case response(DDCCapabilitiesResponseFailure)
}

enum DDCCapabilitiesError: Error, Equatable, Sendable {
    case cancelled
    case deadlineExceeded
    case responseLimitExceeded
    case retryLimitExceeded(offset: UInt16, lastFailure: DDCCapabilitiesAttemptFailure)
    case capabilityDataTooLarge
    case invalidTextEncoding
}

enum DDCCapabilitiesPacket {
    static let maximumPayloadBytes = 32

    static func request(offset: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            0x83,
            0xF3,
            UInt8(truncatingIfNeeded: offset >> 8),
            UInt8(truncatingIfNeeded: offset),
        ]
        packet.append(packet.reduce(0x6E ^ 0x51, ^))
        return packet
    }

    static func responsePayload(
        from reply: [UInt8],
        expectedOffset: UInt16
    ) throws -> [UInt8] {
        guard reply.contains(where: { $0 != 0 }) else {
            throw DDCCapabilitiesResponseFailure.allZeroResponse
        }
        guard reply.count >= 2 else {
            throw DDCCapabilitiesResponseFailure.responseTooShort(actual: reply.count)
        }
        if reply[0] == 0x6E, reply[1] == 0x80 {
            throw DDCCapabilitiesResponseFailure.nullResponse
        }
        guard reply[0] == 0x6E else {
            throw DDCCapabilitiesResponseFailure.unexpectedSource(reply[0])
        }

        let lengthByte = reply[1]
        guard lengthByte & 0x80 != 0 else {
            throw DDCCapabilitiesResponseFailure.invalidLengthByte(lengthByte)
        }
        let bodyLength = Int(lengthByte & 0x7F)
        guard (3...35).contains(bodyLength) else {
            throw DDCCapabilitiesResponseFailure.invalidPayloadLength(bodyLength)
        }

        let envelopeCount = bodyLength + 3
        guard reply.count >= envelopeCount else {
            throw DDCCapabilitiesResponseFailure.truncatedResponse(
                expected: envelopeCount,
                actual: reply.count
            )
        }

        let envelope = reply.prefix(envelopeCount)
        guard envelope.reduce(UInt8(0x50), ^) == 0 else {
            throw DDCCapabilitiesResponseFailure.checksumMismatch
        }
        guard envelope[2] == 0xE3 else {
            throw DDCCapabilitiesResponseFailure.unexpectedOpcode(envelope[2])
        }

        let actualOffset = (UInt16(envelope[3]) << 8) | UInt16(envelope[4])
        guard actualOffset == expectedOffset else {
            throw DDCCapabilitiesResponseFailure.unexpectedOffset(
                expected: expectedOffset,
                actual: actualOffset
            )
        }

        return Array(envelope[5..<(envelopeCount - 1)])
    }
}

struct DDCCapabilitiesTransport {
    struct Limits: Equatable, Sendable {
        let maximumBytes: Int
        let maximumResponses: Int
        let maximumAttemptsPerOffset: Int
        let minimumRequestIntervalNanoseconds: UInt64
        let deadlineNanoseconds: UInt64

        static let standard = Limits(
            maximumBytes: 16_384,
            maximumResponses: 3_072,
            maximumAttemptsPerOffset: 5,
            minimumRequestIntervalNanoseconds: 50_000_000,
            deadlineNanoseconds: 60_000_000_000
        )
    }

    typealias Transaction = ([UInt8]) throws -> [UInt8]
    typealias CancellationCheck = () -> Bool
    typealias MonotonicTime = () -> UInt64
    typealias Delay = (UInt64) -> Void

    private let limits: Limits
    private let transaction: Transaction
    private let isCancelled: CancellationCheck
    private let monotonicTime: MonotonicTime
    private let delay: Delay

    init(
        limits: Limits = .standard,
        transaction: @escaping Transaction,
        isCancelled: @escaping CancellationCheck = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        },
        monotonicTime: @escaping MonotonicTime = { DispatchTime.now().uptimeNanoseconds },
        delay: @escaping Delay = { nanoseconds in
            Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
        }
    ) {
        precondition(limits.maximumBytes > 0)
        precondition(limits.maximumBytes <= Int(UInt16.max))
        precondition(limits.maximumResponses > 0)
        precondition(limits.maximumAttemptsPerOffset > 0)
        precondition(limits.deadlineNanoseconds > 0)
        self.limits = limits
        self.transaction = transaction
        self.isCancelled = isCancelled
        self.monotonicTime = monotonicTime
        self.delay = delay
    }

    func read() throws -> [UInt8] {
        let startedAt = monotonicTime()
        let (deadline, overflow) = startedAt.addingReportingOverflow(limits.deadlineNanoseconds)
        let effectiveDeadline = overflow ? UInt64.max : deadline
        var previousRequestAt: UInt64?
        var responseCount = 0
        var output: [UInt8] = []

        while true {
            let offset = UInt16(output.count)
            var lastFailure = DDCCapabilitiesAttemptFailure.transaction

            for attempt in 1...limits.maximumAttemptsPerOffset {
                try checkProgress(deadline: effectiveDeadline)
                if let previousRequestAt {
                    let now = monotonicTime()
                    let elapsed = now >= previousRequestAt ? now - previousRequestAt : 0
                    if elapsed < limits.minimumRequestIntervalNanoseconds {
                        delay(limits.minimumRequestIntervalNanoseconds - elapsed)
                        try checkProgress(deadline: effectiveDeadline)
                    }
                }

                guard responseCount < limits.maximumResponses else {
                    throw DDCCapabilitiesError.responseLimitExceeded
                }
                responseCount += 1
                previousRequestAt = monotonicTime()

                let reply: [UInt8]
                do {
                    reply = try transaction(DDCCapabilitiesPacket.request(offset: offset))
                } catch is CancellationError {
                    throw DDCCapabilitiesError.cancelled
                } catch {
                    lastFailure = .transaction
                    if attempt == limits.maximumAttemptsPerOffset {
                        throw DDCCapabilitiesError.retryLimitExceeded(
                            offset: offset,
                            lastFailure: lastFailure
                        )
                    }
                    continue
                }

                try checkProgress(deadline: effectiveDeadline)

                do {
                    let payload = try DDCCapabilitiesPacket.responsePayload(
                        from: reply,
                        expectedOffset: offset
                    )
                    guard !payload.isEmpty else {
                        try checkProgress(deadline: effectiveDeadline)
                        return output
                    }
                    guard output.count <= limits.maximumBytes - payload.count else {
                        throw DDCCapabilitiesError.capabilityDataTooLarge
                    }
                    output.append(contentsOf: payload)
                    break
                } catch let error as DDCCapabilitiesResponseFailure {
                    lastFailure = .response(error)
                    if attempt == limits.maximumAttemptsPerOffset {
                        throw DDCCapabilitiesError.retryLimitExceeded(
                            offset: offset,
                            lastFailure: lastFailure
                        )
                    }
                }
            }
        }
    }

    private func checkProgress(deadline: UInt64) throws {
        guard !isCancelled() else { throw DDCCapabilitiesError.cancelled }
        guard monotonicTime() < deadline else { throw DDCCapabilitiesError.deadlineExceeded }
    }
}

#endif
