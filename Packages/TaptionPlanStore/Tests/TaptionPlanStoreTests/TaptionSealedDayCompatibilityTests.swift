import Foundation
import TaptionPlanCore
import Testing
@testable import TaptionPlanStore

/// 확정한 하루(sealed_days 표의 payload)의 저장 바이트 계약.
/// 기대값은 앱 타깃에 있던 옮기기 전 선언으로 만든 결과다(`build/validation/RFA1102A01/phase2/golden`).
struct TaptionSealedDayCompatibilityTests {
    static let start = Date(timeIntervalSince1970: 1_762_560_000)

    static var sample: TaptionSealedDay {
        TaptionSealedDay(
            dayStart: start, sealedAt: start.addingTimeInterval(90_000), sourceFingerprint: "fp1",
            categorySeconds: ["movement": 3_600], metrics: ["distance": 1_234.5], stepCount: 4_200,
            distanceMeters: 3_000.25, workSeconds: 28_800, readingCount: 1_440,
            firstReadingAt: start.addingTimeInterval(60), lastReadingAt: start.addingTimeInterval(86_000),
            polyline: [375_000_000, 1_272_500_000, 10, -20],
            weather: TaptionSealedWeather(
                observedAt: start.addingTimeInterval(3_600), symbolName: "sun.max", condition: "맑음",
                temperatureCelsius: 12.5, placeName: "서울"
            ),
            memoCount: 2, actualCount: 30, travelCount: 4, placeCount: 5
        )
    }

    @Test func storedEnvelopeBytesAreUnchanged() throws {
        let stored = Data(base64Encoded: "VFAtQ0FOT04AAAAAAAAAAoIzODQwMmU3YzBmYWZlMWYxZGVmNjE5NmM4NGYwNTdlMDc4YTMzZWNmODYwNzQ1ZjkwNzEyNmVmNzgwODJlMjQ1YnBsaXN0MDDfEBIBAgMEBQYHCAkKCwwNDg8QERITFBUWFxodHh8gISIjKDM0NTZXdmVyc2lvblhkYXlTdGFydFhzZWFsZWRBdF8QEXNvdXJjZUZpbmdlcnByaW50XxAPY2F0ZWdvcnlTZWNvbmRzV21ldHJpY3NZc3RlcENvdW50XmRpc3RhbmNlTWV0ZXJzW3dvcmtTZWNvbmRzXHJlYWRpbmdDb3VudF5maXJzdFJlYWRpbmdBdF1sYXN0UmVhZGluZ0F0WHBvbHlsaW5lV3dlYXRoZXJZbWVtb0NvdW50W2FjdHVhbENvdW50W3RyYXZlbENvdW50WnBsYWNlQ291bnQQATNBx19fwAAAADNBx2APiAAAAFNmcDHRGBlYbW92ZW1lbnQRDhDRGxxYZGlzdGFuY2UjQJNKAAAAAAAREGgjQKdwgAAAAAARcIARBaAzQcdfX94AAAAzQcdgB7gAAACkJCUmJxIWWgvAEkvYzyAQChP/////////7NUpKissLS4vMDEyWm9ic2VydmVkQXRac3ltYm9sTmFtZVljb25kaXRpb25fEBJ0ZW1wZXJhdHVyZUNlbHNpdXNZcGxhY2VOYW1lM0HHX2bIAAAAV3N1bi5tYXhiudHHTCNAKQAAAAAAAGLBHMa4EAIQHhAEEAUACAAvADcAQABJAF0AbwB3AIEAkACcAKkAuADGAM8A1wDhAO0A+QEEAQYBDwEYARwBHwEoASsBLgE3AUABQwFMAU8BUgFbAWQBaQFuAXMBdQF+AYkBlAGfAakBvgHIAdEB2QHeAecB7AHuAfAB8gAAAAAAAAIBAAAAAAAAADcAAAAAAAAAAAAAAAAAAAH0")!
        let payload = try TaptionPlanCanonicalStorage.encodedPayload(from: stored)
        #expect(try TaptionPlanCanonicalStorage.decode(TaptionSealedDay.self, from: payload) == Self.sample)
        let rewritten = TaptionPlanCanonicalStorage.envelope(for: try TaptionPlanCanonicalStorage.encode(Self.sample, compress: true))
        #expect(rewritten == stored)
    }

    @Test func jsonKeysAreUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(Self.sample), as: UTF8.self)
        #expect(json == #"{"actualCount":30,"categorySeconds":{"movement":3600},"dayStart":1762560000,"distanceMeters":3000.25,"firstReadingAt":1762560060,"lastReadingAt":1762646000,"memoCount":2,"metrics":{"distance":1234.5},"placeCount":5,"polyline":[375000000,1272500000,10,-20],"readingCount":1440,"sealedAt":1762650000,"sourceFingerprint":"fp1","stepCount":4200,"travelCount":4,"version":1,"weather":{"condition":"맑음","observedAt":1762563600,"placeName":"서울","symbolName":"sun.max","temperatureCelsius":12.5},"workSeconds":28800}"#)
    }
}
