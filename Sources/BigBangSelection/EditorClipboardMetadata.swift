import Foundation

/// Decodes VS Code's selection flag without mistaking a whole-line copy for a selection.
internal enum EditorClipboardMetadata {
    private static let nativeType = "vscode-editor-data"
    private static let copyMetadataType = "application/vnd.code.copymetadata"
    private static let chromiumType = "org.chromium.web-custom-data"
    private static let maximumBytes = 1_048_576
    private static let maximumPairs: UInt32 = 256

    enum State: Equatable { case selection, emptySelection, absent, invalid }

    /// `nil` means the metadata is absent, unsupported, malformed, or contradictory.
    static func isFromEmptySelection(_ customData: [String: Data]) -> Bool? {
        switch inspect(customData) {
        case .selection: return false
        case .emptySelection: return true
        case .absent, .invalid: return nil
        }
    }

    static func inspect(_ customData: [String: Data]) -> State {
        let direct = customData[nativeType]
        let copyMetadata = customData[copyMetadataType]
        let chromium = customData[chromiumType]
        guard (direct?.count ?? 0) <= maximumBytes,
              (chromium?.count ?? 0) <= maximumBytes,
              (copyMetadata?.count ?? 0) <= maximumBytes,
              (direct?.count ?? 0) + (copyMetadata?.count ?? 0) + (chromium?.count ?? 0) <= maximumBytes else { return .invalid }

        var flags: [Bool] = []
        if let direct {
            guard let flag = decodeJSON(direct) else { return .invalid }
            flags.append(flag)
        }
        if let copyMetadata {
            guard let flag = decodeCopyMetadata(copyMetadata) else { return .invalid }
            flags.append(flag)
        }

        if let chromium {
            guard let pairs = decodeChromiumPickle(chromium) else { return .invalid }
            if let metadata = pairs[nativeType] {
                guard let flag = decodeJSON(Data(metadata.utf8)) else { return .invalid }
                flags.append(flag)
            }
            if let metadata = pairs[copyMetadataType] {
                guard let flag = decodeCopyMetadata(Data(metadata.utf8)) else { return .invalid }
                flags.append(flag)
            }
        }

        guard let first = flags.first else { return .absent }
        guard flags.allSatisfy({ $0 == first }) else { return .invalid }
        return first ? .emptySelection : .selection
    }

    // VS Code writes JSON metadata version 1 with a boolean isFromEmptySelection:
    // https://github.com/microsoft/vscode/blob/main/src/vs/editor/browser/controller/editContext/clipboardUtils.ts
    private struct Metadata: Decodable {
        let version: Int
        let isFromEmptySelection: Bool
    }

    private static func decodeJSON(_ data: Data) -> Bool? {
        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.version == 1 else { return nil }
        return metadata.isFromEmptySelection
    }

    // CopyPasteController publishes a separate MIME. pasteOnNewLine is copied
    // directly from dataToCopy.isFromEmptySelection; it is not a legacy version flag.
    // https://github.com/microsoft/vscode/blob/2a59476c9bfcb90b3ddc372c36762471b7dfad1c/src/vs/editor/contrib/dropOrPasteInto/browser/copyPasteController.ts
    private struct CopyMetadata: Decodable {
        struct Payload: Decodable { let pasteOnNewLine: Bool }
        let defaultPastePayload: Payload
    }
    private static func decodeCopyMetadata(_ data: Data) -> Bool? {
        (try? JSONDecoder().decode(CopyMetadata.self, from: data))?.defaultPastePayload.pasteOnNewLine
    }

    // Chromium's macOS web-custom-data format is a base::Pickle, containing the
    // number of entries followed by UTF-16 key/value strings. Current macOS
    // architectures use little endian for Pickle's native-endian integer fields.
    // https://github.com/chromium/chromium/blob/main/ui/base/clipboard/custom_data_helper.cc
    // https://github.com/chromium/chromium/blob/main/base/pickle.cc
    private static func decodeChromiumPickle(_ data: Data) -> [String: String]? {
        guard data.count >= 8, data.count <= maximumBytes else { return nil }
        var reader = PickleReader(bytes: Array(data))
        guard let payloadBytes = reader.readUInt32(),
              Int(payloadBytes) == data.count - 4,
              let pairCount = reader.readUInt32(), pairCount <= maximumPairs else { return nil }

        var pairs: [String: String] = [:]
        for _ in 0..<pairCount {
            guard let key = reader.readString16(),
                  let value = reader.readString16(),
                  pairs[key] == nil else { return nil }
            pairs[key] = value
        }
        guard reader.offset == reader.bytes.count else { return nil }
        return pairs
    }

    private struct PickleReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func readUInt32() -> UInt32? {
            guard bytes.count - offset >= 4 else { return nil }
            let result = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return result
        }

        mutating func readString16() -> String? {
            guard let rawLength = readUInt32(), Int32(bitPattern: rawLength) >= 0 else { return nil }
            let codeUnitCount = Int(rawLength)
            // Bound before multiplying or allocating; all offsets stay inside bytes.
            guard codeUnitCount <= (bytes.count - offset) / 2 else { return nil }
            let byteCount = codeUnitCount * 2
            let paddedByteCount = (byteCount + 3) & ~3
            guard paddedByteCount <= bytes.count - offset else { return nil }

            var units: [UInt16] = []
            units.reserveCapacity(codeUnitCount)
            var needsLowSurrogate = false
            for index in 0..<codeUnitCount {
                let position = offset + index * 2
                let unit = UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
                if needsLowSurrogate {
                    guard (0xDC00...0xDFFF).contains(unit) else { return nil }
                    needsLowSurrogate = false
                } else if (0xD800...0xDBFF).contains(unit) {
                    needsLowSurrogate = true
                } else if (0xDC00...0xDFFF).contains(unit) {
                    return nil
                }
                units.append(unit)
            }
            guard !needsLowSurrogate else { return nil }
            offset += paddedByteCount
            return String(decoding: units, as: UTF16.self)
        }
    }
}
