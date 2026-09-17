import XCTest
@testable import ShrinkerPro

/// Covers `OutputNaming`, the pure type behind the Output section's second
/// radio pair.
///
/// The defect it exists to fix: that radio binds `keepOriginal`, which does
/// exactly one thing in the engine — appends `.min` to the stem
/// (`OutputPathResolver.swift:107`) — but it was labelled as though it also
/// decided whether an original survived. It only decides that when the
/// output lands in the original's own folder. Send the output to a chosen
/// folder or a `minified/` subfolder and "Replace originals" describes
/// something that cannot happen; the choice is purely what the file is
/// called.
///
/// Tested at the type rather than through the rendered `Picker` for the
/// reason given in `SettingsViewTests`: this project carries no view-tree
/// testing dependency, so logic left inline in a `body` is unreachable.
final class OutputNamingTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/Users/someone/Desktop/shrunk")

    // MARK: - Which style a combination selects

    /// The one combination where the suffix is the only thing standing
    /// between the user and an overwritten file.
    func testSameFolderWithoutSubfolderNamesFilesAgainstTheirOriginals() {
        XCTAssertEqual(
            OutputNaming.style(saveInSameFolder: true, savePath: nil, useSubfolder: false),
            .besideOriginals
        )
    }

    /// `minified/` is a different directory, so nothing of the user's is at
    /// stake and the choice is only what the copy is called.
    func testSubfolderMovesTheOutputOffTheOriginalsPath() {
        XCTAssertEqual(
            OutputNaming.style(saveInSameFolder: true, savePath: nil, useSubfolder: true),
            .separateDestination
        )
    }

    func testChosenFolderMovesTheOutputOffTheOriginalsPath() {
        XCTAssertEqual(
            OutputNaming.style(saveInSameFolder: false, savePath: folder, useSubfolder: false),
            .separateDestination
        )
    }

    /// The trap. "Choose folder…" is selected but no folder has been picked
    /// yet, and `OutputPathResolver.destination` only redirects when a save
    /// path actually exists — so files still land beside their originals and
    /// the labels must still say so.
    func testChosenFolderWithNoFolderPickedYetStillWritesBesideOriginals() {
        XCTAssertEqual(
            OutputNaming.style(saveInSameFolder: false, savePath: nil, useSubfolder: false),
            .besideOriginals
        )
    }

    /// …unless the subfolder rescues it, which it does on its own.
    func testSubfolderRescuesAChosenFolderWithNoFolderPickedYet() {
        XCTAssertEqual(
            OutputNaming.style(saveInSameFolder: false, savePath: nil, useSubfolder: true),
            .separateDestination
        )
    }

    // MARK: - What each style puts on screen

    func testBesideOriginalsLabelsNameTheStakeNotTheFilename() {
        let naming = OutputNaming.besideOriginals
        XCTAssertEqual(naming.rowLabel, "Files")
        XCTAssertEqual(naming.suffixOnTitle, "Keep originals, save a .min copy")
        XCTAssertEqual(naming.suffixOffTitle, "Replace originals")
        XCTAssertNil(naming.suffixOnExample)
        XCTAssertNil(naming.suffixOffExample)
    }

    func testSeparateDestinationLabelsNameTheFilenameAndShowIt() {
        let naming = OutputNaming.separateDestination
        XCTAssertEqual(naming.rowLabel, "Filenames")
        XCTAssertEqual(naming.suffixOnTitle, "Add .min")
        XCTAssertEqual(naming.suffixOffTitle, "Leave as is")
        XCTAssertEqual(naming.suffixOnExample, "photo.min.png")
        XCTAssertEqual(naming.suffixOffExample, "photo.png")
    }

    /// No label may promise that an original is replaced when the style says
    /// the output lands somewhere else entirely — that is the whole bug.
    func testSeparateDestinationNeverMentionsReplacingOrKeepingOriginals() {
        let titles = [OutputNaming.separateDestination.suffixOnTitle,
                      OutputNaming.separateDestination.suffixOffTitle]
        for title in titles {
            XCTAssertFalse(
                title.lowercased().contains("original"),
                "\"\(title)\" talks about originals, which this combination never touches"
            )
        }
    }

    // MARK: - The warning reads the same table

    /// `OutputWarning.replacesOriginals` is now expressed in terms of this
    /// type, so the two cannot disagree about which combinations are
    /// dangerous. Asserting the equivalence directly is what pins that.
    func testWarningFiresExactlyWhenTheSuffixIsOffAndFilesLandBesideOriginals() {
        for keepOriginal in [true, false] {
            for saveInSameFolder in [true, false] {
                for savePath in [folder, nil] {
                    for useSubfolder in [true, false] {
                        let style = OutputNaming.style(
                            saveInSameFolder: saveInSameFolder,
                            savePath: savePath,
                            useSubfolder: useSubfolder
                        )
                        let expected = !keepOriginal && style == .besideOriginals
                        XCTAssertEqual(
                            OutputWarning.replacesOriginals(
                                keepOriginal: keepOriginal,
                                saveInSameFolder: saveInSameFolder,
                                savePath: savePath,
                                useSubfolder: useSubfolder
                            ),
                            expected,
                            "keep=\(keepOriginal) same=\(saveInSameFolder) path=\(savePath != nil) sub=\(useSubfolder)"
                        )
                    }
                }
            }
        }
    }
}
