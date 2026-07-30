import CoreGraphics
import Foundation

/// Undeclared CoreGraphics/SkyLight symbols, resolved at runtime.
///
/// These exist in the SDK's CoreGraphics.tbd and would link directly, but Swift
/// cannot express `weak_import`: a weakly-declared C function still imports as a
/// non-optional Swift function, so there is no way to test for its absence.
/// dlsym keeps removal survivable.
enum CoreGraphicsSPI {
    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        RTLD_LAZY | RTLD_LOCAL
    )

    private typealias DisplayPredicate = @convention(c) (CGDirectDisplayID) -> Bool

    private static func sym<T>(_ name: String) -> T? {
        guard let handle, let addr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(addr, to: T.self)
    }

    private static let isHDRSupportedFn: DisplayPredicate? = sym("CGSIsHDRSupported")
    private static let isHDREnabledFn: DisplayPredicate? = sym("CGSIsHDREnabled")

    static func isHDRSupported(_ display: CGDirectDisplayID) -> Bool {
        isHDRSupportedFn?(display) ?? false
    }

    static func isHDREnabled(_ display: CGDirectDisplayID) -> Bool {
        isHDREnabledFn?(display) ?? false
    }
}
