import SwiftUI

extension Animation {
    /// Standard UI transition (chips, confirmations, tooltips). 0.2s ease-in-out.
    static let snappy = Animation.easeInOut(duration: 0.2)
    /// Quick dismiss/appear. 0.15s ease-out.
    static let quick = Animation.easeOut(duration: 0.15)
}
