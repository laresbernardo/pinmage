import Foundation
import ImageIO
import CoreServices

struct MetadataWriter {
    /// Copies image from sourceURL to destinationURL while embedding date and coordinates.
    /// Returns true on success.
    static func updateImageMetadata(sourceURL: URL, destinationURL: URL, date: Date?, latitude: Double?, longitude: Double?) -> Bool {
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
        
        // Create destination writer
        guard let imageDestination = CGImageDestinationCreateWithURL(destinationURL as CFURL, uti, 1, nil) else {
            print("Failed to create image destination at: \(destinationURL)")
            return false
        }
        
        // Copy original metadata properties
        var metadataDict = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        
        // Update EXIF
        if let date = date {
            var exifDict = metadataDict[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let dateString = formatter.string(from: date)
            exifDict[kCGImagePropertyExifDateTimeOriginal] = dateString
            exifDict[kCGImagePropertyExifDateTimeDigitized] = dateString
            metadataDict[kCGImagePropertyExifDictionary] = exifDict
            
            // Also write to TIFF dictionary just in case
            var tiffDict = metadataDict[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiffDict[kCGImagePropertyTIFFDateTime] = dateString
            metadataDict[kCGImagePropertyTIFFDictionary] = tiffDict
        }
        
        // Update GPS
        if let lat = latitude, let lon = longitude {
            var gpsDict = metadataDict[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
            gpsDict[kCGImagePropertyGPSLatitude] = abs(lat)
            gpsDict[kCGImagePropertyGPSLatitudeRef] = lat >= 0 ? "N" : "S"
            gpsDict[kCGImagePropertyGPSLongitude] = abs(lon)
            gpsDict[kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? "E" : "W"
            metadataDict[kCGImagePropertyGPSDictionary] = gpsDict
        }
        
        // Add image with the updated metadata properties dictionary
        CGImageDestinationAddImageFromSource(imageDestination, imageSource, 0, metadataDict as CFDictionary)
        
        // Finalize (writes target output file to disk)
        guard CGImageDestinationFinalize(imageDestination) else {
            print("Failed to finalize image destination")
            return false
        }
        
        return true
    }
}
