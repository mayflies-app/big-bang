import Foundation
import XCTest
@testable import BigBangSelection

final class EditorClipboardMetadataTests: XCTestCase {
    private let nativeType = "vscode-editor-data"
    private let copyMetadataType = "application/vnd.code.copymetadata"
    private let chromiumType = "org.chromium.web-custom-data"
    private let emptyJSON = #"{"version":1,"isFromEmptySelection":true}"#
    private let selectionJSON = #"{"version":1,"isFromEmptySelection":false}"#
    // VS Code 1.141.0 CopyPasteController emits this independent MIME, with
    // defaultPastePayload.pasteOnNewLine assigned from isFromEmptySelection.
    // id and providerCopyMimeTypes are optional; the nested payload has no version.
    // https://github.com/microsoft/vscode/blob/2a59476c9bfcb90b3ddc372c36762471b7dfad1c/src/vs/editor/contrib/dropOrPasteInto/browser/copyPasteController.ts#L177-L199
    private let copyEmptyJSON = #"{"defaultPastePayload":{"multicursorText":null,"pasteOnNewLine":true,"isBlock":false,"mode":null}}"#
    private let copySelectionJSON = #"{"defaultPastePayload":{"multicursorText":null,"pasteOnNewLine":false,"isBlock":false,"mode":null}}"#

    func testNativeJSONRecognizesEmptyAndActualSelections() {
        XCTAssertEqual(decodeNative(emptyJSON), true)
        XCTAssertEqual(decodeNative(selectionJSON), false)
    }

    func testChromiumPickleRecognizesEmptyAndActualSelections() {
        XCTAssertEqual(decodePickle([(nativeType, emptyJSON)]), true)
        XCTAssertEqual(decodePickle([(nativeType, selectionJSON)]), false)
    }

    func testCopyMetadataMIMERecognizesDirectEmptyAndActualSelections() {
        XCTAssertEqual(EditorClipboardMetadata.isFromEmptySelection([copyMetadataType: Data(copyEmptyJSON.utf8)]), true)
        XCTAssertEqual(EditorClipboardMetadata.isFromEmptySelection([copyMetadataType: Data(copySelectionJSON.utf8)]), false)
    }

    func testCopyMetadataMIMERecognizesChromiumEmptyAndActualSelections() {
        XCTAssertEqual(decodePickle([(copyMetadataType, copyEmptyJSON)]), true)
        XCTAssertEqual(decodePickle([(copyMetadataType, copySelectionJSON)]), false)
    }

    func testCopyMetadataOptionalProviderFieldsDoNotChangeSelectionFlag() {
        let json = #"{"id":"1f231ad8-00ab-45d6-a741-93de85f084dd","providerCopyMimeTypes":["text/plain","application/自定义"],"defaultPastePayload":{"multicursorText":["第一行\n😀","second"],"pasteOnNewLine":false,"isBlock":false,"mode":null}}"#
        XCTAssertEqual(EditorClipboardMetadata.isFromEmptySelection([copyMetadataType: Data(json.utf8)]), false)
        XCTAssertEqual(decodePickle([("unrelated", "value"), (copyMetadataType, json)]), false)
    }

