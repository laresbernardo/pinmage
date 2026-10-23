import Foundation
import ImageIO
import CoreGraphics
import Darwin

// Standalone macOS test executable, compiled with MetadataWriter.swift.
// No app launch, real photos, credentials or destructive disk simulation.
@main
struct MetadataWriterTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func fixture(at url: URL, type: CFString, frames: Int = 1) throws {
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
                                bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = context.makeImage()!
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, type, frames, nil) else {
            throw NSError(domain: "Fixtures", code: 1)
        }
        for _ in 0..<frames { CGImageDestinationAddImage(writer, image, nil) }
        try require(CGImageDestinationFinalize(writer), "Fixture finalize failed")
    }

    /// Fixture carrying EXIF/TIFF capture dates and GPS coordinates, so removal
    /// has something real to remove in every supported format.
    static func fixtureWithMetadata(at url: URL, type: CFString) throws {
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
                                bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = context.makeImage()!
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw NSError(domain: "Fixtures", code: 1)
        }
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2001:02:03 04:05:06",
            kCGImagePropertyExifDateTimeDigitized: "2001:02:03 04:05:06",
        ]
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFDateTime: "2001:02:03 04:05:06",
        ]
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 40.4,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 3.7,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyGPSDictionary: gps,
        ]
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        try require(CGImageDestinationFinalize(writer), "Metadata fixture finalize failed")
    }

    /// Fixture with non-default orientation, DPI and a Display P3 color profile,
    /// plus removable date/GPS metadata: preservation through a removal rewrite
    /// is only meaningful when the source actually carries those values.
    static func fixturePreservation(at url: URL, type: CFString) throws {
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw NSError(domain: "Fixtures", code: 2)
        }
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
                                bytesPerRow: 32, space: p3,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = context.makeImage()!
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw NSError(domain: "Fixtures", code: 1)
        }
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2001:02:03 04:05:06",
            kCGImagePropertyExifDateTimeDigitized: "2001:02:03 04:05:06",
        ]
        // EXIF Orientation is an IFD0 tag: it belongs in the TIFF dictionary,
        // which is also where ImageIO maps it for PNG's eXIf chunk.
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFDateTime: "2001:02:03 04:05:06",
            kCGImagePropertyTIFFOrientation: 6,
        ]
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 40.4,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 3.7,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyDPIWidth: 300.0,
            kCGImagePropertyDPIHeight: 300.0,
        ]
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        try require(CGImageDestinationFinalize(writer), "Preservation fixture finalize failed")
    }

    /// Property snapshot used to prove preservation through a removal rewrite.
    static func propertySnapshot(_ url: URL) throws -> (orientation: Int?, dpiWidth: Double?, dpiHeight: Double?, colorSpaceName: String?, gpsPresent: Bool, datePresent: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw NSError(domain: "Fixtures", code: 3)
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int
        let dpiWidth = props[kCGImagePropertyDPIWidth] as? Double
        let dpiHeight = props[kCGImagePropertyDPIHeight] as? Double
        var colorSpaceName: String? = nil
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let name = image.colorSpace?.name {
            colorSpaceName = name as String
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gpsPresent = props[kCGImagePropertyGPSDictionary] != nil
        let datePresent = exif?[kCGImagePropertyExifDateTimeOriginal] != nil
        return (orientation, dpiWidth, dpiHeight, colorSpaceName, gpsPresent, datePresent)
    }

    /// Renders an image file to raw RGBA bytes so tests can prove re-encoding
    /// never changed a single pixel, independent of container bytes.
    static func pixelData(_ url: URL) throws -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    static func update(_ source: URL, _ target: URL, remove: Bool = false) -> Bool {
        MetadataWriter.updateImageMetadata(sourceURL: source, destinationURL: target,
            date: remove ? nil : Date(timeIntervalSince1970: 1_700_000_000), removeDate: remove,
            latitude: remove ? nil : 40.4, longitude: remove ? nil : -3.7, removeLocation: remove)
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PinmageTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("original.png")
        try fixture(at: source, type: "public.png" as CFString)
        let original = try Data(contentsOf: source)
        let partialEncode: (URL) -> Bool = { url in
            try! Data("partial image".utf8).write(to: url)
            return false
        }
        try require(!MetadataWriter.writeSafely(sourceURL: source, destinationURL: source,
            overwrite: true, encode: partialEncode), "Finalize failure must fail")
        try require(try Data(contentsOf: source) == original, "Finalize failure changed original")
        let validEncode: (URL) -> Bool = { url in try! original.write(to: url); return true }
        try require(!MetadataWriter.writeSafely(sourceURL: source, destinationURL: source,
            overwrite: true, encode: validEncode, validate: { _, _ in false }), "Validation failure must fail")
        try require(try Data(contentsOf: source) == original, "Validation failure changed original")
        try require(!MetadataWriter.writeSafely(sourceURL: source, destinationURL: source,
            overwrite: true, encode: validEncode, publish: { _, _, _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }), "Disk failure must fail")
        try require(try Data(contentsOf: source) == original, "Disk failure changed original")
        let missing = root.appendingPathComponent("missing/output.png")
        try require(!MetadataWriter.writeSafely(sourceURL: source, destinationURL: missing,
            overwrite: false, encode: validEncode), "Staging failure must fail")
        try require(try Data(contentsOf: source) == original, "Staging failure changed original")

        let copy = root.appendingPathComponent("copy.png")
        try require(update(source, copy), "Copy write failed")
        try require(try Data(contentsOf: source) == original, "Copy mode changed source")
        let savedCopy = try Data(contentsOf: copy)
        try require(!update(source, copy), "Existing copy must not be overwritten")
        try require(try Data(contentsOf: copy) == savedCopy, "Collision changed existing copy")
        // Simulate another writer creating the target after encoding but before publication.
        let racedCopy = root.appendingPathComponent("raced.png")
        try require(!MetadataWriter.writeSafely(sourceURL: source, destinationURL: racedCopy,
            overwrite: false, encode: validEncode, publish: { temp, target, overwrite in
                try Data("other writer".utf8).write(to: target)
                try MetadataWriter.publishImage(temp, target, overwrite)
            }), "Copy publication race must fail")
        try require(try Data(contentsOf: racedCopy) == Data("other writer".utf8), "Race clobbered copy")

        for (ext, uti) in [("png", "public.png"), ("jpg", "public.jpeg"), ("tiff", "public.tiff"), ("heic", "public.heic")] {
            let photo = root.appendingPathComponent("format.\(ext)")
            try fixture(at: photo, type: uti as CFString)
            let pixelsBeforeWrite = try pixelData(photo)
            try require(update(photo, photo), "Overwrite failed for \(ext)")
            try require(try pixelData(photo) == pixelsBeforeWrite, "Pixels changed during write in \(ext)")
            try require(MetadataWriter.validateImage(photo, photo), "Invalid \(ext) output")
            let coords = MetadataWriter.readExistingCoordinates(from: photo)
            try require(coords != nil && abs(coords!.latitude - 40.4) < 0.001 && abs(coords!.longitude + 3.7) < 0.001,
                        "GPS tags missing in \(ext)")
            let imageSource = CGImageSourceCreateWithURL(photo as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
            try require(exif?[kCGImagePropertyExifDateTimeOriginal] != nil, "Date missing in \(ext)")
        }

        // M17: honest removal semantics. Removing date/location must produce a
        // file that no longer carries those tags in ANY supported format
        // (the PNG encoder previously inherited the source GPS dictionary).
        for (ext, uti) in [("png", "public.png"), ("jpg", "public.jpeg"), ("tiff", "public.tiff"), ("heic", "public.heic")] {
            let photo = root.appendingPathComponent("removal.\(ext)")
            try fixtureWithMetadata(at: photo, type: uti as CFString)
            try require(MetadataWriter.readExistingCoordinates(from: photo) != nil, "Fixture GPS missing in \(ext)")
            let pixelsBeforeRemoval = try pixelData(photo)
            try require(update(photo, photo, remove: true), "Removal overwrite failed for \(ext)")
            try require(MetadataWriter.validateImage(photo, photo), "Invalid \(ext) after removal")
            try require(try pixelData(photo) == pixelsBeforeRemoval, "Pixels changed during removal in \(ext)")
            try require(MetadataWriter.readExistingCoordinates(from: photo) == nil, "GPS survived removal in \(ext)")
            let imageSource = CGImageSourceCreateWithURL(photo as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
            try require(exif?[kCGImagePropertyExifDateTimeOriginal] == nil, "DateTimeOriginal survived removal in \(ext)")
            try require(exif?[kCGImagePropertyExifDateTimeDigitized] == nil, "DateTimeDigitized survived removal in \(ext)")
            let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            try require(tiff?[kCGImagePropertyTIFFDateTime] == nil, "TIFF DateTime survived removal in \(ext)")
            try require(props?[kCGImagePropertyGPSDictionary] == nil, "GPS dictionary survived removal in \(ext)")
        }
        // Preservation through the PNG/TIFF removal rewrite: orientation, DPI
        // and color profile must survive; date/GPS must not. When an artifact
        // directory is provided (CI), before/after files and a property dump
        // land there for human inspection of the actual outputs.
        let artifactDir = ProcessInfo.processInfo.environment["PRESERVATION_ARTIFACT_DIR"]
        var dump = ""
        for (ext, uti) in [("png", "public.png"), ("tiff", "public.tiff")] {
            let photo = root.appendingPathComponent("preserve.\(ext)")
            try fixturePreservation(at: photo, type: uti as CFString)
            let before = try propertySnapshot(photo)
            let sRGBName = CGColorSpace(name: CGColorSpace.sRGB)?.name as String?
            try require(before.orientation == 6, "Fixture orientation not non-default in \(ext)")
            try require(before.dpiWidth == 300 && before.dpiHeight == 300, "Fixture DPI not non-default in \(ext)")
            try require(before.colorSpaceName != nil && before.colorSpaceName != sRGBName, "Fixture profile not non-default in \(ext)")
            let pixelsBefore = try pixelData(photo)
            if let dir = artifactDir {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let copy = URL(fileURLWithPath: dir).appendingPathComponent("before.\(ext)")
                try? fm.removeItem(at: copy)
                try? fm.copyItem(at: photo, to: copy)
            }
            try require(update(photo, photo, remove: true), "Preservation removal failed for \(ext)")
            try require(try pixelData(photo) == pixelsBefore, "Pixels changed during preservation removal in \(ext)")
            let after = try propertySnapshot(photo)
            try require(after.orientation == before.orientation, "Orientation lost in \(ext) removal rewrite (before \(String(describing: before.orientation)) after \(String(describing: after.orientation)))")
            try require(after.dpiWidth == before.dpiWidth && after.dpiHeight == before.dpiHeight, "DPI lost in \(ext) removal rewrite")
            try require(after.colorSpaceName == before.colorSpaceName, "Color profile lost in \(ext) removal rewrite (before \(String(describing: before.colorSpaceName)) after \(String(describing: after.colorSpaceName)))")
            try require(!after.gpsPresent && !after.datePresent, "Removal incomplete in \(ext) preservation pass")
            if let dir = artifactDir {
                let copy = URL(fileURLWithPath: dir).appendingPathComponent("after.\(ext)")
                try? fm.removeItem(at: copy)
                try? fm.copyItem(at: photo, to: copy)
                dump += "\(ext): orientation \(String(describing: before.orientation)) -> \(String(describing: after.orientation)); dpi \(String(describing: before.dpiWidth))x\(String(describing: before.dpiHeight)) -> \(String(describing: after.dpiWidth))x\(String(describing: after.dpiHeight)); profile \(String(describing: before.colorSpaceName)) -> \(String(describing: after.colorSpaceName)); gps \(before.gpsPresent)->\(after.gpsPresent); date \(before.datePresent)->\(after.datePresent)\n"
            }
        }
        if let dir = artifactDir {
            try? dump.write(to: URL(fileURLWithPath: dir).appendingPathComponent("preservation-dump.txt"), atomically: true, encoding: .utf8)
        }

        let multi = root.appendingPathComponent("multipage.tiff")
        try fixture(at: multi, type: "public.tiff" as CFString, frames: 2)
        let multiData = try Data(contentsOf: multi)
        try require(!update(multi, multi), "Multi-frame original must not lose frames")
        try require(try Data(contentsOf: multi) == multiData, "Multi-frame original changed")
        let alias = root.appendingPathComponent("alias.png")
        try fm.createSymbolicLink(at: alias, withDestinationURL: source)
        try require(update(alias, alias), "Symlink overwrite failed")
        try require(try fm.destinationOfSymbolicLink(atPath: alias.path) == source.path, "Symlink was replaced")
        try require(!(try fm.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".pinmage-write-") }),
                    "Staging directories leaked")
        print("Metadata write safety tests passed (PNG, JPEG, TIFF, HEIC).")
    }
}
