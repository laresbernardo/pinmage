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
        // Orientation goes through the top-level kCGImagePropertyOrientation
        // convenience key (ImageIO places it in the format-native location);
        // the TIFF-dict copy stays because PNG evidence shows that route lands
        // in the eXIf chunk and exercises the writer's TIFF-dict copy path.
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
            kCGImagePropertyOrientation: 6,
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
    static func propertySnapshot(_ url: URL) throws -> (orientation: Int?, tiffOrientation: Int?, dpiWidth: Double?, dpiHeight: Double?, colorSpaceName: String?, gpsPresent: Bool, datePresent: Bool) {
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
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let tiffOrientation = tiff?[kCGImagePropertyTIFFOrientation] as? Int
        let gpsPresent = props[kCGImagePropertyGPSDictionary] != nil
        let datePresent = exif?[kCGImagePropertyExifDateTimeOriginal] != nil
            || tiff?[kCGImagePropertyTIFFDateTime] != nil
        return (orientation, tiffOrientation, dpiWidth, dpiHeight, colorSpaceName, gpsPresent, datePresent)
    }

    /// Splices an extra chunk before IEND, so tests can prove aux handling on a
    /// source the ImageIO fixtures do not build. Rewrites the file in place.
    static func appendPNGChunk(_ url: URL, type: String, payload: [UInt8]) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        // IEND is the final 12 bytes: zero length, "IEND", CRC.
        try require(bytes.count >= 12 && Array(bytes[(bytes.count - 8)..<(bytes.count - 4)]) == Array("IEND".utf8),
                    "PNG fixture missing its trailing IEND")
        guard let chunk = MetadataWriter.pngChunkBytes(type: type, payload: Data(payload)) else {
            throw NSError(domain: "Fixtures", code: 4, userInfo: [NSLocalizedDescriptionKey: "Bad test chunk type"])
        }
        bytes.insert(contentsOf: chunk, at: bytes.count - 12)
        try Data(bytes).write(to: url)
    }

    /// Reads the XMP packet text of a PNG file, or nil when it has no
    /// uncompressed XMP-carrier iTXt chunk.
    static func xmpPacketString(_ url: URL) throws -> String? {
        guard let chunks = MetadataWriter.pngChunks(try Data(contentsOf: url)) else { return nil }
        let prefix = Array("XML:com.adobe.xmp\0".utf8)
        for payload in chunks["iTXt"] ?? [] {
            let bytes = [UInt8](payload)
            if bytes.count > prefix.count + 4, Array(bytes.prefix(prefix.count)) == prefix,
               bytes[prefix.count] == 0, bytes[prefix.count + 1] == 0 {
                var index = prefix.count + 2
                while index < bytes.count, bytes[index] != 0 { index += 1 } // language tag
                index += 1
                while index < bytes.count, bytes[index] != 0 { index += 1 } // translated keyword
                index += 1
                guard index <= bytes.count else { return nil }
                return String(bytes: bytes[index...], encoding: .utf8)
            }
        }
        return nil
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
            if ext == "png" {
                // M15b XMP correction: the carrier is either gone (nothing
                // survived) or holds a corrected packet. It must never carry
                // the removed values - stale XMP is the M17 bug.
                if let packet = try xmpPacketString(photo) {
                    try require(!packet.contains("2001-02-03") && !packet.contains("2001:02:03"),
                                "Removed date survived in png XMP packet")
                    try require(!packet.contains("GPSLatitude"), "Removed GPS survived in png XMP packet")
                }
            }
        }
        // Preservation through the PNG/TIFF removal rewrite: orientation, DPI
        // and color profile must survive; date/GPS must not. When an artifact
        // directory is provided (CI), before/after files and a property dump
        // land there for human inspection of the actual outputs.
        let artifactDir = ProcessInfo.processInfo.environment["PRESERVATION_ARTIFACT_DIR"]
        var dump = ""
        func flushDump() {
            guard let dir = artifactDir else { return }
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? dump.write(to: URL(fileURLWithPath: dir).appendingPathComponent("preservation-dump.txt"), atomically: true, encoding: .utf8)
        }
        func snapshotLine(_ label: String, _ ext: String, _ s: (orientation: Int?, tiffOrientation: Int?, dpiWidth: Double?, dpiHeight: Double?, colorSpaceName: String?, gpsPresent: Bool, datePresent: Bool)) -> String {
            "\(ext) \(label): orientation \(String(describing: s.orientation)) tiffOrientation \(String(describing: s.tiffOrientation)) dpi \(String(describing: s.dpiWidth))x\(String(describing: s.dpiHeight)) profile \(String(describing: s.colorSpaceName)) gps \(s.gpsPresent) date \(s.datePresent)\n"
        }
        for (ext, uti) in [("png", "public.png"), ("tiff", "public.tiff")] {
            let photo = root.appendingPathComponent("preserve.\(ext)")
            try fixturePreservation(at: photo, type: uti as CFString)
            if let dir = artifactDir {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let copy = URL(fileURLWithPath: dir).appendingPathComponent("before.\(ext)")
                try? fm.removeItem(at: copy)
                try? fm.copyItem(at: photo, to: copy)
            }
            let before = try propertySnapshot(photo)
            dump += snapshotLine("before", ext, before)
            flushDump()
            let sRGBName = CGColorSpace(name: CGColorSpace.sRGB)?.name as String?
            try require(before.orientation == 6, "Fixture orientation not non-default in \(ext)")
            try require(before.dpiWidth == 300 && before.dpiHeight == 300, "Fixture DPI not non-default in \(ext)")
            try require(before.colorSpaceName != nil && before.colorSpaceName != sRGBName, "Fixture profile not non-default in \(ext)")
            let pixelsBefore = try pixelData(photo)
            try require(update(photo, photo, remove: true), "Preservation removal failed for \(ext)")
            try require(try pixelData(photo) == pixelsBefore, "Pixels changed during preservation removal in \(ext)")
            let after = try propertySnapshot(photo)
            if let dir = artifactDir {
                let copy = URL(fileURLWithPath: dir).appendingPathComponent("after.\(ext)")
                try? fm.removeItem(at: copy)
                try? fm.copyItem(at: photo, to: copy)
            }
            dump += snapshotLine("after", ext, after)
            flushDump()
            try require(after.orientation == before.orientation, "Orientation lost in \(ext) removal rewrite (before \(String(describing: before.orientation)) after \(String(describing: after.orientation)))")
            try require(after.dpiWidth == before.dpiWidth && after.dpiHeight == before.dpiHeight, "DPI lost in \(ext) removal rewrite")
            try require(after.colorSpaceName == before.colorSpaceName, "Color profile lost in \(ext) removal rewrite (before \(String(describing: before.colorSpaceName)) after \(String(describing: after.colorSpaceName)))")
            try require(!after.gpsPresent && !after.datePresent, "Removal incomplete in \(ext) preservation pass")
        }

        // M15b: a PNG carrying aux chunks outside the writer's carried set
        // (oFFs position data, private chunks) must never lose them silently.
        // The removal rewrite cannot reproduce them, so the write is refused
        // and the original stays untouched; a copy attempt leaves no output.
        // The set path may transport the chunk untouched - accept transport or
        // refusal, never silent loss.
        for (chunkType, payload) in [("oFFs", [UInt8]([0, 0, 0, 1, 0, 0, 0, 2, 1])), ("prVt", [UInt8]([9, 8, 7]))] {
            let aux = root.appendingPathComponent("aux-\(chunkType).png")
            try fixtureWithMetadata(at: aux, type: "public.png" as CFString)
            try appendPNGChunk(aux, type: chunkType, payload: payload)
            try require(MetadataWriter.pngChunkTypeCounts(try Data(contentsOf: aux))?[chunkType] == 1,
                        "Spliced \(chunkType) missing before the write")
            let auxBytes = try Data(contentsOf: aux)
            try require(!update(aux, aux, remove: true),
                        "PNG removal must refuse an uncarried \(chunkType) chunk")
            try require(try Data(contentsOf: aux) == auxBytes,
                        "Refused PNG removal changed the original")
            let auxCopy = root.appendingPathComponent("aux-\(chunkType)-copy.png")
            try require(!update(aux, auxCopy, remove: true),
                        "PNG removal copy must refuse an uncarried \(chunkType) chunk")
            try require(!fm.fileExists(atPath: auxCopy.path),
                        "Refused PNG removal left a copy")
            let setSucceeded = update(aux, aux)
            if setSucceeded {
                try require(MetadataWriter.pngChunkTypeCounts(try Data(contentsOf: aux))?[chunkType] == 1,
                            "PNG set silently dropped \(chunkType)")
            } else {
                try require(try Data(contentsOf: aux) == auxBytes,
                            "Refused PNG set changed the original")
            }
        }
        // The guard parses strictly: truncated PNG bytes are not a valid inventory.
        try require(MetadataWriter.pngChunkTypeCounts(Data([1, 2, 3])) == nil,
                    "Chunk parser accepted non-PNG bytes")
        // Loss comparison is payload-exact per occurrence: a chunk that
        // survives with altered bytes counts as lost, and partial
        // disappearance of repeated chunks is caught.
        let altA = root.appendingPathComponent("alt-a.png")
        try fixture(at: altA, type: "public.png" as CFString)
        try appendPNGChunk(altA, type: "prVt", payload: [9, 8, 7])
        try appendPNGChunk(altA, type: "prVt", payload: [1, 1, 1])
        let altABytes = try Data(contentsOf: altA)
        let altB = root.appendingPathComponent("alt-b.png")
        try fm.copyItem(at: altA, to: altB)
        try require(MetadataWriter.pngLostAuxChunks(source: altABytes, output: try Data(contentsOf: altB)) == [],
                    "Identical files reported aux loss")
        try fixture(at: altB, type: "public.png" as CFString)
        try appendPNGChunk(altB, type: "prVt", payload: [9, 8, 8])
        try require(MetadataWriter.pngLostAuxChunks(source: altABytes, output: try Data(contentsOf: altB)) == ["prVt x2"],
                    "Altered or missing payloads not reported as lost")
        try appendPNGChunk(altB, type: "prVt", payload: [9, 8, 7])
        try require(MetadataWriter.pngLostAuxChunks(source: altABytes, output: try Data(contentsOf: altB)) == ["prVt x1"],
                    "Partial disappearance of repeated chunks not reported")

        // M15b, tag level: a rebuild-from-properties removal must not drop
        // source tags beyond the requested removals (presence, not values).
        let tagSource: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2001:02:03 04:05:06",
                                             kCGImagePropertyExifMakerNote: [1, 2]],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2001:02:03 04:05:06",
                                             kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.4],
        ]
        try require(MetadataWriter.droppedUntouchedTags(source: tagSource, output: tagSource,
            removeDate: true, removeLocation: true).isEmpty,
                    "Requested removals reported as dropped untouched tags")
        let stripped: [CFString: Any] = [kCGImagePropertyExifDictionary: [CFString: Any](), kCGImagePropertyTIFFDictionary: [CFString: Any]()]
        try require(MetadataWriter.droppedUntouchedTags(source: tagSource, output: stripped,
            removeDate: true, removeLocation: true) == ["EXIF.MakerNote"],
                    "Dropped untouched tags not reported")
        // Orientation is exempt from the tag check (ImageIO may relocate it
        // between dictionaries); the preservation test asserts its value.
        var noOrientation = tagSource
        var tiffOnly = tagSource[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiffOnly.removeValue(forKey: kCGImagePropertyTIFFDateTime)
        tiffOnly.removeValue(forKey: kCGImagePropertyTIFFOrientation)
        noOrientation[kCGImagePropertyTIFFDictionary] = tiffOnly
        try require(MetadataWriter.droppedUntouchedTags(source: tagSource, output: noOrientation,
            removeDate: true, removeLocation: true).isEmpty,
                    "Relocated orientation must not refuse the write")
        var noGps = tagSource
        noGps.removeValue(forKey: kCGImagePropertyGPSDictionary)
        try require(MetadataWriter.droppedUntouchedTags(source: tagSource, output: noGps,
            removeDate: true, removeLocation: false) == ["GPS.Latitude"],
                    "Dropped GPS tag not reported when location removal was not requested")

        // XMP transform + ImageIO serialization: requested removals are gone
        // from the packet, untouched tags survive. Uses registered prefixes so
        // SetValueWithPath creates the tags.
        let planMetadata = CGImageMetadataCreateMutable()
        try require(CGImageMetadataSetValueWithPath(planMetadata, nil, "photoshop:DateCreated" as CFString, "2001-02-03T04:05:06" as CFString), "Fixture DateCreated write failed")
        try require(CGImageMetadataSetValueWithPath(planMetadata, nil, "exif:GPSLatitude" as CFString, 40.4 as CFNumber), "Fixture GPS write failed")
        try require(CGImageMetadataSetValueWithPath(planMetadata, nil, "tiff:Model" as CFString, "TestCamera" as CFString), "Fixture Model write failed")
        try require(MetadataWriter.applyMetadataPlan(planMetadata, date: nil, removeDate: true,
            latitude: nil, longitude: nil, removeLocation: true), "Metadata plan failed")
        guard let packetData = CGImageMetadataCreateXMPData(planMetadata, nil),
              let packetText = String(data: packetData as Data, encoding: .utf8) else {
            throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "XMP serialization failed"])
        }
        try require(!packetText.contains("DateCreated") && !packetText.contains("GPSLatitude"),
                    "Removed tags survived XMP serialization")
        try require(packetText.contains("TestCamera"), "Untouched tag lost in XMP serialization")

        // The preservation invariant itself: the round-tripped graph must
        // provably keep every untouched source property, or the write refuses.
        func makeGraph(_ model: String?, date: Bool, gps: Bool) -> CGMutableImageMetadata {
            let g = CGImageMetadataCreateMutable()
            if date { _ = CGImageMetadataSetValueWithPath(g, nil, "photoshop:DateCreated" as CFString, "2001-02-03T04:05:06" as CFString) }
            if gps { _ = CGImageMetadataSetValueWithPath(g, nil, "exif:GPSLatitude" as CFString, 40.4 as CFNumber) }
            if let model { _ = CGImageMetadataSetValueWithPath(g, nil, "tiff:Model" as CFString, model as CFString) }
            return g
        }
        let invariantSource = makeGraph("TestCamera", date: true, gps: true)
        // Good result: date/GPS removed, Model intact.
        try require(MetadataWriter.xmpPlanViolations(source: invariantSource,
            result: makeGraph("TestCamera", date: false, gps: false),
            date: nil, removeDate: true, latitude: nil, longitude: nil, removeLocation: true).isEmpty,
                    "Invariant rejected a correct removal")
        // Lost untouched tag.
        try require(MetadataWriter.xmpPlanViolations(source: invariantSource,
            result: makeGraph(nil, date: false, gps: false),
            date: nil, removeDate: true, latitude: nil, longitude: nil, removeLocation: true) == ["lost tiff:Model"],
                    "Invariant missed a lost untouched tag")
        // Altered untouched value.
        try require(MetadataWriter.xmpPlanViolations(source: invariantSource,
            result: makeGraph("OtherCamera", date: false, gps: false),
            date: nil, removeDate: true, latitude: nil, longitude: nil, removeLocation: true) == ["altered tiff:Model"],
                    "Invariant missed an altered untouched tag")
        // Stale removal target, anywhere in the result.
        let stale = MetadataWriter.xmpPlanViolations(source: invariantSource,
            result: makeGraph("TestCamera", date: true, gps: false),
            date: nil, removeDate: true, latitude: nil, longitude: nil, removeLocation: true)
        try require(stale == ["stale removal target at photoshop:DateCreated"],
                    "Invariant missed a surviving removal target, got \(stale)")
        // Planned sets verified by value: date set must carry the new value.
        let setSource = makeGraph("TestCamera", date: false, gps: false)
        let withSet = CGImageMetadataCreateMutable()
        _ = CGImageMetadataSetValueWithPath(withSet, nil, "tiff:Model" as CFString, "TestCamera" as CFString)
        try require(MetadataWriter.applyMetadataPlan(withSet, date: Date(timeIntervalSince1970: 1_700_000_000),
            removeDate: false, latitude: nil, longitude: nil, removeLocation: false), "Set plan failed")
        let planDate = Date(timeIntervalSince1970: 1_700_000_000)
        try require(MetadataWriter.xmpPlanViolations(source: setSource, result: withSet,
            date: planDate, removeDate: false, latitude: nil, longitude: nil, removeLocation: false).isEmpty,
                    "Invariant rejected a correct set")
        let wrongSet = CGImageMetadataCreateMutable()
        _ = CGImageMetadataSetValueWithPath(wrongSet, nil, "tiff:Model" as CFString, "TestCamera" as CFString)
        _ = CGImageMetadataSetValueWithPath(wrongSet, nil, "photoshop:DateCreated" as CFString, "1999-01-01T00:00:00" as CFString)
        _ = CGImageMetadataSetValueWithPath(wrongSet, nil, "xmp:CreateDate" as CFString, "1999-01-01T00:00:00" as CFString)
        _ = CGImageMetadataSetValueWithPath(wrongSet, nil, "exif:DateTimeOriginal" as CFString, "1999-01-01T00:00:00" as CFString)
        _ = CGImageMetadataSetValueWithPath(wrongSet, nil, "exif:DateTimeDigitized" as CFString, "1999-01-01T00:00:00" as CFString)
        _ = CGImageMetadataSetValueWithPath(wrongSet, nil, "tiff:DateTime" as CFString, "1999-01-01T00:00:00" as CFString)
        let wrongViolations = MetadataWriter.xmpPlanViolations(source: setSource, result: wrongSet,
            date: planDate, removeDate: false, latitude: nil, longitude: nil, removeLocation: false)
        try require(!wrongViolations.isEmpty, "Invariant accepted a wrong set value")

        let multi = root.appendingPathComponent("multipage.tiff")
        try fixture(at: multi, type: "public.tiff" as CFString, frames: 2)
        let multiData = try Data(contentsOf: multi)
        try require(!update(multi, multi), "Multi-frame original must not lose frames")
        try require(try Data(contentsOf: multi) == multiData, "Multi-frame original changed")
        // M15: the refusal covers copies, not only overwrites. A multi-frame
        // source copied to a new destination previously produced a single-frame
        // file, silently dropping the rest; it must fail and leave no output.
        let multiCopy = root.appendingPathComponent("multipage-copy.tiff")
        try require(!update(multi, multiCopy), "Multi-frame copy must be refused")
        try require(!fm.fileExists(atPath: multiCopy.path), "Refused multi-frame copy left an output")
        try require(try Data(contentsOf: multi) == multiData, "Refused multi-frame copy changed source")
        // M16: a request with nothing to set or remove never re-encodes.
        for (ext, uti) in [("png", "public.png"), ("jpg", "public.jpeg"), ("tiff", "public.tiff"), ("heic", "public.heic")] {
            let still = root.appendingPathComponent("noop.\(ext)")
            try fixtureWithMetadata(at: still, type: uti as CFString)
            let stillData = try Data(contentsOf: still)
            let stillMTime = try fm.attributesOfItem(atPath: still.path)[.modificationDate] as? Date
            try require(MetadataWriter.updateImageMetadata(sourceURL: still, destinationURL: still, date: nil, removeDate: false, latitude: nil, longitude: nil, removeLocation: false), "No-op overwrite failed for \(ext)")
            try require(try Data(contentsOf: still) == stillData, "No-op overwrite changed bytes in \(ext)")
            try require(try fm.attributesOfItem(atPath: still.path)[.modificationDate] as? Date == stillMTime, "No-op overwrite touched the file in \(ext)")
            // Partial coordinates are not a location: still a no-op.
            try require(MetadataWriter.updateImageMetadata(sourceURL: still, destinationURL: still, date: nil, removeDate: false, latitude: 40.4, longitude: nil, removeLocation: false), "Half-location no-op failed for \(ext)")
            try require(try Data(contentsOf: still) == stillData, "Half-location request changed bytes in \(ext)")
            let stillCopy = root.appendingPathComponent("noop-copy.\(ext)")
            try require(MetadataWriter.updateImageMetadata(sourceURL: still, destinationURL: stillCopy, date: nil, removeDate: false, latitude: nil, longitude: nil, removeLocation: false), "No-op copy failed for \(ext)")
            try require(try Data(contentsOf: stillCopy) == stillData, "No-op copy is not byte-identical in \(ext)")
            try require(!MetadataWriter.updateImageMetadata(sourceURL: still, destinationURL: stillCopy, date: nil, removeDate: false, latitude: nil, longitude: nil, removeLocation: false), "No-op copy must not overwrite an existing file in \(ext)")
        }
        try require(!MetadataWriter.updateImageMetadata(sourceURL: multi, destinationURL: multi, date: nil, removeDate: false, latitude: nil, longitude: nil, removeLocation: false), "No-op must still refuse multi-frame")
        let multiNoOpCopy = root.appendingPathComponent("multipage-noop-copy.tiff")
        try require(!MetadataWriter.updateImageMetadata(sourceURL: multi, destinationURL: multiNoOpCopy, date: nil, removeDate: false, latitude: nil, longitude: nil, removeLocation: false), "No-op copy must refuse multi-frame")
        try require(!fm.fileExists(atPath: multiNoOpCopy.path), "Refused no-op copy left an output")
        // Removal wins over a set of the same field.
        let removeWins = MetadataWriter.WritePlan(date: Date(), removeDate: true, latitude: 1, longitude: 2, removeLocation: true)
        try require(removeWins.date == nil && !removeWins.hasLocation && !removeWins.isNoOp, "Plan must normalize removal over set")

        // Mixed request (set one field, remove the other) goes through the copy-write
        // path with the readback check on: the production combination must still publish.
        for (ext, uti) in [("png", "public.png"), ("jpg", "public.jpeg"), ("tiff", "public.tiff"), ("heic", "public.heic")] {
            let mixed = root.appendingPathComponent("mixed.\(ext)")
            try fixtureWithMetadata(at: mixed, type: uti as CFString)
            try require(MetadataWriter.updateImageMetadata(sourceURL: mixed, destinationURL: mixed,
                date: Date(timeIntervalSince1970: 1_700_000_000), removeDate: false,
                latitude: nil, longitude: nil, removeLocation: true), "Set date + remove location failed for \(ext)")
            try require(MetadataWriter.readExistingCoordinates(from: mixed) == nil, "GPS survived mixed write in \(ext)")
        }
        // Reverse mixed request: set location, remove date. Date must be gone, GPS must be the requested one.
        for (ext, uti) in [("png", "public.png"), ("jpg", "public.jpeg"), ("tiff", "public.tiff"), ("heic", "public.heic")] {
            let mixed = root.appendingPathComponent("mixed2.\(ext)")
            try fixtureWithMetadata(at: mixed, type: uti as CFString)
            try require(MetadataWriter.updateImageMetadata(sourceURL: mixed, destinationURL: mixed,
                date: nil, removeDate: true, latitude: 12.5, longitude: -45.25, removeLocation: false), "Remove date + set location failed for \(ext)")
            let coords = MetadataWriter.readExistingCoordinates(from: mixed)
            try require(coords != nil && abs(coords!.latitude - 12.5) < 0.001 && abs(coords!.longitude + 45.25) < 0.001, "Requested GPS missing after mixed write in \(ext)")
            let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(mixed as CFURL, nil)!, 0, nil) as? [CFString: Any]
            let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
            try require(exif?[kCGImagePropertyExifDateTimeOriginal] == nil, "Date survived mixed removal in \(ext)")
        }
        // No-op copy of a symlinked source yields a regular file.
        let linkSource = root.appendingPathComponent("link-source.png")
        try fixture(at: linkSource, type: "public.png" as CFString)
        let linkAlias = root.appendingPathComponent("link-alias.png")
        try fm.createSymbolicLink(at: linkAlias, withDestinationURL: linkSource)
        let linkCopy = root.appendingPathComponent("link-copy.png")
        try require(MetadataWriter.updateImageMetadata(sourceURL: linkAlias, destinationURL: linkCopy, date: nil, removeDate: false, latitude: nil, longitude: nil, removeLocation: false), "No-op copy of symlink failed")
        try require((try? fm.destinationOfSymbolicLink(atPath: linkCopy.path)) == nil, "No-op copy published a symlink")
        try require(try Data(contentsOf: linkCopy) == Data(contentsOf: linkSource), "No-op symlink copy not byte-identical")

        // I03: readback verification. A failing verifier must publish nothing.
        let verifySource = root.appendingPathComponent("verify.png")
        try fixture(at: verifySource, type: "public.png" as CFString)
        let verifyBytes = try Data(contentsOf: verifySource)
        let verifyEncode: (URL) -> Bool = { url in try! verifyBytes.write(to: url); return true }
        try require(!MetadataWriter.writeSafely(sourceURL: verifySource, destinationURL: verifySource,
            overwrite: true, encode: verifyEncode, verify: { _ in false }), "Readback failure must fail")
        try require(try Data(contentsOf: verifySource) == verifyBytes, "Readback failure changed original")
        let verifyCopy = root.appendingPathComponent("verify-copy.png")
        try require(!MetadataWriter.writeSafely(sourceURL: verifySource, destinationURL: verifyCopy,
            overwrite: false, encode: verifyEncode, verify: { _ in false }), "Readback failure must fail for copies")
        try require(!fm.fileExists(atPath: verifyCopy.path), "Readback failure left a copy")
        // verifyIntent against real outputs, per format.
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        for (ext, uti) in [("png", "public.png"), ("jpg", "public.jpeg"), ("tiff", "public.tiff"), ("heic", "public.heic")] {
            let written = root.appendingPathComponent("intent.\(ext)")
            try fixture(at: written, type: uti as CFString)
            try require(update(written, written), "Intent write failed for \(ext)")
            let good = MetadataWriter.WritePlan(date: when, removeDate: false, latitude: 40.4, longitude: -3.7, removeLocation: false)
            try require(MetadataWriter.verifyIntent(good, in: written), "Readback rejected a correct write in \(ext)")
            let wrongDate = MetadataWriter.WritePlan(date: when.addingTimeInterval(86_400), removeDate: false, latitude: nil, longitude: nil, removeLocation: false)
            try require(!MetadataWriter.verifyIntent(wrongDate, in: written), "Readback accepted a wrong date in \(ext)")
            let wrongPlace = MetadataWriter.WritePlan(date: nil, removeDate: false, latitude: 10, longitude: 10, removeLocation: false)
            try require(!MetadataWriter.verifyIntent(wrongPlace, in: written), "Readback accepted a wrong location in \(ext)")
            let notRemoved = MetadataWriter.WritePlan(date: nil, removeDate: true, latitude: nil, longitude: nil, removeLocation: true)
            try require(!MetadataWriter.verifyIntent(notRemoved, in: written), "Readback accepted surviving date/GPS in \(ext)")
            try require(update(written, written, remove: true), "Intent removal failed for \(ext)")
            try require(MetadataWriter.verifyIntent(notRemoved, in: written), "Readback rejected a correct removal in \(ext)")
        }
        let alias = root.appendingPathComponent("alias.png")
        try fm.createSymbolicLink(at: alias, withDestinationURL: source)
        try require(update(alias, alias), "Symlink overwrite failed")
        try require(try fm.destinationOfSymbolicLink(atPath: alias.path) == source.path, "Symlink was replaced")
        try require(!(try fm.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".pinmage-write-") }),
                    "Staging directories leaked")
        print("Metadata write safety tests passed (PNG, JPEG, TIFF, HEIC).")
    }
}
