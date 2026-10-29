import Foundation

/// Hard ceilings for anything that allocates pixels. A hostile PDF or image can
/// ask for an unreasonable bitmap; refusing is better than being killed.
enum Limits {
    /// 40 megapixels: a 8000 x 5000 scan is 40, a 300 DPI A3 is 17.
    static let maxPixels = 40_000_000
    /// No single side above this, which also catches absurd skinny pages.
    static let maxEdge = 16_384

    static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw EngineError(message: "The page has no size")
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard width <= maxEdge, height <= maxEdge, !overflow, pixels <= maxPixels else {
            throw EngineError(
                message: "That page is too large to render safely (\(width) x \(height) px)")
        }
    }
}
