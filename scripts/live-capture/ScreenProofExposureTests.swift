import Foundation

@main
struct ScreenProofExposureTests {
    static func check(_ condition: Bool, _ message: String = "Unexpected exposure duration") {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        var exposure = ScreenProofExposure()
        exposure.sample(at: 100, eligible: true)
        check(exposure.seconds == 0, "A single active sample is not sustained exposure")
        for second in 101...120 {
            exposure.sample(at: TimeInterval(second), eligible: true)
        }
        check(exposure.seconds == 20, "Twenty consecutive seconds must be observable")

        exposure.sample(at: 121, eligible: false)
        check(exposure.seconds == 0, "Background, hidden or unfocused state resets exposure")
        exposure.sample(at: 130, eligible: true)
        check(exposure.seconds == 0, "Time spent elsewhere must not count")
        exposure.sample(at: 131, eligible: true)
        check(exposure.seconds == 1)
        exposure.sample(at: 150, eligible: true)
        check(exposure.seconds == 0, "An unobserved sampling gap must reset exposure")
        exposure.sample(at: 151, eligible: true)
        check(exposure.seconds == 1)
        exposure.sample(at: 140, eligible: true)
        check(exposure.seconds == 0, "A clock regression must not add time")
        exposure.sample(at: 140, eligible: true)
        check(exposure.seconds == 0, "Duplicate samples must not add time")
        exposure.sample(at: 142, eligible: true)
        check(exposure.seconds == 2, "The bounded sampling tolerance is two seconds")
        exposure.sample(at: .infinity, eligible: true)
        check(exposure.seconds == 0, "Invalid time fails closed")
        exposure.sample(at: 144, eligible: true)
        check(exposure.seconds == 0, "Invalid time must not remain the comparison baseline")
        print("PASS: screen-proof exposure requires continuous eligible observations")
    }
}
