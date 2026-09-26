import Foundation

/// A reset is a separate authority generation, not a fabricated sender sequence.
struct LoopdyPresentationRecovery {
    private(set) var pending: UUID?
    mutating func accept(_ data: Data, deviceID: String, epoch: Int) throws {
        guard data.count <= 4_096,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["version","type","deviceId","authorizationEpoch","reason"],
              let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
              value["type"] as? String == "presentation.reset", value["deviceId"] as? String == deviceID,
              let number = value["authorizationEpoch"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue == epoch,
              let reason = value["reason"] as? String, ["reconnect","gap","overflow"].contains(reason) else {
            throw LoopdyLinkSocketError.invalidMessage
        }
        pending = UUID()
    }
    mutating func complete(_ checkpoint: UUID?) {
        if pending == checkpoint { pending = nil }
    }
}
