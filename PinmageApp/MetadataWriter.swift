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
        
        // Copy original metadata properties (stripping any non-metadata keys)
        var metadataDict = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        metadataDict.removeValue(forKey: kCGImageDestinationLossyCompressionQuality)
        
        // Update EXIF:
        //   DateTimeOriginal — the date/time the photo was taken (original creation date)
        //   DateTimeDigitized — the date/time the image was digitized (relevant for scans)
        if removeDate {
            var exifDict = metadataDict[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exifDict.removeValue(forKey: kCGImagePropertyExifDateTimeOriginal)
            exifDict.removeValue(forKey: kCGImagePropertyExifDateTimeDigitized)
            metadataDict[kCGImagePropertyExifDictionary] = exifDict
            
            var tiffDict = metadataDict[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiffDict.removeValue(forKey: kCGImagePropertyTIFFDateTime)
            metadataDict[kCGImagePropertyTIFFDictionary] = tiffDict
        } else if let date = date {
            var exifDict = metadataDict[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let dateString = formatter.string(from: date)
            exifDict[kCGImagePropertyExifDateTimeOriginal] = dateString
            exifDict[kCGImagePropertyExifDateTimeDigitized] = dateString
            metadataDict[kCGImagePropertyExifDictionary] = exifDict
            
            // Also write to TIFF dictionary as a fallback
            var tiffDict = metadataDict[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiffDict[kCGImagePropertyTIFFDateTime] = dateString
            metadataDict[kCGImagePropertyTIFFDictionary] = tiffDict
        }
        
        // Update GPS
        if removeLocation {
            metadataDict.removeValue(forKey: kCGImagePropertyGPSDictionary)
        } else if let lat = latitude, let lon = longitude {
            var gpsDict = metadataDict[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
            gpsDict[kCGImagePropertyGPSLatitude] = abs(lat)
            gpsDict[kCGImagePropertyGPSLatitudeRef] = lat >= 0 ? "N" : "S"
            gpsDict[kCGImagePropertyGPSLongitude] = abs(lon)
            gpsDict[kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? "E" : "W"
            metadataDict[kCGImagePropertyGPSDictionary] = gpsDict
        }
        
        // Add image with the updated metadata properties dictionary
        // Using the same UTI as the source preserves the original format
        CGImageDestinationAddImageFromSource(imageDestination, imageSource, 0, metadataDict as CFDictionary)
        
        // Finalize (writes target output file to disk)
        guard CGImageDestinationFinalize(imageDestination) else {
            print("Failed to finalize image destination")
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
