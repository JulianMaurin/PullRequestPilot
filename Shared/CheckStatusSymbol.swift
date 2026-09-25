import SwiftUI

extension CheckStatus {
    /// The mark the list row and the widgets draw for this rollup.
    var symbolName: String {
        switch self {
        case .success: "checkmark"
        case .pending, .expected: "circle.fill"
        case .failure, .error: "xmark"
        }
    }

    var tint: Color {
        switch self {
        case .success: .blue
        case .pending, .expected: .yellow
        case .failure, .error: .red
        }
    }

    /// The pending dot is drawn smaller than the marks.
    var isInProgress: Bool {
        switch self {
        case .pending, .expected: true
        case .success, .failure, .error: false
        }
    }
}
