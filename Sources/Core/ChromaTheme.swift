import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Shared ChromaScan darkroom palette derived from the watercolor poppy app icon:
/// warm archival cold-press cream accent paired with vermilion poppy pigment.
enum ChromaTheme {
    /// Warm archival paper cream (`#F2E0C4`) used as the primary UI accent on dark surfaces.
    static let creamRed: Double = 0.949
    static let creamGreen: Double = 0.878
    static let creamBlue: Double = 0.769

    /// Vivid vermilion poppy pigment (`#FA5724`) paired with cream & optical scan cyan.
    static let vermilionRed: Double = 0.980
    static let vermilionGreen: Double = 0.341
    static let vermilionBlue: Double = 0.141

    /// Deep darkroom ink (`#1A1715`) for crisp foreground contrast on cream prominent buttons.
    static let inkRed: Double = 0.102
    static let inkGreen: Double = 0.090
    static let inkBlue: Double = 0.082

    #if canImport(SwiftUI)
    static let cream = Color(red: creamRed, green: creamGreen, blue: creamBlue)
    static let vermilion = Color(red: vermilionRed, green: vermilionGreen, blue: vermilionBlue)
    static let ink = Color(red: inkRed, green: inkGreen, blue: inkBlue)
    #endif

    #if canImport(AppKit)
    static let creamNS = NSColor(srgbRed: creamRed, green: creamGreen, blue: creamBlue, alpha: 1.0)
    static let vermilionNS = NSColor(srgbRed: vermilionRed, green: vermilionGreen, blue: vermilionBlue, alpha: 1.0)
    static let inkNS = NSColor(srgbRed: inkRed, green: inkGreen, blue: inkBlue, alpha: 1.0)
    #endif
}
