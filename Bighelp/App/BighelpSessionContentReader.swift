import SwiftUI

struct BighelpSessionContentReader {
    let load: @MainActor (String, String) async throws -> BighelpJSONValue
}

private struct BighelpSessionContentReaderKey: EnvironmentKey {
    static let defaultValue: BighelpSessionContentReader? = nil
}

extension EnvironmentValues {
    var bighelpSessionContentReader: BighelpSessionContentReader? {
        get { self[BighelpSessionContentReaderKey.self] }
        set { self[BighelpSessionContentReaderKey.self] = newValue }
    }
}
