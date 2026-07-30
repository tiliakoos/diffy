import SwiftUI

enum GlassVariant: String {
    case frosted
    case clear

    var glass: Glass { self == .clear ? .clear : .regular }
}

enum GlassPrefs {
    static let variantKey = "DiffyGlassVariant"
    static let opacityKey = "DiffyGlassOpacity"
    static let defaultOpacity = 0.5
    // Lower bound is the legibility floor: the scrim never goes fully clear.
    static let opacityRange: ClosedRange<Double> = 0.1...1.0
}

struct GlassBackground<S: Shape>: View {
    @AppStorage(GlassPrefs.variantKey) private var variant: GlassVariant = .frosted
    @AppStorage(GlassPrefs.opacityKey) private var opacity: Double = GlassPrefs.defaultOpacity

    var shape: S

    var body: some View {
        Color.clear
            .glassEffect(variant.glass, in: shape)
            .overlay(shape.fill(Color(nsColor: .windowBackgroundColor)).opacity(opacity))
    }
}
