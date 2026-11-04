import SwiftUI
import AppKit
import ImageIO

// RefusalUISnapshot - visual verification harness for the per-item refusal UI.
//
// NOT a mock: this binary is compiled from the REAL app sources (every
// PinmageApp/*.swift except the @main entry) plus this file. It performs a
// REAL refused write through MetadataWriter.updateImageMetadata on a real
// fixture (the ruled GPS textual-form boundary: a PNG whose XMP packet
// carries plain-form GPS values), surfaces the genuine
// "Metadata write refused: <cause>" NSError exactly as PinmageManager
// constructs it (PinmageManager.swift write path), places it on a real
// ImageItem, and renders the REAL QueueRowView (the per-item row used by
// ProcessView) offscreen via NSHostingView at the app's minimum content
// width (600pt, MainView.swift content minWidth), dark appearance as the
// app enforces (preferredColorScheme(.dark)).
//
// Verified: refusal text presentation in the real row (clipping, wrapping,
// readability, Reprocess context) at real width with the real long guard
// string. NOT verified here: app-launch interaction, thumbnail loading
// (async .task does not run in an offscreen render; the placeholder
// renders), popovers/buttons behavior. This is a pixel check of the real
// view code, not an end-to-end app session.
//
// Output: $PRESERVATION_ARTIFACT_DIR/refusal-ui-queue-row.png (plus a
// -narrow variant at 400pt for clipping visibility) and the rendered
// refusal string on stderr.

