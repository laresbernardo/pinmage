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
            // Beyond the coordinate four: altitude, direction and the fix
            // date/time exercise the B1 whole-IFD removal exemption, the B2
            // preservation of untargeted GPS tags on coordinate sets, and the
            // GPSDateStamp capture-date alias strip on date removals.
            kCGImagePropertyGPSAltitude: 12.0,
            kCGImagePropertyGPSImgDirection: 90.0,
            kCGImagePropertyGPSImgDirectionRef: "T",
            kCGImagePropertyGPSTimeStamp: "04:05:06",
            kCGImagePropertyGPSDateStamp: "2001:02:03",
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
                lines.append("\(label) \(type) size=\(size) head=\(hexPrefix(payload, type == "ftyp" ? 256 : 8))")
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


    // MARK: - M15 cycle-3 deep probe (diagnostic-only)

    /// Full-hex dump of the JPEG segments whose contents decide guard shape.
    static func jpegSegmentDump(_ data: Data) -> [String] {
        guard let inv = jpegInventory(data) else { return ["unparseable"] }
        return inv.map { name, len, payload in
            if ["FFE0", "FFE1", "FFE2", "FFED", "FFEE", "FFDB"].contains(name) {
                return "\(name) len=\(len) hex=\(hexPrefix(payload, 320))"
            }
            return "\(name) len=\(len)"
        }
    }

    static func buildIRB(_ resources: [(Int, Data)]) -> Data {
        var out = Data("Photoshop 3.0\0".utf8)
        for (rid, payload) in resources {
            out.append(contentsOf: [0x38, 0x42, 0x49, 0x4D])
            out.append(UInt8((rid >> 8) & 0xFF)); out.append(UInt8(rid & 0xFF))
            out.append(0); out.append(0)
            out.append(UInt8((payload.count >> 24) & 0xFF)); out.append(UInt8((payload.count >> 16) & 0xFF))
            out.append(UInt8((payload.count >> 8) & 0xFF)); out.append(UInt8(payload.count & 0xFF))
            out.append(payload)
            if payload.count % 2 != 0 { out.append(0) }
        }
        return out
    }

    /// IRB builder with Pascal-name fields (the name survives in the
    /// resource's complete bytes; a name never makes a resource void).
    static func buildIRBNamed(_ resources: [(Int, Data, Data)]) -> Data {
        var out = Data("Photoshop 3.0\0".utf8)
        for (rid, name, payload) in resources {
            out.append(contentsOf: [0x38, 0x42, 0x49, 0x4D])
            out.append(UInt8((rid >> 8) & 0xFF)); out.append(UInt8(rid & 0xFF))
            out.append(UInt8(name.count)); out.append(name)
            if (1 + name.count) % 2 != 0 { out.append(0) }
            out.append(UInt8((payload.count >> 24) & 0xFF)); out.append(UInt8((payload.count >> 16) & 0xFF))
            out.append(UInt8((payload.count >> 8) & 0xFF)); out.append(UInt8(payload.count & 0xFF))
            out.append(payload)
            if payload.count % 2 != 0 { out.append(0) }
        }
        return out
    }

    /// In-place semantic patch: replace the first occurrence of one 4-byte
    /// box/field marker with another of the same length.
    static func replaceFirstBytes(_ data: Data, _ needle: String, _ replacement: String) -> Data? {
        guard let range = data.range(of: Data(needle.utf8)) else { return nil }
        var out = data
        out.replaceSubrange(range, with: Data(replacement.utf8))
        return out
    }

    static func irbResources(_ payload: Data) -> [(Int, Data)]? {
        let prefix = Data("Photoshop 3.0\0".utf8)
        guard payload.count > prefix.count, payload.prefix(prefix.count) == prefix else { return nil }
        let b = [UInt8](payload)
        var pos = prefix.count
        var out: [(Int, Data)] = []
        while pos + 12 <= b.count {
            guard b[pos] == 0x38 && b[pos + 1] == 0x42 && b[pos + 2] == 0x49 && b[pos + 3] == 0x4D else { return out }
            let rid = Int(b[pos + 4]) << 8 | Int(b[pos + 5])
            var p = pos + 6
            let nameLen = Int(b[p]); p += 1 + nameLen
            if (1 + nameLen) % 2 != 0 { p += 1 }
            guard p + 4 <= b.count else { return nil }
            let size = Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
            p += 4
            guard p + size <= b.count else { return nil }
            out.append((rid, Data(b[p..<(p + size)])))
            p += size + (size % 2)
            pos = p
        }
        return out
    }

    /// Replaces the first genuine Photoshop IRB (APP13) with the given
    /// payload; inserts one before SOS when the file has none.
    static func jpegReplacingAPP13(_ data: Data, payload: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var out = Data([0xFF, 0xD8])
        var pos = 2
        var replaced = false
        while pos + 1 < b.count {
            guard b[pos] == 0xFF else { return nil }
            let segStart = pos
            while pos < b.count && b[pos] == 0xFF { pos += 1 }
            guard pos < b.count else { return nil }
            let m = b[pos]; pos += 1
            if m == 0xD8 || m == 0xD9 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) {
                out.append(Data(b[segStart..<pos]))
                if m == 0xD9 { return out }
                continue
            }
            guard pos + 2 <= b.count else { return nil }
            let len = Int(b[pos]) << 8 | Int(b[pos + 1])
            guard len >= 2, pos + len <= b.count else { return nil }
            if m == 0xDA {
                if !replaced {
                    let plen = payload.count + 2
                    out.append(contentsOf: [0xFF, 0xED, UInt8((plen >> 8) & 0xFF), UInt8(plen & 0xFF)])
                    out.append(payload)
                }
                out.append(Data(b[segStart...]))
                return out
            }
            if m == 0xED && !replaced,
               Data(b[(pos + 2)..<(pos + len)]).prefix(14) == Data("Photoshop 3.0\0".utf8) {
                let plen = payload.count + 2
                out.append(contentsOf: [0xFF, 0xED, UInt8((plen >> 8) & 0xFF), UInt8(plen & 0xFF)])
                out.append(payload)
                replaced = true
            } else {
                out.append(Data(b[segStart..<(pos + len)]))
            }
            pos += len
        }
        return nil
    }

    /// Inserts raw marker segments before SOS.
    static func spliceJPEGMarkers(_ data: Data, _ inserts: [(UInt8, Data)]) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var pos = 2
        var sosAt: Int?
        while pos + 1 < b.count {
            guard b[pos] == 0xFF else { return nil }
            while pos < b.count && b[pos] == 0xFF { pos += 1 }
            guard pos < b.count else { return nil }
            let m = b[pos]; pos += 1
            if m == 0xDA { sosAt = pos - 2; break }
            if m == 0xD8 || m == 0xD9 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) { continue }
            guard pos + 2 <= b.count else { return nil }
            let len = Int(b[pos]) << 8 | Int(b[pos + 1])
            guard len >= 2, pos + len <= b.count else { return nil }
            pos += len
        }
        guard let cut = sosAt else { return nil }
        var out = Data(b[0..<cut])
        for (marker, payload) in inserts {
            let len = payload.count + 2
            out.append(contentsOf: [0xFF, marker, UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
            out.append(payload)
        }
        out.append(Data(b[cut...]))
        return out
    }

    /// Splices a tag into the JPEG Exif APP1 payload (TIFF structure after
    /// the 6-byte Exif header).
    static func spliceJPEGExifTag(_ data: Data, tag: Int, payload: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var out = Data()
        var pos = 0
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
            let payloadStart = pos + 2
            let segPayload = Data(b[payloadStart..<(pos + len)])
            if m == 0xE1 && !done && segPayload.prefix(6) == Data("Exif\0\0".utf8),
               let spliced = spliceTIFFTag(segPayload.dropFirst(6), tag: tag, type: 7, payload: payload) {
                var newPayload = Data("Exif\0\0".utf8)
                newPayload.append(spliced)
                let newLen = newPayload.count + 2
                out.append(contentsOf: [0xFF, 0xE1, UInt8((newLen >> 8) & 0xFF), UInt8(newLen & 0xFF)])
                out.append(newPayload)
                done = true
            } else {
                out.append(Data(b[segStart..<(pos + len)]))
            }
            pos += len
        }
        return nil
    }

    /// The XMP packet carried in the JPEG XMP APP1 segment, if any.
    static func jpegXMPPacket(_ data: Data) -> String? {
        guard let inv = jpegInventory(data) else { return nil }
        let xmpPrefix = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        for (name, _, payload) in inv where name == "FFE1" {
            if payload.prefix(xmpPrefix.count) == xmpPrefix {
                return String(data: payload.dropFirst(xmpPrefix.count), encoding: .utf8)
            }
        }
        return nil
    }

    /// Per-resource IRB survival report against the source IRB.
    static func irbReport(source: Data, output: Data) -> [String] {
        guard let inv = jpegInventory(output) else { return ["output unparseable"] }
        let srcResources = irbResources(source) ?? []
        var lines: [String] = ["source IRB resources: \(srcResources.map { String(format: "0x%04X len=%d hex=%@", $0.0, $0.1.count, hexPrefix($0.1, 40)) }.joined(separator: " | "))"]
        let outAPP13s = inv.filter { $0.0 == "FFED" }
        for (i, seg) in outAPP13s.enumerated() {
            if let res = irbResources(seg.2) {
                lines.append("output IRB[\(i)] resources: \(res.map { String(format: "0x%04X len=%d hex=%@", $0.0, $0.1.count, hexPrefix($0.1, 40)) }.joined(separator: " | "))")
            } else {
                lines.append("output FFED[\(i)] non-IRB len=\(seg.1) hex=\(hexPrefix(seg.2, 40))")
            }
        }
        let outPayloads = outAPP13s.flatMap { irbResources($0.2) ?? [] }.map { $0.1 }
        for (rid, payload) in srcResources {
            lines.append("resource \(String(format: "0x%04X", rid)): \(outPayloads.contains(payload) ? "SURVIVED-EXACT" : "MISSING-OR-ALTERED")")
        }
        return lines
    }

    /// Cycle-3 evidence for the remaining unverified surfaces: IRB resource
    /// survival on both JPEG routes, APP2/APP14 survival and ordering, Exif
    /// MakerNote/private-tag survival in JPEG APP1, TIFF ICC carry vs
    /// regenerate, XMP unrelated-field round-trip, DQT/entropy on the plain
    /// set, HEIC meta children on removal. Diagnostic only: never throws.
    static func runDeepProbe(root: URL) {
        let outDir = ProcessInfo.processInfo.environment["PRESERVATION_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        let probeRoot = root.appendingPathComponent("deepprobe", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        var report: [String] = []

        // A/B: plain set + removal with full payload dumps.
        for (name, remove) in [("set", false), ("remove", true)] {
            let f = probeRoot.appendingPathComponent("deep-plain-\(name).jpg")
            try? fixtureWithMetadata(at: f, type: "public.jpeg" as CFString)
            if let before = try? Data(contentsOf: f) {
                let ok = update(f, f, remove: remove)
                let after = (try? Data(contentsOf: f)) ?? Data()
                report.append("== jpg-plain-\(name): ok=\(ok) entropyEqual=\(jpegEntropyData(before) == jpegEntropyData(after))")
                report.append("BEFORE: " + jpegSegmentDump(before).joined(separator: " ; "))
                report.append("AFTER: " + jpegSegmentDump(after).joined(separator: " ; "))
                if let x = jpegXMPPacket(before) { report.append("XMP-BEFORE: \(x)") }
                if let x = jpegXMPPacket(after) { report.append("XMP-AFTER: \(x)") }
            }
        }

        // C: crafted genuine-format IRB through both routes.
        let resolution = Data([0x00, 0x48, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x48, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01])
        let irb = buildIRB([
            (0x03ED, resolution),
            (0x0404, Data("IPTC-DATED-2001-02-03".utf8)),
            (0x0424, Data("<x:xmpmeta>STALE-XMP-IN-IRB-2001</x:xmpmeta>".utf8)),
            (0x0FA0, Data("DEEPPROBE-UNKNOWNRES".utf8)),
        ])
        for (name, remove) in [("set", false), ("remove", true)] {
            let f = probeRoot.appendingPathComponent("deep-irb-\(name).jpg")
            try? fixtureWithMetadata(at: f, type: "public.jpeg" as CFString)
            if let data = try? Data(contentsOf: f), let spliced = jpegReplacingAPP13(data, payload: irb) {
                try? spliced.write(to: f)
                let ok = update(f, f, remove: remove)
                let after = (try? Data(contentsOf: f)) ?? Data()
                report.append("== jpg-irb-\(name): ok=\(ok)")
                report.append(contentsOf: irbReport(source: irb, output: after))
            }
        }

        // D: APP2 (fake ICC) + APP14 (Adobe transform) through both routes.
        let app14 = Data("Adobe".utf8) + Data([0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x01])
        for (name, remove) in [("set", false), ("remove", true)] {
            let f = probeRoot.appendingPathComponent("deep-app2-\(name).jpg")
            try? fixtureWithMetadata(at: f, type: "public.jpeg" as CFString)
            if let data = try? Data(contentsOf: f),
               let spliced = spliceJPEGMarkers(data, [(0xE2, Data("DEEPPROBE-FAKEICC".utf8)), (0xEE, app14)]) {
                try? spliced.write(to: f)
                let ok = update(f, f, remove: remove)
                let after = (try? Data(contentsOf: f)) ?? Data()
                report.append("== jpg-app2app14-\(name): ok=\(ok)")
                report.append("AFTER: " + jpegSegmentDump(after).joined(separator: " ; "))
            }
        }

        // E: MakerNote + private tag inside JPEG Exif APP1, removal route.
        let fExif = probeRoot.appendingPathComponent("deep-exif-remove.jpg")
        try? fixtureWithMetadata(at: fExif, type: "public.jpeg" as CFString)
        if let data = try? Data(contentsOf: fExif),
           let spliced1 = spliceJPEGExifTag(data, tag: 37500, payload: Data("DEEPPROBE-MAKERNOTE".utf8)),
           let spliced2 = spliceJPEGExifTag(spliced1, tag: 65000, payload: Data("DEEPPROBE-EXIFPRIV".utf8)) {
            try? spliced2.write(to: fExif)
            let beforeInv = jpegInventory(spliced2)?.filter { $0.0 == "FFE1" }.first.map { hexPrefix($0.2, 400) } ?? "none"
            let ok = update(fExif, fExif, remove: true)
            let after = (try? Data(contentsOf: fExif)) ?? Data()
            let afterInv = jpegInventory(after)?.filter { $0.0 == "FFE1" }.first.map { hexPrefix($0.2, 400) } ?? "none"
            report.append("== jpg-exif-remove: ok=\(ok)")
            report.append("EXIF-BEFORE: \(beforeInv)")
            report.append("EXIF-AFTER: \(afterInv)")
        }

        // F: TIFF ICC carry vs regenerate on both paths.
        for (name, remove) in [("set", false), ("remove", true)] {
            let f = probeRoot.appendingPathComponent("deep-icc-\(name).tiff")
            try? fixtureWithMetadata(at: f, type: "public.tiff" as CFString)
            if let data = try? Data(contentsOf: f),
               let spliced = spliceTIFFTag(data, tag: 34675, type: 7, payload: Data("DEEPPROBE-FAKE-ICC-PROFILE".utf8)) {
                try? spliced.write(to: f)
                let beforeLines = tiffInventory(spliced)?.filter { $0.contains("tag=34675") } ?? ["no-34675"]
                let ok = update(f, f, remove: remove)
                let after = (try? Data(contentsOf: f)) ?? Data()
                let afterLines = tiffInventory(after)?.filter { $0.contains("tag=34675") } ?? ["no-34675"]
                report.append("== tiff-icc-\(name): ok=\(ok)")
                report.append("ICC-BEFORE: \(beforeLines.joined(separator: " | "))")
                report.append("ICC-AFTER: \(afterLines.joined(separator: " | "))")
            }
        }

        // G: HEIC meta children on the removal path.
        let fHeic = probeRoot.appendingPathComponent("deep-remove.heic")
        try? fixtureWithMetadata(at: fHeic, type: "public.heic" as CFString)
        if let before = try? Data(contentsOf: fHeic) {
            report.append("== heic-remove-before: " + heicMetaChildHex(before).joined(separator: " | "))
            let ok = update(fHeic, fHeic, remove: true)
            let after = (try? Data(contentsOf: fHeic)) ?? Data()
            report.append("== heic-remove: ok=\(ok)")
            report.append("== heic-remove-after: " + heicMetaChildHex(after).joined(separator: " | "))
        }

        if let outDir = outDir {
            try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("deepprobe-report.txt"), atomically: true, encoding: .utf8)
        }
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

    // MARK: - Added-Exif TIFF builder (verification boundary tests)

    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: Int) -> [UInt8] { be16((v >> 16) & 0xFFFF) + be16(v & 0xFFFF) }

    /// Assembles a minimal big-endian Exif TIFF matching the shape ImageIO
    /// emitted in run 41716235473: IFD0 (+ optional ExifIFD/GPSIFD reached
    /// through pointer tags 34665/34853), out-of-line values appended after
    /// all directories. `extraIFD0` injects raw extra entries (tag, type,
    /// payload) for unknown/duplicate tag cases.
    static func addedExifTIFF(
        orientation: Int? = 1,
        dateTime: String? = nil,
        tileWidth: Int? = nil,
        tileHeight: Int? = nil,
        exifIFDDates: [String]? = nil,
        gpsLatRef: String? = nil,
        gpsLat: [(Int, Int)]? = nil,
        gpsLonRef: String? = nil,
        gpsLon: [(Int, Int)]? = nil,
        extraIFD0: [(Int, Int, [UInt8])] = []
    ) -> Data {
        func ascii(_ str: String) -> [UInt8] { Array(str.utf8) + [0] }
        func rationals(_ rs: [(Int, Int)]) -> [UInt8] {
            var out: [UInt8] = []
            for (n, d) in rs { out += be32(n) + be32(d) }
            return out
        }
        func typeSize(_ t: Int) -> Int {
            switch t { case 3: return 2; case 4: return 4; case 5: return 8; default: return 1 }
        }
        var ifd0: [(Int, Int, [UInt8])] = []
        if let orientation = orientation { ifd0.append((274, 3, be16(orientation))) }
        if let dateTime = dateTime { ifd0.append((306, 2, ascii(dateTime))) }
        if let tileWidth = tileWidth { ifd0.append((322, 4, be32(tileWidth))) }
        if let tileHeight = tileHeight { ifd0.append((323, 4, be32(tileHeight))) }
        var exifIFD: [(Int, Int, [UInt8])] = []
        if let exifIFDDates = exifIFDDates {
            for (i, d) in exifIFDDates.enumerated() { exifIFD.append((36867 + i, 2, ascii(d))) }
        }
        var gpsIFD: [(Int, Int, [UInt8])] = []
        if let gpsLatRef = gpsLatRef { gpsIFD.append((1, 2, ascii(gpsLatRef))) }
        if let gpsLat = gpsLat { gpsIFD.append((2, 5, rationals(gpsLat))) }
        if let gpsLonRef = gpsLonRef { gpsIFD.append((3, 2, ascii(gpsLonRef))) }
        if let gpsLon = gpsLon { gpsIFD.append((4, 5, rationals(gpsLon))) }
        if !exifIFD.isEmpty { ifd0.append((34665, 4, [0, 0, 0, 0])) }
        if !gpsIFD.isEmpty { ifd0.append((34853, 4, [0, 0, 0, 0])) }
        ifd0 += extraIFD0
        func ifdSize(_ entries: [(Int, Int, [UInt8])]) -> Int { 2 + 12 * entries.count + 4 }
        let ifd0Offset = 8
        let exifOffset = ifd0Offset + ifdSize(ifd0)
        let gpsOffset = exifOffset + (exifIFD.isEmpty ? 0 : ifdSize(exifIFD))
        var dataOffset = gpsOffset + (gpsIFD.isEmpty ? 0 : ifdSize(gpsIFD))
        ifd0 = ifd0.map { entry in
            if entry.0 == 34665, entry.1 == 4 { return (34665, 4, be32(exifOffset)) }
            if entry.0 == 34853, entry.1 == 4 { return (34853, 4, be32(gpsOffset)) }
            return entry
        }
        var dataArea: [UInt8] = []
        func renderIFD(_ entries: [(Int, Int, [UInt8])]) -> [UInt8] {
            var out = be16(entries.count)
            for (tag, type, payload) in entries.sorted(by: { $0.0 < $1.0 }) {
                out += be16(tag) + be16(type) + be32(payload.count / typeSize(type))
                if payload.count <= 4 {
                    out += payload + Array(repeating: 0, count: 4 - payload.count)
                } else {
                    out += be32(dataOffset)
                    dataArea += payload
                    dataOffset += payload.count
                }
            }
            out += be32(0)
            return out
        }
        var tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A] + be32(ifd0Offset)
        tiff += renderIFD(ifd0)
        if !exifIFD.isEmpty { tiff += renderIFD(exifIFD) }
        if !gpsIFD.isEmpty { tiff += renderIFD(gpsIFD) }
        tiff += dataArea
        return Data(tiff)
    }

    /// M18 (B3 + S8): a TIFF carrying a native IPTC-NAA tag (33723) refuses
    /// every date/location-touching op, the refusal reaches the operation's
    /// note, and the refused write leaves the original byte-identical.
    static func runTIFFIPTCRefusalProbe(root: URL) throws {
        // Minimal little-endian 8x6 gray TIFF with an inline 4-byte IPTC-NAA tag.
        let pixelCount = 8 * 6
        let ifdBytes = 2 + 12 * 10 + 4
        let pixelOffset = 8 + ifdBytes
        var tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) {
            tiff.append(contentsOf: [UInt8(tag & 0xFF), UInt8(tag >> 8), UInt8(type & 0xFF), UInt8(type >> 8),
                                     UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF), UInt8((count >> 16) & 0xFF), UInt8((count >> 24) & 0xFF),
                                     UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
        }
        tiff.append(contentsOf: [0x0A, 0x00]) // 10 entries
        entry(256, 3, 1, 8)                    // ImageWidth
        entry(257, 3, 1, 6)                    // ImageLength
        entry(258, 3, 1, 8)                    // BitsPerSample
        entry(259, 3, 1, 1)                    // Compression: none
        entry(262, 3, 1, 1)                    // Photometric: BlackIsZero
        entry(273, 4, 1, UInt32(pixelOffset))  // StripOffsets
        entry(277, 3, 1, 1)                    // SamplesPerPixel
        entry(278, 4, 1, 6)                    // RowsPerStrip
        entry(279, 4, 1, UInt32(pixelCount))   // StripByteCounts
        entry(33723, 7, 4, 0x43545049)         // IPTC-NAA, inline "IPTC"
        tiff.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // next IFD
        tiff.append(Data(repeating: 0x7F, count: pixelCount))
        let f = root.appendingPathComponent("m18-iptc.tiff")
        try tiff.write(to: f)
        let before = try Data(contentsOf: f)
        for op in [(date: Date(timeIntervalSince1970: 981173106) as Date?, removeDate: false, removeLocation: false, name: "set"),
                   (date: nil as Date?, removeDate: true, removeLocation: false, name: "removeDate"),
                   (date: nil as Date?, removeDate: false, removeLocation: true, name: "removeLocation")] {
            let note = MetadataWriter.RefusalNote()
            let ok = MetadataWriter.updateImageMetadata(sourceURL: f, destinationURL: f, date: op.date, removeDate: op.removeDate,
                                                        latitude: nil, longitude: nil, removeLocation: op.removeLocation, refusalNote: note)
            try require(!ok, "TIFF with native IPTC-NAA must refuse a \(op.name)")
            try require(note.reason?.contains("33723") == true, "refusal note must name 33723, got: \(note.reason ?? "none")")
            try require(try Data(contentsOf: f) == before, "refused write must leave the original intact")
        }
    }

    /// M18 (S2): a HEIC removal that empties the XMP packet passes via the
    /// spliced minimal packet; the output mime item reparses to zero tags.
    /// Also prints the xmp:MetadataDate regeneration evidence (reviewer
    /// verification item 4) for CI codification.
    static func runHEICEmptyPacketProbe(root: URL) throws {
        let heic = root.appendingPathComponent("m18-empty-packet.heic")
        // Seeded known-stale xmp:MetadataDate (reviewer requirement): a
        // boolean presence print cannot distinguish serializer regeneration
        // from survival of an old value. The output value is compared
        // against the seed and the write clock: equal to the seed proves
        // stale survival (the membership question flags back); near the
        // write clock proves regeneration as the edit timestamp; absent
        // proves the serializer drops it (no stale carry to remove).
        let staleSeed = "1999-12-31T23:59:59Z"
        try fixtureWithSeededMetadataDate(at: heic, seed: staleSeed)
        printMetadataDateEvidence(heic, label: "fixture", seed: staleSeed)
        let date = Date(timeIntervalSince1970: 981173106)
        let setClock = Date()
        try require(MetadataWriter.updateImageMetadata(sourceURL: heic, destinationURL: heic, date: date, removeDate: false,
                                                       latitude: nil, longitude: nil, removeLocation: false),
                    "HEIC date set must succeed")
        printMetadataDateEvidence(heic, label: "post-set", seed: staleSeed, writeClock: setClock)
        let removalClock = Date()
        try require(MetadataWriter.updateImageMetadata(sourceURL: heic, destinationURL: heic, date: nil, removeDate: true,
                                                       latitude: nil, longitude: nil, removeLocation: false),
                    "HEIC removal emptying the XMP packet must succeed via the spliced minimal packet (S2)")
        printMetadataDateEvidence(heic, label: "post-removal", seed: staleSeed, writeClock: removalClock)
    }

    /// Minimal HEIC whose XMP packet carries a known-stale xmp:MetadataDate.
    static func fixtureWithSeededMetadataDate(at url: URL, seed: String) throws {
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
                                bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = context.makeImage()!
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            throw NSError(domain: "Fixtures", code: 1)
        }
        let meta = CGImageMetadataCreateMutable()
        try require(CGImageMetadataSetValueWithPath(meta, nil, "xmp:MetadataDate" as CFString, seed as CFString),
                    "seeded MetadataDate write failed")
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationMetadata: meta] as CFDictionary)
        try require(CGImageDestinationFinalize(writer), "seeded HEIC finalize failed")
    }

    /// Prints the actual xmp:MetadataDate value (or "absent") with the seed
    /// and the write clock, so the regeneration-vs-survival question is
    /// decidable from the log alone.
    static func printMetadataDateEvidence(_ url: URL, label: String, seed: String, writeClock: Date? = nil) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return }
        var value = "absent"
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:MetadataDate" as CFString),
           let v = CGImageMetadataTagCopyValue(tag) as? String {
            value = v
        }
        var line = "M18 probe: \(label) xmp:MetadataDate value = \(value) (seed \(seed)"
        if let clock = writeClock {
            line += ", write clock \(ISO8601DateFormatter().string(from: clock))"
        }
        line += ")"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// M18 (B4): 16-bit sources keep native precision through the PNG
    /// re-encode paths; interlaced sources pass only while the re-encode
    /// provably keeps the interlace method (CI9), otherwise the writer
    /// refuses and this probe goes red.
    static func run16BitProbe(root: URL) throws {
        let p16 = root.appendingPathComponent("m18-synth16.png")
        guard let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 16, bytesPerRow: 64,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
              let image = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(p16 as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "Fixtures", code: 3, userInfo: [NSLocalizedDescriptionKey: "16-bit fixture creation failed"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        try require(CGImageDestinationFinalize(dest), "16-bit fixture finalize")
        try require(MetadataWriter.updateImageMetadata(sourceURL: p16, destinationURL: p16, date: Date(timeIntervalSince1970: 981173106),
                                                       removeDate: false, latitude: nil, longitude: nil, removeLocation: false),
                    "16-bit PNG set must preserve native precision (B4)")
        guard let source = CGImageSourceCreateWithURL(p16 as CFURL, nil),
              let reread = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "16-bit output must decode"])
        }
        try require(reread.bitsPerComponent == 16, "16-bit PNG must stay 16bpc after a set")
    }

    /// M18: committed PngSuite fixtures (freeware, pinned SHA-256). Missing
    /// files skip locally but fail in CI (PINMAGE_FIXTURES_DIR set).
    static func runPngSuiteProbe(root: URL) throws {
        let ci = ProcessInfo.processInfo.environment["PINMAGE_FIXTURES_DIR"] != nil
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/pngsuite")
        func staged(_ name: String) throws -> URL? {
            let src = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else {
                try require(!ci, "PngSuite fixture \(name) missing in CI")
                print("M18: \(name) not found; skipped")
                return nil
            }
            let dst = root.appendingPathComponent(name)
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        }
        let date = Date(timeIntervalSince1970: 981173106)
        if let rgb16 = try staged("basn2c16.png") {
            try require(MetadataWriter.updateImageMetadata(sourceURL: rgb16, destinationURL: rgb16, date: date, removeDate: false,
                                                           latitude: nil, longitude: nil, removeLocation: false),
                        "basn2c16 (16bpc RGB) set must pass at native precision")
            guard let source = CGImageSourceCreateWithURL(rgb16 as CFURL, nil),
                  let reread = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "basn2c16 output must decode"])
            }
            try require(reread.bitsPerComponent == 16, "basn2c16 must stay 16bpc")
        }
        // CI9 (run 41753660960): ImageIO preserves the Adam7 interlace method
        // on the PNG re-encode - the staged output's IHDR matched the source
        // byte-exact (interlace byte included) and decoded pixels matched at
        // native 16bpc precision, so the write passed its own fail-closed
        // gates. The must-refuse premise (re-encode always de-interlaces)
        // was wrong on this runtime; the guarantee is structure preserved or
        // refuse, and the gates still refuse the moment any runtime
        // de-interlaces. Codified as must-pass with IHDR evidence printed.
        if let interlaced = try staged("basi2c16.png") {
            let note = MetadataWriter.RefusalNote()
            let ok = MetadataWriter.updateImageMetadata(sourceURL: interlaced, destinationURL: interlaced, date: date, removeDate: false,
                                                        latitude: nil, longitude: nil, removeLocation: false, refusalNote: note)
            FileHandle.standardError.write(Data("M18 probe: basi2c16 set outcome = \(ok ? "pass" : "refuse: \(note.reason ?? "unknown")")\n".utf8))
            try require(ok, "basi2c16 (interlaced) set must pass with the interlace method preserved (CI9 evidence): \(note.reason ?? "no note")")
            let out = try Data(contentsOf: interlaced)
            // PNG signature 8 bytes, then length(4) + type(4); IHDR payload
            // starts at offset 16: width(4) height(4) bitDepth colorType
            // compression filter interlace.
            if out.count > 28, [UInt8](out[8..<16]) == [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52] {
                let ihdr = [UInt8](out[16..<29]).map { String(format: "%02x", $0) }.joined()
                FileHandle.standardError.write(Data("M18 probe: basi2c16 output IHDR = \(ihdr) (bit depth \(out[24]), interlace \(out[28]))\n".utf8))
            }
            guard let interlaceSource = CGImageSourceCreateWithURL(interlaced as CFURL, nil),
                  let interlaceReread = CGImageSourceCreateImageAtIndex(interlaceSource, 0, nil) else {
                throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "basi2c16 output must decode"])
            }
            FileHandle.standardError.write(Data("M18 probe: basi2c16 output reread bitsPerComponent = \(interlaceReread.bitsPerComponent)\n".utf8))
            try require(interlaceReread.bitsPerComponent == 16, "basi2c16 output must stay 16bpc")
        }
        // CI10 (run 41754985589) codified outcomes: basn0g16 (16bpc gray)
        // passes at native precision; cdun2c08 refuses because the re-encode
        // drops the sBIT chunk and the aux guard names it - both are the
        // designed behavior, now asserted so any silent change goes red.
        if let gray16 = try staged("basn0g16.png") {
            let note = MetadataWriter.RefusalNote()
            let ok = MetadataWriter.updateImageMetadata(sourceURL: gray16, destinationURL: gray16, date: date, removeDate: false,
                                                        latitude: nil, longitude: nil, removeLocation: false, refusalNote: note)
            FileHandle.standardError.write(Data("M18 probe: basn0g16.png set outcome = \(ok ? "pass" : "refuse: \(note.reason ?? "unknown")")\n".utf8))
            try require(ok, "basn0g16 (16bpc gray) set must pass at native precision (CI10): \(note.reason ?? "no note")")
        }
        if let sbit = try staged("cdun2c08.png") {
            let note = MetadataWriter.RefusalNote()
            let ok = MetadataWriter.updateImageMetadata(sourceURL: sbit, destinationURL: sbit, date: date, removeDate: false,
                                                        latitude: nil, longitude: nil, removeLocation: false, refusalNote: note)
            FileHandle.standardError.write(Data("M18 probe: cdun2c08.png set outcome = \(ok ? "pass" : "refuse: \(note.reason ?? "unknown")")\n".utf8))
            try require(!ok && (note.reason ?? "").contains("sBIT"),
                        "cdun2c08 set must refuse naming the dropped sBIT chunk (CI10), got: \(ok) \(note.reason ?? "none")")
        }
    }

    /// M18: a Display-P3 HEIC keeps its color space through a transport
    /// write. The byte-exact item/iprp carriers are the transport guarantee;
    /// this readback is the independent runtime assertion (plan-vs-delta
    /// reconciliation: bounded to P3, no HDR claim).
    static func runP3HEICProbe(root: URL) throws {
        let p3heic = root.appendingPathComponent("m18-p3.heic")
        // CI10 (run 41754985589): premultipliedLast made ImageIO emit an
        // auxiliary alpha hvc1 item (auxl 2->[1]), and the writer's verified
        // plain-still shape gate refuses multi-hvc1 sources by design. The
        // probe's subject is the P3 color signal on the supported
        // single-item shape, so the fixture is opaque (T1 fixture-alignment
        // precedent: the fixture reflects the supported structure).
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(p3heic as CFURL, "public.heic" as CFString, 1, nil) else {
            throw NSError(domain: "Fixtures", code: 5, userInfo: [NSLocalizedDescriptionKey: "P3 HEIC fixture creation failed"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        try require(CGImageDestinationFinalize(dest), "P3 HEIC fixture finalize")
        try require(MetadataWriter.updateImageMetadata(sourceURL: p3heic, destinationURL: p3heic,
                                                       date: Date(timeIntervalSince1970: 981173106), removeDate: false,
                                                       latitude: nil, longitude: nil, removeLocation: false),
                    "P3 HEIC date set must pass")
        guard let source = CGImageSourceCreateWithURL(p3heic as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "P3 HEIC output must read back"])
        }
        // Establish the actual exposed color signal: the carrier-dependent
        // "ColorSpace" property when ImageIO surfaces it, otherwise the
        // decoded image's color space name. A nil property is not a pass:
        // the probe records which signal it observed and asserts on it.
        let exposed = props["ColorSpace" as CFString] as? String
        var decodedName = "unavailable"
        if let outImage = CGImageSourceCreateImageAtIndex(source, 0, nil), let space = outImage.colorSpace, let name = space.name as String? {
            decodedName = name
        }
        FileHandle.standardError.write(Data("M18 probe: P3 HEIC color signal: property=\(exposed ?? "unexposed") decoded=\(decodedName)\n".utf8))
        if let exposed = exposed {
            try require(exposed.contains("P3"), "P3 HEIC color space property must survive, got \(exposed)")
        } else {
            try require(decodedName.contains("P3"), "P3 HEIC decoded color space must survive, got \(decodedName)")
        }
    }

    /// Reviewer-requested evidence for the F2 representation question:
    /// replicates the production copy-write staging path (applyMetadataPlan
    /// + CGImageDestinationCopyImageSource, merge off) on the actual Nokia
    /// file and prints the GPS IFD entries (type/count/value bytes) from
    /// both the source and the staged output, so the SRATIONAL->RATIONAL
    /// question is settled on this file's own staged Exif.
    static func printNokiaGPSEvidence(_ file: URL, date: Date) {
        func gpsLines(_ data: Data, _ label: String) -> [String] {
            guard let inv = jpegInventory(data) else { return ["\(label): not a JPEG"] }
            for (name, _, payload) in inv where name == "FFE1" {
                if payload.count > 6, payload.starts(with: Data([0x45, 0x78, 0x69, 0x66, 0, 0])),
                   let lines = tiffInventory(Data(payload.dropFirst(6))) {
                    return lines.filter { $0.contains("34853") }.map { "\(label) \($0)" }
                }
            }
            return ["\(label): no Exif APP1"]
        }
        do {
            let srcData = try Data(contentsOf: file)
            for line in gpsLines(srcData, "F2-source") {
                FileHandle.standardError.write(Data("M18 probe: \(line)\n".utf8))
            }
            let simURL = file.deletingLastPathComponent().appendingPathComponent("HMD_Nokia_8.3_5G-copysim.jpg")
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let dest = CGImageDestinationCreateWithURL(simURL as CFURL, "public.jpeg" as CFString, 1, nil),
                  let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap({ CGImageMetadataCreateMutableCopy($0) }) else {
                FileHandle.standardError.write(Data("M18 probe: F2 staged simulation setup failed\n".utf8))
                return
            }
            _ = MetadataWriter.applyMetadataPlan(meta, date: date, removeDate: false, latitude: nil, longitude: nil, removeLocation: false)
            var copyError: Unmanaged<CFError>?
            let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: kCFBooleanFalse as Any]
            guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &copyError) else {
                FileHandle.standardError.write(Data("M18 probe: F2 staged simulation copy failed\n".utf8))
                return
            }
            let simData = try Data(contentsOf: simURL)
            for line in gpsLines(simData, "F2-staged") {
                FileHandle.standardError.write(Data("M18 probe: \(line)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("M18 probe: F2 staged simulation error \(error.localizedDescription)\n".utf8))
        }
    }

    /// M18: lawfully-licensed public camera fixtures (CC BY-SA 4.0,
    /// ianare/exif-py; fetched by CI with pinned SHA-256). Skipped when
    /// PINMAGE_FIXTURES_DIR is unset, enforced when set.
    static func runPublicFixtureProbe(root: URL) throws {
        guard let dir = ProcessInfo.processInfo.environment["PINMAGE_FIXTURES_DIR"], !dir.isEmpty else {
            print("M18: PINMAGE_FIXTURES_DIR unset; public-fixture probes skipped")
            return
        }
        let fdir = URL(fileURLWithPath: dir)
        func staged(_ name: String, as local: String? = nil) throws -> URL {
            let dst = root.appendingPathComponent(local ?? name)
            try FileManager.default.copyItem(at: fdir.appendingPathComponent(name), to: dst)
            return dst
        }
        let date = Date(timeIntervalSince1970: 981173106)
        // F-cases are independent staged copies: collect per-case failures
        // so one run surfaces every fixture outcome, then throw one
        // aggregate (same independence rule as the probe harness).
        var caseFailures: [String] = []
        func fcase(_ name: String, _ body: () throws -> Void) {
            do { try body() } catch {
                caseFailures.append("\(name): \(error.localizedDescription)")
                FileHandle.standardError.write(Data("M18 fixture case \(name) FAILED: \(error.localizedDescription)\n".utf8))
            }
        }
        fcase("F1") {
            let f1 = try staged("DSCN0010.jpg")
            try require(!MetadataWriter.updateImageMetadata(sourceURL: f1, destinationURL: f1, date: nil, removeDate: false,
                                                            latitude: nil, longitude: nil, removeLocation: true),
                        "F1 Nikon MakerNote removeLocation must refuse")
        }
        fcase("F2") {
            let f2a = try staged("HMD_Nokia_8.3_5G.jpg")
            printNokiaGPSEvidence(f2a, date: date)
            try require(MetadataWriter.updateImageMetadata(sourceURL: f2a, destinationURL: f2a, date: date, removeDate: false,
                                                           latitude: nil, longitude: nil, removeLocation: false),
                        "F2 Nokia date set must pass (B2 semantic compare)")
            try require(MetadataWriter.readExistingCoordinates(from: f2a) != nil, "F2 GPS must survive a date set")
            let f2b = try staged("HMD_Nokia_8.3_5G.jpg", as: "HMD_Nokia_8.3_5G-b.jpg")
            try require(MetadataWriter.updateImageMetadata(sourceURL: f2b, destinationURL: f2b, date: nil, removeDate: false,
                                                           latitude: nil, longitude: nil, removeLocation: true),
                        "F2 Nokia removeLocation must pass (B1 whole-IFD exemption)")
            try require(MetadataWriter.readExistingCoordinates(from: f2b) == nil, "F2 GPS must be gone after removeLocation")
        }
        fcase("F3") {
            let f3 = try staged("iphone_13_pro_max.heic")
            try require(!MetadataWriter.updateImageMetadata(sourceURL: f3, destinationURL: f3, date: nil, removeDate: false,
                                                            latitude: nil, longitude: nil, removeLocation: true),
                        "F3 Apple HEIC removeLocation must refuse (MakerNote policy)")
        }
        fcase("F4") {
            let f4 = try staged("Canon_40D.jpg")
            try require(MetadataWriter.updateImageMetadata(sourceURL: f4, destinationURL: f4, date: date, removeDate: false,
                                                           latitude: nil, longitude: nil, removeLocation: false),
                        "F4 Canon date set must pass")
            guard let f4Source = CGImageSourceCreateWithURL(f4 as CFURL, nil),
                  let f4Props = CGImageSourceCopyPropertiesAtIndex(f4Source, 0, nil) as? [CFString: Any],
                  let f4Exif = f4Props[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
                throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "F4 output must read back"])
            }
            try require(f4Exif[kCGImagePropertyExifSubsecTimeOriginal] != nil, "F4 SubSecTimeOriginal must survive")
        }
        fcase("F6") {
            let f6 = try staged("Tless0.tiff")
            try require(MetadataWriter.updateImageMetadata(sourceURL: f6, destinationURL: f6, date: date, removeDate: false,
                                                           latitude: nil, longitude: nil, removeLocation: false),
                        "F6 Tless0.tiff date set must pass")
        }
        fcase("F7") {
            let f7 = try staged("Arbitro.tiff")
            try require(MetadataWriter.updateImageMetadata(sourceURL: f7, destinationURL: f7, date: nil, removeDate: true,
                                                           latitude: nil, longitude: nil, removeLocation: false),
                        "F7 Arbitro.tiff removeDate must pass (tag 700 surgery)")
        }
        try require(caseFailures.isEmpty, "public fixture case failures [\(caseFailures.count)]: \(caseFailures.joined(separator: " | "))")
    }

    /// M18 (G1/S5): large camera-shaped HEIC (4032x3024) with full GPS.
    /// Non-enforcing: prints the write outcome, refusal reason and the added
    /// Exif item inventory so the Tile* rule gets codified from CI evidence.
    static func runLargeHEICProbe(root: URL) throws {
        let big = root.appendingPathComponent("m18-large.heic")
        guard let context = CGContext(data: nil, width: 4032, height: 3024, bitsPerComponent: 8,
                                      bytesPerRow: 4032 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(big as CFURL, "public.heic" as CFString, 1, nil) else {
            throw NSError(domain: "Fixtures", code: 4, userInfo: [NSLocalizedDescriptionKey: "large HEIC fixture creation failed"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        try require(CGImageDestinationFinalize(dest), "large HEIC fixture finalize")
        let before = try Data(contentsOf: big)
        let note = MetadataWriter.RefusalNote()
        let ok = MetadataWriter.updateImageMetadata(sourceURL: big, destinationURL: big, date: Date(timeIntervalSince1970: 981173106),
                                                    removeDate: false, latitude: 40.4, longitude: 3.7, removeLocation: false,
                                                    refusalNote: note)
        let after = try Data(contentsOf: big)
        let inventory = MetadataWriter.heicDiagnosticInventory(source: before, staged: after)
        FileHandle.standardError.write(Data("M18 large-HEIC probe: succeeded = \(ok), reason = \(note.reason ?? "none")\n\(inventory)\n".utf8))
        // CI10 (run 41754985589): a 98-item grid HEIC whose meta box carries
        // an idat child refuses with "unknown meta child idat" - the
        // designed fail-closed boundary (ImageIO restructures idat-carried
        // items into mdat, so meta byte-exactness is unprovable). Asserted
        // so any silent support change forces re-review.
        try require(!ok && (note.reason ?? "").contains("idat"),
                    "large grid HEIC with idat items must refuse naming the unsupported meta child (CI10), got: \(ok) \(note.reason ?? "none")")
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PinmageTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        // Soft checks collect failures across independent format stages so
        // one CI run surfaces every failing surface with its evidence; the
        // hard gate at the end of main keeps the suite red on any of them.
        var softFailures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                softFailures.append(message)
                FileHandle.standardError.write(Data("CHECK FAILED: \(message)\n".utf8))
            }
        }
        runDiagnosticsProbe(root: root)
        runAuxTransportProbe(root: root)
        runRouteProbe(root: root)
        runDeepProbe(root: root)
        // GPS coordinate parsing is strict and axis-aware: the hemisphere
        // reference must belong to the axis and sets the sign; malformed,
        // out-of-range or trailing-data values never parse; genuinely
        // different coordinates never compare equal.
        try require(abs((MetadataWriter.gpsDegrees("40,24N" as CFString, latitude: true) ?? 0) - 40.4) < 1e-9, "GPS sexagesimal N parse")
        try require(abs((MetadataWriter.gpsDegrees("40,24S" as CFString, latitude: true) ?? 0) + 40.4) < 1e-9, "GPS sexagesimal S sign")
        try require(abs((MetadataWriter.gpsDegrees("3,42E" as CFString, latitude: false) ?? 0) - 3.7) < 1e-9, "GPS sexagesimal E parse")
        try require(abs((MetadataWriter.gpsDegrees("3,42W" as CFString, latitude: false) ?? 0) + 3.7) < 1e-9, "GPS sexagesimal W sign")
        try require(abs((MetadataWriter.gpsDegrees("40,24,0N" as CFString, latitude: true) ?? 0) - 40.4) < 1e-9, "GPS sexagesimal with seconds")
        try require(MetadataWriter.gpsDegrees("40,24E" as CFString, latitude: true) == nil, "GPS latitude with longitude ref must fail")
        try require(MetadataWriter.gpsDegrees("3,42N" as CFString, latitude: false) == nil, "GPS longitude with latitude ref must fail")
        try require(MetadataWriter.gpsDegrees("40,24" as CFString, latitude: true) == nil, "GPS missing hemisphere ref must fail")
        try require(MetadataWriter.gpsDegrees("40,24N9" as CFString, latitude: true) == nil, "GPS trailing data must fail")
        try require(MetadataWriter.gpsDegrees("40,24 N" as CFString, latitude: true) == nil, "GPS embedded space must fail")
        try require(MetadataWriter.gpsDegrees("40,,24N" as CFString, latitude: true) == nil, "GPS empty component must fail")
        try require(MetadataWriter.gpsDegrees("-40,24N" as CFString, latitude: true) == nil, "GPS negative degrees must fail")
        try require(MetadataWriter.gpsDegrees("40,60N" as CFString, latitude: true) == nil, "GPS minutes out of range must fail")
        try require(MetadataWriter.gpsDegrees("40,24,60N" as CFString, latitude: true) == nil, "GPS seconds out of range must fail")
        try require(MetadataWriter.gpsDegrees("91,0N" as CFString, latitude: true) == nil, "GPS latitude out of range must fail")
        try require(MetadataWriter.gpsDegrees("181,0E" as CFString, latitude: false) == nil, "GPS longitude out of range must fail")
        try require(MetadataWriter.gpsDegrees("95" as CFString, latitude: true) == nil, "GPS numeric latitude out of range must fail")
        try require(MetadataWriter.gpsDegrees(40.4 as CFNumber, latitude: true) != nil, "GPS numeric parse")

        // M18 surgery unit tests (S9): the byte-surgery and semantic-compare
        // helpers are exercised directly, not only through full writes.
        // Exact rational reduction: no epsilon, sign into numerator, zero
        // denominators never equal (B2).
        try require(MetadataWriter.reducedRational(num: 6, den: 8).map { $0.0 == 3 && $0.1 == 4 } == true, "reduce 6/8")
        try require(MetadataWriter.reducedRational(num: -6, den: 8).map { $0.0 == -3 && $0.1 == 4 } == true, "reduce -6/8")
        try require(MetadataWriter.reducedRational(num: 6, den: -8).map { $0.0 == -3 && $0.1 == 4 } == true, "reduce 6/-8")
        try require(MetadataWriter.reducedRational(num: -4, den: -2).map { $0.0 == 2 && $0.1 == 1 } == true, "reduce -4/-2")
        try require(MetadataWriter.reducedRational(num: 0, den: 5).map { $0.0 == 0 && $0.1 == 1 } == true, "reduce 0/5")
        try require(MetadataWriter.reducedRational(num: 5, den: 0) == nil, "zero denominator refuses")
        try require(MetadataWriter.reducedRational(num: Int64(Int32.min), den: 1).map { $0.0 == Int64(Int32.min) } == true, "Int32.min numerator safe")
        // Rational field reads honor per-file endianness and signedness.
        let ratBE = Data([0, 0, 0, 100, 0, 0, 0, 1])
        let ratLE = Data([100, 0, 0, 0, 1, 0, 0, 0])
        try require(MetadataWriter.tiffRationalAt(ratBE, 0, false, false).map { $0.0 == 100 && $0.1 == 1 } == true, "rational BE read")
        try require(MetadataWriter.tiffRationalAt(ratLE, 0, false, true).map { $0.0 == 100 && $0.1 == 1 } == true, "rational LE read")
        let ratNeg = Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 2])
        try require(MetadataWriter.tiffRationalAt(ratNeg, 0, true, false).map { $0.0 == -1 && $0.1 == 2 } == true, "srational sign")
        // Semantic TIFF value equality (B2).
        try require(MetadataWriter.tiffValuesMatch(label: "IFD0", tag: 282, type: 5, sourceValue: ratBE, sourceLittle: false, outputValue: ratLE, outputLittle: true), "cross-endian rational equal")
        let halfA = Data([0, 0, 0, 1, 0, 0, 0, 2])
        let halfB = Data([0, 0, 0, 2, 0, 0, 0, 4])
        let third = Data([0, 0, 0, 1, 0, 0, 0, 3])
        try require(MetadataWriter.tiffValuesMatch(label: "IFD0", tag: 282, type: 5, sourceValue: halfA, sourceLittle: false, outputValue: halfB, outputLittle: false), "1/2 == 2/4 by reduction")
        try require(!MetadataWriter.tiffValuesMatch(label: "IFD0", tag: 282, type: 5, sourceValue: halfA, sourceLittle: false, outputValue: third, outputLittle: false), "1/2 != 1/3")
        let zeroDenA = Data([0, 0, 0, 1, 0, 0, 0, 0])
        let zeroDenB = Data([0, 0, 0, 2, 0, 0, 0, 0])
        try require(!MetadataWriter.tiffValuesMatch(label: "IFD0", tag: 282, type: 5, sourceValue: zeroDenA, sourceLittle: false, outputValue: zeroDenB, outputLittle: false), "zero denominators never semantically equal")
        let negHalf = Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 2])
        let negHalfB = Data([0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFE])
        try require(MetadataWriter.tiffValuesMatch(label: "IFD0", tag: 207, type: 10, sourceValue: negHalf, sourceLittle: false, outputValue: negHalfB, outputLittle: false), "srational -1/2 == 1/-2")
        // GPS DMS composition (tags 2/4 only): legal recomposition matches,
        // real differences and axis violations refuse.
        func dms(_ parts: [(Int, Int)]) -> Data {
            var d = Data()
            for (n, den) in parts {
                d.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF),
                                      UInt8(den >> 24 & 0xFF), UInt8(den >> 16 & 0xFF), UInt8(den >> 8 & 0xFF), UInt8(den & 0xFF)])
            }
            return d
        }
        let canon = dms([(40, 1), (24, 1), (0, 1)])
        let recomposed = dms([(40, 1), (23, 1), (6000, 100)])
        let different = dms([(41, 1), (0, 1), (0, 1)])
        try require(MetadataWriter.tiffValuesMatch(label: "IFD0>34853", tag: 2, type: 5, sourceValue: canon, sourceLittle: false, outputValue: recomposed, outputLittle: false), "DMS 40/24/0 == 40/23/60.00")
        try require(!MetadataWriter.tiffValuesMatch(label: "IFD0>34853", tag: 2, type: 5, sourceValue: canon, sourceLittle: false, outputValue: different, outputLittle: false), "DMS 40.4 != 41.0")
        try require(!MetadataWriter.tiffValuesMatch(label: "IFD0>34853", tag: 2, type: 5, sourceValue: canon, sourceLittle: false, outputValue: dms([(40, 1), (24, 1)]), outputLittle: false), "DMS count mismatch refuses")
        // The same recomposition under a non-GPS tag stays byte-exact.
        try require(!MetadataWriter.tiffValuesMatch(label: "IFD0", tag: 282, type: 5, sourceValue: canon, sourceLittle: false, outputValue: recomposed, outputLittle: false), "DMS tolerance confined to GPS degree tags")
        // ASCII: NUL-trimmed equality, content differences refuse.
        try require(MetadataWriter.tiffValuesMatch(label: "IFD0", tag: 271, type: 2, sourceValue: Data("abc\0".utf8), sourceLittle: false, outputValue: Data("abc\0\0".utf8), outputLittle: false), "ASCII NUL-trim")
        try require(!MetadataWriter.tiffValuesMatch(label: "IFD0", tag: 271, type: 2, sourceValue: Data("abc\0".utf8), sourceLittle: false, outputValue: Data("abd\0".utf8), outputLittle: false), "ASCII content differs")
        // Unproven types stay byte-exact.
        try require(!MetadataWriter.tiffValuesMatch(label: "IFD0", tag: 256, type: 3, sourceValue: Data([0, 8]), sourceLittle: false, outputValue: Data([0, 9]), outputLittle: false), "SHORT stays byte-exact")
        // TIFF tag-700 surgery: replace and drop, header repointed, bytes sane.
        var tiff700 = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        tiff700.append(contentsOf: [0x01, 0x00])                 // one entry
        tiff700.append(contentsOf: [0xBC, 0x02, 0x07, 0x00])     // tag 700 (0x02BC little-endian), type UNDEFINED
        tiff700.append(contentsOf: [0x05, 0x00, 0x00, 0x00])     // count 5 (>4, so offset-referenced)
        tiff700.append(contentsOf: [0x1A, 0x00, 0x00, 0x00])     // value offset 26
        tiff700.append(contentsOf: [0x00, 0x00, 0x00, 0x00])     // next IFD = 0
        tiff700.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE]) // packet bytes
        let packet = Data("<x/>".utf8)
        guard let replaced700 = MetadataWriter.tiffReplacingTag700(tiff700, correctedPacket: packet) else {
            throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "tag700 replace returned nil"])
        }
        try require(replaced700.count > tiff700.count, "tag700 replace appends the IFD copy")
        try require(replaced700.range(of: packet) != nil, "tag700 replace carries the new packet")
        try require(replaced700.range(of: Data([0xAA, 0xBB, 0xCC, 0xDD])) == nil, "tag700 replace drops the old packet")
        guard let dropped700 = MetadataWriter.tiffReplacingTag700(tiff700, correctedPacket: nil) else {
            throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "tag700 drop returned nil"])
        }
        try require(dropped700.range(of: Data([0xAA, 0xBB, 0xCC, 0xDD])) == nil, "tag700 drop removes the packet")
        // JPEG APP13 surgery: insert, replace, malformed refusal. The
        // insert policy fires on the first length-bearing segment past the
        // APP0/APP1 block; SOS is intercepted before that branch, so the
        // fixture needs the real-world shape of a DQT between APP0 and SOS
        // (the writer's documented supported structure, not an assumption
        // that every JPEG carries one - files that don't are replace-only
        // or refuse, which the malformed case below covers).
        var jpegBase = Data([0xFF, 0xD8])
        jpegBase.append(contentsOf: [0xFF, 0xE0, 0x00, 0x10])
        jpegBase.append(contentsOf: Data("JFIF\0".utf8) + Data(repeating: 0, count: 9))
        jpegBase.append(contentsOf: [0xFF, 0xDB, 0x00, 0x43])
        jpegBase.append(Data(repeating: 0, count: 65))  // Pq/Tq byte + 64 table entries
        jpegBase.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02])
        jpegBase.append(contentsOf: [0x11, 0x22, 0x33])
        jpegBase.append(contentsOf: [0xFF, 0xD9])
        // 8BIM + id 0x0406 + empty Pascal name (length byte + pad) + 4-byte
        // zero size = 12 bytes, a well-formed empty resource.
        let irb = Data("Photoshop 3.0\0".utf8) + Data([0x38, 0x42, 0x49, 0x4D, 0x04, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        guard let insertedIRB = MetadataWriter.jpegReplacingAPP13(jpegBase, payload: irb) else {
            throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "APP13 insert returned nil"])
        }
        try require(insertedIRB.range(of: irb) != nil, "APP13 insert carries the resource bytes")
        try require(insertedIRB.count > jpegBase.count, "APP13 insert grows the file")
        guard let replacedIRB = MetadataWriter.jpegReplacingAPP13(insertedIRB, payload: irb) else {
            throw NSError(domain: "MetadataWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "APP13 replace returned nil"])
        }
        try require(replacedIRB == insertedIRB, "APP13 replace is idempotent for identical bytes")
        try require(MetadataWriter.jpegReplacingAPP13(Data([0xFF, 0xD8, 0xFF]), payload: irb) == nil, "APP13 malformed source refuses")
        try require(MetadataWriter.metadataTagValuesEqual(path: "exif:GPSLatitude", "40,24N" as CFString, 40.4 as CFNumber), "GPS decimal vs sexagesimal equality")
        try require(!MetadataWriter.metadataTagValuesEqual(path: "exif:GPSLatitude", "40,24N" as CFString, (-40.4) as CFNumber), "GPS sign mismatch must not compare equal")
        try require(!MetadataWriter.metadataTagValuesEqual(path: "exif:GPSLatitude", "40,24N" as CFString, "40,24S" as CFString), "GPS hemisphere mismatch must not compare equal")
        try require(!MetadataWriter.metadataTagValuesEqual(path: "exif:GPSLatitude", "40,24N" as CFString, "41,24N" as CFString), "GPS different coordinate must not compare equal")

        // Added-Exif carrier verification: the real observed payload shape
        // (run 41716235473, non-canonical seconds == 60) plus boundary,
        // normalization and refusal cases. TIFF GPS rationals are compared
        // numerically with explicit bounds; the XMP string parser above
        // stays strictly canonical - an intentional asymmetry.
        let exifIntentDate = Date(timeIntervalSince1970: 1_700_000_000)
        let exifFmt = DateFormatter()
        exifFmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let exifDateString = exifFmt.string(from: exifIntentDate)
        func exifVerdict(_ tiff: Data, date: Date? = nil, removeDate: Bool = false,
                         lat: Double? = nil, lon: Double? = nil, removeLocation: Bool = false,
                         width: Int? = 8, height: Int? = 6, sourceOrientation: Int? = nil) -> Bool {
            MetadataWriter.verifyAddedExifCarrier(
                tiff: tiff, date: date, removeDate: removeDate,
                latitude: lat, longitude: lon, removeLocation: removeLocation,
                pixelWidth: width, pixelHeight: height, sourceOrientation: sourceOrientation).ok
        }
        let realExifPayload = addedExifTIFF(
            orientation: 1, dateTime: exifDateString, tileWidth: 8, tileHeight: 6,
            exifIFDDates: [exifDateString, exifDateString],
            gpsLatRef: "N", gpsLat: [(40, 1), (23, 1), (6000, 100)],
            gpsLonRef: "W", gpsLon: [(3, 1), (42, 1), (0, 1)])
        check(exifVerdict(realExifPayload, date: exifIntentDate, lat: 40.4, lon: -3.7),
              "added Exif: real observed payload (seconds == 60) must verify")
        let canonicalExifPayload = addedExifTIFF(
            orientation: 1, dateTime: exifDateString, tileWidth: 8, tileHeight: 6,
            exifIFDDates: [exifDateString, exifDateString],
            gpsLatRef: "N", gpsLat: [(40, 1), (24, 1), (0, 1)],
            gpsLonRef: "W", gpsLon: [(3, 1), (42, 1), (0, 1)])
        check(exifVerdict(canonicalExifPayload, date: exifIntentDate, lat: 40.4, lon: -3.7),
              "added Exif: canonical 40/24/0 must normalize to the same degrees")
        check(!exifVerdict(addedExifTIFF(orientation: 1, dateTime: exifDateString, tileWidth: 8, tileHeight: 6,
                                         exifIFDDates: [exifDateString, exifDateString],
                                         gpsLatRef: "N", gpsLat: [(40, 1), (23, 1), (60, 0)],
                                         gpsLonRef: "W", gpsLon: [(3, 1), (42, 1), (0, 1)]),
                           date: exifIntentDate, lat: 40.4, lon: -3.7),
              "added Exif: zero rational denominator must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: 1, dateTime: exifDateString, tileWidth: 8, tileHeight: 6,
                                         exifIFDDates: [exifDateString, exifDateString],
                                         gpsLatRef: "N", gpsLat: [(4_294_967_295, 1), (0, 1), (0, 1)],
                                         gpsLonRef: "W", gpsLon: [(3, 1), (42, 1), (0, 1)]),
                           date: exifIntentDate, lat: 40.4, lon: -3.7),
              "added Exif: overflowing rational numerator must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: 1, dateTime: exifDateString, tileWidth: 8, tileHeight: 6,
                                         exifIFDDates: [exifDateString, exifDateString],
                                         gpsLatRef: "N", gpsLat: [(91, 1), (0, 1), (0, 1)],
                                         gpsLonRef: "W", gpsLon: [(3, 1), (42, 1), (0, 1)]),
                           date: exifIntentDate, lat: 91, lon: -3.7),
              "added Exif: out-of-axis latitude must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: 1, dateTime: exifDateString, tileWidth: 8, tileHeight: 6,
                                         exifIFDDates: [exifDateString, exifDateString],
                                         gpsLatRef: "S", gpsLat: [(40, 1), (24, 1), (0, 1)],
                                         gpsLonRef: "W", gpsLon: [(3, 1), (42, 1), (0, 1)]),
                           date: exifIntentDate, lat: 40.4, lon: -3.7),
              "added Exif: hemisphere mismatch must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: 1, dateTime: exifDateString, tileWidth: 8, tileHeight: 6,
                                         exifIFDDates: [exifDateString, exifDateString],
                                         gpsLatRef: "N", gpsLat: [(40, 1), (25, 1), (0, 1)],
                                         gpsLonRef: "W", gpsLon: [(3, 1), (42, 1), (0, 1)]),
                           date: exifIntentDate, lat: 40.4, lon: -3.7),
              "added Exif: different coordinate must refuse")
        // Orientation preservation: a source orientation must round-trip,
        // never be silently reset to 1 or dropped; with no source
        // orientation only the synthesized default 1 admits.
        let orientedPayload = addedExifTIFF(orientation: 6, tileWidth: 8, tileHeight: 6)
        check(exifVerdict(orientedPayload, sourceOrientation: 6),
              "added Exif: source Orientation 6 preserved must verify")
        check(!exifVerdict(orientedPayload, sourceOrientation: 3),
              "added Exif: Orientation reset relative to source must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: nil, tileWidth: 8, tileHeight: 6), sourceOrientation: 6),
              "added Exif: dropped source Orientation must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: 2, tileWidth: 8, tileHeight: 6)),
              "added Exif: synthesized Orientation != 1 without source orientation must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: 1, dateTime: "2020:01:01 00:00:00", tileWidth: 8, tileHeight: 6,
                                         exifIFDDates: [exifDateString, exifDateString],
                                         gpsLatRef: "N", gpsLat: [(40, 1), (24, 1), (0, 1)],
                                         gpsLonRef: "W", gpsLon: [(3, 1), (42, 1), (0, 1)]),
                           date: exifIntentDate, lat: 40.4, lon: -3.7),
              "added Exif: wrong date value must refuse")
        check(!exifVerdict(realExifPayload, removeDate: true, removeLocation: true),
              "added Exif: intent metadata present under removal must refuse")
        check(exifVerdict(addedExifTIFF(orientation: 1, tileWidth: 8, tileHeight: 6)),
              "added Exif: synthesized-only payload with empty intent must verify")
        check(!exifVerdict(addedExifTIFF(orientation: 1, dateTime: exifDateString, tileWidth: 8, tileHeight: 6,
                                         exifIFDDates: [exifDateString, exifDateString]),
                           date: exifIntentDate, lat: 40.4, lon: -3.7),
              "added Exif: missing GPS under location intent must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: 1, tileWidth: 9, tileHeight: 6)),
              "added Exif: TileWidth != decoded width must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: 1, tileWidth: 8, tileHeight: 6,
                                         extraIFD0: [(500, 3, be16(1))])),
              "added Exif: unknown tag must refuse")
        check(!exifVerdict(addedExifTIFF(orientation: 1, tileWidth: 8, tileHeight: 6,
                                         extraIFD0: [(274, 3, be16(1))])),
              "added Exif: duplicate tag must refuse")
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
            let wrote = update(photo, photo)
            check(wrote, "Overwrite failed for \(ext)")
            if wrote {
                check(try pixelData(photo) == pixelsBeforeWrite, "Pixels changed during write in \(ext)")
                check(MetadataWriter.validateImage(photo, photo), "Invalid \(ext) output")
                let coords = MetadataWriter.readExistingCoordinates(from: photo)
                check(coords != nil && abs(coords!.latitude - 40.4) < 0.001 && abs(coords!.longitude + 3.7) < 0.001,
                      "GPS tags missing in \(ext)")
                let imageSource = CGImageSourceCreateWithURL(photo as CFURL, nil)!
                let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
                let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
                check(exif?[kCGImagePropertyExifDateTimeOriginal] != nil, "Date missing in \(ext)")
            }
        }

        // M17: honest removal semantics. Removing date/location must produce a
        // file that no longer carries those tags in ANY supported format
        // (the PNG encoder previously inherited the source GPS dictionary).
        for (ext, uti) in [("png", "public.png"), ("jpg", "public.jpeg"), ("tiff", "public.tiff"), ("heic", "public.heic")] {
            let photo = root.appendingPathComponent("removal.\(ext)")
            try fixtureWithMetadata(at: photo, type: uti as CFString)
            try require(MetadataWriter.readExistingCoordinates(from: photo) != nil, "Fixture GPS missing in \(ext)")
            let pixelsBeforeRemoval = try pixelData(photo)
            let removed = update(photo, photo, remove: true)
            check(removed, "Removal overwrite failed for \(ext)")
            if removed {
                check(MetadataWriter.validateImage(photo, photo), "Invalid \(ext) after removal")
                check(try pixelData(photo) == pixelsBeforeRemoval, "Pixels changed during removal in \(ext)")
                check(MetadataWriter.readExistingCoordinates(from: photo) == nil, "GPS survived removal in \(ext)")
                let imageSource = CGImageSourceCreateWithURL(photo as CFURL, nil)!
                let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
                let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
                check(exif?[kCGImagePropertyExifDateTimeOriginal] == nil, "DateTimeOriginal survived removal in \(ext)")
                check(exif?[kCGImagePropertyExifDateTimeDigitized] == nil, "DateTimeDigitized survived removal in \(ext)")
                let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                check(tiff?[kCGImagePropertyTIFFDateTime] == nil, "TIFF DateTime survived removal in \(ext)")
                check(props?[kCGImagePropertyGPSDictionary] == nil, "GPS dictionary survived removal in \(ext)")
            }
            if ext == "png", removed {
                // M15b XMP correction: the carrier is either gone (nothing
                // survived) or holds a corrected packet. It must never carry
                // the removed values - stale XMP is the M17 bug.
                if let packet = try xmpPacketString(photo) {
                    check(!packet.contains("2001-02-03") && !packet.contains("2001:02:03"),
                          "Removed date survived in png XMP packet")
                    check(!packet.contains("GPSLatitude"), "Removed GPS survived in png XMP packet")
                }
            }
        }
        // M15 ftyp transplant: a successful HEIC write must publish the
        // source's own brand declarations. ImageIO rewrites the ftyp brand
        // list (run 41697547199 evidence); the transplant restores the
        // source box and shifts iloc offsets, fully re-verified.
        do {
            let f = root.appendingPathComponent("ftyp-restore.heic")
            try fixtureWithMetadata(at: f, type: "public.heic" as CFString)
            let before = try Data(contentsOf: f)
            let wrote = update(f, f)
            check(wrote, "HEIC set must succeed with the ftyp transplant")
            if wrote {
                let after = try Data(contentsOf: f)
                let beforeLine = heicInventory(before)?.first(where: { $0.hasPrefix("top ftyp") })
                let afterLine = heicInventory(after)?.first(where: { $0.hasPrefix("top ftyp") })
                check(beforeLine != nil && beforeLine == afterLine,
                      "HEIC output ftyp does not match the source declarations")
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
            let intentWrote = update(written, written)
            check(intentWrote, "Intent write failed for \(ext)")
            if intentWrote {
                let good = MetadataWriter.WritePlan(date: when, removeDate: false, latitude: 40.4, longitude: -3.7, removeLocation: false)
                check(MetadataWriter.verifyIntent(good, in: written), "Readback rejected a correct write in \(ext)")
                let wrongDate = MetadataWriter.WritePlan(date: when.addingTimeInterval(86_400), removeDate: false, latitude: nil, longitude: nil, removeLocation: false)
                check(!MetadataWriter.verifyIntent(wrongDate, in: written), "Readback accepted a wrong date in \(ext)")
                let wrongPlace = MetadataWriter.WritePlan(date: nil, removeDate: false, latitude: 10, longitude: 10, removeLocation: false)
                check(!MetadataWriter.verifyIntent(wrongPlace, in: written), "Readback accepted a wrong location in \(ext)")
                let notRemoved = MetadataWriter.WritePlan(date: nil, removeDate: true, latitude: nil, longitude: nil, removeLocation: true)
                check(!MetadataWriter.verifyIntent(notRemoved, in: written), "Readback accepted surviving date/GPS in \(ext)")
                let intentRemoved = update(written, written, remove: true)
                check(intentRemoved, "Intent removal failed for \(ext)")
                if intentRemoved {
                    check(MetadataWriter.verifyIntent(notRemoved, in: written), "Readback rejected a correct removal in \(ext)")
                }
            }
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
        let tiff700URL = root.appendingPathComponent("aux-tiff-700.tiff")
        try fixtureWithMetadata(at: tiff700URL, type: "public.tiff" as CFString)
        let stalePacket = Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:CreateDate=\"2001-02-03T04:05:06\"/></rdf:RDF></x:xmpmeta>".utf8)
        let with700 = spliceTIFFTag(try Data(contentsOf: tiff700URL), tag: 700, type: 7, payload: stalePacket)
        try require(with700 != nil, "TIFF tag-700 splice failed")
        try with700!.write(to: tiff700URL)
        try require(update(tiff700URL, tiff700URL, remove: true), "TIFF removal with a stale XMP carrier must correct or drop it, not refuse")
        let tiff700Bytes = try Data(contentsOf: tiff700URL)
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

        // JPEG set (copy-write route, settled on run 41690332177 evidence):
        // foreign aux segments are transported byte-exact like on removal.
        let jpgSet = root.appendingPathComponent("aux-jpg-set.jpg")
        try fixtureWithMetadata(at: jpgSet, type: "public.jpeg" as CFString)
        let splicedJS = spliceJPEGAux(try Data(contentsOf: jpgSet), tag: "suite")
        try require(splicedJS != nil, "JPEG aux splice failed")
        try splicedJS!.write(to: jpgSet)
        try require(update(jpgSet, jpgSet), "JPEG set must transport foreign aux segments")
        let jpgSetBytes = try Data(contentsOf: jpgSet)
        for needle in ["AUXPROBE-APP13-suite", "AUXPROBE-COM-suite", "AUXPROBE-APP11-suite"] {
            try require(jpgSetBytes.range(of: Data(needle.utf8)) != nil, "JPEG set lost \(needle)")
        }

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

        // HEIC verified-shape refusals: in-place semantic patches keep the
        // box structure valid but leave the verified plain-still shape
        // (single hvc1 primary + Exif/XMP items + cdsc references only).
        for (label, needle, replacement) in [("non-cdsc reference", "cdsc", "dimg"),
                                             ("aux reference", "cdsc", "auxl"),
                                             ("unknown meta child", "hdlr", "xxxx")] {
            let f = root.appendingPathComponent("aux-heic-shape-\(replacement).heic")
            try fixtureWithMetadata(at: f, type: "public.heic" as CFString)
            let patched = replaceFirstBytes(try Data(contentsOf: f), needle, replacement)
            try require(patched != nil, "HEIC shape patch failed for \(label)")
            try patched!.write(to: f)
            let before = try Data(contentsOf: f)
            try require(!update(f, f), "HEIC set must refuse a \(label)")
            try require(!update(f, f, remove: true), "HEIC removal must refuse a \(label)")
            try require(try Data(contentsOf: f) == before, "Refused HEIC write must leave the original intact")
        }


        // M15 cycle 3 (deep-probe evidence, run 41690332177): the remaining
        // carve-outs proved lossy in CI - TIFF ICC is regenerated, JPEG Exif
        // loses MakerNote/private tags, non-empty IPTC in an IRB has
        // unverifiable date semantics. All refuse now; verified content must
        // survive byte-exact.

        // TIFF: an embedded ICC profile the writer regenerates refuses both paths.
        for remove in [true, false] {
            let f = root.appendingPathComponent("aux-tiff-icc-\(remove ? "remove" : "set").tiff")
            try fixtureWithMetadata(at: f, type: "public.tiff" as CFString)
            let spliced = spliceTIFFTag(try Data(contentsOf: f), tag: 34675, type: 7, payload: Data("SUITE-FAKE-ICC-PROFILE".utf8))
            try require(spliced != nil, "TIFF ICC splice failed")
            try spliced!.write(to: f)
            let before = try Data(contentsOf: f)
            try require(!update(f, f, remove: remove), "TIFF \(remove ? "removal" : "set") must refuse a regenerated ICC profile")
            try require(try Data(contentsOf: f) == before, "Refused TIFF ICC write must leave the original intact")
        }

        // JPEG: MakerNote or private Exif tags the writer drops refuse removal.
        let jpgMaker = root.appendingPathComponent("aux-jpg-makernote.jpg")
        try fixtureWithMetadata(at: jpgMaker, type: "public.jpeg" as CFString)
        let withMaker = spliceJPEGExifTag(try Data(contentsOf: jpgMaker), tag: 37500, payload: Data("SUITE-MAKERNOTE".utf8))
        try require(withMaker != nil, "JPEG Exif splice failed")
        try withMaker!.write(to: jpgMaker)
        let jpgMakerBefore = try Data(contentsOf: jpgMaker)
        try require(!update(jpgMaker, jpgMaker, remove: true), "JPEG removal must refuse a dropped MakerNote")
        try require(try Data(contentsOf: jpgMaker) == jpgMakerBefore, "Refused JPEG removal must leave the original intact")

        // JPEG IRB, verify-or-refuse (option A): only resources proven
        // edit-independent reattach, as complete verified bytes - the
        // Adobe-spec editor/print state ids (0x0406 quality, 0x0408 grid,
        // 0x0426 print scale, 0x0428 pixel aspect) and the writer-authored
        // empty-IPTC + MD5-verified digest pair. Everything else refuses,
        // on both paths, leaving the original intact.
        let md5Empty = Data([0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04,
                             0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e])
        // Non-empty IPTC carries IIM date datasets: refuse set and removal.
        let jpgIRB = root.appendingPathComponent("aux-jpg-irb.jpg")
        try fixtureWithMetadata(at: jpgIRB, type: "public.jpeg" as CFString)
        let targetedIRB = buildIRB([(0x0404, Data("IPTC-DATED-2001".utf8))])
        let withIRB = jpegReplacingAPP13(try Data(contentsOf: jpgIRB), payload: targetedIRB)
        try require(withIRB != nil, "JPEG IRB splice failed")
        try withIRB!.write(to: jpgIRB)
        let jpgIRBBefore = try Data(contentsOf: jpgIRB)
        try require(!update(jpgIRB, jpgIRB, remove: true), "JPEG removal must refuse non-empty IPTC in the IRB")
        try require(!update(jpgIRB, jpgIRB), "JPEG set must refuse non-empty IPTC in the IRB")
        try require(try Data(contentsOf: jpgIRB) == jpgIRBBefore, "Refused JPEG IRB write must leave the original intact")
        // Targeted or unverified resource ids refuse even with tiny payloads.
        for (rid, payload) in [(0x0422, Data("Exif-copy".utf8)), (0x0423, Data("Exif3".utf8)),
                               (0x0424, Data("<x/>".utf8)), (0x0419, Data([0, 0, 1, 0])),
                               (0x040C, Data([0xFF, 0xD8, 0xFF])), (0x0FA0, Data("PLUGIN".utf8))] {
            let hex = String(rid, radix: 16)
            let f = root.appendingPathComponent("aux-jpg-irb-\(hex).jpg")
            try fixtureWithMetadata(at: f, type: "public.jpeg" as CFString)
            let crafted = jpegReplacingAPP13(try Data(contentsOf: f), payload: buildIRB([(rid, payload)]))
            try require(crafted != nil, "JPEG IRB splice failed for \(hex)")
            try crafted!.write(to: f)
            let before = try Data(contentsOf: f)
            try require(!update(f, f), "JPEG set must refuse IRB resource \(hex)")
            try require(!update(f, f, remove: true), "JPEG removal must refuse IRB resource \(hex)")
            try require(try Data(contentsOf: f) == before, "Refused JPEG IRB write must leave the original intact")
        }
        // A digest is preservable only as the verified MD5 of its empty
        // IPTC: a wrong digest or a digest without its IPTC refuses.
        for (i, bad) in [buildIRB([(0x0404, Data()), (0x0425, Data(repeating: 1, count: 16))]),
                         buildIRB([(0x0425, md5Empty)])].enumerated() {
            let f = root.appendingPathComponent("aux-jpg-irb-digest-\(i).jpg")
            try fixtureWithMetadata(at: f, type: "public.jpeg" as CFString)
            let crafted = jpegReplacingAPP13(try Data(contentsOf: f), payload: bad)
            try require(crafted != nil, "JPEG IRB digest splice failed")
            try crafted!.write(to: f)
            let before = try Data(contentsOf: f)
            try require(!update(f, f), "JPEG set must refuse an unverified IRB digest")
            try require(!update(f, f, remove: true), "JPEG removal must refuse an unverified IRB digest")
            try require(try Data(contentsOf: f) == before, "Refused JPEG IRB write must leave the original intact")
        }
        // Verified content reattaches as complete bytes - Pascal names and
        // pads included: whitelisted editor state plus the empty-IPTC pair.
        let jpgOK = root.appendingPathComponent("aux-jpg-irb-ok.jpg")
        try fixtureWithMetadata(at: jpgOK, type: "public.jpeg" as CFString)
        let okIRB = buildIRBNamed([(0x0406, Data("Quality".utf8), Data([0, 3, 1, 0, 1])),
                                   (0x0404, Data("Caption".utf8), Data()),
                                   (0x0425, Data(), md5Empty)])
        let withOK = jpegReplacingAPP13(try Data(contentsOf: jpgOK), payload: okIRB)
        try require(withOK != nil, "JPEG IRB whitelist splice failed")
        try withOK!.write(to: jpgOK)
        try require(update(jpgOK, jpgOK), "JPEG set must transport verified IRB resources")
        try require(update(jpgOK, jpgOK, remove: true), "JPEG removal must transport verified IRB resources")
        let okAfter = try Data(contentsOf: jpgOK)
        let okAfterIRB = jpegInventory(okAfter)?.filter { $0.0 == "FFED" }.first?.2
        try require(okAfterIRB == okIRB, "Verified IRB must survive byte-exact, names included")
        // Malformed IRB (truncated final pad) refuses.
        let jpgBad = root.appendingPathComponent("aux-jpg-irb-trunc.jpg")
        try fixtureWithMetadata(at: jpgBad, type: "public.jpeg" as CFString)
        var truncIRB = buildIRB([(0x0406, Data([1, 2, 3]))])
        truncIRB.removeLast()
        let withBad = jpegReplacingAPP13(try Data(contentsOf: jpgBad), payload: truncIRB)
        try require(withBad != nil, "JPEG IRB truncate splice failed")
        try withBad!.write(to: jpgBad)
        let badBefore = try Data(contentsOf: jpgBad)
        try require(!update(jpgBad, jpgBad), "JPEG set must refuse a malformed IRB")
        try require(try Data(contentsOf: jpgBad) == badBefore, "Refused JPEG IRB write must leave the original intact")

        // JPEG happy path (copy-write route, evidence runs 41686881879 +
        // 41690332177): the writer-authored IRB - an empty IPTC resource
        // plus its MD5-verified digest, the one pair proven metadata-free -
        // is restored byte-exact, entropy and pixels are transported, and
        // the intended date/GPS values verify.
        for remove in [true, false] {
            let f = root.appendingPathComponent("aux-jpg-happy-\(remove ? "remove" : "set").jpg")
            try fixtureWithMetadata(at: f, type: "public.jpeg" as CFString)
            let before = try Data(contentsOf: f)
            let sourceIRBPayload = jpegInventory(before)?.filter { $0.0 == "FFED" }.first?.2
            try require(sourceIRBPayload != nil, "Fixture JPEG should carry the ImageIO IRB")
            try require(update(f, f, remove: remove), "Plain JPEG \(remove ? "removal" : "set") must succeed")
            let after = try Data(contentsOf: f)
            let afterIRBPayload = jpegInventory(after)?.filter { $0.0 == "FFED" }.first?.2
            try require(afterIRBPayload == sourceIRBPayload, "JPEG IRB must survive byte-exact")
            try require(jpegEntropyData(before) == jpegEntropyData(after), "JPEG entropy must survive byte-exact")
            try require(try pixelData(f) != nil, "JPEG output must decode")
        }

        // M18 probes are independent: a failure in one must not abort the
        // harvest of the rest. Capture each probe's error, print it, and
        // throw one aggregate failure at the end - nothing turns green, but
        // every later probe still executes. Genuinely shared setup (fixture
        // root, earlier scenario units) stays fatal above.
        var probeFailures: [String] = []
        func runProbe(_ name: String, _ body: () throws -> Void) {
            do { try body() } catch {
                probeFailures.append("\(name): \(error.localizedDescription)")
                FileHandle.standardError.write(Data("M18 probe \(name) FAILED: \(error.localizedDescription)\n".utf8))
            }
        }
        runProbe("TIFFIPTCRefusal") { try runTIFFIPTCRefusalProbe(root: root) }
        runProbe("HEICEmptyPacket") { try runHEICEmptyPacketProbe(root: root) }
        runProbe("16Bit") { try run16BitProbe(root: root) }
        runProbe("PngSuite") { try runPngSuiteProbe(root: root) }
        runProbe("P3HEIC") { try runP3HEICProbe(root: root) }
        runProbe("PublicFixture") { try runPublicFixtureProbe(root: root) }
        runProbe("LargeHEIC") { try runLargeHEICProbe(root: root) }
        try require(probeFailures.isEmpty, "M18 probe failures [\(probeFailures.count)]: \(probeFailures.joined(separator: " | "))")
        // M18 (B3): the IPTC presence check and its removal exemptions.
        let iptcSource: [CFString: Any] = [kCGImagePropertyIPTCDictionary: ["DateCreated": "2001:02:03", "City": "Madrid", "Caption": "x"] as [CFString: Any]]
        var iptcDropped = MetadataWriter.droppedUntouchedTags(source: iptcSource, output: [:], removeDate: true, removeLocation: false)
        try require(iptcDropped == ["IPTC.Caption", "IPTC.City"], "IPTC date keys exempt under removeDate only: \(iptcDropped)")
        iptcDropped = MetadataWriter.droppedUntouchedTags(source: iptcSource, output: [:], removeDate: false, removeLocation: true)
        try require(iptcDropped == ["IPTC.Caption", "IPTC.DateCreated"], "IPTC location keys exempt under removeLocation only: \(iptcDropped)")
        let gpsDateSource: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSDateStamp: "2001:02:03", kCGImagePropertyGPSLatitude: 40.4] as [CFString: Any]]
        let gpsDropped = MetadataWriter.droppedUntouchedTags(source: gpsDateSource, output: [:], removeDate: true, removeLocation: false)
        try require(gpsDropped.count == 1 && !gpsDropped[0].contains("DateStamp"), "GPSDateStamp exempt under removeDate: \(gpsDropped)")

        try require(softFailures.isEmpty, "\(softFailures.count) check(s) failed across format stages: \(softFailures.joined(separator: " | "))")
        print("Metadata write safety tests passed (PNG, JPEG, TIFF, HEIC).")
    }
}
