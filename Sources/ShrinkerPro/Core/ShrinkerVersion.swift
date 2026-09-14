import Foundation

/// The version `shrinker --version` reports.
///
/// It lives in `Core` rather than beside the tool's entry point for a
/// specific reason: `main.swift` belongs to the `shrinker` target, and the
/// test bundle links the *app* target, so a constant declared there is
/// unreachable by any test. That is exactly how it came to be unguarded.
/// `Core` is compiled into both products, which is what lets
/// `CommandLineOptionsTests` read `MARKETING_VERSION` out of project.yml and
/// fail when the two drift apart.
///
/// The app needs none of this — it reads `CFBundleShortVersionString` from
/// its own Info.plist at runtime, so it cannot go stale. Only a product with
/// no bundle has to keep a copy by hand, and a copy kept by hand needs
/// something other than good intentions keeping it correct.
enum ShrinkerVersion {
    /// Must equal `MARKETING_VERSION` in project.yml, which is asserted.
    static let current = "1.2.0"
}
