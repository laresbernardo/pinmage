import Foundation
import ImageIO
import CoreServices
import Darwin

struct MetadataWriter {
    /// The complete, immutable edit request for one file. Built once from the caller's
    /// arguments; the same values drive the no-op decision, the encoder and the readback
    /// check, so they cannot disagree. Removal wins over a set of the same field, as the
    /// encoder always did. A location needs both coordinates, as before.
    struct WritePlan: Equatable {
        let date: Date?
        let latitude: Double?
        let longitude: Double?
        let removeDate: Bool
        let removeLocation: Bool

        init(date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?, removeLocation: Bool) {
            self.removeDate = removeDate
            self.removeLocation = removeLocation
            self.date = removeDate ? nil : date
            if !removeLocation, let latitude = latitude, let longitude = longitude {
                self.latitude = latitude
                self.longitude = longitude
            } else {
                self.latitude = nil
                self.longitude = nil
            }
        }

        var hasLocation: Bool { latitude != nil && longitude != nil }
        /// Nothing to set and nothing to remove: the file has no reason to be re-encoded.
        var isNoOp: Bool { date == nil && !hasLocation && !removeDate && !removeLocation }
    }

    /// Copies image from sourceURL to destinationURL while embedding date and coordinates.
    /// Returns true on success. Refuses multi-frame sources (copy or overwrite):
    /// the encoder writes one image, so accepting them would silently drop frames.
    /// A request with nothing to set or remove never re-encodes: an overwrite leaves the
    /// original untouched and a copy is a byte-for-byte copy of the source.
    static func updateImageMetadata(sourceURL: URL, destinationURL: URL, date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?, removeLocation: Bool) -> Bool {
        let plan = WritePlan(date: date, removeDate: removeDate, latitude: latitude, longitude: longitude, removeLocation: removeLocation)
        let isOverwrite = sourceURL.resolvingSymlinksInPath().standardizedFileURL == destinationURL.resolvingSymlinksInPath().standardizedFileURL
        let targetURL = isOverwrite ? sourceURL.resolvingSymlinksInPath() : destinationURL
        if plan.isNoOp {
            if isOverwrite {
                // Same readable single-image check the write path applies, without any write.
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                      CGImageSourceGetCount(source) == 1,
                      CGImageSourceGetStatus(source) == .statusComplete else { return false }
                return true
            }
            // Copy: verbatim bytes through the same staging, validation and exclusive publish.
            return writeSafely(sourceURL: sourceURL, destinationURL: targetURL, overwrite: false, encode: { temporaryURL in
                do {
                    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                          CGImageSourceGetCount(source) == 1 else { return false }
                    // Data, not copyItem: a symlinked source must yield a regular file.
                    try Data(contentsOf: sourceURL).write(to: temporaryURL)
                    return true
                } catch {
                    return false
                }
            })
        }
        return writeSafely(sourceURL: sourceURL, destinationURL: targetURL, overwrite: isOverwrite, encode: { temporaryURL in
            encodeImageMetadata(sourceURL: sourceURL, destinationURL: temporaryURL, date: plan.date, removeDate: plan.removeDate, latitude: plan.latitude, longitude: plan.longitude, removeLocation: plan.removeLocation)
        }, verify: { stagedURL in verifyIntent(plan, in: stagedURL) })
    }

