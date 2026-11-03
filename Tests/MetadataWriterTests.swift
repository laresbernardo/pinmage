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


    /// M15b diagnostics probe (diagnostic-only; no production or assertion
    /// change). Runs BEFORE the suite and never throws: every scenario x format
    /// case executes independently and appends its evidence to a per-case file
    /// in PRESERVATION_ARTIFACT_DIR, even when the production write refuses or
    /// a step fails. For each case it records (a) the ACTUAL production
    /// updateImageMetadata result plus before/after bytes and properties, and
    /// (b) for PNG a GRAPH SIMULATION that replicates the correctedXMPPacket
    /// steps (source graph -> applyMetadataPlan -> CGImageMetadataCreateXMPData
    /// -> CGImageMetadataCreateFromXMPData -> xmpPlanViolations) so the exact
    /// requested/transformed/serialized/reparsed values and paths are visible
    /// instead of hidden behind the first aborting require().
    static func runDiagnosticsProbe(root: URL) {
        struct Scenario {
            let name: String
            let date: Date?
            let removeDate: Bool
            let lat: Double?
            let lon: Double?
            let removeLocation: Bool
        }
        let scenarios = [
            Scenario(name: "set-date-remove-location", date: Date(timeIntervalSince1970: 1_700_000_000), removeDate: false, lat: nil, lon: nil, removeLocation: true),
            Scenario(name: "set-location-remove-date", date: nil, removeDate: true, lat: 12.5, lon: -45.25, removeLocation: false),
            Scenario(name: "set-date-only", date: Date(timeIntervalSince1970: 1_700_000_000), removeDate: false, lat: nil, lon: nil, removeLocation: false),
            Scenario(name: "remove-date-only", date: nil, removeDate: true, lat: nil, lon: nil, removeLocation: false),
            Scenario(name: "remove-location-only", date: nil, removeDate: false, lat: nil, lon: nil, removeLocation: true),
            Scenario(name: "set-location-only", date: nil, removeDate: false, lat: 12.5, lon: -45.25, removeLocation: false),
        ]
        let formats: [(String, CFString)] = [("png", "public.png" as CFString), ("jpg", "public.jpeg" as CFString), ("tiff", "public.tiff" as CFString), ("heic", "public.heic" as CFString)]
        let env = ProcessInfo.processInfo.environment
        let outDir = env["PRESERVATION_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let probeRoot = root.appendingPathComponent("probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        for scenario in scenarios {
            for (ext, uti) in formats {
                var report: [String] = []
                report.append("scenario=\(scenario.name) format=\(ext)")
                report.append("requested: date=\(String(describing: scenario.date)) removeDate=\(scenario.removeDate) lat=\(String(describing: scenario.lat)) lon=\(String(describing: scenario.lon)) removeLocation=\(scenario.removeLocation)")
                let file = probeRoot.appendingPathComponent("probe-\(scenario.name).\(ext)")
                do {
                    try fixtureWithMetadata(at: file, type: uti)
                    report.append("fixture: created")
                } catch {
                    report.append("fixture: FAILED \(error.localizedDescription)")
                    try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("probe-\(scenario.name)-\(ext).txt"), atomically: true, encoding: .utf8)
                    continue
                }
                if let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                    let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
                    report.append("PROPERTIES BEFORE: exif=\(exif) tiff=\(tiff) gps=\(gps)")
                }
                let before = try? Data(contentsOf: file)
                let ok = MetadataWriter.updateImageMetadata(sourceURL: file, destinationURL: file,
                    date: scenario.date, removeDate: scenario.removeDate,
                    latitude: scenario.lat, longitude: scenario.lon, removeLocation: scenario.removeLocation)
                let after = try? Data(contentsOf: file)
                report.append("PRODUCTION updateImageMetadata -> \(ok); output exists=\(FileManager.default.fileExists(atPath: file.path)) bytesChanged=\(before != after)")
                if let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                    let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
                    report.append("PROPERTIES AFTER: exif=\(exif) tiff=\(tiff) gps=\(gps)")
                }
                if ext == "png" {
                    report.append(contentsOf: simulateCorrectedXMPPacket(probeRoot: probeRoot, scenario: (scenario.name, scenario.date, scenario.removeDate, scenario.lat, scenario.lon, scenario.removeLocation)))
                }
                try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("probe-\(scenario.name)-\(ext).txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    /// Graph-level mirror of the production correctedXMPPacket steps, run on a
    /// FRESH fixture (independent of the production write above). Diagnostic
    /// only: it documents what the transform/serialize/reparse stages produce;
    /// the authoritative production outcome is the updateImageMetadata result
    /// recorded separately.
    static func simulateCorrectedXMPPacket(probeRoot: URL, scenario: (name: String, date: Date?, removeDate: Bool, lat: Double?, lon: Double?, removeLocation: Bool)) -> [String] {
        var report: [String] = []
        let simFile = probeRoot.appendingPathComponent("probe-sim-\(scenario.name).png")
        do { try fixtureWithMetadata(at: simFile, type: "public.png" as CFString) } catch {
            report.append("GRAPH SIMULATION: fixture failed \(error.localizedDescription)")
            return report
        }
        guard let src = CGImageSourceCreateWithURL(simFile as CFURL, nil),
              let sourceMetadata = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let mutable = CGImageMetadataCreateMutableCopy(sourceMetadata) else {
            report.append("GRAPH SIMULATION UNAVAILABLE (source metadata read failed)")
            return report
        }
        report.append("GRAPH SIMULATION (mirrors correctedXMPPacket steps; not the production write itself)")
        report.append("SOURCE GRAPH:\n" + dumpMetadataGraph(sourceMetadata))
        let applied = MetadataWriter.applyMetadataPlan(mutable, date: scenario.date, removeDate: scenario.removeDate,
            latitude: scenario.lat, longitude: scenario.lon, removeLocation: scenario.removeLocation)
        report.append("applyMetadataPlan -> \(applied)")
        report.append("TRANSFORMED GRAPH:\n" + dumpMetadataGraph(mutable))
        guard let xmpData = CGImageMetadataCreateXMPData(mutable, nil) else {
            report.append("SERIALIZE FAILED (CGImageMetadataCreateXMPData returned nil)")
            return report
        }
        report.append("SERIALIZED XMP PACKET (\((xmpData as Data).count) bytes):\n" + (String(data: xmpData as Data, encoding: .utf8) ?? "<non-utf8>"))
        guard let reparsed = CGImageMetadataCreateFromXMPData(xmpData) else {
            report.append("REPARSE FAILED (CGImageMetadataCreateFromXMPData returned nil)")
            return report
        }
        report.append("REPARSED GRAPH:\n" + dumpMetadataGraph(reparsed))
        let violations = MetadataWriter.xmpPlanViolations(source: sourceMetadata, result: reparsed,
            date: scenario.date, removeDate: scenario.removeDate,
            latitude: scenario.lat, longitude: scenario.lon, removeLocation: scenario.removeLocation)
        report.append("VIOLATIONS: \(violations.isEmpty ? "none" : violations.joined(separator: "; "))")
        return report
    }

    /// Path = value (+ qualifiers) per enumerated tag, same enumeration
    /// options the production verifier uses (nil = default recursion).
    static func dumpMetadataGraph(_ metadata: CGImageMetadata) -> String {
        var lines: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let value = CGImageMetadataTagCopyValue(tag)
            let qualifiers = CGImageMetadataTagCopyQualifiers(tag)
            lines.append("  \(path as String) = \(String(describing: value)) | qualifiers: \(String(describing: qualifiers))")
            return true
        }
        return lines.sorted().joined(separator: "\n")
    }


    // MARK: - M15 aux-transport inventory probe (diagnostic-only)

    /// Byte-level inventories for the formats whose aux containers have no
    /// preservation guard yet (JPEG APPn/COM segments, TIFF IFD tags, HEIC
    /// boxes; PNG included as a control against its existing chunk guard).
    /// Each case splices a recognizable foreign payload into the fixture,
    /// runs the production write, and records whether the payload survived
    /// byte-exact, so the verify-or-refuse work is grounded in the real
    /// transport behavior instead of assumptions. Diagnostic only: never
    /// throws, one report file per case in PRESERVATION_ARTIFACT_DIR.
    static func hexPrefix(_ data: Data, _ limit: Int) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined()
    }

    /// JPEG marker walk up to SOS: (name, segment length, payload) per segment.
    static func jpegInventory(_ data: Data) -> [(String, Int, Data)]? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var segs: [(String, Int, Data)] = [("SOI", 0, Data())]
        var pos = 2
        while pos + 1 < b.count {
            guard b[pos] == 0xFF else { return nil }
            while pos < b.count && b[pos] == 0xFF { pos += 1 }
            guard pos < b.count else { return nil }
            let m = b[pos]; pos += 1
            if m == 0xD8 || m == 0xD9 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) {
                segs.append((String(format: "FF%02X", m), 0, Data()))
                if m == 0xD9 { return segs }
                continue
            }
            guard pos + 2 <= b.count else { return nil }
            let len = Int(b[pos]) << 8 | Int(b[pos + 1])
            guard len >= 2, pos + len <= b.count else { return nil }
            let payload = Data(b[(pos + 2)..<(pos + len)])
            if m == 0xDA {
                segs.append(("SOS", len, payload))
                segs.append(("ENTROPY-EOI", b.count - (pos + len), Data()))
                return segs
            }
            segs.append((String(format: "FF%02X", m), len, payload))
            pos += len
        }
        return nil
    }

    /// TIFF IFD walk: one line per entry with its resolved value bytes
    /// (inline or via offset), following the next-IFD chain and the Exif/GPS/
    /// Interop sub-IFD pointers. Endianness from the header.
    static func tiffInventory(_ data: Data) -> [String]? {
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
        var lines: [String] = []
        func readIFD(_ off: Int, _ label: String, _ depth: Int) {
            guard off > 0, off + 2 <= b.count, depth <= 4 else { return }
            let n = u16(off)
            let base = off + 2
            guard base + 12 * n + 4 <= b.count else {
                lines.append("\(label): TRUNCATED")
                return
            }
            for i in 0..<n {
                let ent = base + 12 * i
                let tag = u16(ent)
                let typ = u16(ent + 2)
                let cnt = u32(ent + 4)
                let size = (typeSizes[typ] ?? 1) * cnt
                let value: Data
                if size <= 4 {
                    value = Data(b[(ent + 8)..<(ent + 8 + size)])
                } else {
                    let voff = u32(ent + 8)
                    value = voff + size <= b.count ? Data(b[voff..<(voff + size)]) : Data("<BADOFFSET>".utf8)
                }
                lines.append("\(label) tag=\(tag) type=\(typ) count=\(cnt) value=\(hexPrefix(value, 12))")
                if (tag == 34665 || tag == 34853 || tag == 40965) && size <= 4 {
                    readIFD(u32(ent + 8), "\(label)>\(tag)", depth + 1)
                }
            }
            let next = u32(base + 12 * n)
            if next != 0 { readIFD(next, label + "+next", depth + 1) }
        }
        readIFD(u32(4), "IFD0", 0)
        return lines
    }

    /// HEIC/ISOBMFF box walk, one level into meta's children.
    static func heicInventory(_ data: Data) -> [String]? {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }
        var lines: [String] = []
        func walk(_ start: Int, _ end: Int, _ label: String, _ depth: Int) {
            var pos = start
            while pos + 8 <= end {
                var size = Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
                let type = String(bytes: b[(pos + 4)..<(pos + 8)], encoding: .ascii) ?? "????"
                var header = 8
                if size == 1 {
                    guard pos + 16 <= end else { return }
                    size = Int(b[pos + 8]) << 56 | Int(b[pos + 9]) << 48 | Int(b[pos + 10]) << 40 | Int(b[pos + 11]) << 32
                         | Int(b[pos + 12]) << 24 | Int(b[pos + 13]) << 16 | Int(b[pos + 14]) << 8 | Int(b[pos + 15])
                    header = 16
                } else if size == 0 {
                    size = end - pos
                }
                guard size >= header, pos + size <= end else {
                    lines.append("\(label): BADBOX at \(pos)")
                    return
                }
                let payload = Data(b[(pos + header)..<(pos + size)])
                lines.append("\(label) \(type) size=\(size) head=\(hexPrefix(payload, 8))")
                if type == "meta" && depth == 0 && payload.count >= 4 {
                    walk(pos + header + 4, pos + size, "meta", depth + 1)
                }
                pos += size
            }
        }
        walk(0, b.count, "top", 0)
        return lines
    }

    /// Splices recognizable foreign APP13/COM/APP11 segments before SOS.
    static func spliceJPEGAux(_ data: Data, tag: String) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var pos = 2
        var sosAt: Int?
        while pos + 1 < b.count {
            guard b[pos] == 0xFF else { return nil }
            while pos < b.count && b[pos] == 0xFF { pos += 1 }
            guard pos < b.count else { return nil }
            let m = b[pos]; pos += 1
            if m == 0xDA { sosAt = pos - 2; break }  // cut at the FF prefix
            if m == 0xD8 || m == 0xD9 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) { continue }
            guard pos + 2 <= b.count else { return nil }
            let len = Int(b[pos]) << 8 | Int(b[pos + 1])
            guard len >= 2, pos + len <= b.count else { return nil }
            pos += len
        }
        guard let cut = sosAt else { return nil }
        var out = Data(b[0..<cut])
        for (marker, name) in [(0xED, "AUXPROBE-APP13"), (0xFE, "AUXPROBE-COM"), (0xEB, "AUXPROBE-APP11")] {
            let payload = Data("\(name)-\(tag)".utf8)
            let len = payload.count + 2
            out.append(Data([0xFF, UInt8(marker), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]))
            out.append(payload)
        }
        out.append(Data(b[cut...]))
        return out
    }

    /// Splices a private TIFF tag 65000 by rebuilding IFD0 at EOF and
    /// repointing the header: original entry bytes (and their out-of-line
    /// value offsets) stay valid; the new tag's payload is appended.
    static func spliceTIFFAux(_ data: Data, tag: String) -> Data? {
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
        let payload = Data("AUXPROBE-TIFF-\(tag)".utf8)
        var out = Data(b)
        let newIFD = out.count
        let valueOff = newIFD + 2 + 12 * (n + 1) + 4
        var ifd = Data()
        put16(&ifd, n + 1)
        var inserted = false
        for i in 0..<n {
            let ent = base + 12 * i
            let entryTag = u16(ent)
            if !inserted && entryTag > 65000 {
                put16(&ifd, 65000); put16(&ifd, 7); put32(&ifd, payload.count); put32(&ifd, valueOff)
                inserted = true
            }
            ifd.append(Data(b[ent..<(ent + 12)]))
        }
        if !inserted {
            put16(&ifd, 65000); put16(&ifd, 7); put32(&ifd, payload.count); put32(&ifd, valueOff)
        }
        ifd.append(Data(b[(base + 12 * n)..<(base + 12 * n + 4)]))
        var headerFix = Data()
        put32(&headerFix, newIFD)
        out.replaceSubrange(4..<8, with: headerFix)
        out.append(ifd)
        out.append(payload)
        return out
    }

    /// Appends top-level free and uuid boxes with recognizable payloads.
    static func spliceHEICAux(_ data: Data, tag: String) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }
        var out = Data(b)
        func appendBox(_ type: String, _ payload: Data) {
            let size = payload.count + 8
            out.append(Data([UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]))
            out.append(Data(type.utf8))
            out.append(payload)
        }
        appendBox("free", Data("AUXPROBE-FREE-\(tag)".utf8))
        appendBox("uuid", Data([UInt8](repeating: 0xAB, count: 16)) + Data("AUXPROBE-UUID-\(tag)".utf8))
        return out
    }


    /// Splices an arbitrary TIFF tag by the same IFD0-at-EOF repoint the
    /// production tag-700 correction uses.
    static func spliceTIFFTag(_ data: Data, tag: Int, type: Int, payload: Data) -> Data? {
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
        var kept: [(Int, Data)] = []
        for i in 0..<n {
            let ent = base + 12 * i
            if u16(ent) != tag { kept.append((u16(ent), Data(b[ent..<(ent + 12)]))) }
        }
        var out = Data(b)
        let newIFD = out.count
        let valueOff = newIFD + 2 + 12 * (kept.count + 1) + 4
        var ifd = Data()
        put16(&ifd, kept.count + 1)
        var inserted = false
        for (entryTag, raw) in kept.sorted(by: { $0.0 < $1.0 }) {
            if !inserted && entryTag > tag {
                put16(&ifd, tag); put16(&ifd, type); put32(&ifd, payload.count); put32(&ifd, valueOff)
                inserted = true
            }
            ifd.append(raw)
        }
        if !inserted {
            put16(&ifd, tag); put16(&ifd, type); put32(&ifd, payload.count); put32(&ifd, valueOff)
        }
        ifd.append(Data(b[(base + 12 * n)..<(base + 12 * n + 4)]))
        var headerFix = Data()
        put32(&headerFix, newIFD)
        out.replaceSubrange(4..<8, with: headerFix)
        out.append(ifd)
        out.append(payload)
        return out
    }

    /// Entropy-coded bytes between the SOS segment and the trailing EOI.
    static func jpegEntropyData(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var pos = 2
        while pos + 1 < b.count {
            guard b[pos] == 0xFF else { return nil }
            while pos < b.count && b[pos] == 0xFF { pos += 1 }
            guard pos < b.count else { return nil }
            let m = b[pos]; pos += 1
            if m == 0xD8 || m == 0xD9 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) { continue }
            guard pos + 2 <= b.count else { return nil }
            let len = Int(b[pos]) << 8 | Int(b[pos + 1])
            guard len >= 2, pos + len <= b.count else { return nil }
            if m == 0xDA {
                let start = pos + len
                guard b.count >= start + 2, b[b.count - 2] == 0xFF, b[b.count - 1] == 0xD9 else { return nil }
                return Data(b[start..<(b.count - 2)])
            }
            pos += len
        }
        return nil
    }

    /// Hex dump of the meta children whose contents decide whether aux HEIC
    /// entities can be verified (iinf item types, iref references, iloc
    /// extents, pitm). Semantic parsing happens offline from the artifact.
    static func heicMetaChildHex(_ data: Data) -> [String] {
        let b = [UInt8](data)
        guard b.count >= 8 else { return ["unparseable"] }
        var out: [String] = []
        var pos = 0
        while pos + 8 <= b.count {
            var size = Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
            let type = String(bytes: b[(pos + 4)..<(pos + 8)], encoding: .ascii) ?? "????"
            var hdr = 8
            if size == 1 {
                guard pos + 16 <= b.count else { return out }
                size = 0
                for i in 0..<8 { size = size << 8 | Int(b[pos + 8 + i]) }
                hdr = 16
            } else if size == 0 {
                size = b.count - pos
            }
            guard size >= hdr, pos + size <= b.count else { return out }
            if type == "meta" {
                var c = pos + hdr + 4
                while c + 8 <= pos + size {
                    var cs = Int(b[c]) << 24 | Int(b[c + 1]) << 16 | Int(b[c + 2]) << 8 | Int(b[c + 3])
                    let ct = String(bytes: b[(c + 4)..<(c + 8)], encoding: .ascii) ?? "????"
                    var ch = 8
                    if cs == 1 {
                        guard c + 16 <= pos + size else { break }
                        cs = 0
                        for i in 0..<8 { cs = cs << 8 | Int(b[c + 8 + i]) }
                        ch = 16
                    }
                    guard cs >= ch, c + cs <= pos + size else { break }
                    if ct == "iinf" || ct == "iref" || ct == "iloc" || ct == "pitm" || ct == "iprp" {
                        out.append("\(ct) size=\(cs) hex=\(hexPrefix(Data(b[(c + ch)..<(c + cs)]), 200))")
                    }
                    c += cs
                }
            }
            pos += size
        }
        return out
    }

    // MARK: - M15 cycle-2 route probe (diagnostic-only)

    /// Settles two open questions with byte evidence: (1) whether the JPEG
    /// dictionary set route re-encodes the compressed stream (DQT evidence
    /// says yes) and whether the copy-write route maps a planned date/GPS set
    /// back into EXIF readback while transporting pixels and entropy exactly;
    /// (2) what the HEIC meta children (iinf/iref/iloc) actually contain on
    /// the fixture before and after a copy-write set, so the final HEIC aux
    /// guard can be built on verified structure instead of shape parity.
    static func runRouteProbe(root: URL) {
        let outDir = ProcessInfo.processInfo.environment["PRESERVATION_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        let probeRoot = root.appendingPathComponent("routeprobe", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        var report: [String] = []
        let requestedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let exifFormatter = DateFormatter()
        exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        // JPEG set, dictionary route (production path).
        let dictJpg = probeRoot.appendingPathComponent("route-set-dict.jpg")
        try? fixtureWithMetadata(at: dictJpg, type: "public.jpeg" as CFString)
        if let before = try? Data(contentsOf: dictJpg), let rgbaBefore = try? pixelData(dictJpg) {
            let ok = update(dictJpg, dictJpg)
            let after = (try? Data(contentsOf: dictJpg)) ?? Data()
            let rgbaAfter = try? pixelData(dictJpg)
            let entBefore = jpegEntropyData(before) ?? Data()
            let entAfter = jpegEntropyData(after) ?? Data()
            report.append("jpg-set-dictionary: ok=\(ok) rgbaEqual=\(rgbaAfter == rgbaBefore) entropyEqual=\(entBefore == entAfter)")
            report.append("entropy-before \(hexPrefix(entBefore, 96))")
            report.append("entropy-after  \(hexPrefix(entAfter, 96))")
        } else {
            report.append("jpg-set-dictionary: fixture failed")
        }

        // JPEG set, copy-write route (simulation through the production plan).
        let cwJpg = probeRoot.appendingPathComponent("route-set-cw-src.jpg")
        let cwOut = probeRoot.appendingPathComponent("route-set-cw-out.jpg")
        try? fixtureWithMetadata(at: cwJpg, type: "public.jpeg" as CFString)
        if let data = try? Data(contentsOf: cwJpg), let rgbaBefore = try? pixelData(cwJpg),
           let cwSource = CGImageSourceCreateWithData(data as CFData, nil),
           let cwDest = CGImageDestinationCreateWithURL(cwOut as CFURL, "public.jpeg" as CFString, 1, nil) {
            let meta = CGImageSourceCopyMetadataAtIndex(cwSource, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            let planned = MetadataWriter.applyMetadataPlan(meta, date: requestedDate, removeDate: false,
                                                           latitude: 40.4, longitude: -3.7, removeLocation: false)
            var copyError: Unmanaged<CFError>?
            let copyOptions: [CFString: Any] = [
                kCGImageDestinationMetadata: meta,
                kCGImageDestinationMergeMetadata: kCFBooleanFalse as Any,
            ]
            let ok = planned && CGImageDestinationCopyImageSource(cwDest, cwSource, copyOptions as CFDictionary, &copyError)
            if ok, let outData = try? Data(contentsOf: cwOut), let rgbaAfter = try? pixelData(cwOut) {
                let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(cwOut as CFURL, nil)!, 0, nil) as? [CFString: Any]
                let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
                let readback = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
                let gps = props?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
                let entBefore = jpegEntropyData(data) ?? Data()
                let entAfter = jpegEntropyData(outData) ?? Data()
                report.append("jpg-set-copywrite: ok=true rgbaEqual=\(rgbaAfter == rgbaBefore) entropyEqual=\(entBefore == entAfter)")
                report.append("jpg-set-copywrite: dateReadback=\(readback ?? "nil") expected=\(exifFormatter.string(from: requestedDate)) gpsPresent=\(gps != nil)")
                for line in (jpegInventory(outData) ?? []).map({ "\($0.0) len=\($0.1)" }) {
                    report.append("jpg-set-copywrite seg: \(line)")
                }
            } else {
                let errDesc = copyError?.takeRetainedValue().localizedDescription ?? "unknown"
                report.append("jpg-set-copywrite: ok=false planned=\(planned) error=\(errDesc)")
            }
        } else {
            report.append("jpg-set-copywrite: setup failed")
        }

        // HEIC meta children before and after a production copy-write set.
        let heic = probeRoot.appendingPathComponent("route-set.heic")
        try? fixtureWithMetadata(at: heic, type: "public.heic" as CFString)
        if let before = try? Data(contentsOf: heic) {
            report.append("heic-before: " + heicMetaChildHex(before).joined(separator: " | "))
            let ok = update(heic, heic)
            let after = (try? Data(contentsOf: heic)) ?? Data()
            report.append("heic-set: ok=\(ok)")
            report.append("heic-after: " + heicMetaChildHex(after).joined(separator: " | "))
        } else {
            report.append("heic-set: fixture failed")
        }

        if let outDir = outDir {
            try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("routeprobe-report.txt"), atomically: true, encoding: .utf8)
        }
    }

    static func runAuxTransportProbe(root: URL) {
        struct Scenario {
            let name: String
            let date: Date?
            let removeDate: Bool
            let removeLocation: Bool
        }
        let scenarios = [
            Scenario(name: "aux-set-date", date: Date(timeIntervalSince1970: 1_700_000_000), removeDate: false, removeLocation: false),
            Scenario(name: "aux-remove-date", date: nil, removeDate: true, removeLocation: false),
            Scenario(name: "aux-remove-location", date: nil, removeDate: false, removeLocation: true),
        ]
        let formats: [(String, CFString)] = [("png", "public.png" as CFString), ("jpg", "public.jpeg" as CFString), ("tiff", "public.tiff" as CFString), ("heic", "public.heic" as CFString)]
        let env = ProcessInfo.processInfo.environment
        let outDir = env["PRESERVATION_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let probeRoot = root.appendingPathComponent("probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        for scenario in scenarios {
            for (ext, uti) in formats {
                var report: [String] = []
                report.append("scenario=\(scenario.name) format=\(ext)")
                let file = probeRoot.appendingPathComponent("auxprobe-\(scenario.name).\(ext)")
                do {
                    try fixtureWithMetadata(at: file, type: uti)
                    report.append("fixture: created")
                } catch {
                    report.append("fixture: FAILED \(error.localizedDescription)")
                    try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("auxprobe-\(scenario.name)-\(ext).txt"), atomically: true, encoding: .utf8)
                    continue
                }
                var magics: [String] = []
                do {
                    switch ext {
                    case "jpg":
                        guard let src = try? Data(contentsOf: file), let s = spliceJPEGAux(src, tag: scenario.name) else { throw NSError(domain: "Probe", code: 2) }
                        try s.write(to: file)
                        magics = ["AUXPROBE-APP13", "AUXPROBE-COM", "AUXPROBE-APP11"]
                    case "tiff":
                        guard let src = try? Data(contentsOf: file), let s = spliceTIFFAux(src, tag: scenario.name) else { throw NSError(domain: "Probe", code: 3) }
                        try s.write(to: file)
                        magics = ["AUXPROBE-TIFF"]
                    case "heic":
                        guard let src = try? Data(contentsOf: file), let s = spliceHEICAux(src, tag: scenario.name) else { throw NSError(domain: "Probe", code: 4) }
                        try s.write(to: file)
                        magics = ["AUXPROBE-FREE", "AUXPROBE-UUID"]
                    default:
                        try appendPNGChunk(file, type: "prVt", payload: [UInt8](Data("AUXPROBE-PNG-\(scenario.name)".utf8)))
                        magics = ["AUXPROBE-PNG"]
                    }
                    report.append("splice: ok \(magics)")
                } catch {
                    report.append("splice: FAILED")
                    try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("auxprobe-\(scenario.name)-\(ext).txt"), atomically: true, encoding: .utf8)
                    continue
                }
                func dumpInventory(_ label: String, _ data: Data?) {
                    guard let data = data else { report.append("\(label): no data"); return }
                    switch ext {
                    case "jpg":
                        for (name, len, payload) in jpegInventory(data) ?? [("PARSE-FAIL", 0, Data())] {
                            report.append("\(label) seg \(name) len=\(len) payload=\(hexPrefix(payload, 10))")
                        }
                    case "tiff":
                        for line in tiffInventory(data) ?? ["PARSE-FAIL"] { report.append("\(label) \(line)") }
                    case "heic":
                        for line in heicInventory(data) ?? ["PARSE-FAIL"] { report.append("\(label) \(line)") }
                    default:
                        let counts = MetadataWriter.pngChunkTypeCounts(data) ?? [:]
                        report.append("\(label) chunks=\(counts)")
                    }
                }
                dumpInventory("BEFORE", try? Data(contentsOf: file))
                let ok = MetadataWriter.updateImageMetadata(sourceURL: file, destinationURL: file,
                    date: scenario.date, removeDate: scenario.removeDate,
                    latitude: nil, longitude: nil, removeLocation: scenario.removeLocation)
                let after = try? Data(contentsOf: file)
                report.append("PRODUCTION updateImageMetadata -> \(ok)")
                for magic in magics {
                    let found = after?.range(of: Data(magic.utf8)) != nil
                    let fate = ok ? (found ? "SURVIVED-EXACT" : "MISSING") : (found ? "REFUSED-WRITE-ORIGINAL-INTACT" : "REFUSED-WRITE")
                    report.append("SPLICED \(magic): \(fate)")
                }
                dumpInventory("AFTER", after)
                try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("auxprobe-\(scenario.name)-\(ext).txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PinmageTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        runDiagnosticsProbe(root: root)
        runAuxTransportProbe(root: root)
        runRouteProbe(root: root)
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
        // Regression (diagnostic probe evidence, run 41660381865): plain
        // metadata sets on a PNG must succeed too - the destination-synthesized
        // iTXt XMP carrier used to trip the aux guard, and xmp:ModifyDate kept
        // the stale source date on a date set because the plan never wrote the
        // MWG-canonical TIFF DateTime location.
        let setOnly = root.appendingPathComponent("setonly.png")
        try fixtureWithMetadata(at: setOnly, type: "public.png" as CFString)
        let requestedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try require(MetadataWriter.updateImageMetadata(sourceURL: setOnly, destinationURL: setOnly,
            date: requestedDate, removeDate: false, latitude: nil, longitude: nil, removeLocation: false), "Set date only failed for png")
        let setOnlyProps = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(setOnly as CFURL, nil)!, 0, nil) as? [CFString: Any]
        let setOnlyExif = setOnlyProps?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exifFormatter = DateFormatter()
        exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        try require(setOnlyExif?[kCGImagePropertyExifDateTimeOriginal] as? String == exifFormatter.string(from: requestedDate), "Set date missing in png readback")
        var modifyDateValue: String?
        if let setOnlyGraph = CGImageSourceCopyMetadataAtIndex(CGImageSourceCreateWithURL(setOnly as CFURL, nil)!, 0, nil) {
            CGImageMetadataEnumerateTagsUsingBlock(setOnlyGraph, nil, nil) { path, tag in
                if (path as String) == "xmp:ModifyDate" {
                    modifyDateValue = CGImageMetadataTagCopyValue(tag) as? String
                }
                return true
            }
        }
        let xmpFormatter = DateFormatter()
        xmpFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        try require(modifyDateValue == xmpFormatter.string(from: requestedDate), "xmp:ModifyDate stale after png date set")
        let locOnly = root.appendingPathComponent("loconly.png")
        try fixtureWithMetadata(at: locOnly, type: "public.png" as CFString)
        try require(MetadataWriter.updateImageMetadata(sourceURL: locOnly, destinationURL: locOnly,
            date: nil, removeDate: false, latitude: 12.5, longitude: -45.25, removeLocation: false), "Set location only failed for png")
        let locCoords = MetadataWriter.readExistingCoordinates(from: locOnly)
        try require(locCoords != nil && abs(locCoords!.latitude - 12.5) < 0.001 && abs(locCoords!.longitude + 45.25) < 0.001, "Requested GPS missing after png set")

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

        // M15 aux guards (verify-or-refuse; transport evidence run 41683971917,
        // guard semantics mirrored and validated on crafted bytes locally):
        // JPEG/TIFF/HEIC writes must never silently drop auxiliary data.

        // TIFF: an unsurfaced private tag refuses both removal and set, intact.
        for remove in [true, false] {
            let f = root.appendingPathComponent("aux-tiff-priv-\(remove ? "remove" : "set").tiff")
            try fixtureWithMetadata(at: f, type: "public.tiff" as CFString)
            let spliced = spliceTIFFAux(try Data(contentsOf: f), tag: "suite")
            try require(spliced != nil, "TIFF aux splice failed")
            try spliced!.write(to: f)
            let before = try Data(contentsOf: f)
            try require(!update(f, f, remove: remove), "TIFF \(remove ? "removal" : "set") with an unsurfaced private tag must refuse")
            try require(try Data(contentsOf: f) == before, "Refused TIFF write must leave the original intact")
        }

        // TIFF: a stale XMP carrier (tag 700) is corrected or dropped, never carried stale.
        let tiff700 = root.appendingPathComponent("aux-tiff-700.tiff")
        try fixtureWithMetadata(at: tiff700, type: "public.tiff" as CFString)
        let stalePacket = Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:CreateDate=\"2001-02-03T04:05:06\"/></rdf:RDF></x:xmpmeta>".utf8)
        let with700 = spliceTIFFTag(try Data(contentsOf: tiff700), tag: 700, type: 7, payload: stalePacket)
        try require(with700 != nil, "TIFF tag-700 splice failed")
        try with700!.write(to: tiff700)
        try require(update(tiff700, tiff700, remove: true), "TIFF removal with a stale XMP carrier must correct or drop it, not refuse")
        let tiff700Bytes = try Data(contentsOf: tiff700)
        try require(tiff700Bytes.range(of: Data("2001:02:03".utf8)) == nil, "Stale XMP date (native form) survived TIFF removal")
        try require(tiff700Bytes.range(of: Data("2001-02-03".utf8)) == nil, "Stale XMP date (packet form) survived TIFF removal")

        // JPEG removal transports foreign aux segments byte-exact (run 41683971917).
        let jpgAux = root.appendingPathComponent("aux-jpg-remove.jpg")
        try fixtureWithMetadata(at: jpgAux, type: "public.jpeg" as CFString)
        let splicedJ = spliceJPEGAux(try Data(contentsOf: jpgAux), tag: "suite")
        try require(splicedJ != nil, "JPEG aux splice failed")
        try splicedJ!.write(to: jpgAux)
        try require(update(jpgAux, jpgAux, remove: true), "JPEG removal must transport foreign aux segments")
        let jpgAuxBytes = try Data(contentsOf: jpgAux)
        for needle in ["AUXPROBE-APP13-suite", "AUXPROBE-COM-suite", "AUXPROBE-APP11-suite"] {
            try require(jpgAuxBytes.range(of: Data(needle.utf8)) != nil, "JPEG removal lost \(needle)")
        }

        // JPEG set on the dictionary route drops foreign segments (run 41683971917):
        // refuse until the route is settled, leave the original intact.
        let jpgSet = root.appendingPathComponent("aux-jpg-set.jpg")
        try fixtureWithMetadata(at: jpgSet, type: "public.jpeg" as CFString)
        let splicedJS = spliceJPEGAux(try Data(contentsOf: jpgSet), tag: "suite")
        try require(splicedJS != nil, "JPEG aux splice failed")
        try splicedJS!.write(to: jpgSet)
        let jpgSetBefore = try Data(contentsOf: jpgSet)
        try require(!update(jpgSet, jpgSet), "JPEG set with foreign aux segments must refuse until the route is settled")
        try require(try Data(contentsOf: jpgSet) == jpgSetBefore, "Refused JPEG set must leave the original intact")

        // HEIC: foreign top-level boxes refuse on both write paths, intact.
        for remove in [true, false] {
            let f = root.appendingPathComponent("aux-heic-\(remove ? "remove" : "set").heic")
            try fixtureWithMetadata(at: f, type: "public.heic" as CFString)
            let splicedH = spliceHEICAux(try Data(contentsOf: f), tag: "suite")
            try require(splicedH != nil, "HEIC aux splice failed")
            try splicedH!.write(to: f)
            let before = try Data(contentsOf: f)
            try require(!update(f, f, remove: remove), "HEIC \(remove ? "removal" : "set") with foreign top-level boxes must refuse")
            try require(try Data(contentsOf: f) == before, "Refused HEIC write must leave the original intact")
        }

        print("Metadata write safety tests passed (PNG, JPEG, TIFF, HEIC).")
    }
}
