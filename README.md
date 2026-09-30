# <img src="PinmageApp/AppIcon.png" width="42" align="center" style="border-radius: 8px;" /> Pinmage — AI-Powered Photo Date & Location Injector

Pinmage is a native **macOS SwiftUI** utility that automatically restores historical metadata to your photo library. It leverages AI to extract dates and locations from scanned pages or photos, then embeds them natively.

---

## 🛠️ Key Features & How It Works

1. **AI Date & Location Extraction**: Scans images using Multimodal AI (Google Gemini or local Ollama models) to identify written dates, captions, notes, or landmarks, returning structured date and location metadata alongside AI confidence scores.
2. **Dual AI Provider Support**: Use **Google Gemini** (cloud API, pay-per-use) or **Ollama** (local, free, fully offline) — switch seamlessly in Settings with a refresh button to detect newly installed local models.
3. **Customizable Certainty Thresholds**: Filters AI output using a customizable threshold slider (defaulting to 80%). The app dynamically shows how many images will be updated and writes dates and GPS tags conditionally based on their individual confidence scores.
4. **Real-Time Cost Tracking**: Parses Gemini token usage metadata to compute real-time API spend in USD (Ollama is free) — stored persistently with support for resetting after confirmation.
5. **Chronological Interpolation**: Automatically sorts queue images alphabetically (essential for chronological matching of scanned album pages). If an image doesn't have an AI-identifiable date, it inherits the date of the previous photo.
6. **CoreLocation Geocoding**: Resolves text place-names (e.g., "Paris, France" or "Eiffel Tower") into precise latitude and longitude GPS coordinates.
7. **Local Caching**: Computes unique image hashes to cache analysis results, preventing redundant network requests.
8. **Concurrency Controls**: Allows configuring parallel requests limits to balance extraction speed and avoid API rate limits.
9. **Smart Downscaling**: Option to downscale large uploaded files to a maximum dimension of 1600px, reducing upload bandwidth usage by up to 98%.
10. **EXIF & GPS Injection**: Natively embeds metadata (`DateTimeOriginal` and GPS tags) into output copies (or overwrites originals) without requiring heavy external dependencies.

---

## 🚀 Installation & Build

You can compile and run Pinmage locally without using Xcode:

1. Clone the repository:
   ```bash
   git clone https://github.com/laresbernardo/pinmage.git
   cd pinmage
   ```
2. Run the build & install script:
   ```bash
   ./install.sh
   ```

This will automatically compile Swift sources, generate app icons, sign the app bundle, bypass Gatekeeper, install the app to `/Applications/Pinmage.app`, and package a shareable **`Pinmage.dmg`** in the project root.

---

## Metadata write safety

Metadata is encoded in a private staging directory beside the target, then reopened
and checked for format, dimensions and successful image decoding before publication.
Overwrite mode flushes the completed file and atomically replaces the original path;
encoder, validation and publication failures leave the original in place. Symlinks
are followed rather than replaced. Multi-frame originals are refused because the
current encoder writes one image. Existing output copies are never overwritten:
choose a different output filename or folder if a copy already exists.

The encoder and EXIF/GPS tag handling are unchanged. This does not make JPEG
rewrites lossless, provide a backup, or guarantee recovery after sudden power loss.
Original POSIX permissions are retained; other filesystem attributes (Finder tags,
ACLs and creation timestamps) are not guaranteed by this write path. Close other
editors before overwrite: the source is checked for changes before publication,
but this is not a lock against another process writing at the same instant.

Run the standalone safety tests on macOS:

```bash
swiftc PinmageApp/MetadataWriter.swift Tests/MetadataWriterTests.swift -o /tmp/pinmage-metadata-tests
/tmp/pinmage-metadata-tests
```

PR CI runs these tests before building the app and DMG. They use synthetic images
and injected failures, not real disk exhaustion or user photos.

## 🌐 Website & Automatic Deploys

The landing site lives in `website/` and is served at [pinmage.bervos.org](https://pinmage.bervos.org).

Every merge to `main` runs [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) on a macOS runner: it builds `Pinmage.dmg`, puts it in `website/` for the download button, and deploys Firebase Hosting and Firestore rules. Pull requests run the same build without deploying, and the DMG is attached to the run so you can test it.

- Version: bump `website/version.json` in each PR. CI stamps that version into the app before building.
- Credentials: a deploy-only service account, stored as the `FIREBASE_SERVICE_ACCOUNT_PINMAGE_BILLIO` repo secret.
- Manual fallback: `PINMAGE_DEPLOY=1 ./install.sh`.

---

## Ollama (Local AI) Setup

To use local AI models instead of the Gemini cloud API:

1. **Install Ollama** from [ollama.ai](https://ollama.ai)
2. **Pull a multimodal model** (required for image analysis):
   ```bash
   ollama pull llava
   # or: ollama pull bakllava, ollama pull moondream, etc.
   ```
3. **Keep Ollama running** in the background — Pinmage discovers it automatically at `http://localhost:11434`.
4. **In Pinmage Settings**, switch the *AI Provider* to **Ollama (Local)** and click **Refresh** to see your installed models.

> Only multimodal models (llava, bakllava, moondream) support image analysis. Ensure the model you pull is vision-capable.

## Free update checks

Pinmage checks the official release manifest asynchronously once per launch, then at most
once every 24 hours when reactivated. Offline checks are silent. There are no timers,
analytics, photo uploads, cookies or credentials in update requests. Use **Pinmage > Check
for Updates** to check immediately, including a release previously dismissed with Later.

The compact notice waits until photo processing and metadata writes finish. Download free
update opens the official DMG in your browser; quit Pinmage and drag the new app into
Applications. This does not replace the running app automatically. Existing installs need
one manual download to gain the checker. Releases remain ad-hoc signed, not notarized.

CI publishes version/build/minimum-macOS metadata from the built app only after successful
compilation and DMG packaging. A release must bump both its version and build number. The DMG targets Apple silicon
and macOS 14 or later (the SwiftUI views already use macOS 14 APIs).
