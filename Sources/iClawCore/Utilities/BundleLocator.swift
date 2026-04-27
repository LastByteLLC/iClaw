import Foundation

extension Bundle {
    /// Robust resource bundle accessor that works in all deployment contexts:
    /// - SPM debug builds (bundle adjacent to binary in .build/)
    /// - macOS .app bundles (bundle in Contents/Resources/)
    /// - CI builds (hardcoded build path doesn't exist on user machines)
    ///
    /// SPM's auto-generated `Bundle.module` only checks `Bundle.main.bundleURL`
    /// (the .app root) and a hardcoded build path. For macOS app bundles, resources
    /// live in `Contents/Resources/`, which `bundleURL` doesn't reach. SPM also
    /// regenerates its accessor on every build, making sed patches unreliable.
    public static let iClawCore: Bundle = {
        let bundleName = "iClaw_iClawCore"

        // 1. Contents/Resources/ — standard macOS app bundle location
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        // 2. Adjacent to binary — SPM development builds
        if let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        // 3. Adjacent to the executable — some deployment layouts
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent(),
           let bundle = Bundle(url: execURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        // 4. Fall through to SPM's generated accessor (works in dev builds)
        return Bundle.module
    }()
}