@main
struct RefusalUISnapshot {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp?.appearance = NSAppearance(named: .darkAqua)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("refusal-ui-snapshot-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Fixture: PNG with EXIF dates + full GPS dictionary. On PNG the
        // destination serializer routes GPS into the iTXt XMP packet in
        // plain textual forms, so the next write that rebuilds the packet
        // hits the ruled Guard A textual-form boundary and refuses.
        // (Same construction as Tests/MetadataWriterTests.swift
        // fixtureWithMetadata; duplicated because the suites are separate
        // binaries.)
        let fixture = root.appendingPathComponent("IMG_2001.png")
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
                                bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = context.makeImage()!
        guard let writer = CGImageDestinationCreateWithURL(fixture as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "RefusalUISnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture writer failed"])
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2001:02:03 04:05:06",
                kCGImagePropertyExifDateTimeDigitized: "2001:02:03 04:05:06",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFDateTime: "2001:02:03 04:05:06",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 40.4,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 3.7,
                kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 12.0,
                kCGImagePropertyGPSImgDirection: 90.0,
                kCGImagePropertyGPSImgDirectionRef: "T",
                kCGImagePropertyGPSTimeStamp: "04:05:06",
                kCGImagePropertyGPSDateStamp: "2001:02:03",
            ],
        ]
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            throw NSError(domain: "RefusalUISnapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "fixture finalize failed"])
        }
        let fixtureBytes = try Data(contentsOf: fixture)

        // Real refused write: reverse-mixed request (set location, remove
        // date), the scenario CI25/CI26 observed refusing on PNG.
        let note = MetadataWriter.RefusalNote()
        let success = MetadataWriter.updateImageMetadata(
            sourceURL: fixture, destinationURL: fixture,
            date: nil, removeDate: true,
            latitude: 12.5, longitude: -45.25, removeLocation: false,
            refusalNote: note)
        guard !success, let reason = note.reason, !reason.isEmpty else {
            throw NSError(domain: "RefusalUISnapshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "expected a refused write with a recorded reason; got success=\(success)"])
        }
        guard (try? Data(contentsOf: fixture)) == fixtureBytes else {
            throw NSError(domain: "RefusalUISnapshot", code: 4, userInfo: [NSLocalizedDescriptionKey: "refused write altered the original"])
        }

        // The exact surface string PinmageManager builds for the queue item.
        let errorText = "Metadata write refused: \(reason)"
        FileHandle.standardError.write(Data("REFUSAL-UI-VERIFY refusal string:\n\(errorText)\n".utf8))

        var item = ImageItem(fileURL: fixture)
        item.status = .failed
        item.errorMessage = errorText
        item.existingLatitude = 40.4
        item.existingLongitude = 3.7

        let manager = PinmageManager()
        let settings = AppSettings()

        let artifactDir = ProcessInfo.processInfo.environment["PRESERVATION_ARTIFACT_DIR"]
            ?? root.path
        try fm.createDirectory(atPath: artifactDir, withIntermediateDirectories: true)

        // 600pt = MainView content minWidth (the real worst-case list
        // width); 400pt = narrower-than-minimum variant so wrapping /
        // clipping behavior of the long string is visible too.
        for (label, width) in [("refusal-ui-queue-row", 600.0), ("refusal-ui-queue-row-narrow", 400.0)] {
            let row = QueueRowView(item: item, manager: manager, settings: settings,
                                   selectedIds: .constant([]), onRemove: {}, onEditLocation: {})
            // Real window, real backdrop: the queue row's actual context is
            // an inset List over the content area's .underWindowBackground
            // material (MainView), which only renders against a real window.
            // A bare NSHostingView cannot provide either, and its
            // fittingSize returned the collapsed row height (106pt) while
            // the wrapped caption drew past it - so layout is driven by a
            // real (borderless, never-fronted) NSWindow and the bitmap is
            // captured generously tall, then auto-cropped to the actual
            // content. No dependence on fittingSize. Offscreen window is
            // still not an app-launch session.
            let framed = ZStack {
                VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                row
                    .padding(.vertical, 4)
                    .padding(.horizontal, 16)
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let hosting = NSHostingView(rootView: framed)
            window.contentView = hosting
            window.orderBack(nil)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            // Diagnose: does the laid-out view hierarchy CONTAIN the caption,
            // or does text draw past its declared bounds? Print the deepest
            // laid-out bottom edge of any subview as evidence.
            func deepestBottom(_ view: NSView) -> CGFloat {
                var bottom = view.subviews.map { deepestBottom($0) }.max() ?? 0
                let own = view.frame.maxY
                if own > bottom { bottom = own }
                return bottom
            }
            FileHandle.standardError.write(Data("REFUSAL-UI-VERIFY \(label) hosting bounds \(hosting.bounds), deepest subview bottom \(deepestBottom(hosting))\n".utf8))

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw NSError(domain: "RefusalUISnapshot", code: 5, userInfo: [NSLocalizedDescriptionKey: "bitmap rep failed"])
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let full = rep.cgImage else {
                throw NSError(domain: "RefusalUISnapshot", code: 6, userInfo: [NSLocalizedDescriptionKey: "cgImage failed"])
            }

            // Auto-crop to actual content: last row differing from the
            // backdrop sample (top-left), plus a small margin.
            guard let data = full.dataProvider?.data,
                  let ptr = CFDataGetBytePtr(data) else {
                throw NSError(domain: "RefusalUISnapshot", code: 7, userInfo: [NSLocalizedDescriptionKey: "pixels unavailable"])
            }
            let bpr = full.bytesPerRow
            let bpp = full.bitsPerPixel / 8
            let bgR = Int(ptr[0]), bgG = Int(ptr[1]), bgB = Int(ptr[2])
            var lastContentRow = 0
            for y in 0..<full.height {
                var differs = false
                var x = 0
                while x < full.width && !differs {
                    let o = y * bpr + x * bpp
                    if abs(Int(ptr[o]) - bgR) > 10 || abs(Int(ptr[o+1]) - bgG) > 10 || abs(Int(ptr[o+2]) - bgB) > 10 {
                        differs = true
                    }
                    x += 4
                }
                if differs { lastContentRow = y }
            }
            // Coordinates: bitmap y grows downward from top; crop keeps the
            // top of the image through the content bottom + 12pt margin.
            let cropHeight = min(lastContentRow + 13, full.height)
            let cropRect = CGRect(x: 0, y: 0, width: CGFloat(full.width), height: CGFloat(cropHeight))
            guard let cropped = full.cropping(to: cropRect) else {
                throw NSError(domain: "RefusalUISnapshot", code: 8, userInfo: [NSLocalizedDescriptionKey: "crop failed"])
            }
            let outRep = NSBitmapImageRep(cgImage: cropped)
            guard let png = outRep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "RefusalUISnapshot", code: 9, userInfo: [NSLocalizedDescriptionKey: "png encoding failed"])
            }
            let out = URL(fileURLWithPath: artifactDir).appendingPathComponent("\(label).png")
            try png.write(to: out)
            FileHandle.standardError.write(Data("REFUSAL-UI-VERIFY wrote \(out.path) (\(cropped.width)x\(cropped.height), content bottom at row \(lastContentRow) of \(full.height))\n".utf8))
            window.orderOut(nil)
        }
    }
}
