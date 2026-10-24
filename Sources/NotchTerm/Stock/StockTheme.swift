import AppKit
import SwiftUI

enum StockTheme {
    static let upNS = NSColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 1)
    static let downNS = NSColor(srgbRed: 0.02, green: 0.55, blue: 0.36, alpha: 1)

    static let up = Color(nsColor: upNS)
    static let down = Color(nsColor: downNS)

    static func color(isUp: Bool) -> Color { isUp ? up : down }
    static func nsColor(isUp: Bool) -> NSColor { isUp ? upNS : downNS }
}
