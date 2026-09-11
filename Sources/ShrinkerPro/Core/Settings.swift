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
        /// Backs `keepOriginal`. The key keeps its original name — and its
        /// original polarity — deliberately: the property was renamed from
        /// `addSuffix` to say what is at stake rather than what is
        /// appended, and renaming the key alongside it would have been a
        /// migration with a real chance of reading somebody's existing
        /// preference backwards, for no benefit they could see.
        static let suffix = "suffix"
        static let updatecheck = "updatecheck"
        static let subfolder = "subfolder"
        static let conversionPNG = "conversionPNG"
        static let conversionJPEG = "conversionJPEG"
        static let conversionHEIC = "conversionHEIC"
        static let conversionWebP = "conversionWebP"
        static let conversionAVIF = "conversionAVIF"
        static let metadata = "metadata"
    }

    private let defaults: UserDefaults

    @Published var notification: Bool { didSet { defaults.set(notification, forKey: Key.notification) } }
    @Published var saveInSameFolder: Bool { didSet { defaults.set(saveInSameFolder, forKey: Key.folderswitch) } }
    @Published var clearList: Bool { didSet { defaults.set(clearList, forKey: Key.clearlist) } }
    @Published var keepOriginal: Bool { didSet { defaults.set(keepOriginal, forKey: Key.suffix) } }
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

    /// What metadata survives compression — see `MetadataPolicy`. Note this
    /// never governs orientation, which is always applied to the pixels and
    /// always absent from the output.
    @Published var metadataPolicy: MetadataPolicy {
        didSet { defaults.set(metadataPolicy.rawValue, forKey: Key.metadata) }
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
            // `.all` because it is the only default that doesn't silently
            // regress: JPEG -> JPEG preserves EXIF today (cjpeg copies every
            // APPn marker), so anything else would start deleting capture
            // data from files this app already round-trips intact.
            Key.metadata: MetadataPolicy.all.rawValue,
        ])
        notification = defaults.bool(forKey: Key.notification)
        saveInSameFolder = defaults.bool(forKey: Key.folderswitch)
        clearList = defaults.bool(forKey: Key.clearlist)
        keepOriginal = defaults.bool(forKey: Key.suffix)
        updateCheck = defaults.bool(forKey: Key.updatecheck)
        useSubfolder = defaults.bool(forKey: Key.subfolder)
        savePath = defaults.string(forKey: Key.savepath).map(URL.init(fileURLWithPath:))
        pngConversion = Self.readTarget(defaults, Key.conversionPNG, default: .keep)
        jpegConversion = Self.readTarget(defaults, Key.conversionJPEG, default: .keep)
        heicConversion = Self.readFormat(defaults, Key.conversionHEIC, default: .jpeg)
        webpConversion = Self.readTarget(defaults, Key.conversionWebP, default: .keep)
        avifConversion = Self.readTarget(defaults, Key.conversionAVIF, default: .keep)
        metadataPolicy = Self.readPolicy(defaults, Key.metadata, default: .all)
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

    /// Same fallback contract as `readTarget`: a value written by a future
    /// version of this app, with a policy this build has never heard of,
    /// must come back as the default rather than crash on launch.
    private static func readPolicy(
        _ defaults: UserDefaults, _ key: String, default def: MetadataPolicy
    ) -> MetadataPolicy {
        defaults.string(forKey: key).flatMap(MetadataPolicy.init(rawValue:)) ?? def
    }

    /// The persisted half of what the engine needs. The session override is
    /// deliberately absent: it lives on `AppModel`, is never written here,
    /// and is layered onto this snapshot per batch.
    var outputSettings: OutputSettings {
        OutputSettings(
            saveInSameFolder: saveInSameFolder,
            savePath: savePath,
            useSubfolder: useSubfolder,
            keepOriginal: keepOriginal,
            conversionRules: ConversionRules(
                png: pngConversion,
                jpeg: jpegConversion,
                heic: heicConversion,
                webp: webpConversion,
                avif: avifConversion
            ),
            metadataPolicy: metadataPolicy
        )
    }
}