    /// I03: reads the staged output back through ImageIO, independent of the encoder,
    /// and checks it holds what the plan asked for. Fails closed.
    static func verifyIntent(_ plan: WritePlan, in url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if plan.removeDate {
            if exif?[kCGImagePropertyExifDateTimeOriginal] != nil
                || exif?[kCGImagePropertyExifDateTimeDigitized] != nil
                || tiff?[kCGImagePropertyTIFFDateTime] != nil {
                FileHandle.standardError.write(Data("Readback: date still present after removal\n".utf8))
                return false
            }
        }
        if plan.removeLocation, props[kCGImagePropertyGPSDictionary] != nil {
            FileHandle.standardError.write(Data("Readback: GPS still present after removal\n".utf8))
            return false
        }
        if let date = plan.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let expected = formatter.string(from: date)
            guard let written = exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                  normalizedDateString(written) == expected else {
                FileHandle.standardError.write(Data("Readback: capture date differs from the requested date\n".utf8))
                return false
            }
        }
        if let lat = plan.latitude, let lon = plan.longitude {
            guard let coords = readExistingCoordinates(from: url),
                  abs(coords.latitude - lat) < 0.0001, abs(coords.longitude - lon) < 0.0001 else {
                FileHandle.standardError.write(Data("Readback: coordinates differ from the requested location\n".utf8))
                return false
            }
        }
        return true
    }

    /// Accepts the EXIF layout and the XMP layout ImageIO may report, to second precision.
    private static func normalizedDateString(_ value: String) -> String {
        var text = Array(value.prefix(19))
        if text.count == 19 {
            for index in [4, 7] where text[index] == "-" { text[index] = ":" }
            if text[10] == "T" { text[10] = " " }
        }
        return String(text)
    }

    /// The injected operations let tests simulate encoder, validation and disk failures.
    /// No operation writes to the target until the verified staging file is published.
    static func writeSafely(
        sourceURL: URL,
        destinationURL: URL,
        overwrite: Bool,
        encode: (URL) -> Bool,
        validate: (URL, URL) -> Bool = validateImage,
        verify: (URL) -> Bool = { _ in true },
        publish: (URL, URL, Bool) throws -> Void = publishImage
    ) -> Bool {
        let fileManager = FileManager.default
        // mkdtemp reserves a private sibling directory exclusively, on the target volume.
        var template = Array(destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".pinmage-write-XXXXXX").path.utf8CString)
        guard let directoryPath = mkdtemp(&template) else {
            print("Failed to create metadata staging directory: \(errno)")
            return false
        }
        let stagingDirectory = URL(fileURLWithPath: String(cString: directoryPath), isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        let temporaryURL = stagingDirectory.appendingPathComponent(destinationURL.lastPathComponent)
        do {
            // Snapshot allows refusing an original changed during encoding.
            let originalData = overwrite ? try Data(contentsOf: sourceURL) : nil
            if overwrite {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                      CGImageSourceGetCount(source) == 1 else { return false }
            }
            guard encode(temporaryURL), validate(sourceURL, temporaryURL), verify(temporaryURL) else { return false }
            if overwrite {
                guard try Data(contentsOf: sourceURL) == originalData else { return false }
                let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
                if let permissions = attributes[.posixPermissions] {
                    try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
                }
            }
            // Flush the completed file before making it visible at the target path.
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }
            try handle.synchronize()
            try publish(temporaryURL, destinationURL, overwrite)
            return true
        } catch {
            print("Failed to publish metadata image: \(error)")
            return false
        }
    }

    static func publishImage(_ temporaryURL: URL, _ destinationURL: URL, _ overwrite: Bool) throws {
        let result = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { targetPath in
                if overwrite {
                    // Same-volume POSIX rename atomically replaces the directory entry.
                    return Darwin.rename(sourcePath!, targetPath!)
                }
                // Exclusive rename closes the race between checking and publishing a copy.
                return Darwin.renamex_np(sourcePath!, targetPath!, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func validateImage(_ sourceURL: URL, _ outputURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let output = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceGetCount(source) >= 1,
              CGImageSourceGetCount(output) == 1,
              CGImageSourceGetStatus(output) == .statusComplete,
              let sourceType = CGImageSourceGetType(source),
              let outputType = CGImageSourceGetType(output),
              CFEqual(sourceType, outputType),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let written = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any],
              let sourceWidth = original[kCGImagePropertyPixelWidth] as? NSNumber,
              let sourceHeight = original[kCGImagePropertyPixelHeight] as? NSNumber,
              sourceWidth == (written[kCGImagePropertyPixelWidth] as? NSNumber),
              sourceHeight == (written[kCGImagePropertyPixelHeight] as? NSNumber),
              CGImageSourceCreateImageAtIndex(output, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            print("Metadata output failed format, frame, dimensions or decode validation")
            return false
        }
        return true
    }

    private static func encodeImageMetadata(sourceURL: URL, destinationURL: URL, date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?, removeLocation: Bool) -> Bool {
        // Read file data
        guard let sourceData = try? Data(contentsOf: sourceURL),
              let imageSource = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            print("Failed to create image source from: \(sourceURL)")
            return false
        }
        
        // M15 (multi-frame fidelity): the destination below writes exactly one
        // image (count 1), so a multi-frame source would silently lose its
        // remaining frames. Refuse at the encoder entry for every operation:
        // writeSafely refuses multi-frame overwrites upstream, but a copy to a
        // different destination reached this encoder unchecked.
        guard CGImageSourceGetCount(imageSource) == 1 else {
            FileHandle.standardError.write(Data("Refusing multi-frame image: writing it would drop frames\n".utf8))
            return false
        }

        // Retrieve Uniform Type Identifier (UTI)
        guard let uti = CGImageSourceGetType(imageSource) else {
            print("Failed to get image source type")
            return false
        }
        
        // Create destination writer with lossless compression to avoid quality loss
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0
        ]
        guard let imageDestination = CGImageDestinationCreateWithURL(destinationURL as CFURL, uti, 1, destinationOptions as CFDictionary) else {
            print("Failed to create image destination at: \(destinationURL)")
            return false
        }
        
        // Three write paths, chosen by CI evidence:
        // - PNG/TIFF removal decodes and re-encodes with an explicit
        //   dictionary (below): CI proved CopyImageSource transports the
        //   source's native eXIf chunk untouched, so capture dates survived
        //   an XMP-only removal.
        // - JPEG/HEIC removal and all HEIC writes go through
        //   CGImageDestinationCopyImageSource with a CGImageMetadataRef
        //   (merging disabled): HEIC because AddImageFromSource re-encodes
        //   its pixels (M15, CI "Pixels changed during write in heic");
        //   JPEG/HEIC removal because a lossy re-encode would violate pixel
        //   fidelity. UNVERIFIED: whether CopyImageSource regenerates those
        //   formats' native EXIF containers from the provided metadata or
        //   transports the source's - see verification gaps in the PR notes.
        // - Plain sets on PNG/JPEG/TIFF keep the dictionary path: the app
        //   verifies writes through CGImageSourceCopyPropertiesAtIndex, and
        //   only the dictionary path maps date values back into the native
        //   metadata chunks (CI: XMP-only PNG write fails "Date missing").
        let utiString = uti as String
        let isRemoval = removeDate || removeLocation
        
        if isRemoval && (utiString == "public.png" || utiString == "public.tiff") {
            // Decode + re-encode removal for losslessly re-encodable formats:
            // the output carries only the metadata in this dictionary.
            // Raw pixels are expected to round-trip exactly for PNG/TIFF (the
            // suite asserts raw RGBA equality). Source data not represented in
            // the properties dictionary - custom ancillary chunks, embedded
            // profiles handled outside the image's color space, or auxiliary
            // images - is not carried over; for PNG the XMP carrier is
            // corrected and re-spliced below, and any other uncarried aux
            // chunk refuses the write instead of being silently dropped
            // (M15b, per the reject-what-we-cannot-verify rule). TIFF aux
            // tags beyond the
            // properties dictionaries remain a documented gap. Multi-frame
            // sources are refused at this function's entry (M15).
            guard let decodedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                FileHandle.standardError.write(Data("Failed to decode image for removal write\n".utf8))
                return false
            }
            var removalDict = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
            removalDict.removeValue(forKey: kCGImageDestinationLossyCompressionQuality)
            if removeDate {
                var exifDict = removalDict[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                exifDict.removeValue(forKey: kCGImagePropertyExifDateTimeOriginal)
                exifDict.removeValue(forKey: kCGImagePropertyExifDateTimeDigitized)
                removalDict[kCGImagePropertyExifDictionary] = exifDict
                var tiffDict = removalDict[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                tiffDict.removeValue(forKey: kCGImagePropertyTIFFDateTime)
                removalDict[kCGImagePropertyTIFFDictionary] = tiffDict
            }
            if removeLocation {
                removalDict.removeValue(forKey: kCGImagePropertyGPSDictionary)
            }
            // A mixed request (remove one field, set the other) must still carry the
            // requested values: this branch used to apply only the removals, so the set
            // half was silently dropped. Same EXIF-string form as the dictionary path.
            if !removeDate, let date = date {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                let dateString = formatter.string(from: date)
                var exifDict = removalDict[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                exifDict[kCGImagePropertyExifDateTimeOriginal] = dateString
                exifDict[kCGImagePropertyExifDateTimeDigitized] = dateString
                removalDict[kCGImagePropertyExifDictionary] = exifDict
                var tiffDict = removalDict[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                tiffDict[kCGImagePropertyTIFFDateTime] = dateString
                removalDict[kCGImagePropertyTIFFDictionary] = tiffDict
            }
            if !removeLocation, let lat = latitude, let lon = longitude {
                var gpsDict = removalDict[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
                gpsDict[kCGImagePropertyGPSLatitude] = abs(lat)
                gpsDict[kCGImagePropertyGPSLatitudeRef] = lat >= 0 ? "N" : "S"
                gpsDict[kCGImagePropertyGPSLongitude] = abs(lon)
                gpsDict[kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? "E" : "W"
                removalDict[kCGImagePropertyGPSDictionary] = gpsDict
            }
            CGImageDestinationAddImage(imageDestination, decodedImage, removalDict as CFDictionary)
            guard CGImageDestinationFinalize(imageDestination) else {
                FileHandle.standardError.write(Data("Failed to finalize image destination\n".utf8))
                return false
            }
            if utiString == "public.png" {
                let corrected = correctStagedXMPCarrier(sourceData: sourceData, destinationURL: destinationURL, imageSource: imageSource,
                                                        date: date, removeDate: removeDate, latitude: latitude, longitude: longitude,
                                                        removeLocation: removeLocation, operation: "removal")
                guard corrected.success else { return false }
                guard pngAuxChunksPreserved(source: sourceData, destinationURL: destinationURL, operation: "removal", xmpHandled: corrected.xmpHandled) else { return false }
            }
            // M15b, tag level: this branch rebuilds metadata from the
            // properties dictionary, so every source tag the dictionary
            // surfaces must come back unless the request removed it. Applies
            // to PNG and TIFF; tags the dictionary never surfaces remain a
            // documented gap. Values are not compared: ImageIO may normalize
            // representations without losing information.
            guard let sourceProps = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let stagedSource = CGImageSourceCreateWithURL(destinationURL as CFURL, nil),
                  let stagedProps = CGImageSourceCopyPropertiesAtIndex(stagedSource, 0, nil) as? [CFString: Any] else {
                FileHandle.standardError.write(Data("Refusing \(utiString) removal: could not read back staged metadata\n".utf8))
                return false
            }
            let droppedTags = droppedUntouchedTags(source: sourceProps, output: stagedProps, removeDate: removeDate, removeLocation: removeLocation)
            guard droppedTags.isEmpty else {
                FileHandle.standardError.write(Data("Refusing \(utiString) removal: output would drop untouched tags [\(droppedTags.joined(separator: ", "))]\n".utf8))
                return false
            }
            return true
        }
        
        let useCopyWrite = isRemoval || utiString == "public.heic" || utiString == "public.heif"
        
        if !useCopyWrite {
            // Dictionary path (no removal requested): copy source properties,
            // apply the date/GPS edits in EXIF string form, write with
            // AddImageFromSource which transports compressed data untouched
            // for PNG/JPEG/TIFF and maps values into native chunks.
            var metadataDict = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
            metadataDict.removeValue(forKey: kCGImageDestinationLossyCompressionQuality)
            
            if let date = date {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                let dateString = formatter.string(from: date)
                var exifDict = metadataDict[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                exifDict[kCGImagePropertyExifDateTimeOriginal] = dateString
                exifDict[kCGImagePropertyExifDateTimeDigitized] = dateString
                metadataDict[kCGImagePropertyExifDictionary] = exifDict
                var tiffDict = metadataDict[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                tiffDict[kCGImagePropertyTIFFDateTime] = dateString
                metadataDict[kCGImagePropertyTIFFDictionary] = tiffDict
            }
            if let lat = latitude, let lon = longitude {
                var gpsDict = metadataDict[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
                gpsDict[kCGImagePropertyGPSLatitude] = abs(lat)
                gpsDict[kCGImagePropertyGPSLatitudeRef] = lat >= 0 ? "N" : "S"
                gpsDict[kCGImagePropertyGPSLongitude] = abs(lon)
                gpsDict[kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? "E" : "W"
                metadataDict[kCGImagePropertyGPSDictionary] = gpsDict
            }
            
            CGImageDestinationAddImageFromSource(imageDestination, imageSource, 0, metadataDict as CFDictionary)
            guard CGImageDestinationFinalize(imageDestination) else {
                FileHandle.standardError.write(Data("Failed to finalize image destination\n".utf8))
                return false
            }
            if utiString == "public.png" {
                // Same XMP carrier correction as the removal rebuild path:
                // AddImageFromSource synthesizes an iTXt XMP packet from the
                // written properties, which never matches the source packet
                // byte-wise, so the aux guard refused every metadata-carrying
                // PNG set (CI probe, run 41660381865). The corrected packet
                // keeps exact-payload semantics for every other chunk and is
                // itself verified against the staged file.
                let corrected = correctStagedXMPCarrier(sourceData: sourceData, destinationURL: destinationURL, imageSource: imageSource,
                                                        date: date, removeDate: removeDate, latitude: latitude, longitude: longitude,
                                                        removeLocation: removeLocation, operation: "set")
                guard corrected.success else { return false }
                guard pngAuxChunksPreserved(source: sourceData, destinationURL: destinationURL, operation: "set", xmpHandled: corrected.xmpHandled) else { return false }
            }
            return true
        }
        
        // Build the metadata object for the copy write.
        // CGImageDestinationCopyImageSource requires kCGImageDestinationMetadata
        // to hold a CGImageMetadataRef - a plain properties dictionary fails
        // with kCFErrorDomainCGImageMetadata error 2 ("Invalid type"). Start
        // from the source's own metadata so every untouched tag survives;
        // removed keys cannot come back because merging is disabled below.
        let mutableMetadata: CGMutableImageMetadata
        if let sourceMetadata = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil),
           let metadataCopy = CGImageMetadataCreateMutableCopy(sourceMetadata) {
            mutableMetadata = metadataCopy
        } else {
            mutableMetadata = CGImageMetadataCreateMutable()
        }
        
        guard applyMetadataPlan(mutableMetadata, date: date, removeDate: removeDate,
                                latitude: latitude, longitude: longitude, removeLocation: removeLocation) else {
            return false
        }
        
        // Write the image with the updated metadata properties dictionary.
        // Using the same UTI as the source preserves the original format.
        //
        // CGImageDestinationCopyImageSource transports the source's compressed
        // image data untouched and writes only the provided metadata (merging
        // disabled). This is required twice over:
        // - M17 (honest removal semantics): AddImageFromSource merges the
        //   passed properties over the source metadata instead of replacing
        //   them, so deleted GPS/date keys survived in PNG and JPEG output -
        //   the file kept exactly what the user asked to remove.
        // - M15 (fidelity): the AddImageFromSource path re-encodes HEIC,
        //   silently altering pixels on a plain metadata write.
        // Fail closed: if the destination cannot honor the copy, publish
        // nothing rather than a file with surviving or re-encoded content.
        let copyOptions: [CFString: Any] = [
            kCGImageDestinationMetadata: mutableMetadata,
            kCGImageDestinationMergeMetadata: kCFBooleanFalse as Any,
        ]
        var copyError: Unmanaged<CFError>?
        // CopyImageSource saves the result to the destination itself when it
        // returns; CGImageDestinationFinalize must NOT be called afterward
        // (ImageIO header contract) - the extra call fails and would discard
        // an otherwise successful write.
        guard CGImageDestinationCopyImageSource(imageDestination, imageSource, copyOptions as CFDictionary, &copyError) else {
            // stderr: print() output is block-buffered and lost when the test
            // harness aborts; the CI log needs the real CFError to diagnose.
            let errDesc = copyError?.takeRetainedValue().localizedDescription ?? "unknown"
            FileHandle.standardError.write(Data("Failed to write image with updated metadata: \(errDesc)\n".utf8))
            return false
        }
        
        return true
    }
    
    // MARK: - M15b PNG aux-chunk fidelity

    /// Chunk types a PNG write is proven to reproduce, so their absence from a
    /// re-encoded output is not by itself a loss:
    /// - IHDR/PLTE/IDAT/IEND are structural. Decoding consumes PLTE and tRNS:
    ///   the re-encode writes truecolor pixels and carries transparency in the
    ///   alpha channel, which the pixel-equality tests prove.
    /// - eXIf round-trips through the EXIF/TIFF/GPS property dictionaries
    ///   (asserted by the write and removal tests; on the rebuild path its
    ///   contents are guarded tag by tag, below); pHYs as DPIWidth/DPIHeight
    ///   and iCCP/sRGB/gAMA/cHRM as the decoded color space (both asserted by
    ///   the preservation test).
    /// Every other chunk type carries information the writer cannot represent.
    /// The guard requires each occurrence of such a chunk to survive with its
    /// exact payload; anything less is a silent loss or alteration.
    private static let pngCarriedChunkTypes: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "tRNS",
        "eXIf", "pHYs", "iCCP", "sRGB", "gAMA", "cHRM",
    ]

    /// Every chunk's payload in a PNG byte stream, grouped by type in file
    /// order, or nil when the bytes are not a well-formed PNG (bad signature,
    /// truncated chunk or a missing IEND). Payloads, not just types: a
    /// transported chunk with altered bytes is a loss, and repeated chunks
    /// (sPLT, private chunks) each carry data.
    static func pngChunks(_ data: Data) -> [String: [Data]]? {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count + 12,
              Array(bytes.prefix(signature.count)) == signature else { return nil }
        var chunks: [String: [Data]] = [:]
        var offset = signature.count
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let typeEnd = offset + 8
            let dataEnd = typeEnd + length
            guard let type = String(bytes: bytes[(offset + 4)..<typeEnd], encoding: .ascii),
                  dataEnd + 4 <= bytes.count else { return nil }
            chunks[type, default: []].append(Data(bytes[typeEnd..<dataEnd]))
            offset = dataEnd + 4
            if type == "IEND" { return chunks }
        }
        return nil
    }

    /// Occurrence count per chunk type, derived from pngChunks.
    static func pngChunkTypeCounts(_ data: Data) -> [String: Int]? {
        pngChunks(data)?.mapValues { $0.count }
    }

    /// Aux-chunk loss between two PNG byte streams: each source occurrence of
    /// a chunk the writer is not proven to reproduce needs an identical
    /// payload in the output (multiset match; order between chunks is not
    /// significant). When xmpHandled is set, XMP-carrier iTXt payloads are
    /// excluded both sides because the caller verified the corrected packet
    /// itself. Returns the lost or altered chunks as "type xN", empty when
    /// everything survived, nil when either stream is not a PNG.
    static func pngLostAuxChunks(source: Data, output: Data, xmpHandled: Bool = false) -> [String]? {
        guard let sourceChunks = pngChunks(source),
              let outputChunks = pngChunks(output) else { return nil }
        var lost: [String] = []
        for (type, payloads) in sourceChunks where !pngCarriedChunkTypes.contains(type) {
            // When the rebuild path corrected the XMP carrier, those payloads
            // are verified separately (exact corrected packet); other iTXt
            // keywords still compare payload-exact.
            let sourcePayloads = xmpHandled && type == "iTXt" ? payloads.filter { !isXMPCarrierPayload($0) } : payloads
            let outputPayloads = xmpHandled && type == "iTXt" ? (outputChunks[type] ?? []).filter { !isXMPCarrierPayload($0) } : (outputChunks[type] ?? [])
            var unmatched = sourcePayloads
            for candidate in outputPayloads {
                if let index = unmatched.firstIndex(of: candidate) { unmatched.remove(at: index) }
            }
            if !unmatched.isEmpty { lost.append("\(type) x\(unmatched.count)") }
        }
        return lost.sorted()
    }

    /// M15b: a PNG write must never silently drop or alter an aux chunk. Fails
    /// closed on any loss or on bytes that do not parse as PNG.
    private static func pngAuxChunksPreserved(source sourceData: Data, destinationURL: URL, operation: String, xmpHandled: Bool = false) -> Bool {
        guard let outputData = try? Data(contentsOf: destinationURL),
              let lost = pngLostAuxChunks(source: sourceData, output: outputData, xmpHandled: xmpHandled) else {
            FileHandle.standardError.write(Data("Refusing PNG \(operation): source or staged output did not parse as PNG\n".utf8))
            return false
        }
        guard lost.isEmpty else {
            FileHandle.standardError.write(Data("Refusing PNG \(operation): output would lose or alter chunks [\(lost.joined(separator: ", "))]\n".utf8))
            return false
        }
        return true
    }

    // MARK: - XMP carrier correction (PNG rebuild path)

    /// The PNG XMP carrier: an iTXt chunk whose keyword is this string,
    /// uncompressed (XMP Specification Part 3).
    private static let xmpITXtKeyword = "XML:com.adobe.xmp"

    /// The one metadata transformation both write paths share: removal by
    /// enumerated XMP path (no namespace guessing), then sets in XMP form.
    /// Fail closed on any tag that cannot be removed or created.
    static func applyMetadataPlan(_ mutableMetadata: CGMutableImageMetadata, date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?, removeLocation: Bool) -> Bool {
        // Removal: ImageIO has no remove-by-image-property API, so the real
        // XMP paths are discovered by recursive enumeration (no namespace
        // guessing) and then deleted. A date removal deletes every capture-date
        // representation (EXIF DateTimeOriginal/Digitized, TIFF DateTime); a
        // location removal deletes every GPS tag (exif:GPS* and nested members).
        // Metadata must not be modified during enumeration, so paths are
        // collected first and removed afterwards.
        if removeDate || removeLocation {
            var pathsToRemove: [String] = []
            let enumerateOptions = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
            CGImageMetadataEnumerateTagsUsingBlock(mutableMetadata, nil, enumerateOptions) { path, _ in
                let fullPath = path as String
                let leaf = fullPath.components(separatedBy: "/").last ?? fullPath
                let tagName = leaf.components(separatedBy: ":").last ?? leaf
                // MWG mapping (ImageIO header guidance): TIFF/EXIF DateTime
                // (tag 0x0132) lives in XMP as xmp:ModifyDate - removing the
                // approved TIFF DateTime criterion requires removing it here
                // (CI: "TIFF DateTime survived removal in heic" without it).
                if isRemovalTarget(tagName, removeDate: removeDate, removeLocation: removeLocation) {
                    pathsToRemove.append(fullPath)
                }
                return true
            }
            for removePath in pathsToRemove {
                // Fail closed: a tag that cannot be removed must not publish.
                guard CGImageMetadataRemoveTagWithPath(mutableMetadata, nil, removePath as CFString) else {
                    FileHandle.standardError.write(Data("Failed to remove metadata tag: \(removePath)\n".utf8))
                    return false
                }
            }
        }

        // Date set: writes the standard EXIF/TIFF XMP tags (registered
        // prefixes), which read back into the EXIF/TIFF property dictionaries.
        // Fail closed if any write cannot be created.
        if !removeDate, let date = date {
            let formatter = DateFormatter()
            // XMP date values must be in XMP form (YYYY-MM-DDThh:mm:ss); the
            // EXIF layout "yyyy:MM:dd HH:mm:ss" is not parseable as XMP and the
            // tag is dropped on readback (CI: "Date missing in png", while
            // numeric GPS tags mapped fine).
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let dateString = formatter.string(from: date)
            // MWG mappings (ImageIO header guidance): EXIF DateTimeOriginal
            // lives in XMP as photoshop:DateCreated, DateTimeDigitized as
            // xmp:CreateDate, TIFF DateTime as xmp:ModifyDate. The exif:/tiff:
            // XMP tags are written too for readers that consume them, but
            // ImageIO's own property-dictionary readback follows the MWG
            // mapping (CI: exif:DateTimeOriginal alone read back as missing).
            guard CGImageMetadataSetValueWithPath(mutableMetadata, nil, "photoshop:DateCreated" as CFString, dateString as CFString),
                  CGImageMetadataSetValueWithPath(mutableMetadata, nil, "xmp:CreateDate" as CFString, dateString as CFString),
                  CGImageMetadataSetValueWithPath(mutableMetadata, nil, "xmp:ModifyDate" as CFString, dateString as CFString),
                  CGImageMetadataSetValueWithPath(mutableMetadata, nil, "exif:DateTimeOriginal" as CFString, dateString as CFString),
                  CGImageMetadataSetValueWithPath(mutableMetadata, nil, "exif:DateTimeDigitized" as CFString, dateString as CFString),
                  CGImageMetadataSetValueWithPath(mutableMetadata, nil, "tiff:DateTime" as CFString, dateString as CFString) else {
                FileHandle.standardError.write(Data("Failed to set date metadata\n".utf8))
                return false
            }
        }

        // GPS set: EXIF GPS tags in XMP live in the exif namespace as
        // exif:GPS*; "gps:" is not a registered XMP prefix, so
        // SetValueWithPath would fail to create it.
        if !removeLocation, let lat = latitude, let lon = longitude {
            guard CGImageMetadataSetValueWithPath(mutableMetadata, nil, "exif:GPSLatitude" as CFString, abs(lat) as CFNumber),
                  CGImageMetadataSetValueWithPath(mutableMetadata, nil, "exif:GPSLatitudeRef" as CFString, (lat >= 0 ? "N" : "S") as CFString),
                  CGImageMetadataSetValueWithPath(mutableMetadata, nil, "exif:GPSLongitude" as CFString, abs(lon) as CFNumber),
                  CGImageMetadataSetValueWithPath(mutableMetadata, nil, "exif:GPSLongitudeRef" as CFString, (lon >= 0 ? "E" : "W") as CFString) else {
                FileHandle.standardError.write(Data("Failed to set GPS metadata\n".utf8))
                return false
            }
        }
        return true
    }

    /// True when an iTXt payload is the uncompressed XMP carrier. Payload
    /// layout: keyword, NUL, compression flag, compression method, language
    /// tag NUL, translated keyword NUL, then UTF-8 text.
    private static func isXMPCarrierPayload(_ payload: Data) -> Bool {
        let prefix = Array("\(xmpITXtKeyword)\0".utf8)
        let bytes = [UInt8](payload)
        guard bytes.count > prefix.count + 4, Array(bytes.prefix(prefix.count)) == prefix else { return false }
        return bytes[prefix.count] == 0 && bytes[prefix.count + 1] == 0
    }

    /// PNG CRC (zlib CRC-32 over chunk type + payload) and chunk assembly,
    /// shared by the XMP surgery and the tests.
    static func pngCRC32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        }
        return crc ^ 0xFFFFFFFF
    }

    static func pngChunkBytes(type: String, payload: Data) -> [UInt8]? {
        let typeBytes = Array(type.utf8)
        guard typeBytes.count == 4 else { return nil }
        let payloadBytes = [UInt8](payload)
        let length = UInt32(payloadBytes.count)
        var chunk: [UInt8] = [UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        chunk += typeBytes
        chunk += payloadBytes
        let crc = pngCRC32(typeBytes + payloadBytes)
        chunk += [UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return chunk
    }

    /// XMP carrier correction shared by the removal rebuild and the plain-set
    /// PNG paths: the rewrite must not silently drop the source XMP packet
    /// (v3 CI: "output would lose or alter chunks [iTXt x1]") nor carry it
    /// stale (removed dates/GPS would survive inside XMP, the M17 bug), and
    /// the destination-synthesized carrier on a set never matches the source
    /// packet byte-wise. Replace it with the corrected packet built from the
    /// source's own metadata, staged and verified exactly. Returns whether
    /// the write may proceed and whether the XMP carrier was handled, so the
    /// aux guard verifies it by identity instead of payload comparison.
    private static func correctStagedXMPCarrier(sourceData: Data, destinationURL: URL, imageSource: CGImageSource,
                                                date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?,
                                                removeLocation: Bool, operation: String) -> (success: Bool, xmpHandled: Bool) {
        guard let sourceChunks = pngChunks(sourceData) else {
            FileHandle.standardError.write(Data("Refusing PNG \(operation): source did not parse as PNG\n".utf8))
            return (false, false)
        }
        let sourceXMP = (sourceChunks["iTXt"] ?? []).filter(isXMPCarrierPayload)
        guard sourceXMP.count <= 1 else {
            FileHandle.standardError.write(Data("Refusing PNG \(operation): multiple XMP packets\n".utf8))
            return (false, false)
        }
        guard !sourceXMP.isEmpty else {
            return (true, false)
        }
        // An empty packet means nothing survived the plan, so the carrier is
        // dropped rather than written empty.
        guard let packet = correctedXMPPacket(imageSource: imageSource, date: date, removeDate: removeDate,
                                              latitude: latitude, longitude: longitude, removeLocation: removeLocation),
              let staged = try? Data(contentsOf: destinationURL),
              let replaced = pngReplacingXMPCarrier(staged, correctedPacket: packet.isEmpty ? nil : packet) else {
            FileHandle.standardError.write(Data("Refusing PNG \(operation): could not build or stage the corrected XMP packet\n".utf8))
            return (false, false)
        }
        do {
            try replaced.write(to: destinationURL)
        } catch {
            FileHandle.standardError.write(Data("Refusing PNG \(operation): could not stage the corrected XMP packet\n".utf8))
            return (false, false)
        }
        // Verify the staged file carries exactly the intended packet (none,
        // when the plan emptied it). Chunk payloads include the iTXt header
        // (keyword, NUL, flags, two empty NUL-terminated strings), so the
        // expected payload is the same header the splice wrote plus the
        // packet bytes.
        let carrierHeader = Array("\(xmpITXtKeyword)\0".utf8) + [0, 0, 0, 0]
        let expected: [Data] = packet.isEmpty ? [] : [Data(carrierHeader + [UInt8](packet))]
        guard let finalData = try? Data(contentsOf: destinationURL),
              let finalChunks = pngChunks(finalData),
              (finalChunks["iTXt"] ?? []).filter(isXMPCarrierPayload) == expected else {
            FileHandle.standardError.write(Data("Refusing PNG \(operation): corrected XMP packet did not verify\n".utf8))
            return (false, false)
        }
        return (true, true)
    }

    /// Byte-level surgery on a finished PNG: drop every XMP-carrier iTXt and,
    /// when a corrected packet is given, insert it as a fresh iTXt before
    /// IEND. Returns nil when the bytes are not a well-formed PNG. Chunk
    /// surgery is what the removal rewrite needs: ImageIO synthesizes XMP only
    /// from the properties it is given, so preserving the source packet's
    /// unrelated content requires carrying the packet ourselves.
    static func pngReplacingXMPCarrier(_ data: Data, correctedPacket: Data?) -> Data? {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count + 12,
              Array(bytes.prefix(signature.count)) == signature else { return nil }
        var out: [UInt8] = signature
        var offset = signature.count
        var sawIEND = false
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let typeEnd = offset + 8
            let dataEnd = typeEnd + length
            guard let type = String(bytes: bytes[(offset + 4)..<typeEnd], encoding: .ascii),
                  dataEnd + 4 <= bytes.count else { return nil }
            let payload = Data(bytes[typeEnd..<dataEnd])
            if type == "IEND" {
                if let packet = correctedPacket {
                    var payloadBytes: [UInt8] = Array("\(xmpITXtKeyword)\0".utf8)
                    payloadBytes += [0, 0, 0, 0]
                    payloadBytes += [UInt8](packet)
                    guard let chunk = pngChunkBytes(type: "iTXt", payload: Data(payloadBytes)) else { return nil }
                    out += chunk
                }
                sawIEND = true
            }
            // XMP-carrier iTXt chunks are replaced, not copied.
            if !(type == "iTXt" && isXMPCarrierPayload(payload)) {
                out += bytes[offset..<(dataEnd + 4)]
            }
            offset = dataEnd + 4
            if type == "IEND" { break }
        }
        guard sawIEND else { return nil }
        return Data(out)
    }

    /// The M17 removal predicate, shared by the metadata transform and the
    /// preservation invariant: a date removal deletes every capture-date
    /// representation (the CI-proven alias set: EXIF DateTimeOriginal and
    /// DateTimeDigitized, TIFF DateTime, and the MWG-mapped XMP names
    /// DateCreated, CreateDate, ModifyDate - any namespace); a location
    /// removal deletes every GPS tag (leaf names with the GPS prefix,
    /// including nested members). Tags outside this set are not removal
    /// targets; nonstandard aliases are a documented residual.
    private static func isRemovalTarget(_ leaf: String, removeDate: Bool, removeLocation: Bool) -> Bool {
        (removeDate && ["DateTimeOriginal", "DateTimeDigitized", "DateTime", "DateCreated", "CreateDate", "ModifyDate"].contains(leaf))
            || (removeLocation && leaf.hasPrefix("GPS"))
    }

    /// The XMP paths a plan sets, with their expected values, at the canonical
    /// locations ImageIO's XMP writer provably round-trips. CI probe evidence
    /// (run 41660381865): the serializer carries photoshop:DateCreated,
    /// xmp:CreateDate, xmp:ModifyDate and exif:DateTimeOriginal but omits the
    /// exif:DateTimeDigitized and tiff:DateTime aliases from the packet, so
    /// requiring them here refused every date set. applyMetadataPlan still
    /// writes those aliases into the graph for property-dictionary consumers;
    /// the invariant checks the paths that survive serialization.
    private static func plannedSetValues(date: Date?, latitude: Double?, longitude: Double?) -> [String: CFTypeRef] {
        var expected: [String: CFTypeRef] = [:]
        if let date = date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let dateString = formatter.string(from: date)
            for path in ["photoshop:DateCreated", "xmp:CreateDate", "xmp:ModifyDate", "exif:DateTimeOriginal"] {
                expected[path] = dateString as CFString
            }
        }
        if let lat = latitude, let lon = longitude {
            expected["exif:GPSLatitude"] = abs(lat) as CFNumber
            expected["exif:GPSLatitudeRef"] = (lat >= 0 ? "N" : "S") as CFString
            expected["exif:GPSLongitude"] = abs(lon) as CFNumber
            expected["exif:GPSLongitudeRef"] = (lon >= 0 ? "E" : "W") as CFString
        }
        return expected
    }

    /// CFEqual with a string-form tolerance: a number may round-trip through
    /// XMP as a string without losing information.
    private static func metadataValuesEqual(_ a: CFTypeRef?, _ b: CFTypeRef?) -> Bool {
        switch (a, b) {
        case let (a?, b?): return CFEqual(a, b) || String(describing: a) == String(describing: b)
        case (nil, nil): return true
        default: return false
        }
    }

    /// Every enumerated tag of a metadata graph, keyed by full path.
    private static func metadataTagMap(_ metadata: CGImageMetadata) -> [String: CGImageMetadataTag] {
        var map: [String: CGImageMetadataTag] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            map[path as String] = tag
            return true
        }
        return map
    }

    /// The enforced preservation invariant between the source graph and the
    /// round-tripped corrected graph (serialize + reparse - insertion of a
    /// packet never proves retention). Returns violations; empty means:
    /// - no removal-target leaf survives anywhere in the result, at any path;
    /// - every untouched source tag is present at its path with equal value
    ///   and equal qualifiers (nested/array content included via CFEqual);
    /// - every planned set tag carries the requested value.
    /// Tags the source graph never exposes remain outside this invariant -
    /// that gap is documented, not claimed solved.
    static func xmpPlanViolations(source: CGImageMetadata, result: CGImageMetadata, date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?, removeLocation: Bool) -> [String] {
        let resultTags = metadataTagMap(result)
        let plannedSets = plannedSetValues(date: removeDate ? nil : date,
                                           latitude: removeLocation ? nil : latitude,
                                           longitude: removeLocation ? nil : longitude)
        var violations: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(source, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            let fullPath = path as String
            let leaf = fullPath.components(separatedBy: "/").last ?? fullPath
            let tagName = leaf.components(separatedBy: ":").last ?? leaf
            if isRemovalTarget(tagName, removeDate: removeDate, removeLocation: removeLocation) {
                return true // the result-side sweep below catches survivors
            }
            if let expected = plannedSets[fullPath] {
                guard let resultTag = resultTags[fullPath],
                      metadataValuesEqual(CGImageMetadataTagCopyValue(resultTag), expected) else {
                    violations.append("set value missing or wrong at \(fullPath)")
                    return true
                }
                return true
            }
            guard let resultTag = resultTags[fullPath] else {
                violations.append("lost \(fullPath)")
                return true
            }
            if !metadataValuesEqual(CGImageMetadataTagCopyValue(tag), CGImageMetadataTagCopyValue(resultTag)) {
                violations.append("altered \(fullPath)")
            }
            if !metadataValuesEqual(CGImageMetadataTagCopyQualifiers(tag), CGImageMetadataTagCopyQualifiers(resultTag)) {
                violations.append("qualifiers changed at \(fullPath)")
            }
            return true
        }
        // Planned sets are verified whether or not the source carried the tag:
        // a write must not publish a requested value that never landed.
        for (path, expected) in plannedSets {
            guard let resultTag = resultTags[path],
                  metadataValuesEqual(CGImageMetadataTagCopyValue(resultTag), expected) else {
                violations.append("set value missing or wrong at \(path)")
                continue
            }
        }
        // A removal target anywhere in the result - including a path the
        // source never used - means stale data survived the correction.
        for path in resultTags.keys {
            let leaf = path.components(separatedBy: "/").last ?? path
            let tagName = leaf.components(separatedBy: ":").last ?? leaf
            if isRemovalTarget(tagName, removeDate: removeDate, removeLocation: removeLocation) {
                violations.append("stale removal target at \(path)")
            }
        }
        return violations.sorted()
    }

    /// The corrected XMP packet for a rebuild-path write: the source's full
    /// metadata graph (unknown namespaces preserved) with the requested
    /// removals and sets applied, serialized with ImageIO's own XMP writer.
    /// Empty data means no tags survived the plan (drop the carrier); nil
    /// means the source metadata could not be read, transformed or
    /// serialized - callers treat nil as a refusal, never as "no XMP needed".
    private static func correctedXMPPacket(imageSource: CGImageSource, date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?, removeLocation: Bool) -> Data? {
        guard let sourceMetadata = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil),
              let mutableMetadata = CGImageMetadataCreateMutableCopy(sourceMetadata),
              applyMetadataPlan(mutableMetadata, date: date, removeDate: removeDate,
                                latitude: latitude, longitude: longitude, removeLocation: removeLocation) else {
            return nil
        }
        var tagCount = 0
        CGImageMetadataEnumerateTagsUsingBlock(mutableMetadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { _, _ in
            tagCount += 1
            return true
        }
        guard tagCount > 0 else { return Data() }
        guard let xmpData = CGImageMetadataCreateXMPData(mutableMetadata, nil) else { return nil }
        // Serialization success is not retention: the packet must parse back
        // into a graph that provably preserves every untouched source property.
        guard let reparsed = CGImageMetadataCreateFromXMPData(xmpData) else { return nil }
        let violations = xmpPlanViolations(source: sourceMetadata, result: reparsed, date: date,
                                           removeDate: removeDate, latitude: latitude,
                                           longitude: longitude, removeLocation: removeLocation)
        guard violations.isEmpty else {
            FileHandle.standardError.write(Data("Refusing write: corrected XMP failed preservation checks [\(violations.joined(separator: ", "))]\n".utf8))
            return nil
        }
        return xmpData as Data
    }

    /// Tags a rebuild-from-properties write must not lose. Returns the missing
    /// tag names; empty means every source tag the properties dictionary
    /// surfaced is present in the output, apart from the removals the request
    /// asked for. Presence only: ImageIO may normalize a tag's value
    /// representation without losing its information. Tags the properties
    /// dictionary never surfaces are outside this check and remain a
    /// documented gap.
    static func droppedUntouchedTags(source: [CFString: Any], output: [CFString: Any], removeDate: Bool, removeLocation: Bool) -> [String] {
        var dropped: [String] = []
        let sourceExif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let outputExif = output[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let dateKeys: [CFString] = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized]
        for key in sourceExif.keys where !(removeDate && dateKeys.contains(key)) {
            if outputExif[key] == nil { dropped.append("EXIF.\(key)") }
        }
        let sourceTiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let outputTiff = output[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        // Orientation is exempt: ImageIO may relocate it between the TIFF
        // dictionary and the format-native location (PNG evidence: the
        // TIFF-dict orientation lands in the eXIf chunk). Its value is
        // asserted separately through the top-level kCGImagePropertyOrientation
        // by the preservation test.
        for key in sourceTiff.keys where !(removeDate && key == kCGImagePropertyTIFFDateTime)
            && key != kCGImagePropertyTIFFOrientation {
            if outputTiff[key] == nil { dropped.append("TIFF.\(key)") }
        }
        if !removeLocation, let sourceGps = source[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            let outputGps = output[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
            for key in sourceGps.keys where outputGps[key] == nil {
                dropped.append("GPS.\(key)")
            }
        }
        return dropped.sorted()
    }

    static func readExistingCoordinates(from url: URL) -> (latitude: Double, longitude: Double)? {
        guard let sourceData = try? Data(contentsOf: url),
              let imageSource = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let gpsDict = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else {
            return nil
        }
        
        guard let latNum = gpsDict[kCGImagePropertyGPSLatitude] as? Double,
              let lonNum = gpsDict[kCGImagePropertyGPSLongitude] as? Double else {
            return nil
        }
        
        let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        
        let latitude = latRef == "S" ? -latNum : latNum
        let longitude = lonRef == "W" ? -lonNum : lonNum
        
        return (latitude, longitude)
    }
}
