import Foundation
import ImageIO
import CoreServices
import Darwin
import CryptoKit

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
            // (M15b, per the reject-what-we-cannot-verify rule). For TIFF the
            // byte-level aux guard below refuses any source tag the rebuild
            // would drop or alter (private tags included), with the XMP
            // carrier (tag 700) corrected through the plan-verified XMP
            // machinery. Multi-frame
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
            if utiString == "public.tiff" {
                guard tiffAuxTagsHandled(sourceData: sourceData, destinationURL: destinationURL, imageSource: imageSource,
                                         date: date, removeDate: removeDate, latitude: latitude, longitude: longitude,
                                         removeLocation: removeLocation, operation: "removal") else { return false }
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
        
        // JPEG joins the copy-write route (CI evidence, runs 41686881879 and
        // 41690332177): the dictionary set route drops APP2/APP14 and foreign
        // segments, regenerates Exif (losing MakerNote and private tags) and
        // the Photoshop IRB, and rewrote a quantization table row while
        // transporting the entropy stream - the copy-write route transports
        // all of those byte-exact, so it is the only route the verified
        // guard stack below can clear.
        let useCopyWrite = isRemoval || utiString == "public.heic" || utiString == "public.heif" || utiString == "public.jpeg"
        
        if !useCopyWrite {
            // Dictionary path (no removal requested): copy source properties,
            // apply the date/GPS edits in EXIF string form, write with
            // AddImageFromSource, which maps values into native chunks. CI
            // evidence (run 41683971917): this route preserves decoded pixels
            // on the fixture but rewrites the JPEG quantization tables and
            // drops foreign JPEG segments and unsurfaced TIFF tags, so the
            // byte-level guards below refuse writes it cannot carry; the
            // JPEG set routing itself is being settled against the
            // copy-write route probe.
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
            if utiString == "public.tiff" {
                guard tiffAuxTagsHandled(sourceData: sourceData, destinationURL: destinationURL, imageSource: imageSource,
                                         date: date, removeDate: removeDate, latitude: latitude, longitude: longitude,
                                         removeLocation: removeLocation, operation: "set") else { return false }
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
        if utiString == "public.jpeg" {
            guard jpegWriteVerified(sourceData: sourceData, destinationURL: destinationURL, imageSource: imageSource,
                                    date: date, removeDate: removeDate, latitude: latitude, longitude: longitude,
                                    removeLocation: removeLocation, operation: isRemoval ? "removal" : "set") else { return false }
        }
        if utiString == "public.heic" || utiString == "public.heif" {
            guard heicWriteVerified(sourceData: sourceData, destinationURL: destinationURL, imageSource: imageSource,
                                    date: date, removeDate: removeDate, latitude: latitude, longitude: longitude,
                                    removeLocation: removeLocation, operation: isRemoval ? "removal" : "set") else { return false }
        }
        return true
    }
    

    // MARK: - M15 aux guards: JPEG, TIFF, HEIC (verify-or-refuse)

    /// JPEG marker walk up to the first SOS: (marker, payload) per segment
    /// plus every byte from the end of the SOS segment to the trailing EOI
    /// (entropy-coded data, including later scans). Nil when the bytes are
    /// not a well-formed JPEG. Payload-exact comparison of the segments the
    /// writer is not proven to regenerate is how a write proves it did not
    /// silently drop or alter auxiliary data; comparing the entropy bytes is
    /// how it proves the compressed image was transported, not re-encoded.
    private static func jpegSegments(_ data: Data) -> (segments: [(marker: UInt8, payload: Data)], entropy: Data)? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var segs: [(UInt8, Data)] = []
        var pos = 2
        while pos + 1 < b.count {
            guard b[pos] == 0xFF else { return nil }
            while pos < b.count && b[pos] == 0xFF { pos += 1 }
            guard pos < b.count else { return nil }
            let m = b[pos]; pos += 1
            if m == 0xD8 || m == 0xD9 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) {
                continue
            }
            guard pos + 2 <= b.count else { return nil }
            let len = Int(b[pos]) << 8 | Int(b[pos + 1])
            guard len >= 2, pos + len <= b.count else { return nil }
            segs.append((m, Data(b[(pos + 2)..<(pos + len)])))
            if m == 0xDA {
                let entropyStart = pos + len
                guard b.count >= entropyStart + 2,
                      b[b.count - 2] == 0xFF, b[b.count - 1] == 0xD9 else { return nil }
                return (segs, Data(b[entropyStart..<(b.count - 2)]))
            }
            pos += len
        }
        return nil
    }

    /// Decoded RGBA bytes of a single-frame image. The per-write pixel
    /// fidelity check: exact decoded equality between source and staged
    /// output, route-agnostic, never inferred from fixture evidence.
    private static func rgbaData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(bytes)
    }

    /// Photoshop IRB (APP13 "Photoshop 3.0") 8BIM resource walk, keeping
    /// each resource's complete bytes (signature, id, Pascal name, size,
    /// payload, pad). Strict: nil when the payload does not parse
    /// completely, including a truncated final pad - a resource list we
    /// cannot walk refuses the write rather than passing partially checked.
    private static func irbResources(_ payload: Data) -> [(id: Int, name: Data, payload: Data, bytes: Data)]? {
        let prefix = Data("Photoshop 3.0\0".utf8)
        let b = [UInt8](payload)
        guard b.count >= prefix.count, payload.prefix(prefix.count) == prefix else { return nil }
        var pos = prefix.count
        var out: [(Int, Data, Data, Data)] = []
        while pos < b.count {
            guard pos + 12 <= b.count,
                  b[pos] == 0x38 && b[pos + 1] == 0x42 && b[pos + 2] == 0x49 && b[pos + 3] == 0x4D else { return nil }
            let rid = Int(b[pos + 4]) << 8 | Int(b[pos + 5])
            var p = pos + 6
            let nameLength = Int(b[p])
            p += 1 + nameLength
            if (1 + nameLength) % 2 != 0 { p += 1 }
            guard p + 4 <= b.count else { return nil }
            let size = Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
            p += 4
            let end = p + size + (size % 2)
            guard end <= b.count else { return nil }
            let nameData = nameLength > 0 ? Data(b[(pos + 7)..<(pos + 6 + nameLength)]) : Data()
            out.append((rid, nameData, Data(b[p..<(p + size)]), Data(b[pos..<end])))
            pos = end
        }
        return out
    }

    /// IRB resources whose Adobe-spec semantics are provably free of dates,
    /// locations and user content, so byte-exact reattachment cannot
    /// resurrect or depend on an edited field: JPEG quality (0x0406), grid
    /// and guides (0x0408), print scale (0x0426), pixel aspect ratio
    /// (0x0428). (Adobe Photoshop File Formats Specification, Image
    /// Resources section.) Everything else refuses: IPTC-NAA (0x0404, which
    /// carries IIM date datasets 2:55/2:60/2:62/2:63), Exif copies
    /// (0x0422/0x0423), XMP (0x0424), global altitude (0x0419), thumbnails
    /// (0x0409/0x040C, which can embed a full Exif APP1), the IPTC digest
    /// (0x0425, an XMP<->IPTC sync marker that goes stale under edit) except
    /// in the one verified form below, plug-in and unknown ids. The single
    /// verified digest form is the writer-authored pair of an EMPTY IPTC
    /// resource (zero IIM datasets, so provably no date/location or any
    /// other content) plus a 0x0425 payload proven to be the MD5 of that
    /// exact empty payload: the pair asserts only "XMP is in sync with no
    /// IPTC content", an assertion no date/GPS edit can falsify. A non-empty
    /// Pascal name never makes a resource void: names survive only as part
    /// of the complete reattached bytes, never as a reason to keep or drop.
    private static let irbPreservableResources: Set<Int> = [0x0406, 0x0408, 0x0426, 0x0428]

    /// Replaces the first genuine Photoshop IRB with the given payload;
    /// inserts one after the last APP0/APP1 when the file has none (the
    /// conventional IRB position, keeping compared-segment order stable).
    private static func jpegReplacingAPP13(_ data: Data, payload: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var out = Data([0xFF, 0xD8])
        var pos = 2
        var done = false
        while pos + 1 < b.count {
            guard b[pos] == 0xFF else { return nil }
            let segStart = pos
            while pos < b.count && b[pos] == 0xFF { pos += 1 }
            guard pos < b.count else { return nil }
            let m = b[pos]; pos += 1
            if m == 0xD8 || m == 0xD9 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) {
                out.append(Data(b[segStart..<pos]))
                if m == 0xD9 { return done ? out : nil }
                continue
            }
            guard pos + 2 <= b.count else { return nil }
            let len = Int(b[pos]) << 8 | Int(b[pos + 1])
            guard len >= 2, pos + len <= b.count else { return nil }
            if m == 0xDA {
                out.append(Data(b[segStart...]))
                return done ? out : nil
            }
            let segPayload = Data(b[(pos + 2)..<(pos + len)])
            if !done && ((m == 0xED && segPayload.prefix(14) == Data("Photoshop 3.0\0".utf8))) {
                let plen = payload.count + 2
                out.append(contentsOf: [0xFF, 0xED, UInt8((plen >> 8) & 0xFF), UInt8(plen & 0xFF)])
                out.append(payload)
                done = true
            } else {
                out.append(Data(b[segStart..<(pos + len)]))
                if !done && m != 0xE0 && m != 0xE1 {
                    // Past the APP0/APP1 block without an IRB to replace:
                    // insert at the conventional position.
                    let plen = payload.count + 2
                    var segment = Data([0xFF, 0xED, UInt8((plen >> 8) & 0xFF), UInt8(plen & 0xFF)])
                    segment.append(payload)
                    out.insert(contentsOf: segment, at: out.count - (pos + len - segStart))
                    done = true
                }
            }
            pos += len
        }
        return nil
    }

    /// The intended-change exemptions shared by the TIFF guard and the JPEG
    /// Exif-APP1 compare: only the exact tags the request itself changes.
    private static func intentExemptions(date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?, removeLocation: Bool) -> [String: Set<Int>] {
        var exempt: [String: Set<Int>] = [:]
        if date != nil || removeDate {
            exempt["IFD0", default: []].insert(306)
            exempt["IFD0>34665", default: []].formUnion([36867, 36868])
        }
        if latitude != nil || removeLocation {
            exempt["IFD0>34853", default: []] = [0, 1, 2, 3, 4]
        }
        return exempt
    }

    /// Full JPEG write verification, fail-closed at every step, per actual
    /// input/output - nothing is inferred from fixture evidence:
    /// 1. Both files parse as JPEG. Decoded RGBA and the entropy-coded
    ///    stream are byte-exact; every payload-bearing segment outside the
    ///    semantically-handled APP1/APP13 classes survives payload-exact
    ///    (frame/coding tables, APP0, APP2, APP14, COM, foreign APPn, SOS
    ///    header), as a multiset per marker; only no-payload markers are
    ///    exempt. The compared segments keep their relative order.
    /// 2. Exif APP1 payloads are compared tag by tag through the TIFF
    ///    machinery, with exemptions only for the values the request itself
    ///    changes. MakerNote and private tags the writer drops refuse.
    /// 3. The XMP APP1 packet must equal the plan-verified corrected packet
    ///    (the PNG/TIFF carrier machinery).
    /// 4. A Photoshop IRB is restored from the source's complete 8BIM
    ///    resource bytes and verified byte-exact. Only resources proven
    ///    edit-independent are restored (see irbPreservableResources and
    ///    the verified empty-IPTC + digest pair); anything else refuses.
    ///    Malformed IRB refuses.
    private static func jpegWriteVerified(sourceData: Data, destinationURL: URL, imageSource: CGImageSource,
                                          date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?,
                                          removeLocation: Bool, operation: String) -> Bool {
        let irbPrefix = Data("Photoshop 3.0\0".utf8)
        let exifPrefix = Data("Exif\0\0".utf8)
        let xmpPrefix = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        func refuse(_ message: String) -> Bool {
            FileHandle.standardError.write(Data("Refusing JPEG \(operation): \(message)\n".utf8))
            return false
        }
        guard let source = jpegSegments(sourceData) else {
            return refuse("source did not parse as JPEG")
        }
        // Source IRB: strict parse into complete resource bytes. Only
        // provably edit-independent resources may be restored, as whole
        // verified bytes; everything else refuses.
        var sourceIRBPayload: Data?
        var sourceIRBResources: [(id: Int, name: Data, payload: Data, bytes: Data)] = []
        for (marker, payload) in source.segments where marker == 0xED {
            if payload.prefix(irbPrefix.count) == irbPrefix {
                guard let resources = irbResources(payload) else {
                    return refuse("malformed Photoshop IRB")
                }
                sourceIRBPayload = payload
                sourceIRBResources = resources
                break
            }
        }
        if let irbPayload = sourceIRBPayload {
            let iptcResources = sourceIRBResources.filter { $0.id == 0x0404 }
            guard iptcResources.count <= 1, iptcResources.allSatisfy({ $0.payload.isEmpty }) else {
                return refuse("Photoshop IRB carries a non-empty IPTC-NAA resource whose date/location semantics cannot be verified")
            }
            // A digest resource is preservable only as the verified MD5 of
            // the empty IPTC payload it sits next to (MWG sync semantics);
            // any other digest - or one without its IPTC - refuses.
            let verifiedDigest = iptcResources.count == 1
                ? Data(Insecure.MD5.hash(data: iptcResources[0].payload))
                : nil
            for resource in sourceIRBResources {
                if irbPreservableResources.contains(resource.id) || resource.id == 0x0404 { continue }
                if resource.id == 0x0425, let digest = verifiedDigest, resource.payload == digest { continue }
                return refuse(String(format: "Photoshop IRB carries resource 0x%04X whose semantics under a metadata change are not proven edit-independent", resource.id))
            }
            // Every resource is provably edit-independent, so the source
            // payload as a whole is safe to restore byte-exact over whatever
            // the writer staged; it verifies below like any other field.
            guard let stagedBytes = try? Data(contentsOf: destinationURL),
                  let replaced = jpegReplacingAPP13(stagedBytes, payload: irbPayload) else {
                return refuse("could not stage the source Photoshop IRB")
            }
            do {
                try replaced.write(to: destinationURL)
            } catch {
                return refuse("could not stage the source Photoshop IRB")
            }
        }
        guard let stagedData = try? Data(contentsOf: destinationURL),
              let staged = jpegSegments(stagedData) else {
            return refuse("staged output did not parse as JPEG")
        }
        let stagedIRB = staged.segments.filter { $0.marker == 0xED && $0.payload.prefix(irbPrefix.count) == irbPrefix }.map { $0.payload }
        if let irbPayload = sourceIRBPayload {
            guard stagedIRB == [irbPayload] else {
                return refuse("Photoshop IRB did not verify byte-exact")
            }
        } else {
            guard stagedIRB.isEmpty else {
                return refuse("output gained a Photoshop IRB the source did not have")
            }
        }
        // Compressed stream + decoded pixels, both exact.
        guard source.entropy == staged.entropy else {
            return refuse("compressed image data was re-encoded")
        }
        guard let sourceRGBA = rgbaData(sourceData), let stagedRGBA = rgbaData(stagedData), sourceRGBA == stagedRGBA else {
            return refuse("decoded pixels changed")
        }
        // Classify segments: Exif/XMP/IRB are handled semantically;
        // no-payload markers are exempt; everything else is payload-exact.
        func classified(_ segments: [(marker: UInt8, payload: Data)]) -> (exact: [UInt8: [Data]], order: [UInt8], exif: [Data], xmp: [Data]) {
            var exact: [UInt8: [Data]] = [:]
            var order: [UInt8] = []
            var exif: [Data] = []
            var xmp: [Data] = []
            for (m, payload) in segments {
                if m == 0xD8 || m == 0xD9 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) { continue }
                order.append(m)
                if m == 0xE1 && payload.prefix(exifPrefix.count) == exifPrefix {
                    exif.append(payload)
                } else if m == 0xE1 && payload.prefix(xmpPrefix.count) == xmpPrefix {
                    xmp.append(payload)
                } else if m == 0xED && payload.prefix(irbPrefix.count) == irbPrefix {
                    continue
                } else {
                    exact[m, default: []].append(payload)
                }
            }
            return (exact, order, exif, xmp)
        }
        let sourceParts = classified(source.segments)
        let stagedParts = classified(staged.segments)
        // Exact class: marker-multiset equality in both directions.
        let markers = Set(sourceParts.exact.keys).union(stagedParts.exact.keys)
        for marker in markers.sorted() {
            let srcPayloads = sourceParts.exact[marker] ?? []
            let stgPayloads = stagedParts.exact[marker] ?? []
            guard srcPayloads.count == stgPayloads.count else {
                return refuse(String(format: "segment FF%02X count changed (%d -> %d)", marker, srcPayloads.count, stgPayloads.count))
            }
            let sortPayloads: ([Data]) -> [[UInt8]] = { $0.map { Array($0) }.sorted { $0.lexicographicallyPrecedes($1) } }
            guard sortPayloads(srcPayloads) == sortPayloads(stgPayloads) else {
                return refuse(String(format: "segment FF%02X payload changed", marker))
            }
        }
        // Relative order of compared segments is preserved.
        var searchFrom = 0
        for marker in sourceParts.order {
            guard let found = stagedParts.order[searchFrom...].firstIndex(of: marker) else {
                return refuse(String(format: "segment order changed at FF%02X", marker))
            }
            searchFrom = found + 1
        }
        // Exif APP1: tag-level compare, intent exemptions only.
        guard sourceParts.exif.count == stagedParts.exif.count else {
            return refuse("Exif APP1 segment count changed")
        }
        for (sourcePayload, stagedPayload) in zip(sourceParts.exif, stagedParts.exif) {
            guard let violations = tiffAuxTagViolations(sourceData: sourcePayload.dropFirst(exifPrefix.count),
                                                        outputData: stagedPayload.dropFirst(exifPrefix.count),
                                                        exempt: intentExemptions(date: date, removeDate: removeDate,
                                                                                 latitude: latitude, longitude: longitude,
                                                                                 removeLocation: removeLocation)) else {
                return refuse("Exif payload did not parse")
            }
            guard violations.isEmpty else {
                return refuse("Exif would lose or alter tags [\(violations.joined(separator: ", "))]")
            }
        }
        // XMP APP1 carriers: at most one each side; a lost carrier or
        // duplicates refuse. When the source carries XMP, the staged packet
        // must match the plan-verified corrected packet. ImageIO ADDS one
        // XMP carrier when the source had none (both routes): that packet
        // is the destination writer's serialization of the same
        // plan-applied graph correctedXMPacket builds, so it must be
        // graph-equal to the verified corrected packet (run 41706940975:
        // it carries the intent values, not just dimensions). The only
        // tags admitted on top are ImageIO's own synthesis, each verified
        // positively: iio:hasXMP (must be true) and the pixel-dimension
        // pair (must equal the decoded source pixels). Anything else
        // refuses. verifyIntent independently proves the requested
        // metadata before publication regardless.
        guard sourceParts.xmp.count <= 1, stagedParts.xmp.count <= 1 else {
            return refuse("unsupported multiple XMP APP1 carriers")
        }
        if sourceParts.xmp.count == 1 {
            guard stagedParts.xmp.count == 1 else {
                return refuse("XMP APP1 carrier lost")
            }
            guard let expectedPacket = correctedXMPPacket(imageSource: imageSource, date: date, removeDate: removeDate,
                                                           latitude: latitude, longitude: longitude, removeLocation: removeLocation),
                  !expectedPacket.isEmpty,
                  let stagedGraph = CGImageMetadataCreateFromXMPData(Data(stagedParts.xmp[0].dropFirst(xmpPrefix.count)) as CFData),
                  let expectedGraph = CGImageMetadataCreateFromXMPData(expectedPacket as CFData) else {
                return refuse("staged XMP packet failed verification")
            }
            let violations = xmpPlanViolations(source: expectedGraph, result: stagedGraph,
                                               date: nil, removeDate: false, latitude: nil, longitude: nil, removeLocation: false)
            guard violations.isEmpty else {
                return refuse("staged XMP packet differs from the verified packet [\(violations.joined(separator: ", "))]")
            }
        } else if stagedParts.xmp.count == 1 {
            guard let addedGraph = CGImageMetadataCreateFromXMPData(Data(stagedParts.xmp[0].dropFirst(xmpPrefix.count)) as CFData) else {
                return refuse("added XMP APP1 carrier did not parse")
            }
            var expectedMap: [String: CGImageMetadataTag] = [:]
            if let expectedPacket = correctedXMPPacket(imageSource: imageSource, date: date, removeDate: removeDate,
                                                       latitude: latitude, longitude: longitude, removeLocation: removeLocation),
               !expectedPacket.isEmpty,
               let expectedGraph = CGImageMetadataCreateFromXMPData(expectedPacket as CFData) {
                expectedMap = metadataTagMap(expectedGraph)
                let violations = xmpPlanViolations(source: expectedGraph, result: addedGraph,
                                                   date: nil, removeDate: false, latitude: nil, longitude: nil, removeLocation: false)
                guard violations.isEmpty else {
                    return refuse("added XMP APP1 carrier differs from the verified packet [\(violations.joined(separator: ", "))]")
                }
            }
            guard let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
                return refuse("source properties did not parse")
            }
            var extras: [String] = []
            for (path, tag) in metadataTagMap(addedGraph) where expectedMap[path] == nil {
                let value = CGImageMetadataTagCopyValue(tag)
                if path == "iio:hasXMP", let b = value as? NSNumber, b.boolValue { continue }
                if path == "iio:hasXMP", (value as? String) == "True" { continue }
                if path == "exif:PixelXDimension", xmpNumericValue(value) == Double(width) { continue }
                if path == "exif:PixelYDimension", xmpNumericValue(value) == Double(height) { continue }
                extras.append("\(path)=\(String(describing: value))")
            }
            guard extras.isEmpty else {
                return refuse("added XMP APP1 carrier carries unverified tags [\(extras.joined(separator: "; "))]")
            }
        }
        return true
    }

    /// TIFF IFD walk with resolved values: (label, entries, next offset) per
    /// IFD, following the Exif/GPS/Interop sub-IFD pointers, endianness from
    /// the header. Comparing resolved values ignores file layout (offsets
    /// move legitimately between writes) and checks tag content.
    private static func tiffIFDs(_ data: Data) -> (little: Bool, ifds: [(label: String, entries: [(tag: Int, type: Int, count: Int, value: Data?, raw: Data)], next: Int)])? {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }
        let little: Bool
        if b[0] == 0x49 && b[1] == 0x49 { little = true }
        else if b[0] == 0x4D && b[1] == 0x4D { little = false }
        else { return nil }
        func u16(_ o: Int) -> Int {
            little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])
        }
        func u32(_ o: Int) -> Int {
            little ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
                   : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        guard u16(2) == 42 else { return nil }
        let typeSizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]
        var ifds: [(String, [(tag: Int, type: Int, count: Int, value: Data?, raw: Data)], Int)] = []
        // Strict: any truncation or unreasonable structure fails the whole
        // parse, and the guards refuse - no partially-checked files.
        var parseFailed = false
        func readIFD(_ off: Int, _ label: String, _ depth: Int) {
            guard off > 0, off + 2 <= b.count, depth <= 4 else {
                parseFailed = true
                return
            }
            let n = u16(off)
            let base = off + 2
            guard base + 12 * n + 4 <= b.count else {
                parseFailed = true
                return
            }
            var entries: [(tag: Int, type: Int, count: Int, value: Data?, raw: Data)] = []
            for i in 0..<n {
                let ent = base + 12 * i
                let tag = u16(ent)
                let typ = u16(ent + 2)
                let cnt = u32(ent + 4)
                let size = (typeSizes[typ] ?? 1) * cnt
                let value: Data?
                if size <= 4 {
                    value = Data(b[(ent + 8)..<(ent + 8 + size)])
                } else {
                    let voff = u32(ent + 8)
                    value = voff + size <= b.count ? Data(b[voff..<(voff + size)]) : nil
                }
                entries.append((tag, typ, cnt, value, Data(b[ent..<(ent + 12)])))
            }
            let next = u32(base + 12 * n)
            ifds.append((label, entries, next))
            for entry in entries where entry.tag == 34665 || entry.tag == 34853 || entry.tag == 40965 {
                guard let inline = entry.value, inline.count >= 4 else { continue }
                let voff = little
                    ? Int(inline[0]) | Int(inline[1]) << 8 | Int(inline[2]) << 16 | Int(inline[3]) << 24
                    : Int(inline[0]) << 24 | Int(inline[1]) << 16 | Int(inline[2]) << 8 | Int(inline[3])
                readIFD(voff, "\(label)>\(entry.tag)", depth + 1)
            }
            if next != 0 { readIFD(next, label + "+next", depth + 1) }
        }
        readIFD(u32(4), "IFD0", 0)
        guard !parseFailed else { return nil }
        return (little, ifds)
    }

    /// Tags whose values are file layout, not content (strip/tile offsets
    /// and byte counts): presence is required, the value is not compared.
    /// Sub-IFD pointers are not checked at all - the sub-IFD contents are
    /// guarded by label, and a fully-exempted sub-IFD may legitimately vanish.
    private static let tiffLayoutTags: Set<Int> = [273, 279, 324, 325, 513, 514]

    /// Every source tag outside the layout/regenerated/exempt sets must
    /// survive in the same IFD with the same type and exact resolved value.
    /// Returns the violations; nil when either file does not parse.
    private static func tiffAuxTagViolations(sourceData: Data, outputData: Data, exempt: [String: Set<Int>]) -> [String]? {
        guard let source = tiffIFDs(sourceData), let output = tiffIFDs(outputData) else { return nil }
        var outValues: [String: [Int: [(Int, Data)]]] = [:]
        for (label, entries, _) in output.ifds {
            for entry in entries {
                if let value = entry.value {
                    outValues[label, default: [:]][entry.tag, default: []].append((entry.type, value))
                }
            }
        }
        var outPresent: Set<String> = []
        for (label, entries, _) in output.ifds {
            for entry in entries { outPresent.insert("\(label)#\(entry.tag)") }
        }
        var violations: [String] = []
        for (label, entries, _) in source.ifds {
            let exemptHere = exempt[label] ?? []
            for entry in entries {
                if exemptHere.contains(entry.tag) { continue }
                if entry.tag == 34665 || entry.tag == 34853 || entry.tag == 40965 { continue }
                if tiffLayoutTags.contains(entry.tag) {
                    if !outPresent.contains("\(label)#\(entry.tag)") {
                        violations.append("layout tag \(entry.tag) missing at \(label)")
                    }
                    continue
                }
                guard let value = entry.value else {
                    violations.append("tag \(entry.tag) unreadable at \(label)")
                    continue
                }
                let candidates = outValues[label]?[entry.tag] ?? []
                if !candidates.contains(where: { $0.0 == entry.type && $0.1 == value }) {
                    violations.append("tag \(entry.tag) missing or altered at \(label)")
                }
            }
        }
        return violations
    }

    /// Rebuilds the output's IFD0 at EOF with tag 700 replaced by the
    /// corrected XMP packet (or dropped when the packet is empty) and repoints
    /// the header. Every original entry byte stays valid because nothing in
    /// the file moves; only the IFD0 pointer and the appended data change.
    /// Tag 700's value is an offset-free blob, so this is the one tag that can
    /// be reattached safely after correction - arbitrary private tags are
    /// refused by the guard instead of reattached (an opaque payload could
    /// embed exactly the values a removal targets).
    private static func tiffReplacingTag700(_ data: Data, correctedPacket: Data?) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }
        let little: Bool
        if b[0] == 0x49 && b[1] == 0x49 { little = true }
        else if b[0] == 0x4D && b[1] == 0x4D { little = false }
        else { return nil }
        func u16(_ o: Int) -> Int {
            little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])
        }
        func u32(_ o: Int) -> Int {
            little ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
                   : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        func put16(_ d: inout Data, _ v: Int) {
            if little { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
            else { d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF)) }
        }
        func put32(_ d: inout Data, _ v: Int) {
            if little { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF)) }
            else { d.append(UInt8((v >> 24) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF)) }
        }
        guard u16(2) == 42 else { return nil }
        let ifd0 = u32(4)
        guard ifd0 > 0, ifd0 + 2 <= b.count else { return nil }
        let n = u16(ifd0)
        let base = ifd0 + 2
        guard base + 12 * n + 4 <= b.count else { return nil }
        var entries: [(Int, Data)] = []
        var had700 = false
        for i in 0..<n {
            let ent = base + 12 * i
            let tag = u16(ent)
            if tag == 700 {
                had700 = true
                continue
            }
            entries.append((tag, Data(b[ent..<(ent + 12)])))
        }
        let willHave700 = correctedPacket != nil && !(correctedPacket?.isEmpty ?? true)
        let newCount = entries.count + (willHave700 ? 1 : 0)
        guard had700 || willHave700 else { return data }
        var out = Data(b)
        let newIFD = out.count
        let valueOff = newIFD + 2 + 12 * newCount + 4
        var ifd = Data()
        put16(&ifd, newCount)
        var inserted = false
        for (tag, raw) in entries.sorted(by: { $0.0 < $1.0 }) {
            if willHave700 && !inserted && tag > 700 {
                put16(&ifd, 700); put16(&ifd, 7); put32(&ifd, correctedPacket!.count); put32(&ifd, valueOff)
                inserted = true
            }
            ifd.append(raw)
        }
        if willHave700 && !inserted {
            put16(&ifd, 700); put16(&ifd, 7); put32(&ifd, correctedPacket!.count); put32(&ifd, valueOff)
        }
        ifd.append(Data(b[(base + 12 * n)..<(base + 12 * n + 4)]))
        var headerFix = Data()
        put32(&headerFix, newIFD)
        out.replaceSubrange(4..<8, with: headerFix)
        out.append(ifd)
        if let packet = correctedPacket, !packet.isEmpty {
            out.append(packet)
            if packet.count % 2 != 0 { out.append(0) }
        }
        return out
    }

    /// TIFF aux handling shared by the removal rebuild and the plain-set
    /// paths. The XMP carrier (tag 700) is never carried stale: it gets the
    /// corrected packet from the plan-verified XMP machinery or is dropped.
    /// Every other source tag outside the layout/regenerated/exempt sets must
    /// survive with its exact resolved value; anything less refuses the
    /// write - no arbitrary private-tag reattach, since an opaque payload
    /// could embed exactly the values a removal targets.
    private static func tiffAuxTagsHandled(sourceData: Data, destinationURL: URL, imageSource: CGImageSource,
                                           date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?,
                                           removeLocation: Bool, operation: String) -> Bool {
        var exempt = intentExemptions(date: date, removeDate: removeDate,
                                      latitude: latitude, longitude: longitude, removeLocation: removeLocation)
        guard let sourceIFDs = tiffIFDs(sourceData) else {
            FileHandle.standardError.write(Data("Refusing TIFF \(operation): source did not parse as TIFF\n".utf8))
            return false
        }
        let sourceHas700 = sourceIFDs.ifds.contains { label, entries, _ in
            label == "IFD0" && entries.contains { $0.tag == 700 }
        }
        if sourceHas700 { exempt["IFD0", default: []].insert(700) }
        if sourceHas700 {
            guard let packet = correctedXMPPacket(imageSource: imageSource, date: date, removeDate: removeDate,
                                                  latitude: latitude, longitude: longitude, removeLocation: removeLocation) else {
                FileHandle.standardError.write(Data("Refusing TIFF \(operation): corrected XMP failed preservation checks\n".utf8))
                return false
            }
            guard let stagedData = try? Data(contentsOf: destinationURL),
                  let replaced = tiffReplacingTag700(stagedData, correctedPacket: packet.isEmpty ? nil : packet) else {
                FileHandle.standardError.write(Data("Refusing TIFF \(operation): could not stage the corrected tag 700\n".utf8))
                return false
            }
            do {
                try replaced.write(to: destinationURL)
            } catch {
                FileHandle.standardError.write(Data("Refusing TIFF \(operation): could not stage the corrected tag 700\n".utf8))
                return false
            }
            // Verify the staged tag 700 carries exactly the corrected packet
            // (or is gone when the corrections emptied it).
            guard let finalData = try? Data(contentsOf: destinationURL),
                  let finalIFDs = tiffIFDs(finalData) else {
                FileHandle.standardError.write(Data("Refusing TIFF \(operation): corrected tag 700 did not verify\n".utf8))
                return false
            }
            let final700 = finalIFDs.ifds.first { label, _, _ in label == "IFD0" }?.entries.filter { $0.tag == 700 } ?? []
            let expected700: [Data] = packet.isEmpty ? [] : [packet]
            guard final700.compactMap({ $0.value }) == expected700 else {
                FileHandle.standardError.write(Data("Refusing TIFF \(operation): corrected tag 700 did not verify\n".utf8))
                return false
            }
        }
        guard let finalData = try? Data(contentsOf: destinationURL),
              let violations = tiffAuxTagViolations(sourceData: sourceData, outputData: finalData, exempt: exempt) else {
            FileHandle.standardError.write(Data("Refusing TIFF \(operation): source or staged output did not parse as TIFF\n".utf8))
            return false
        }
        guard violations.isEmpty else {
            FileHandle.standardError.write(Data("Refusing TIFF \(operation): output would lose or alter tags [\(violations.joined(separator: ", "))]\n".utf8))
            return false
        }
        // Pixel fidelity per actual input/output: the layout tags are only
        // presence-checked, so decoded RGBA equality is what verifies the
        // strip/tile offsets and counts still point at intact pixel data.
        guard let sourceRGBA = rgbaData(sourceData), let stagedRGBA = rgbaData(finalData), sourceRGBA == stagedRGBA else {
            FileHandle.standardError.write(Data("Refusing TIFF \(operation): decoded pixels changed\n".utf8))
            return false
        }
        return true
    }

    /// Top-level ISOBMFF box walk: (type, payload). Nil when the bytes do
    /// not parse as boxes.
    /// ISOBMFF box walk over a byte range: (type, payload, payload range)
    /// per box, the range expressed in the walked data's own coordinates.
    /// Strict: nil on any structural violation.
    private static func heicBoxes(_ data: Data, range: Range<Int>) -> [(type: String, payload: Data, range: Range<Int>)]? {
        let b = [UInt8](data)
        guard range.lowerBound >= 0, range.upperBound <= b.count else { return nil }
        var boxes: [(String, Data, Range<Int>)] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            var size = Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
            guard let type = String(bytes: b[(pos + 4)..<(pos + 8)], encoding: .ascii) else { return nil }
            var header = 8
            if size == 1 {
                guard pos + 16 <= range.upperBound else { return nil }
                size = Int(b[pos + 8]) << 56 | Int(b[pos + 9]) << 48 | Int(b[pos + 10]) << 40 | Int(b[pos + 11]) << 32
                     | Int(b[pos + 12]) << 24 | Int(b[pos + 13]) << 16 | Int(b[pos + 14]) << 8 | Int(b[pos + 15])
                header = 16
            } else if size == 0 {
                size = range.upperBound - pos
            }
            guard size >= header, pos + size <= range.upperBound else { return nil }
            boxes.append((type, Data(b[(pos + header)..<(pos + size)]), (pos + header)..<(pos + size)))
            pos += size
        }
        guard pos == range.upperBound else { return nil }
        return boxes
    }

    /// pitm payload -> primary item id. Strict: version 0 or 1.
    private static func heicPrimaryItem(_ payload: Data) -> Int? {
        let b = [UInt8](payload)
        guard b.count >= 6 else { return nil }
        if b[0] == 0 { return Int(b[4]) << 8 | Int(b[5]) }
        guard b[0] == 1, b.count >= 8 else { return nil }
        return Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
    }

    /// iinf payload -> (id, item_type, mime content_type) per infe entry.
    /// Strict: v2/v3 entries only - the finite shape the writer produces;
    /// older or unknown entry forms refuse rather than pass half-parsed.
    private static func heicIinfItems(_ payload: Data) -> [(id: Int, type: String, contentType: String?)]? {
        let b = [UInt8](payload)
        guard b.count >= 6 else { return nil }
        let count: Int
        let header: Int
        if b[0] == 0 {
            count = Int(b[4]) << 8 | Int(b[5]); header = 6
        } else {
            guard b.count >= 8 else { return nil }
            count = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7]); header = 8
        }
        guard let subs = heicBoxes(payload, range: header..<b.count), subs.count == count else { return nil }
        var items: [(Int, String, String?)] = []
        for sub in subs {
            guard sub.type == "infe" else { return nil }
            let p = [UInt8](sub.payload)
            guard p.count >= 4 else { return nil }
            let entryVersion = p[0]
            guard entryVersion == 2 || entryVersion == 3 else { return nil }
            var o = 4
            let itemID: Int
            if entryVersion == 2 {
                guard o + 2 <= p.count else { return nil }
                itemID = Int(p[o]) << 8 | Int(p[o + 1]); o += 2
            } else {
                guard o + 4 <= p.count else { return nil }
                itemID = Int(p[o]) << 24 | Int(p[o + 1]) << 16 | Int(p[o + 2]) << 8 | Int(p[o + 3]); o += 4
            }
            guard o + 6 <= p.count else { return nil }
            o += 2 // item_protection_index
            guard let itemType = String(bytes: p[o..<(o + 4)], encoding: .ascii) else { return nil }
            o += 4
            guard o <= p.count, let nameEnd = p[o...].firstIndex(of: 0) else { return nil }
            var contentType: String? = nil
            if itemType == "mime" {
                let cstart = nameEnd + 1
                guard cstart <= p.count, let cend = p[cstart...].firstIndex(of: 0) else { return nil }
                contentType = String(bytes: p[cstart..<cend], encoding: .utf8)
            }
            items.append((itemID, itemType, contentType))
        }
        return items
    }

    /// iinf payload -> raw infe box payloads (without size/type headers), or
    /// nil when the strict v0/v1 layout does not parse. Byte-exact entry
    /// comparison uses this; semantic parsing stays with heicIinfItems.
    private static func heicIinfEntryPayloads(_ payload: Data) -> [Data]? {
        let b = [UInt8](payload)
        guard b.count >= 6 else { return nil }
        let header = b[0] == 0 ? 6 : 8
        guard b.count >= header else { return nil }
        guard let subs = heicBoxes(payload, range: header..<b.count),
              subs.allSatisfy({ $0.type == "infe" }) else { return nil }
        return subs.map { $0.payload }
    }

    /// Full structural inventory of a source/staged HEIC pair for CI
    /// refusal evidence: top-level boxes, ftyp bytes, meta children, parsed
    /// items, references, iloc extents and the non-primary item payloads
    /// (hex, capped). Diagnostic only; the sole caller is the
    /// artifact-dir-gated refusal path, so it never runs in the app.
    private static func heicDiagnosticInventory(source: Data, staged: Data) -> String {
        var out = ""
        func describe(_ label: String, _ data: Data) {
            out += "== heic-diag \(label): \(data.count) bytes\n"
            guard let top = heicBoxes(data, range: 0..<data.count) else {
                out += "== heic-diag \(label): top-level parse failed\n"
                return
            }
            var topDesc: [String] = []
            for box in top { topDesc.append("\(box.type)+\(box.payload.count)") }
            out += "== heic-diag \(label) top: " + topDesc.joined(separator: " ") + "\n"
            if let ftyp = top.first(where: { $0.type == "ftyp" }) {
                out += "== heic-diag \(label) ftyp: " + ftyp.payload.map { String(format: "%02x", $0) }.joined() + "\n"
            }
            guard let meta = top.first(where: { $0.type == "meta" }), meta.payload.count >= 4,
                  let children = heicBoxes(meta.payload, range: 4..<meta.payload.count) else {
                out += "== heic-diag \(label): meta children parse failed\n"
                return
            }
            var childDesc: [String] = []
            for child in children { childDesc.append("\(child.type)+\(child.payload.count)") }
            out += "== heic-diag \(label) meta: " + childDesc.joined(separator: " ") + "\n"
            var primary = -1
            if let pitm = children.first(where: { $0.type == "pitm" }), let p = heicPrimaryItem(pitm.payload) {
                primary = p
            }
            if let iinf = children.first(where: { $0.type == "iinf" }),
               let items = heicIinfItems(iinf.payload) {
                var itemDesc: [String] = []
                for item in items { itemDesc.append("id=\(item.id):\(item.type):\(item.contentType ?? "-")") }
                out += "== heic-diag \(label) items: " + itemDesc.joined(separator: " ") + "\n"
            }
            if let iref = children.first(where: { $0.type == "iref" }),
               let refs = heicReferences(iref.payload) {
                var refDesc: [String] = []
                for ref in refs { refDesc.append("\(ref.type) \(ref.from)->\(ref.to)") }
                out += "== heic-diag \(label) refs: " + refDesc.joined(separator: " ") + "\n"
            }
            guard let iloc = children.first(where: { $0.type == "iloc" }),
                  let located = heicExtents(iloc.payload) else {
                out += "== heic-diag \(label): iloc parse failed\n"
                return
            }
            var ilocDesc: [String] = []
            for item in located {
                var extDesc: [String] = []
                for extent in item.extents { extDesc.append("@\(extent.offset)+\(extent.length)") }
                ilocDesc.append("id=\(item.id) m=\(item.method) d=\(item.dref) " + extDesc.joined(separator: ","))
            }
            out += "== heic-diag \(label) iloc: " + ilocDesc.joined(separator: " ") + "\n"
            let mdatRanges = top.filter { $0.type == "mdat" }.map { $0.range }
            let b = [UInt8](data)
            for item in located where item.id != primary {
                guard item.method == 0, item.dref == 0 else { continue }
                var payload = Data()
                var readable = true
                for extent in item.extents {
                    guard extent.offset >= 0, extent.length >= 0, extent.offset + extent.length <= b.count,
                          mdatRanges.contains(where: { extent.offset >= $0.lowerBound && extent.offset + extent.length <= $0.upperBound }) else {
                        readable = false
                        break
                    }
                    payload.append(Data(b[extent.offset..<(extent.offset + extent.length)]))
                }
                guard readable, !payload.isEmpty, payload.count <= 8192 else { continue }
                let hex = payload.map { String(format: "%02x", $0) }.joined()
                out += "== heic-diag \(label) item \(item.id) payload (\(payload.count) bytes): \(hex)\n"
            }
        }
        describe("source", source)
        describe("staged", staged)
        return out
    }

    /// iref payload -> (reference type, from id, to ids) per reference.
    /// Strict: v0 (16-bit ids) and v1 (32-bit ids); from_item_ID precedes
    /// reference_count (ISO/IEC 14496-12 SingleItemTypeReferenceBox).
    private static func heicReferences(_ payload: Data) -> [(type: String, from: Int, to: [Int])]? {
        let b = [UInt8](payload)
        guard b.count >= 4, b[0] <= 1 else { return nil }
        let idLength = b[0] == 1 ? 4 : 2
        guard let subs = heicBoxes(payload, range: 4..<b.count) else { return nil }
        var refs: [(String, Int, [Int])] = []
        for sub in subs {
            let p = [UInt8](sub.payload)
            var o = 0
            while o < p.count {
                guard o + idLength + 2 <= p.count else { return nil }
                let from = idLength == 2 ? Int(p[o]) << 8 | Int(p[o + 1])
                                         : Int(p[o]) << 24 | Int(p[o + 1]) << 16 | Int(p[o + 2]) << 8 | Int(p[o + 3])
                o += idLength
                let count = Int(p[o]) << 8 | Int(p[o + 1]); o += 2
                guard o + count * idLength <= p.count else { return nil }
                var tos: [Int] = []
                for _ in 0..<count {
                    tos.append(idLength == 2 ? Int(p[o]) << 8 | Int(p[o + 1])
                                             : Int(p[o]) << 24 | Int(p[o + 1]) << 16 | Int(p[o + 2]) << 8 | Int(p[o + 3]))
                    o += idLength
                }
                refs.append((sub.type, from, tos))
            }
        }
        return refs
    }

    /// iloc payload -> (id, construction method, data reference index,
    /// extents) per item; extent offsets resolved to base + offset.
    /// Strict: version 0-2, field sizes 0/4/8, trailing bytes refuse.
    private static func heicExtents(_ payload: Data) -> [(id: Int, method: Int, dref: Int, extents: [(offset: Int, length: Int)])]? {
        let b = [UInt8](payload)
        guard b.count >= 8, b[0] <= 2 else { return nil }
        let version = Int(b[0])
        let offsetSize = Int(b[4] >> 4), lengthSize = Int(b[4] & 0xF)
        let baseOffsetSize = Int(b[5] >> 4)
        let indexSize = version >= 1 ? Int(b[5] & 0xF) : 0
        for size in [offsetSize, lengthSize, baseOffsetSize, indexSize] {
            guard size == 0 || size == 4 || size == 8 else { return nil }
        }
        var o = 6
        let count: Int
        if version < 2 {
            guard o + 2 <= b.count else { return nil }
            count = Int(b[o]) << 8 | Int(b[o + 1]); o += 2
        } else {
            guard o + 4 <= b.count else { return nil }
            count = Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]); o += 4
        }
        var items: [(Int, Int, Int, [(Int, Int)])] = []
        for _ in 0..<count {
            let idLength = version < 2 ? 2 : 4
            guard o + idLength <= b.count else { return nil }
            let itemID = idLength == 2 ? Int(b[o]) << 8 | Int(b[o + 1])
                                       : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
            o += idLength
            var method = 0
            if version >= 1 {
                guard o + 2 <= b.count else { return nil }
                method = Int(b[o + 1]) & 0xF
                o += 2
            }
            guard o + 2 <= b.count else { return nil }
            let dref = Int(b[o]) << 8 | Int(b[o + 1])
            o += 2 // data_reference_index
            var base = 0
            if baseOffsetSize > 0 {
                guard o + baseOffsetSize <= b.count else { return nil }
                for i in 0..<baseOffsetSize { base = base << 8 | Int(b[o + i]) }
                o += baseOffsetSize
            }
            guard o + 2 <= b.count else { return nil }
            let extentCount = Int(b[o]) << 8 | Int(b[o + 1]); o += 2
            var extents: [(Int, Int)] = []
            for _ in 0..<extentCount {
                if indexSize > 0 {
                    guard o + indexSize <= b.count else { return nil }
                    o += indexSize
                }
                guard o + offsetSize + lengthSize <= b.count else { return nil }
                var offset = 0
                for i in 0..<offsetSize { offset = offset << 8 | Int(b[o + i]) }
                o += offsetSize
                var length = 0
                for i in 0..<lengthSize { length = length << 8 | Int(b[o + i]) }
                o += lengthSize
                extents.append((base + offset, length))
            }
            items.append((itemID, method, dref, extents))
        }
        guard o == b.count else { return nil }
        return items
    }

    /// HEIC write verification, fail-closed per actual input/output
    /// (structure decoded in evidence runs 41683971917 and 41690332177):
    /// - ftyp and any top-level box outside meta/mdat survive payload-exact
    ///   per occurrence, and the output gains none.
    /// - meta: version/flags payload-exact; hdlr/pitm/iinf/iref/iprp/dinf
    ///   payload-exact; an unknown child refuses.
    /// - Verified plain-still shape: exactly one hvc1 primary item; every
    ///   other iinf item is Exif or mime 'application/rdf+xml'; iref holds
    ///   only cdsc content references from those items to the primary, one
    ///   per item. auxl/dimg/thmb references, unknown item types and any
    ///   other reference shape refuse.
    /// - iloc is verified structurally (extent offsets legitimately move):
    ///   item ids match iinf exactly, construction method 0 only, every
    ///   extent inside an mdat payload. The hvc1 payload is byte-exact; the
    ///   Exif item's TIFF stream is compared tag by tag with intent
    ///   exemptions only; the XMP item graph-matches the plan-verified
    ///   corrected packet. idat-backed items refuse.
    /// Rebuilds the staged file with the source's own ftyp box, shifting
    /// every later byte and adjusting the staged iloc's absolute offsets by
    /// the size delta. Returns nil unless every precondition holds: ftyp is
    /// the first box on both sides, exactly one meta with one iloc, and the
    /// iloc adjustment succeeds. Only ftyp placement is assumed; everything
    /// else is re-verified against the result by the full guard.
    private static func heicRestoringSourceFtyp(sourceData: Data, stagedData: Data) -> Data? {
        func firstBox(_ data: Data, _ type: String) -> (box: Data, boxEnd: Int)? {
            let b = [UInt8](data)
            guard b.count >= 8 else { return nil }
            var size = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard let t = String(bytes: b[4..<8], encoding: .ascii), t == type else { return nil }
            let header: Int
            if size == 1 {
                guard b.count >= 16 else { return nil }
                size = Int(b[8]) << 56 | Int(b[9]) << 48 | Int(b[10]) << 40 | Int(b[11]) << 32
                     | Int(b[12]) << 24 | Int(b[13]) << 16 | Int(b[14]) << 8 | Int(b[15])
                header = 16
            } else {
                header = 8
                if size == 0 { size = b.count }
            }
            guard size >= header, size <= b.count else { return nil }
            return (Data(b[0..<size]), size)
        }
        guard let sourceFtyp = firstBox(sourceData, "ftyp"),
              let stagedFtyp = firstBox(stagedData, "ftyp") else { return nil }
        let delta = sourceFtyp.box.count - stagedFtyp.boxEnd
        var out = Data(sourceFtyp.box)
        out.append(stagedData[stagedFtyp.boxEnd...])
        guard delta != 0 else { return out }
        // Only ftyp/meta/mdat may sit at the top level for the transplant:
        // any other box (fidx, free, uuid, ...) could carry file offsets or
        // layout the shift would invalidate - refuse those writes instead.
        guard let stagedBoxes = heicBoxes(stagedData, range: 0..<stagedData.count),
              stagedBoxes.allSatisfy({ $0.type == "ftyp" || $0.type == "meta" || $0.type == "mdat" }),
              stagedBoxes.filter({ $0.type == "meta" }).count == 1,
              let metaBox = stagedBoxes.first(where: { $0.type == "meta" }),
              metaBox.payload.count >= 4,
              let children = heicBoxes(metaBox.payload, range: 4..<metaBox.payload.count),
              children.filter({ $0.type == "iloc" }).count == 1,
              let iloc = children.first(where: { $0.type == "iloc" }),
              let adjusted = adjustIlocOffsets([UInt8](iloc.payload), delta: delta) else { return nil }
        // iloc.range is relative to the meta payload (which starts at 4 in
        // that buffer); the shift moves everything after the staged ftyp.
        let ilocStartInOut = sourceFtyp.box.count + (metaBox.range.lowerBound + iloc.range.lowerBound - stagedFtyp.boxEnd)
        guard ilocStartInOut >= 0, ilocStartInOut + adjusted.count <= out.count else { return nil }
        out.replaceSubrange(ilocStartInOut..<(ilocStartInOut + adjusted.count), with: adjusted)
        return out
    }

    /// iloc payload -> per-item field positions for in-place edits (raw
    /// base/offset values plus where each field sits in the payload).
    /// Same structural limits as heicExtents; nil on malformed payloads.
    private typealias HeicIlocLayout = (id: Int, method: Int, dref: Int,
                                        basePos: Int?, baseSize: Int, base: Int,
                                        extents: [(offPos: Int?, offSize: Int, offset: Int,
                                                   lenPos: Int, lenSize: Int, length: Int)])
    private static func heicIlocLayout(_ payload: Data) -> [HeicIlocLayout]? {
        let b = [UInt8](payload)
        guard b.count >= 8, b[0] <= 2 else { return nil }
        let version = Int(b[0])
        let offsetSize = Int(b[4] >> 4), lengthSize = Int(b[4] & 0xF)
        let baseOffsetSize = Int(b[5] >> 4)
        let indexSize = version >= 1 ? Int(b[5] & 0xF) : 0
        for size in [offsetSize, lengthSize, baseOffsetSize, indexSize] {
            guard size == 0 || size == 4 || size == 8 else { return nil }
        }
        func read(_ o: Int, _ n: Int) -> Int { var v = 0; for i in 0..<n { v = v << 8 | Int(b[o + i]) }; return v }
        var o = 6
        let count: Int
        if version < 2 {
            guard o + 2 <= b.count else { return nil }
            count = read(o, 2); o += 2
        } else {
            guard o + 4 <= b.count else { return nil }
            count = read(o, 4); o += 4
        }
        var items: [HeicIlocLayout] = []
        for _ in 0..<count {
            let idLength = version < 2 ? 2 : 4
            guard o + idLength <= b.count else { return nil }
            let itemID = read(o, idLength); o += idLength
            var method = 0
            if version >= 1 {
                guard o + 2 <= b.count else { return nil }
                method = Int(b[o + 1]) & 0xF; o += 2
            }
            guard o + 2 <= b.count else { return nil }
            let dref = read(o, 2); o += 2
            guard o + baseOffsetSize <= b.count else { return nil }
            let basePos: Int? = baseOffsetSize > 0 ? o : nil
            let base = read(o, baseOffsetSize); o += baseOffsetSize
            guard o + 2 <= b.count else { return nil }
            let extentCount = read(o, 2); o += 2
            var extents: [(offPos: Int?, offSize: Int, offset: Int, lenPos: Int, lenSize: Int, length: Int)] = []
            for _ in 0..<extentCount {
                o += indexSize
                guard o + offsetSize + lengthSize <= b.count else { return nil }
                let offPos: Int? = offsetSize > 0 ? o : nil
                let offset = read(o, offsetSize); o += offsetSize
                let lenPos = o
                let length = read(o, lengthSize); o += lengthSize
                extents.append((offPos, offsetSize, offset, lenPos, lengthSize, length))
            }
            items.append((itemID, method, dref, basePos, baseOffsetSize, base, extents))
        }
        guard o == b.count else { return nil }
        return items
    }

    /// Replace one item's payload in a staged HEIC byte stream: splice the
    /// new bytes in at the item's single extent, rewrite that extent's iloc
    /// length, shift every extent that starts after the splice point, and
    /// grow the containing mdat's size field. Candidate surgery, never an
    /// exemption: callers must still run the full verification on the
    /// result. nil (no splice) unless the layout is the verified one: top
    /// level only ftyp/meta/mdat, one meta, one iloc, every item method 0 /
    /// data reference 0, the target item single-extent with a nonzero
    /// length, the iloc payload entirely before the splice point, and no
    /// item straddling the splice with a base offset (a base shifts the
    /// whole item, so a straddling base item cannot be adjusted).
    private static func heicSplicingItemPayload(_ whole: Data, itemID: Int, newPayload: Data) -> Data? {
        guard let boxes = heicBoxes(whole, range: 0..<whole.count),
              boxes.allSatisfy({ $0.type == "ftyp" || $0.type == "meta" || $0.type == "mdat" }) else { return nil }
        let metas = boxes.filter { $0.type == "meta" }
        guard metas.count == 1, metas[0].payload.count >= 4,
              let children = heicBoxes(metas[0].payload, range: 4..<metas[0].payload.count) else { return nil }
        let ilocs = children.filter { $0.type == "iloc" }
        guard ilocs.count == 1,
              let layout = heicIlocLayout(ilocs[0].payload),
              layout.allSatisfy({ $0.method == 0 && $0.dref == 0 }) else { return nil }
        let targets = layout.filter { $0.id == itemID }
        guard targets.count == 1, targets[0].extents.count == 1 else { return nil }
        let target = targets[0]
        let oldLength = target.extents[0].length
        guard oldLength > 0 else { return nil }
        let splice = target.base + target.extents[0].offset
        let delta = newPayload.count - oldLength
        // iloc.range is relative to the meta payload; the iloc payload must
        // sit entirely before the splice point so patching it in place is
        // valid after bytes move.
        let ilocStart = metas[0].range.lowerBound + ilocs[0].range.lowerBound
        let ilocEnd = ilocStart + ilocs[0].payload.count
        guard ilocEnd <= splice, splice + oldLength <= whole.count else { return nil }
        var outIloc = [UInt8](ilocs[0].payload)
        func write(_ pos: Int, _ n: Int, _ v: Int) -> Bool {
            guard v >= 0, n > 0, n == 8 || v < (1 << (8 * n)) else { return false }
            for i in 0..<n { outIloc[pos + n - 1 - i] = UInt8((v >> (8 * i)) & 0xFF) }
            return true
        }
        guard write(target.extents[0].lenPos, target.extents[0].lenSize, newPayload.count) else { return nil }
        for item in layout {
            let after = item.extents.map { item.base + $0.offset > splice }
            guard after.contains(true) else { continue }
            if let basePos = item.basePos {
                guard after.allSatisfy({ $0 }) else { return nil }
                guard write(basePos, item.baseSize, item.base + delta) else { return nil }
            } else {
                for (extent, isAfter) in zip(item.extents, after) where isAfter {
                    guard let offPos = extent.offPos,
                          write(offPos, extent.offSize, extent.offset + delta) else { return nil }
                }
            }
        }
        var out = Data(whole.prefix(splice))
        out.append(newPayload)
        out.append(whole[(splice + oldLength)...])
        out.replaceSubrange(ilocStart..<ilocEnd, with: outIloc)
        // Grow the mdat header containing the spliced extent. Box starts
        // derive from parse order, so 8- and 16-byte headers are exact.
        let b = [UInt8](whole)
        var boxStart = 0
        var updatedSize = false
        for box in boxes {
            let start = boxStart
            boxStart = box.range.upperBound
            guard box.type == "mdat", start <= splice, splice + oldLength <= box.range.upperBound else { continue }
            let header = box.range.lowerBound - start
            if header == 16 {
                var size = 0
                for i in 0..<8 { size = size << 8 | Int(b[start + 8 + i]) }
                guard size + delta >= 0 else { return nil }
                var sized = [UInt8](repeating: 0, count: 8)
                for i in 0..<8 { sized[7 - i] = UInt8(((size + delta) >> (8 * i)) & 0xFF) }
                out.replaceSubrange((start + 8)..<(start + 16), with: sized)
                updatedSize = true
            } else if header == 8 {
                var size = 0
                for i in 0..<4 { size = size << 8 | Int(b[start + i]) }
                if size == 0 {
                    updatedSize = true // to-EOF mdat: no size field to update
                } else {
                    guard size + delta >= 0, size + delta < (1 << 32) else { return nil }
                    var sized = [UInt8](repeating: 0, count: 4)
                    for i in 0..<4 { sized[3 - i] = UInt8(((size + delta) >> (8 * i)) & 0xFF) }
                    out.replaceSubrange(start..<(start + 4), with: sized)
                    updatedSize = true
                }
            } else {
                return nil
            }
            break
        }
        guard updatedSize else { return nil }
        return out
    }

    /// ImageIO writes a reduced XMP mime item on HEIC copy-writes (observed
    /// run 41705293732: the staged packet lost exif:DateTimeOriginal,
    /// tiff:Orientation, tiff:TileWidth and tiff:TileLength). Restore the
    /// verified corrected packet as the staged mime item's payload via
    /// heicSplicingItemPayload. nil when the staged file carries no single
    /// XMP mime item or the layout does not support the splice - the full
    /// verification then decides the write as before.
    private static func heicRestoringXmpItem(stagedData: Data, imageSource: CGImageSource,
                                             date: Date?, removeDate: Bool,
                                             latitude: Double?, longitude: Double?, removeLocation: Bool) -> Data? {
        guard let boxes = heicBoxes(stagedData, range: 0..<stagedData.count),
              boxes.allSatisfy({ $0.type == "ftyp" || $0.type == "meta" || $0.type == "mdat" }) else { return nil }
        let metas = boxes.filter { $0.type == "meta" }
        guard metas.count == 1, metas[0].payload.count >= 4,
              let children = heicBoxes(metas[0].payload, range: 4..<metas[0].payload.count) else { return nil }
        let iinfs = children.filter { $0.type == "iinf" }
        guard iinfs.count == 1, let items = heicIinfItems(iinfs[0].payload) else { return nil }
        let mimeIDs = items.filter { $0.type == "mime" && $0.contentType == "application/rdf+xml" }.map { $0.id }
        guard mimeIDs.count == 1 else { return nil }
        guard let packet = correctedXMPPacket(imageSource: imageSource, date: date, removeDate: removeDate,
                                              latitude: latitude, longitude: longitude, removeLocation: removeLocation),
              !packet.isEmpty else { return nil }
        guard let spliced = heicSplicingItemPayload(stagedData, itemID: mimeIDs[0], newPayload: packet) else {
            FileHandle.standardError.write(Data("HEIC note: staged XMP item layout does not support verified-packet restore; verification decides\n".utf8))
            return nil
        }
        return spliced
    }

    /// Strict ftyp parse: major brand, minor version, compatible brands.
    private static func heicFtypBrands(_ payload: Data) -> (major: String, minor: UInt32, brands: [String])? {
        let b = [UInt8](payload)
        guard b.count >= 8, (b.count - 8) % 4 == 0,
              let major = String(bytes: b[0..<4], encoding: .ascii) else { return nil }
        let minor = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        var brands: [String] = []
        var o = 8
        while o + 4 <= b.count {
            guard let brand = String(bytes: b[o..<(o + 4)], encoding: .ascii) else { return nil }
            brands.append(brand)
            o += 4
        }
        return (major, minor, brands)
    }

    /// Shifts an iloc payload's absolute file offsets by delta, editing
    /// fixed-width fields in place. absolute = base_offset + extent_offset,
    /// so the shift goes to the base when a base field exists, otherwise to
    /// each extent offset - never both. Refuses non-file construction
    /// methods, zero-length extents (unverified semantics), field overflow,
    /// and trailing bytes. Field widths 0/4/8 only, versions 0-2, matching
    /// the verifier's parser.
    private static func adjustIlocOffsets(_ payload: [UInt8], delta: Int) -> [UInt8]? {
        let b = payload
        guard b.count >= 8, b[0] <= 2 else { return nil }
        let version = Int(b[0])
        let offsetSize = Int(b[4] >> 4), lengthSize = Int(b[4] & 0xF)
        let baseOffsetSize = Int(b[5] >> 4)
        let indexSize = version >= 1 ? Int(b[5] & 0xF) : 0
        for size in [offsetSize, lengthSize, baseOffsetSize, indexSize] {
            guard size == 0 || size == 4 || size == 8 else { return nil }
        }
        var out = b
        func read(_ o: Int, _ n: Int) -> Int { var v = 0; for i in 0..<n { v = v << 8 | Int(b[o + i]) }; return v }
        func write(_ o: Int, _ n: Int, _ v: Int) -> Bool {
            guard v >= 0, n > 0, n == 8 || v < (1 << (8 * n)) else { return false }
            for i in 0..<n { out[o + n - 1 - i] = UInt8((v >> (8 * i)) & 0xFF) }
            return true
        }
        var o = 6
        let count: Int
        if version < 2 {
            guard o + 2 <= b.count else { return nil }
            count = read(o, 2); o += 2
        } else {
            guard o + 4 <= b.count else { return nil }
            count = read(o, 4); o += 4
        }
        for _ in 0..<count {
            let idLength = version < 2 ? 2 : 4
            guard o + idLength <= b.count else { return nil }
            o += idLength
            if version >= 1 {
                guard o + 2 <= b.count else { return nil }
                guard Int(b[o + 1]) & 0xF == 0 else { return nil }
                o += 2
            }
            guard o + 2 <= b.count else { return nil }
            o += 2 // data_reference_index
            let hasBase = baseOffsetSize > 0
            if hasBase {
                guard o + baseOffsetSize <= b.count else { return nil }
                guard write(o, baseOffsetSize, read(o, baseOffsetSize) + delta) else { return nil }
                o += baseOffsetSize
            }
            guard o + 2 <= b.count else { return nil }
            let extentCount = read(o, 2); o += 2
            for _ in 0..<extentCount {
                if indexSize > 0 {
                    guard o + indexSize <= b.count else { return nil }
                    o += indexSize
                }
                guard o + offsetSize + lengthSize <= b.count else { return nil }
                if offsetSize > 0 && !hasBase {
                    guard write(o, offsetSize, read(o, offsetSize) + delta) else { return nil }
                }
                o += offsetSize
                let length = read(o, lengthSize)
                guard length > 0 else { return nil }
                o += lengthSize
            }
        }
        guard o == b.count else { return nil }
        return out
    }

    /// Verifies an Exif item ImageIO added to a HEIC output when the source
    /// carried no Exif item (observed real payload, run 41716235473: IFD0
    /// {Orientation, DateTime, TileWidth, TileLength, sub-IFD pointers},
    /// ExifIFD {DateTimeOriginal, DateTimeDigitized}, GPSIFD
    /// {refs + rational coordinates}). Admission: every tag must be an intent
    /// tag holding the requested value or a positively verified synthesized
    /// value; intent-set date/location tags must all be present; a source
    /// orientation must never be dropped or silently reset (the tag must
    /// equal it - the hardcoded expectation of 1 applies only when the
    /// source declares no orientation); unknown or duplicate tags, unknown
    /// or chained IFDs refuse.
    ///
    /// GPS rationals are compared NUMERICALLY (composed degrees at 1e-9)
    /// with explicit bounds - zero denominators refuse, composed magnitudes
    /// must be finite and within their axis range (90/180) - because ImageIO
    /// emits non-canonical DMS (observed 40/1 23/1 6000/100, seconds == 60,
    /// which normalizes to exactly 40.4). This is deliberately looser in
    /// form, never in value, than the XMP string parser, which stays
    /// strictly canonical; the TIFF path accepts only values composing to
    /// the exact requested degrees.
    static func verifyAddedExifCarrier(
        tiff: Data,
        date: Date?, removeDate: Bool,
        latitude: Double?, longitude: Double?, removeLocation: Bool,
        pixelWidth: Int?, pixelHeight: Int?, sourceOrientation: Int?
    ) -> (ok: Bool, detail: String) {
        guard let parsed = tiffIFDs(tiff) else {
            return (false, "not a parseable TIFF structure")
        }
        typealias TIFFEntry = (tag: Int, type: Int, count: Int, value: Data?, raw: Data)
        let little = parsed.little
        func exifASCII(_ entry: TIFFEntry) -> String? {
            guard entry.type == 2, let v = entry.value else { return nil }
            var bytes = [UInt8](v)
            while bytes.last == 0 { bytes.removeLast() }
            return String(bytes: bytes, encoding: .utf8)
        }
        func exifUInt(_ entry: TIFFEntry) -> Int? {
            guard let v = entry.value else { return nil }
            let vb = [UInt8](v)
            if entry.type == 3, vb.count == 2 {
                return little ? Int(vb[0]) | Int(vb[1]) << 8 : Int(vb[0]) << 8 | Int(vb[1])
            }
            if entry.type == 4, vb.count == 4 {
                return little ? Int(vb[0]) | Int(vb[1]) << 8 | Int(vb[2]) << 16 | Int(vb[3]) << 24
                              : Int(vb[0]) << 24 | Int(vb[1]) << 16 | Int(vb[2]) << 8 | Int(vb[3])
            }
            return nil
        }
        func exifRationalDegrees(_ entry: TIFFEntry) -> Double? {
            guard entry.type == 5, entry.count >= 1, entry.count <= 3,
                  let v = entry.value, v.count == 8 * entry.count else { return nil }
            let vb = [UInt8](v)
            func u32(_ o: Int) -> Int {
                little ? Int(vb[o]) | Int(vb[o + 1]) << 8 | Int(vb[o + 2]) << 16 | Int(vb[o + 3]) << 24
                       : Int(vb[o]) << 24 | Int(vb[o + 1]) << 16 | Int(vb[o + 2]) << 8 | Int(vb[o + 3])
            }
            var result = 0.0
            var divisor = 1.0
            for i in 0..<entry.count {
                let denominator = u32(8 * i + 4)
                guard denominator != 0 else { return nil }
                result += Double(u32(8 * i)) / Double(denominator) / divisor
                divisor *= 60
            }
            guard result.isFinite else { return nil }
            return result
        }
        let wantDate = date != nil && !removeDate
        let wantLocation = latitude != nil && longitude != nil && !removeLocation
        let tiffDateFormatter = DateFormatter()
        tiffDateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let expectedDate = wantDate ? date.map { tiffDateFormatter.string(from: $0) } : nil
        let expectedOrientation = sourceOrientation ?? 1
        var addedTags: Set<String> = []
        for (label, entries, next) in parsed.ifds {
            guard next == 0 else {
                return (false, "chained IFD at \(label)")
            }
            for entry in entries {
                let key = "\(label)#\(entry.tag)"
                guard addedTags.insert(key).inserted else {
                    return (false, "duplicate tag \(key)")
                }
                switch (label, entry.tag) {
                case ("IFD0", 274):
                    guard exifUInt(entry) == expectedOrientation else {
                        return (false, "Orientation \(exifUInt(entry) ?? -1) != \(expectedOrientation)")
                    }
                case ("IFD0", 306), ("IFD0>34665", 36867), ("IFD0>34665", 36868):
                    guard let expected = expectedDate, exifASCII(entry) == expected else {
                        return (false, "date tag \(entry.tag) does not carry the intent date")
                    }
                case ("IFD0", 322):
                    guard let width = pixelWidth, exifUInt(entry) == width else {
                        return (false, "TileWidth is not the decoded width")
                    }
                case ("IFD0", 323):
                    guard let height = pixelHeight, exifUInt(entry) == height else {
                        return (false, "TileLength is not the decoded height")
                    }
                case ("IFD0", 34665), ("IFD0", 34853):
                    continue // sub-IFD contents are checked by label
                case ("IFD0>34853", 1):
                    guard let lat = latitude, wantLocation, abs(lat) <= 90,
                          exifASCII(entry) == (lat >= 0 ? "N" : "S") else {
                        return (false, "GPSLatitudeRef does not match the intent")
                    }
                case ("IFD0>34853", 2):
                    guard let lat = latitude, wantLocation, abs(lat) <= 90,
                          let degrees = exifRationalDegrees(entry),
                          degrees <= 90, abs(degrees - abs(lat)) < 1e-9 else {
                        return (false, "GPSLatitude does not match the intent")
                    }
                case ("IFD0>34853", 3):
                    guard let lon = longitude, wantLocation, abs(lon) <= 180,
                          exifASCII(entry) == (lon >= 0 ? "E" : "W") else {
                        return (false, "GPSLongitudeRef does not match the intent")
                    }
                case ("IFD0>34853", 4):
                    guard let lon = longitude, wantLocation, abs(lon) <= 180,
                          let degrees = exifRationalDegrees(entry),
                          degrees <= 180, abs(degrees - abs(lon)) < 1e-9 else {
                        return (false, "GPSLongitude does not match the intent")
                    }
                default:
                    return (false, "unverified tag \(entry.tag) at \(label)")
                }
            }
        }
        if wantDate {
            for key in ["IFD0#306", "IFD0>34665#36867", "IFD0>34665#36868"] {
                guard addedTags.contains(key) else {
                    return (false, "missing intent date tag \(key)")
                }
            }
        }
        if wantLocation {
            for key in ["IFD0>34853#1", "IFD0>34853#2", "IFD0>34853#3", "IFD0>34853#4"] {
                guard addedTags.contains(key) else {
                    return (false, "missing intent location tag \(key)")
                }
            }
        }
        if let orientation = sourceOrientation, !addedTags.contains("IFD0#274") {
            return (false, "source Orientation \(orientation) was dropped")
        }
        return (true, "")
    }

    private static func heicWriteVerified(sourceData: Data, destinationURL: URL, imageSource: CGImageSource,
                                          date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?,
                                          removeLocation: Bool, operation: String) -> Bool {
        // Full structural evidence is CI-only: PRESERVATION_ARTIFACT_DIR is
        // set by the workflow and never by the app, so a CI refusal dumps
        // both box structures and the synthetic fixture bytes for one-run
        // diagnosis; in the app a refusal stays the single line above.
        var stagedDataForDump: Data? = nil
        func refuse(_ message: String) -> Bool {
            FileHandle.standardError.write(Data("Refusing HEIC \(operation): \(message)\n".utf8))
            if let dir = ProcessInfo.processInfo.environment["PRESERVATION_ARTIFACT_DIR"],
               let staged = stagedDataForDump {
                let report = heicDiagnosticInventory(source: sourceData, staged: staged)
                FileHandle.standardError.write(Data(report.utf8))
                let base = URL(fileURLWithPath: dir)
                let stamp = "\(operation)-\(UUID().uuidString)"
                try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                try? sourceData.write(to: base.appendingPathComponent("heic-refusal-\(stamp)-source.bin"))
                try? staged.write(to: base.appendingPathComponent("heic-refusal-\(stamp)-staged.bin"))
                try? ("Refusing HEIC \(operation): \(message)\n" + report)
                    .write(to: base.appendingPathComponent("heic-refusal-\(stamp).txt"), atomically: true, encoding: .utf8)
            }
            return false
        }
        typealias Box = (type: String, payload: Data, range: Range<Int>)
        let sortPayloads: ([Data]) -> [[UInt8]] = { $0.map { Array($0) }.sorted { $0.lexicographicallyPrecedes($1) } }
        func multiset(_ boxes: [Box], excluding: Set<String>) -> [String: [Data]] {
            var byType: [String: [Data]] = [:]
            for box in boxes where !excluding.contains(box.type) {
                byType[box.type, default: []].append(box.payload)
            }
            return byType
        }
        guard let sourceBoxes = heicBoxes(sourceData, range: 0..<sourceData.count) else {
            return refuse("source did not parse as boxes")
        }
        guard var stagedData = try? Data(contentsOf: destinationURL) else {
            return refuse("staged output did not parse as boxes")
        }
        stagedDataForDump = stagedData
        // ImageIO rewrites the ftyp brand list on every copy-write (observed
        // run 41697547199: source heic|mif1,MiPr,miaf,MiHB,heic -> staged
        // heic|heic,mif1). The staged content is verified equivalent to the
        // source everywhere else by the checks below, so the source's own
        // conformance declarations remain true of it. Transplant the source
        // ftyp onto the staged file and shift every later byte, adjusting
        // iloc absolute offsets - the only file offsets in the verified
        // plain-still shape. The transplant is a candidate, never an
        // exemption: the result must still pass every check below.
        if let patched = heicRestoringSourceFtyp(sourceData: sourceData, stagedData: stagedData), patched != stagedData {
            do {
                try patched.write(to: destinationURL)
                stagedData = patched
                stagedDataForDump = stagedData
            } catch {
                return refuse("could not stage the source ftyp")
            }
        }
        // ImageIO also rewrites the XMP mime item on HEIC copy-writes
        // (observed run 41705293732: the staged packet lost
        // exif:DateTimeOriginal, tiff:Orientation, tiff:TileWidth and
        // tiff:TileLength). Replace the staged mime item's payload with the
        // verified corrected packet, adjusting iloc and the containing mdat.
        // Same candidate discipline as the ftyp transplant above: the spliced
        // file must still pass every check below, including the packet-graph
        // comparison, which re-verifies the restored packet itself.
        if let patched = heicRestoringXmpItem(stagedData: stagedData, imageSource: imageSource,
                                              date: date, removeDate: removeDate,
                                              latitude: latitude, longitude: longitude,
                                              removeLocation: removeLocation), patched != stagedData {
            do {
                try patched.write(to: destinationURL)
                stagedData = patched
                stagedDataForDump = stagedData
            } catch {
                return refuse("could not stage the corrected XMP item")
            }
        }
        guard let stagedBoxes = heicBoxes(stagedData, range: 0..<stagedData.count) else {
            return refuse("staged output did not parse as boxes")
        }
        // Top level: ftyp and foreign boxes payload-exact, none gained.
        let sourceTop = multiset(sourceBoxes, excluding: ["meta", "mdat"])
        let stagedTop = multiset(stagedBoxes, excluding: ["meta", "mdat"])
        for type in Set(sourceTop.keys).union(stagedTop.keys).sorted() {
            guard sortPayloads(sourceTop[type] ?? []) == sortPayloads(stagedTop[type] ?? []) else {
                if type == "ftyp" {
                    // Diagnostic only: retain exact refusal until staged brand
                    // changes are grounded. Never infer this from the unchanged
                    // original after a refused write.
                    func describe(_ payloads: [Data]) -> String {
                        return payloads.map { data in
                            let hex = data.prefix(256).map { String(format: "%02x", $0) }.joined()
                            return "bytes=\(data.count) hex=\(hex)\(data.count > 256 ? " [truncated]" : "")"
                        }.joined(separator: "; ")
                    }
                    return refuse("ftyp differs: source [\(describe(sourceTop[type] ?? []))] staged [\(describe(stagedTop[type] ?? []))]")
                }
                return refuse("top-level box \(type) changed or was lost")
            }
        }
        // Meta: one box each side, exact header, known children only, and
        // every child but iloc, iinf and iref payload-exact. iinf and iref
        // are verified structurally below (source entries byte-exact inside
        // the staged box, at most one verified added XMP item).
        let sourceMetas = sourceBoxes.filter { $0.type == "meta" }
        let stagedMetas = stagedBoxes.filter { $0.type == "meta" }
        guard sourceMetas.count == 1, stagedMetas.count == 1,
              sourceMetas[0].payload.count >= 4, stagedMetas[0].payload.count >= 4,
              sourceMetas[0].payload.prefix(4) == stagedMetas[0].payload.prefix(4) else {
            return refuse("meta box shape changed")
        }
        guard let sourceChildren = heicBoxes(sourceMetas[0].payload, range: 4..<sourceMetas[0].payload.count),
              let stagedChildren = heicBoxes(stagedMetas[0].payload, range: 4..<stagedMetas[0].payload.count) else {
            return refuse("meta children did not parse")
        }
        let knownChildren: Set<String> = ["hdlr", "pitm", "iinf", "iloc", "iprp", "iref", "dinf"]
        for child in sourceChildren + stagedChildren where !knownChildren.contains(child.type) {
            return refuse("unknown meta child \(child.type)")
        }
        let sourceExact = multiset(sourceChildren, excluding: ["iloc", "iinf", "iref"])
        let stagedExact = multiset(stagedChildren, excluding: ["iloc", "iinf", "iref"])
        for type in Set(sourceExact.keys).union(stagedExact.keys).sorted() {
            guard sortPayloads(sourceExact[type] ?? []) == sortPayloads(stagedExact[type] ?? []) else {
                return refuse("meta child \(type) changed")
            }
        }
        // Verified plain-still shape from the source's (payload-exact) iinf,
        // pitm and iref.
        let sourceIinfs = sourceChildren.filter { $0.type == "iinf" }
        guard sourceIinfs.count == 1, let items = heicIinfItems(sourceIinfs[0].payload) else {
            return refuse("iinf did not parse")
        }
        let sourcePitms = sourceChildren.filter { $0.type == "pitm" }
        guard sourcePitms.count == 1, let primary = heicPrimaryItem(sourcePitms[0].payload) else {
            return refuse("pitm did not parse")
        }
        let primaries = items.filter { $0.type == "hvc1" }
        guard primaries.count == 1, primaries[0].id == primary else {
            return refuse("primary item shape is not a single hvc1 image")
        }
        for item in items {
            if item.type == "hvc1" || item.type == "Exif" { continue }
            if item.type == "mime", item.contentType == "application/rdf+xml" { continue }
            return refuse("iinf item type \(item.type) is not a verified plain-still shape")
        }
        let nonPrimaryIDs = Set(items.filter { $0.id != primary }.map { $0.id })
        let sourceIrefs = sourceChildren.filter { $0.type == "iref" }
        if let irefBox = sourceIrefs.first {
            guard sourceIrefs.count == 1, let refs = heicReferences(irefBox.payload) else {
                return refuse("iref did not parse")
            }
            for ref in refs {
                guard ref.type == "cdsc", ref.from != primary, !ref.to.isEmpty, ref.to.allSatisfy({ $0 == primary }) else {
                    return refuse("iref carries a \(ref.type) reference outside the verified cdsc shape")
                }
            }
            guard Set(refs.map { $0.from }) == nonPrimaryIDs else {
                return refuse("metadata items without exactly one cdsc reference")
            }
        } else {
            guard nonPrimaryIDs.isEmpty else {
                return refuse("metadata items without cdsc references")
            }
        }
        // ImageIO ADDS metadata items when the source had none and the plan
        // sets metadata (observed runs 41710548605 + 41716235473: plain 8x6
        // fixture, staged iinf gained an Exif item and a mime
        // application/rdf+xml item). This is an admission, not an exemption:
        // every source infe entry must survive byte-exact inside the staged
        // iinf; added entries may only be ONE mime application/rdf+xml item
        // and ONE Exif item; any added iref reference must be an added
        // item's cdsc link to the primary image item; the mime item's
        // payload is graph-checked against the verified corrected packet
        // (after the splice it IS that packet, byte-exact) and the Exif
        // item's TIFF content is checked tag by tag against the intent
        // below. Anything else refuses.
        let stagedIinfs = stagedChildren.filter { $0.type == "iinf" }
        guard stagedIinfs.count == 1,
              let stagedItems = heicIinfItems(stagedIinfs[0].payload),
              let sourceInfe = heicIinfEntryPayloads(sourceIinfs[0].payload),
              let stagedInfe = heicIinfEntryPayloads(stagedIinfs[0].payload) else {
            return refuse("staged iinf did not parse")
        }
        var remainingInfe = stagedInfe.map { Array($0) }
        for entry in sourceInfe {
            guard let index = remainingInfe.firstIndex(of: Array(entry)) else {
                return refuse("source iinf entry changed or was lost")
            }
            remainingInfe.remove(at: index)
        }
        var addedMimeID: Int? = nil
        var addedExifID: Int? = nil
        if !remainingInfe.isEmpty {
            let sourceIDs = Set(items.map { $0.id })
            let added = stagedItems.filter { !sourceIDs.contains($0.id) }
            // Self-evidencing: a refusal names the real staged item list,
            // not a guess about what ImageIO added.
            func itemDesc(_ list: [(id: Int, type: String, contentType: String?)]) -> String {
                list.map { "id=\($0.id):\($0.type):\($0.contentType ?? "-")" }.joined(separator: ",")
            }
            guard remainingInfe.count == added.count,
                  Set(stagedItems.map { $0.id }).count == stagedItems.count else {
                return refuse("staged iinf structure outside the verified carriers (extras=\(remainingInfe.count) source=[\(itemDesc(items))] staged=[\(itemDesc(stagedItems))])")
            }
            for entry in added {
                if entry.type == "mime", entry.contentType == "application/rdf+xml", addedMimeID == nil {
                    addedMimeID = entry.id
                } else if entry.type == "Exif", addedExifID == nil {
                    addedExifID = entry.id
                } else {
                    return refuse("staged iinf adds items outside the verified XMP/Exif carriers (source=[\(itemDesc(items))] staged=[\(itemDesc(stagedItems))])")
                }
            }
        }
        let addedItemIDs = Set([addedMimeID, addedExifID].compactMap { $0 })
        // iref: source reference boxes stay byte-exact; the only admissible
        // staged addition is the cdsc link from the added XMP item to the
        // primary image item.
        func refBoxes(_ irefPayload: Data) -> [(type: String, payload: Data)]? {
            guard irefPayload.count >= 4 else { return nil }
            return heicBoxes(irefPayload, range: 4..<irefPayload.count)?.map { (type: $0.type, payload: $0.payload) }
        }
        let stagedIrefs = stagedChildren.filter { $0.type == "iref" }
        guard stagedIrefs.count <= 1 else {
            return refuse("staged iref did not parse")
        }
        var sourceRefBoxes: [(type: String, payload: Data)] = []
        var stagedRefBoxes: [(type: String, payload: Data)] = []
        if let box = sourceIrefs.first {
            guard let parsed = refBoxes(box.payload) else {
                return refuse("source iref did not parse")
            }
            sourceRefBoxes = parsed
        }
        if let box = stagedIrefs.first {
            guard let parsed = refBoxes(box.payload),
                  heicReferences(box.payload) != nil else {
                return refuse("staged iref did not parse")
            }
            stagedRefBoxes = parsed
        }
        if let sourceIref = sourceIrefs.first, let stagedIref = stagedIrefs.first {
            guard sourceIref.payload.prefix(4) == stagedIref.payload.prefix(4) else {
                return refuse("iref version changed")
            }
        }
        var remainingRefs = stagedRefBoxes.map { (type: $0.type, bytes: Array($0.payload)) }
        for box in sourceRefBoxes {
            guard let index = remainingRefs.firstIndex(where: { $0.type == box.type && $0.bytes == Array(box.payload) }) else {
                return refuse("source iref reference changed or was lost")
            }
            remainingRefs.remove(at: index)
        }
        for extra in remainingRefs {
            guard !addedItemIDs.isEmpty, extra.type == "cdsc",
                  let stagedIref = stagedIrefs.first else {
                return refuse("staged iref adds references without an added XMP item")
            }
            // Re-parse the added reference box through the strict parser, in
            // its iref version context.
            var context = Data(stagedIref.payload.prefix(4))
            let size = extra.bytes.count + 8
            context.append(UInt8((size >> 24) & 0xff))
            context.append(UInt8((size >> 16) & 0xff))
            context.append(UInt8((size >> 8) & 0xff))
            context.append(UInt8(size & 0xff))
            context.append(contentsOf: extra.type.utf8)
            context.append(contentsOf: extra.bytes)
            guard let parsed = heicReferences(context), parsed.count == 1,
                  parsed[0].type == "cdsc", addedItemIDs.contains(parsed[0].from),
                  parsed[0].to.count == 1, parsed[0].to[0] == primary else {
                return refuse("staged iref adds a reference outside the verified cdsc shape")
            }
        }
        // iloc: structural verify, then per-item payload comparisons.
        func itemPayloads(_ whole: Data, _ topBoxes: [Box], _ children: [Box]) -> [Int: Data]? {
            let ilocs = children.filter { $0.type == "iloc" }
            guard ilocs.count == 1, let located = heicExtents(ilocs[0].payload) else { return nil }
            let mdatRanges = topBoxes.filter { $0.type == "mdat" }.map { $0.range }
            guard !mdatRanges.isEmpty else { return nil }
            let b = [UInt8](whole)
            var out: [Int: Data] = [:]
            for item in located {
                guard item.method == 0, item.dref == 0 else { return nil }
                var payload = Data()
                for extent in item.extents {
                    guard extent.offset >= 0, extent.length >= 0, extent.offset + extent.length <= b.count,
                          mdatRanges.contains(where: { extent.offset >= $0.lowerBound && extent.offset + extent.length <= $0.upperBound }) else { return nil }
                    payload.append(Data(b[extent.offset..<(extent.offset + extent.length)]))
                }
                out[item.id] = payload
            }
            return out
        }
        guard let sourcePayloads = itemPayloads(sourceData, sourceBoxes, sourceChildren),
              let stagedPayloads = itemPayloads(stagedData, stagedBoxes, stagedChildren) else {
            return refuse("iloc structure unsupported or extents outside mdat")
        }
        let itemIDs = Set(items.map { $0.id })
        var expectedStagedIDs = itemIDs
        expectedStagedIDs.formUnion(addedItemIDs)
        guard Set(sourcePayloads.keys) == itemIDs, Set(stagedPayloads.keys) == expectedStagedIDs else {
            return refuse("iloc item ids do not match iinf")
        }
        guard sourcePayloads[primary] == stagedPayloads[primary] else {
            return refuse("compressed image item was re-encoded")
        }
        for item in items where item.type == "Exif" {
            guard let sourcePayload = sourcePayloads[item.id], let stagedPayload = stagedPayloads[item.id],
                  sourcePayload.count >= 4, stagedPayload.count >= 4 else {
                return refuse("Exif item shape changed")
            }
            let b0 = [UInt8](sourcePayload), b1 = [UInt8](stagedPayload)
            let sourceOffset = Int(b0[0]) << 24 | Int(b0[1]) << 16 | Int(b0[2]) << 8 | Int(b0[3])
            let stagedOffset = Int(b1[0]) << 24 | Int(b1[1]) << 16 | Int(b1[2]) << 8 | Int(b1[3])
            guard 4 + sourceOffset <= b0.count, 4 + stagedOffset <= b1.count else {
                return refuse("Exif item offset out of range")
            }
            guard let violations = tiffAuxTagViolations(sourceData: Data(b0[(4 + sourceOffset)...]),
                                                        outputData: Data(b1[(4 + stagedOffset)...]),
                                                        exempt: intentExemptions(date: date, removeDate: removeDate,
                                                                                 latitude: latitude, longitude: longitude,
                                                                                 removeLocation: removeLocation)) else {
                return refuse("Exif item did not parse as TIFF")
            }
            guard violations.isEmpty else {
                return refuse("Exif item would lose or alter tags [\(violations.joined(separator: ", "))]")
            }
        }
        // An added Exif item carries the intent in TIFF form (observed run
        // 41716235473: IFD0 Orientation/DateTime/TileWidth/TileLength,
        // ExifIFD date tags, GPSIFD ref+rational coordinates). The shared
        // verifier checks every tag against the intent or a positively
        // verified synthesized value; anything unverified refuses.
        if let addedExifID = addedExifID {
            guard let exifPayload = stagedPayloads[addedExifID], exifPayload.count >= 4 else {
                return refuse("added Exif item shape changed")
            }
            let eb = [UInt8](exifPayload)
            let exifTiffOffset = Int(eb[0]) << 24 | Int(eb[1]) << 16 | Int(eb[2]) << 8 | Int(eb[3])
            guard 4 + exifTiffOffset <= eb.count else {
                return refuse("added Exif item offset out of range")
            }
            let sourceProps = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let exifCheck = verifyAddedExifCarrier(
                tiff: Data(eb[(4 + exifTiffOffset)...]),
                date: date, removeDate: removeDate,
                latitude: latitude, longitude: longitude, removeLocation: removeLocation,
                pixelWidth: (sourceProps?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                pixelHeight: (sourceProps?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                sourceOrientation: (sourceProps?[kCGImagePropertyOrientation] as? NSNumber)?.intValue)
            guard exifCheck.ok else {
                return refuse("added Exif item not intent-verified: \(exifCheck.detail)")
            }
        }
        let mimeItemIDs = items.filter { $0.type == "mime" }.map { $0.id } + (addedMimeID.map { [$0] } ?? [])
        if !mimeItemIDs.isEmpty {
            guard let expectedPacket = correctedXMPPacket(imageSource: imageSource, date: date, removeDate: removeDate,
                                                          latitude: latitude, longitude: longitude, removeLocation: removeLocation),
                  !expectedPacket.isEmpty else {
                return refuse("corrected XMP failed preservation checks")
            }
            for mimeID in mimeItemIDs {
                guard let stagedPayload = stagedPayloads[mimeID],
                      let stagedGraph = CGImageMetadataCreateFromXMPData(stagedPayload as CFData),
                      let expectedGraph = CGImageMetadataCreateFromXMPData(expectedPacket as CFData) else {
                    return refuse("staged XMP item failed verification")
                }
                let violations = xmpPlanViolations(source: expectedGraph, result: stagedGraph,
                                                   date: nil, removeDate: false, latitude: nil, longitude: nil, removeLocation: false)
                guard violations.isEmpty else {
                    return refuse("staged XMP item differs from the verified packet [\(violations.joined(separator: ", "))]")
                }
            }
        }
        // Restored ftyp declarations must be TRUE of this output, not just
        // of the source. Only brands whose constraints we can check may be
        // declared; anything else refuses. Constraint rules from MIAF
        // (ISO/IEC 23000-22) as implemented in gpac ComplianceWarden
        // (specs/miaf/brands.cpp, profiles.cpp): base HEIF/MIAF structure is
        // enforced by the verified plain-still shape and payload-exact
        // children above; MiHB profile properties live in the hvcC/ipco and
        // hvc1 item, both byte-exact; MiPr adds the layout rules below.
        // (MiPr's thumbnail rules are vacuous here: the verified shape
        // refuses thumbnails and every non-cdsc reference.)
        guard let stagedFtypBox = stagedBoxes.first(where: { $0.type == "ftyp" }),
              let ftyp = heicFtypBrands(stagedFtypBox.payload) else {
            return refuse("staged ftyp did not parse")
        }
        let checkableBrands: Set<String> = ["heic", "heix", "mif1", "miaf", "MiHB", "MiPr"]
        guard Set(ftyp.brands).isSubset(of: checkableBrands) else {
            return refuse("ftyp declares brands outside the verifiable set [\(ftyp.brands.joined(separator: ","))]")
        }
        guard let stagedIloc = stagedChildren.first(where: { $0.type == "iloc" }),
              let stagedLocated = heicExtents(stagedIloc.payload) else {
            return refuse("staged iloc did not parse")
        }
        // No overlapping extents anywhere, across all items.
        let allExtents = stagedLocated.flatMap { $0.extents }.sorted { $0.offset < $1.offset }
        for pair in zip(allExtents, allExtents.dropFirst()) {
            guard pair.0.offset + pair.0.length <= pair.1.offset else {
                return refuse("overlapping iloc extents")
            }
        }
        if ftyp.brands.contains("MiPr") {
            // MIAF 10.2 layout: ftyp first, meta immediately after, no mdat
            // before meta; the primary item's coded data ends within
            // 128000 bytes of the file start.
            guard stagedBoxes.count >= 2, stagedBoxes[0].type == "ftyp", stagedBoxes[1].type == "meta" else {
                return refuse("MiPr layout: meta must follow ftyp")
            }
            guard let metaIndex = stagedBoxes.firstIndex(where: { $0.type == "meta" }),
                  !stagedBoxes[..<metaIndex].contains(where: { $0.type == "mdat" }) else {
                return refuse("MiPr layout: mdat before meta")
            }
            guard let primaryExtents = stagedLocated.first(where: { $0.id == primary })?.extents,
                  let lastByte = primaryExtents.map({ $0.offset + $0.length }).max(),
                  lastByte <= 128_000 else {
                return refuse("MiPr layout: primary coded data beyond 128000 bytes")
            }
        }
        guard let sourceRGBA = rgbaData(sourceData), let stagedRGBA = rgbaData(stagedData), sourceRGBA == stagedRGBA else {
            return refuse("decoded pixels changed")
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

    /// Numeric value of an XMP tag whether ImageIO typed it number or
    /// decimal string (XMP is text; typing is serializer-dependent).
    private static func xmpNumericValue(_ v: CFTypeRef?) -> Double? {
        guard let v = v else { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Degrees value of a GPS coordinate tag across ImageIO's observed
    /// serializations: a number, a decimal string ("40.399999999999999"),
    /// or the sexagesimal XMP form ("40,24N", optionally with seconds).
    /// Strict, axis-aware: the hemisphere reference must belong to the axis
    /// (N/S latitude, E/W longitude) and sets the sign (S/W negative); the
    /// magnitude must parse fully - integral degrees, minutes (integral when
    /// seconds follow) and seconds below 60, no empty components, no
    /// trailing data - and land within the axis range (|lat| <= 90,
    /// |lon| <= 180). Anything else is nil, never a coordinate, so a
    /// malformed or genuinely different value can never compare equal.
    static func gpsDegrees(_ v: CFTypeRef?, latitude: Bool) -> Double? {
        let limit = latitude ? 90.0 : 180.0
        if let d = xmpNumericValue(v) {
            guard d.isFinite, abs(d) <= limit else { return nil }
            return d
        }
        guard let v = v, let s = v as? String, let ref = s.last else { return nil }
        let sign: Double
        if latitude {
            guard ref == "N" || ref == "S" else { return nil }
            sign = ref == "S" ? -1 : 1
        } else {
            guard ref == "E" || ref == "W" else { return nil }
            sign = ref == "W" ? -1 : 1
        }
        let parts = s.dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let deg = Double(parts[0]), deg >= 0, deg == deg.rounded(),
              let minutes = Double(parts[1]), minutes >= 0, minutes < 60 else { return nil }
        if parts.count == 3, minutes != minutes.rounded() { return nil }
        var value = deg + minutes / 60
        if parts.count == 3 {
            guard let sec = Double(parts[2]), sec >= 0, sec < 60 else { return nil }
            value += sec / 3600
        }
        guard value.isFinite, value <= limit else { return nil }
        return sign * value
    }

    /// Value equality where the tag path is known: GPS coordinates
    /// additionally tolerate alternate serializations of the SAME
    /// coordinate (decimal at full float precision, or sexagesimal),
    /// compared at an explicit 1e-9 tolerance. Hemisphere and axis
    /// consistency is enforced by gpsDegrees: "40,24N" never equals -40.4
    /// or "40,24S", and a latitude never parses an E/W reference.
    static func metadataTagValuesEqual(path: String, _ a: CFTypeRef?, _ b: CFTypeRef?) -> Bool {
        if metadataValuesEqual(a, b) { return true }
        let leaf = path.components(separatedBy: ":").last ?? path
        let isLatitude: Bool
        if leaf == "GPSLatitude" {
            isLatitude = true
        } else if leaf == "GPSLongitude" {
            isLatitude = false
        } else {
            return false
        }
        guard let da = gpsDegrees(a, latitude: isLatitude), let db = gpsDegrees(b, latitude: isLatitude) else { return false }
        return abs(da - db) < 1e-9
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
                      metadataTagValuesEqual(path: fullPath, CGImageMetadataTagCopyValue(resultTag), expected) else {
                    violations.append("set value missing or wrong at \(fullPath)")
                    return true
                }
                return true
            }
            guard let resultTag = resultTags[fullPath] else {
                violations.append("lost \(fullPath)")
                return true
            }
            if !metadataTagValuesEqual(path: fullPath, CGImageMetadataTagCopyValue(tag), CGImageMetadataTagCopyValue(resultTag)) {
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
                  metadataTagValuesEqual(path: path, CGImageMetadataTagCopyValue(resultTag), expected) else {
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
        // Mirror the writer's own construction (updateImageMetadata): a
        // source without a readable metadata graph starts from an EMPTY
        // mutable graph, not from a refusal.
        let sourceMetadata: CGImageMetadata
        let mutableMetadata: CGMutableImageMetadata
        if let source = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil) {
            // A graph exists but cannot be read: refuse. Existing metadata
            // must never be silently treated as empty.
            guard let copy = CGImageMetadataCreateMutableCopy(source) else { return nil }
            sourceMetadata = source
            mutableMetadata = copy
        } else {
            // No metadata graph. The empty fallback is honest only when the
            // source carries no metadata dictionaries either; metadata that
            // exists but did not yield a graph is unreadable, not empty.
            if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
                let carrierKeys = [kCGImagePropertyExifDictionary as String,
                                   kCGImagePropertyGPSDictionary as String,
                                   kCGImagePropertyIPTCDictionary as String]
                if carrierKeys.contains(where: { properties[$0] != nil }) { return nil }
            }
            let empty = CGImageMetadataCreateMutable()
            sourceMetadata = empty
            mutableMetadata = empty
        }
        guard applyMetadataPlan(mutableMetadata, date: date, removeDate: removeDate,
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
