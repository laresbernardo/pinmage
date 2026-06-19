import Foundation
import ImageIO
import CoreServices

struct MetadataWriter {
    /// Copies image from sourceURL to destinationURL while embedding date and coordinates.
    /// Returns true on success.
    static func updateImageMetadata(sourceURL: URL, destinationURL: URL, date: Date?, removeDate: Bool, latitude: Double?, longitude: Double?, removeLocation: Bool) -> Bool {
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
