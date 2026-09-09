#if !APP_STORE

import Synchronization
import Testing
@testable import Semper

@Suite("Display controls")
struct DisplayControlServiceTests {
    private enum TestError: Error {
        case failed
    }

    @Test("Overlapping display probes share one operation")
    func overlappingProbesShareWork() async {
        let callCount = Mutex(0)
        let probe = DisplayProbeSingleFlight<Int> {
            callCount.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(50))
            return 42
        }

        async let first = probe.value()
        async let second = probe.value()
        let values = await (first, second)

        #expect(values.0 == 42)
        #expect(values.1 == 42)
        #expect(callCount.withLock { $0 } == 1)
    }

    @Test("Stable identity requires nonzero EDID components")
    func stableIdentityValidation() {
        #expect(DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3) != nil)
        #expect(DisplayIdentity(vendorID: 0, productID: 2, serialNumber: 3) == nil)
        #expect(DisplayIdentity(vendorID: 1, productID: 0, serialNumber: 3) == nil)
        #expect(DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 0) == nil)
    }

    @Test("Missing and duplicate EDID identities are not stable")
    func duplicateIdentityValidation() {
        let first = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3)!
        let second = DisplayIdentity(vendorID: 1, productID: 2, serialNumber: 4)!
        let unique = DisplayIdentityResolver.unique([first, first, second, nil])

        #expect(unique == [second])
    }

    @Test("Scene identifiers round trip the stable EDID identity")
    func sceneIdentifierRoundTrip() {
        let identity = DisplayIdentity(vendorID: 101, productID: 202, serialNumber: 303)!

        #expect(identity.rawValue == "101:202:303")
        #expect(DisplayIdentity(rawValue: identity.rawValue) == identity)
        #expect(DisplayIdentity(rawValue: "101:202") == nil)
        #expect(DisplayIdentity(rawValue: "0:202:303") == nil)
    }

    @Test("Readings require a reported range and current value within it")
    func readingValidation() {
        #expect(DisplayFeatureReading(current: 0, maximum: 0) == nil)
        #expect(DisplayFeatureReading(current: 101, maximum: 100) == nil)
        #expect(DisplayFeatureReading(current: 25, maximum: 100)?.normalized == 0.25)
    }

    @Test("Normalized values map through the display reported maximum")
    func normalizedMapping() {
        #expect(DisplayFeatureIO.rawValue(normalized: 0.5, maximum: 254) == 127)
        #expect(DisplayFeatureIO.rawValue(normalized: -1, maximum: 80) == nil)
        #expect(DisplayFeatureIO.rawValue(normalized: 2, maximum: 80) == nil)
        #expect(DisplayFeatureIO.rawValue(normalized: .nan, maximum: 80) == nil)
    }

    @Test("Non-finite targets are rejected without a hardware write")
    func invalidTargetIsRejected() {
        var writeCount = 0
        let result = DisplayFeatureIO.set(
            normalized: .infinity,
            maximum: 100,
            write: { _ in writeCount += 1 },
            read: { (0, 100) }
        )

        #expect(result == .invalidTarget)
        #expect(writeCount == 0)
    }

    @Test("Out of range targets are rejected without a hardware write")
    func outOfRangeTargetIsRejected() {
        var writeCount = 0
        let result = DisplayFeatureIO.set(
            normalized: -0.01,
            maximum: 100,
            write: { _ in writeCount += 1 },
            read: { (0, 100) }
        )

        #expect(result == .invalidTarget)
        #expect(writeCount == 0)
    }

    @Test("Feature discovery reads the current value")
    func probeReadsCurrentValue() {
        let result = DisplayFeatureIO.probe(read: { (35, 70) })

        #expect(result == DisplayFeatureReading(current: 35, maximum: 70))
    }

    @Test("Feature discovery leaves a physical change made after its read untouched")
    func probeDoesNotOverwritePhysicalChange() {
        var liveValue: UInt16 = 40
        let result = DisplayFeatureIO.probe {
            let reportedValue = liveValue
            liveValue = 65
            return (reportedValue, 80)
        }

        #expect(result == DisplayFeatureReading(current: 40, maximum: 80))
        #expect(liveValue == 65)
    }

    @Test("Brightness failure does not hide valid contrast support")
    func featuresAreProbedIndependently() {
        let result = DisplayFeatureIO.probeAll(
            read: { feature in
                switch feature {
                case .brightness:
                    throw TestError.failed
                case .contrast:
                    return (25, 50)
                }
            }
        )

        #expect(result.readings[.brightness] == nil)
        #expect(result.readings[.contrast] == DisplayFeatureReading(current: 25, maximum: 50))
        #expect(result.sceneEligibleFeatures == [.contrast])
    }

    @Test("Set succeeds only after an exact matching readback")
    func setRequiresMatchingReadback() {
        var value: UInt16 = 0
        let result = DisplayFeatureIO.set(
            normalized: 0.25,
            maximum: 80,
            write: { value = $0 },
            read: { (value, 80) }
        )

        #expect(result == .applied(DisplayFeatureReading(current: 20, maximum: 80)!))
    }

    @Test("Set reports a valid mismatched readback as failure")
    func setRejectsMismatchedReadback() {
        let result = DisplayFeatureIO.set(
            normalized: 0.5,
            maximum: 100,
            write: { _ in },
            read: { (49, 100) }
        )

        #expect(result == .failed(
            expected: 50,
            readback: DisplayFeatureReading(current: 49, maximum: 100)
        ))
    }

    @Test("A failed display write restores the confirmed slider value")
    func failedWriteRestoresSliderValue() {
        let result = DisplayWriteResult.failed(
            expected: 80,
            readback: DisplayFeatureReading(current: 40, maximum: 100)
        )

        let value = DisplayFeatureIO.resolvedSliderValue(
            requested: 0.8,
            result: result,
            confirmed: 0.4
        )

        #expect(value == 0.4)
    }

    @Test("Set rejects a readback from a changed reported range")
    func setRejectsChangedRange() {
        let result = DisplayFeatureIO.set(
            normalized: 0.5,
            maximum: 100,
            write: { _ in },
            read: { (50, 80) }
        )

        #expect(result == .failed(
            expected: 50,
            readback: DisplayFeatureReading(current: 50, maximum: 80)
        ))
    }

    @Test("Brightness and contrast use their standard VCP codes")
    func featureCodes() {
        #expect(DisplayFeature.brightness.rawValue == 0x10)
        #expect(DisplayFeature.contrast.rawValue == 0x12)
    }
}

#endif