    func testLegacyAndCopyMetadataDirectFormatsMustAgree() {
        for (legacy, copy, expected) in [(emptyJSON, copyEmptyJSON, true), (selectionJSON, copySelectionJSON, false)] {
            XCTAssertEqual(EditorClipboardMetadata.isFromEmptySelection([
                nativeType: Data(legacy.utf8), copyMetadataType: Data(copy.utf8)
            ]), expected)
        }
        for (legacy, copy) in [(emptyJSON, copySelectionJSON), (selectionJSON, copyEmptyJSON)] {
            XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
                nativeType: Data(legacy.utf8), copyMetadataType: Data(copy.utf8)
            ]))
        }
    }

    func testLegacyAndCopyMetadataWithinOnePickleMustAgree() {
        XCTAssertEqual(decodePickle([(nativeType, emptyJSON), (copyMetadataType, copyEmptyJSON)]), true)
        XCTAssertEqual(decodePickle([(copyMetadataType, copySelectionJSON), (nativeType, selectionJSON)]), false)
        XCTAssertNil(decodePickle([(nativeType, emptyJSON), (copyMetadataType, copySelectionJSON)]))
        XCTAssertNil(decodePickle([(copyMetadataType, copyEmptyJSON), (nativeType, selectionJSON)]))
    }

    func testLegacyAndCopyMetadataAcrossNativeAndChromiumMustAgree() {
        XCTAssertEqual(EditorClipboardMetadata.isFromEmptySelection([
            nativeType: Data(selectionJSON.utf8), chromiumType: pickle([(copyMetadataType, copySelectionJSON)])
        ]), false)
        XCTAssertEqual(EditorClipboardMetadata.isFromEmptySelection([
            copyMetadataType: Data(copyEmptyJSON.utf8), chromiumType: pickle([(nativeType, emptyJSON)])
        ]), true)
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
            nativeType: Data(emptyJSON.utf8), chromiumType: pickle([(copyMetadataType, copySelectionJSON)])
        ]))
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
            copyMetadataType: Data(copySelectionJSON.utf8), chromiumType: pickle([(nativeType, emptyJSON)])
        ]))
    }

    func testCopyMetadataDirectAndChromiumMustAgree() {
        XCTAssertEqual(EditorClipboardMetadata.isFromEmptySelection([
            copyMetadataType: Data(copySelectionJSON.utf8), chromiumType: pickle([(copyMetadataType, copySelectionJSON)])
        ]), false)
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
            copyMetadataType: Data(copyEmptyJSON.utf8), chromiumType: pickle([(copyMetadataType, copySelectionJSON)])
        ]))
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
            copyMetadataType: Data(copySelectionJSON.utf8), chromiumType: Data([0])
        ]))
    }

    func testCopyMetadataRequiresBooleanPasteOnNewLineInAnObjectPayload() {
        let invalid = [
            "not json", "[]", "null", "{}",
            #"{"defaultPastePayload":null}"#,
            #"{"defaultPastePayload":[]}"#,
            #"{"defaultPastePayload":false}"#,
            #"{"defaultPastePayload":"payload"}"#,
            #"{"defaultPastePayload":{}}"#,
            #"{"defaultPastePayload":{"pasteOnNewLine":null}}"#,
            #"{"defaultPastePayload":{"pasteOnNewLine":1}}"#,
            #"{"defaultPastePayload":{"pasteOnNewLine":0}}"#,
            #"{"defaultPastePayload":{"pasteOnNewLine":"true"}}"#,
            #"{"defaultPastePayload":{"pasteOnNewLine":"false"}}"#,
            #"{"defaultPastePayload":{"isFromEmptySelection":false}}"#,
            #"{"pasteOnNewLine":false}"#,
            #"{"version":1,"isFromEmptySelection":false}"#
        ]
        for json in invalid {
            XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([copyMetadataType: Data(json.utf8)]), json)
            XCTAssertNil(decodePickle([(copyMetadataType, json)]), json)
            // Invalid recognized metadata cannot be hidden by a valid legacy entry.
            XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
                nativeType: Data(selectionJSON.utf8), copyMetadataType: Data(json.utf8)
            ]), json)
            XCTAssertNil(decodePickle([(nativeType, selectionJSON), (copyMetadataType, json)]), json)
        }
    }

    func testCopyMetadataShapeDoesNotRelaxLegacyVersionOneContract() {
        for json in [copyEmptyJSON, copySelectionJSON, #"{"version":1,"defaultPastePayload":{"isFromEmptySelection":false}}"#] {
            XCTAssertNil(decodeNative(json), json)
            XCTAssertNil(decodePickle([(nativeType, json)]), json)
            XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
                nativeType: Data(json.utf8), copyMetadataType: Data(copySelectionJSON.utf8)
            ]), json)
        }
    }

    func testCopyMetadataRequiresExactMIMEAndRejectsDuplicatePickleEntries() {
        let similarType = "application/vnd.code.copymetadata.extra"
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([similarType: Data(copySelectionJSON.utf8)]))
        XCTAssertNil(decodePickle([(similarType, copySelectionJSON)]))
        XCTAssertNil(decodePickle([(copyMetadataType, copySelectionJSON), (copyMetadataType, copySelectionJSON)]))
    }

    func testCopyMetadataByteLimitRejectsOversizedDirectJSON() {
        let oversized = Data((copySelectionJSON + String(repeating: " ", count: 1_048_576)).utf8)
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([copyMetadataType: oversized]))
    }

    func testExtraFormatsAndUnicodeMultilineValuesArePreservedDuringTraversal() {
        let json = #"{"version":1,"isFromEmptySelection":false,"multicursorText":["中文😀\n第二行","é"],"mode":"swift"}"#
        let pairs = [("其他😀", "多行\n🙂"), (nativeType, json), ("x", "odd")]
        XCTAssertEqual(decodePickle(pairs), false)
        XCTAssertEqual(decodeNative(json), false)
    }

    func testAbsentAndSimilarlyNamedMetadataAreUnknown() {
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([:]))
        XCTAssertNil(decodePickle([]))
        XCTAssertNil(decodePickle([("application/vscode-editor-data", emptyJSON)]))
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection(["application/vscode-editor-data": Data(emptyJSON.utf8)]))
    }

    func testEveryTruncatedPickleIsRejected() {
        let complete = pickle([(nativeType, selectionJSON)])
        for length in 0..<complete.count {
            XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([chromiumType: Data(complete.prefix(length))]), "Truncation at \(length)")
        }
    }

    func testHeaderAndPayloadMustMatchExactly() {
        var shortHeader = pickle([(nativeType, emptyJSON)])
        overwriteWord(&shortHeader, at: 0, with: UInt32(shortHeader.count - 8))
        XCTAssertNil(decodeData(shortHeader))
        var longHeader = pickle([(nativeType, emptyJSON)])
        overwriteWord(&longHeader, at: 0, with: UInt32(longHeader.count))
        XCTAssertNil(decodeData(longHeader))
        var trailing = pickle([(nativeType, emptyJSON)])
        trailing.append(contentsOf: [0, 0, 0, 0])
        overwriteWord(&trailing, at: 0, with: UInt32(trailing.count - 4))
        XCTAssertNil(decodeData(trailing))
    }

    func testNegativeAndOversizedStringLengthsAreRejected() {
        for badLength in [UInt32.max, UInt32(Int32.max)] {
            var data = pickle([(nativeType, emptyJSON)])
            overwriteWord(&data, at: 8, with: badLength)
            XCTAssertNil(decodeData(data))
        }
    }

    func testDuplicateKeysAreRejectedEvenAfterValidMetadata() {
        XCTAssertNil(decodePickle([(nativeType, emptyJSON), (nativeType, emptyJSON)]))
        XCTAssertNil(decodePickle([(nativeType, selectionJSON), ("x", "1"), ("x", "2")]))
    }

    func testMalformedTrailingPairsAreRejectedAfterValidMetadata() {
        var data = pickle([(nativeType, emptyJSON), ("x", "odd")])
        data.removeLast()
        overwriteWord(&data, at: 0, with: UInt32(data.count - 4))
        XCTAssertNil(decodeData(data))
    }

    func testInvalidUTF16IsRejected() {
        var data = pickle([("x", "value"), (nativeType, emptyJSON)])
        data[12] = 0x00
        data[13] = 0xD8 // Unpaired high surrogate in the first key.
        XCTAssertNil(decodeData(data))
    }

    func testJSONRequiresVersionOneAndBooleanSelectionFlag() {
        let invalid = [
            "not json", "[]", "null", "{}",
            #"{"version":2,"isFromEmptySelection":true}"#,
            #"{"version":true,"isFromEmptySelection":true}"#,
            #"{"version":"1","isFromEmptySelection":true}"#,
            #"{"version":1,"isFromEmptySelection":1}"#,
            #"{"version":1,"isFromEmptySelection":0}"#,
            #"{"version":1,"isFromEmptySelection":"true"}"#,
            #"{"version":1,"isFromEmptySelection":null}"#,
            #"{"version":1}"#
        ]
        for json in invalid {
            XCTAssertNil(decodeNative(json), json)
            XCTAssertNil(decodePickle([(nativeType, json)]), json)
        }
    }

    func testNativeAndChromiumMustAgreeWhenBothCarryMetadata() {
        XCTAssertEqual(EditorClipboardMetadata.isFromEmptySelection([
            nativeType: Data(selectionJSON.utf8), chromiumType: pickle([(nativeType, selectionJSON)])
        ]), false)
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
            nativeType: Data(emptyJSON.utf8), chromiumType: pickle([(nativeType, selectionJSON)])
        ]))
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
            nativeType: Data(emptyJSON.utf8), chromiumType: Data([0])
        ]))
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
            nativeType: Data("invalid".utf8), chromiumType: pickle([(nativeType, selectionJSON)])
        ]))
        XCTAssertNil(EditorClipboardMetadata.isFromEmptySelection([
            nativeType: Data(emptyJSON.utf8), chromiumType: pickle([(nativeType, "invalid")])
        ]))
        XCTAssertEqual(EditorClipboardMetadata.isFromEmptySelection([
            nativeType: Data(emptyJSON.utf8), chromiumType: pickle([("x", "unrelated")])
        ]), true)
    }

    func testPairAndByteLimitsRejectUnboundedInput() {
        let tooManyPairs = (0..<257).map { ("key\($0)", "value") } + [(nativeType, emptyJSON)]
        XCTAssertNil(decodePickle(tooManyPairs))
        var invalidCount = pickle([(nativeType, emptyJSON)])
        overwriteWord(&invalidCount, at: 4, with: UInt32.max)
        XCTAssertNil(decodeData(invalidCount))
        XCTAssertNil(decodeNative(emptyJSON + String(repeating: " ", count: 1_048_576)))
        XCTAssertNil(decodePickle([(nativeType, emptyJSON), ("huge", String(repeating: "x", count: 524_288))]))
        let allowedPairs = (0..<255).map { ("key\($0)", "value") } + [(nativeType, selectionJSON)]
        XCTAssertEqual(decodePickle(allowedPairs), false)
    }

    private func decodeNative(_ json: String) -> Bool? {
        EditorClipboardMetadata.isFromEmptySelection([nativeType: Data(json.utf8)])
    }

    private func decodePickle(_ pairs: [(String, String)]) -> Bool? {
        decodeData(pickle(pairs))
    }

    private func decodeData(_ data: Data) -> Bool? {
        EditorClipboardMetadata.isFromEmptySelection([chromiumType: data])
    }

    // Independent fixture serializer follows Chromium WriteCustomDataToPickle:
    // https://github.com/chromium/chromium/blob/main/ui/base/clipboard/custom_data_helper.cc
    // Pickle has a uint32 payload-size header, a uint32 pair count, then key/value
    // strings. WriteString16 writes int32 UTF-16 code-unit counts, native-endian
    // UTF-16 bytes (little endian on macOS), and padding to four-byte boundaries:
    // https://github.com/chromium/chromium/blob/main/base/pickle.cc
    private func pickle(_ pairs: [(String, String)]) -> Data {
        var payload = word(UInt32(pairs.count))
        for (key, value) in pairs {
            for string in [key, value] {
                let units = Array(string.utf16)
                payload.append(word(UInt32(units.count)))
                for unit in units {
                    payload.append(UInt8(truncatingIfNeeded: unit))
                    payload.append(UInt8(truncatingIfNeeded: unit >> 8))
                }
                while payload.count % 4 != 0 { payload.append(0) }
            }
        }
        return word(UInt32(payload.count)) + payload
    }

    private func word(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func overwriteWord(_ data: inout Data, at offset: Int, with value: UInt32) {
        data.replaceSubrange(offset..<(offset + 4), with: word(value))
    }
}
