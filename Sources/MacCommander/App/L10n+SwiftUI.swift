import MacCommanderCore
import SwiftUI

extension L10n {
    /// A `Text` of a looked-up string. `Text` shows a `String` verbatim, so SwiftUI doesn't look it up a second time
    /// in the main bundle as it would a literal.
    static func text(_ key: String, _ english: String) -> Text {
        Text(string(key, english))
    }
}
