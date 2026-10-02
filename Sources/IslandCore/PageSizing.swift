import CoreGraphics

/// The open dashboard has one fixed outer height; whatever its content, the
/// page below the pinned header gets the rest and scrolls inside it.
public enum PageSizing {
    /// Height left for the scrolling page once the header row, the gap under
    /// it and the bottom chrome (inset or padding) are taken out. Never negative.
    public static func viewport(total: CGFloat, header: CGFloat, spacing: CGFloat, chrome: CGFloat) -> CGFloat {
        max(0, total - header - spacing - chrome)
    }
}
