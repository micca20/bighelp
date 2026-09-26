import SwiftUI

struct LoopdySessionContentReader {
    let load: @MainActor (String, String) async throws -> LoopdyJSONValue
}

private struct LoopdySessionContentReaderKey: EnvironmentKey {
    static let defaultValue: LoopdySessionContentReader? = nil
}

extension EnvironmentValues {
    var loopdySessionContentReader: LoopdySessionContentReader? {
        get { self[LoopdySessionContentReaderKey.self] }
        set { self[LoopdySessionContentReaderKey.self] = newValue }
    }
}
