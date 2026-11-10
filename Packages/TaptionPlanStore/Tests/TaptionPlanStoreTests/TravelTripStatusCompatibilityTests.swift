import Foundation
import Testing
@testable import TaptionPlanStore

/// 여행 일정 상태(TRP1110A09). 상태가 없는 예전 기록·백업은 그대로 읽고, 계획(nil)은 키를 쓰지 않아 바이트가 같다.
struct TravelTripStatusCompatibilityTests {
    static let oldItem = #"{"end":1796003600,"endOffsetSeconds":25200,"itemID":"i1","kind":"sight","start":1796000000,"startOffsetSeconds":25200,"title":"왓 아룬","tripID":"t1"}"#
    static let oldStop = #"{"day":1796000000,"id":"6E3B1A52-0C33-4C1D-9F11-2B0E7A9D4A10","itemID":"i1","latitude":13.74,"longitude":100.49,"order":0,"title":"왓 아룬","tripID":"t1"}"#

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    @Test func oldRecordsDecodeAndReencodeUnchanged() throws {
        let item = try Self.decoder().decode(TravelTripItem.self, from: Data(Self.oldItem.utf8))
        let stop = try Self.decoder().decode(TravelPlanStop.self, from: Data(Self.oldStop.utf8))
        #expect(item.status == nil)
        #expect(stop.status == nil)
        #expect(String(decoding: try Self.encoder().encode(item), as: UTF8.self) == Self.oldItem)
        #expect(String(decoding: try Self.encoder().encode(stop), as: UTF8.self) == Self.oldStop)
    }

    @Test func onlyStoredStatusWritesKey() throws {
        var item = try Self.decoder().decode(TravelTripItem.self, from: Data(Self.oldItem.utf8))
        item.status = "booked"
        let json = String(decoding: try Self.encoder().encode(item), as: UTF8.self)
        #expect(json.contains(#""status":"booked""#))
        #expect(try Self.decoder().decode(TravelTripItem.self, from: Data(json.utf8)) == item)
    }
}
