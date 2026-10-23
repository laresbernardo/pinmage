import Foundation
import ImageIO
import CoreServices
import Darwin

struct MetadataWriter {
    /// Copies image from sourceURL to destinationURL while embedding date and coordinates.
    /// Returns true on success.
    static func updateImageMetadata(sourceURL: URL, destinationURL: URL, date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?, removeLocation: Bool) -> Bool {
        let isOverwrite = sourceURL.resolvingSymlinksInPath().standardizedFileURL == destinationURL.resolvingSymlinksInPath().standardizedFileURL
        let targetURL = isOverwrite ? sourceURL.resolvingSymlinksInPath() : destinationURL
        return writeSafely(sourceURL: sourceURL, destinationURL: targetURL, overwrite: isOverwrite, encode: { temporaryURL in
            encodeImageMetadata(sourceURL: sourceURL, destinationURL: temporaryURL, date: date, removeDate: removeDate, latitude: latitude, longitude: longitude, removeLocation: removeLocation)
        })
    }

    /// The injected operations let tests simulate encoder, validation and disk failures.
    /// No operation writes to the target until the verified staging file is published.
    static func writeSafely(
        sourceURL: URL,
        destinationURL: URL,
        overwrite: Bool,
        encode: (URL) -> Bool,
        validate: (URL, URL) -> Bool = validateImage,
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
            guard encode(temporaryURL), validate(sourceURL, temporaryURL) else { return false }
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
                if (removeDate && ["DateTimeOriginal", "DateTimeDigitized", "DateTime"].contains(tagName))
                    || (removeLocation && tagName.hasPrefix("GPS")) {
                    pathsToRemove.append(fullPath)
                }
                return true
            }
            for removePath in pathsToRemove {
                CGImageMetadataRemoveTagWithPath(mutableMetadata, nil, removePath as CFString)
            }
        }
        
        // Date set: writes the standard EXIF/TIFF XMP tags (registered
        // prefixes), which read back into the EXIF/TIFF property dictionaries.
        // Fail closed if any write cannot be created.
        if !removeDate, let date = date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let dateString = formatter.string(from: date)
            guard CGImageMetadataSetValueWithPath(mutableMetadata, nil, "exif:DateTimeOriginal" as CFString, dateString as CFString),
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
