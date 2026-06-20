import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageResizer {
    /// Rescales an image file to a maximum dimension, returning compressed JPEG data.
    /// This uses CGImageSource thumbnail generation to avoid loading full-resolution images into memory.
    static func resizeImage(at url: URL, maxDimension: CGFloat) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        
        CGImageDestinationAddImage(destination, thumbnail, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return data as Data
    }
}
