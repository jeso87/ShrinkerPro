import Foundation
import Combine

/// UserDefaults-backed settings. Keys and defaults mirror upstream
/// image-shrinker's electron-settings store so behavior matches exactly.
@MainActor
final class Settings: ObservableObject {

    private enum Key {
        static let notification = "notification"
        static let folderswitch = "folderswitch"
        static let savepath = "savepath"
        static let clearlist = "clearlist"
        static let suffix = "suffix"
        static let updatecheck = "updatecheck"
        static let subfolder = "subfolder"
        static let conversionPNG = "conversionPNG"
        static let conversionJPEG = "conversionJPEG"
        static let conversionHEIC = "conversionHEIC"
        static let conversionWebP = "conversionWebP"
        static let conversionAVIF = "conversionAVIF"
    }

    private let defaults: UserDefaults

    @Published var notification: Bool { didSet { defaults.set(notification, forKey: Key.notification) } }
    @Published var saveInSameFolder: Bool { didSet { defaults.set(saveInSameFolder, forKey: Key.folderswitch) } }
    @Published var clearList: Bool { didSet { defaults.set(clearList, forKey: Key.clearlist) } }
    @Published var addSuffix: Bool { didSet { defaults.set(addSuffix, forKey: Key.suffix) } }
    @Published var updateCheck: Bool { didSet { defaults.set(updateCheck, forKey: Key.updatecheck) } }
    @Published var useSubfolder: Bool { didSet { defaults.set(useSubfolder, forKey: Key.subfolder) } }

    @Published var savePath: URL? {
        didSet { defaults.set(savePath?.path, forKey: Key.savepath) }
    }

    // One rule per convertible input format — see `ConversionRules`. SVG
    // and GIF deliberately have no rule of their own; ShrinkEngine never
    // consults settings for them at all (spec: "SVG and GIF never
    // convert").
    @Published var pngConversion: ConversionTarget {
        didSet { defaults.set(pngConversion.rawValue, forKey: Key.conversionPNG) }
    }
    @Published var jpegConversion: ConversionTarget {
        didSet { defaults.set(jpegConversion.rawValue, forKey: Key.conversionJPEG) }
    }
    /// Covers both HEIC and HEIF inputs — the spec's table lists them as
    /// one row with one shared rule. Typed `ConversionFormat`, not
    /// `ConversionTarget`: HEIC has no "keep" option (see that type's doc
    /// comment), so there is no case here to accidentally persist or read
    /// back.
    @Published var heicConversion: ConversionFormat {
        didSet { defaults.set(heicConversion.rawValue, forKey: Key.conversionHEIC) }
    }
    @Published var webpConversion: ConversionTarget {
        didSet { defaults.set(webpConversion.rawValue, forKey: Key.conversionWebP) }
    }
    @Published var avifConversion: ConversionTarget {
        didSet { defaults.set(avifConversion.rawValue, forKey: Key.conversionAVIF) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Upstream defaultSettings in main.js, plus the spec's one
        // opinionated conversion default: HEIC/HEIF → JPEG. Every other
        // format defaults to "keep original" — unchanged behavior.
        defaults.register(defaults: [
            Key.notification: true,
            Key.folderswitch: true,
            Key.clearlist: false,
            Key.suffix: true,
            Key.updatecheck: true,
            Key.subfolder: false,
            Key.conversionPNG: ConversionTarget.keep.rawValue,
            Key.conversionJPEG: ConversionTarget.keep.rawValue,
            Key.conversionHEIC: ConversionFormat.jpeg.rawValue,
            Key.conversionWebP: ConversionTarget.keep.rawValue,
            Key.conversionAVIF: ConversionTarget.keep.rawValue,
        ])
        notification = defaults.bool(forKey: Key.notification)
        saveInSameFolder = defaults.bool(forKey: Key.folderswitch)
        clearList = defaults.bool(forKey: Key.clearlist)
        addSuffix = defaults.bool(forKey: Key.suffix)
        updateCheck = defaults.bool(forKey: Key.updatecheck)
        useSubfolder = defaults.bool(forKey: Key.subfolder)
        savePath = defaults.string(forKey: Key.savepath).map(URL.init(fileURLWithPath:))
        pngConversion = Self.readTarget(defaults, Key.conversionPNG, default: .keep)
        jpegConversion = Self.readTarget(defaults, Key.conversionJPEG, default: .keep)
        heicConversion = Self.readFormat(defaults, Key.conversionHEIC, default: .jpeg)
        webpConversion = Self.readTarget(defaults, Key.conversionWebP, default: .keep)
        avifConversion = Self.readTarget(defaults, Key.conversionAVIF, default: .keep)
    }

    /// `defaults.register` guarantees a string is present under normal
    /// operation, but this still falls back to `def` rather than force-
    /// unwrapping — a value written by a future version of this app with
    /// a `ConversionTarget` case this build doesn't know about must not
    /// crash on launch.
    private static func readTarget(
        _ defaults: UserDefaults, _ key: String, default def: ConversionTarget
    ) -> ConversionTarget {
        defaults.string(forKey: key).flatMap(ConversionTarget.init(rawValue:)) ?? def
    }

    /// Same idea as `readTarget`, for HEIC's `ConversionFormat` rule. This
    /// is also where a value stored before HEIC's "keep" option was
    /// removed gets migrated: `ConversionFormat(rawValue: "keep")` returns
    /// `nil` (there is no such case), so a previously-persisted "keep"
    /// falls through to `def` — JPEG, the spec's default — exactly like
    /// any other unrecognised stored value, rather than crashing or
    /// silently landing on some other format.
    private static func readFormat(
        _ defaults: UserDefaults, _ key: String, default def: ConversionFormat
    ) -> ConversionFormat {
        defaults.string(forKey: key).flatMap(ConversionFormat.init(rawValue:)) ?? def
    }

    var outputSettings: OutputSettings {
        OutputSettings(
            saveInSameFolder: saveInSameFolder,
            savePath: savePath,
            useSubfolder: useSubfolder,
            addSuffix: addSuffix,
            conversionRules: ConversionRules(
                png: pngConversion,
                jpeg: jpegConversion,
                heic: heicConversion,
                webp: webpConversion,
                avif: avifConversion
            )
        )
    }
}
