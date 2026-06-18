# Pinmage — AI-Powered Photo Date & Location Injector

Pinmage is a native **macOS SwiftUI** utility that automatically restores historical metadata to your photo library. It uses Gemini AI (Gemini 3.5 Flash / Pro) to extract dates and locations from scanned pages or photos, then embeds them natively.

---

## 🛠️ Key Features & How It Works

1. **AI Date & Location Extraction**: Scans images using Gemini Multimodal AI to identify written dates, captions, notes, or landmarks, returning structured date and location metadata alongside AI confidence scores.
2. **Customizable Certainty Thresholds**: Filters AI output using a customizable threshold slider (defaulting to 80%). The app dynamically shows how many images will be updated and writes dates and GPS tags conditionally based on their individual confidence scores.
3. **Real-Time API Cost Tracking**: Parses Gemini token usage metadata to compute real-time cumulative API spend in USD, stored persistently with support for resetting after confirmation.
4. **Chronological Interpolation**: Automatically sorts queue images alphabetically (essential for chronological matching of scanned album pages). If an image doesn't have an AI-identifiable date, it inherits the date of the previous photo.
5. **CoreLocation Geocoding**: Resolves text place-names (e.g., "Paris, France" or "Eiffel Tower") into precise latitude and longitude GPS coordinates.
6. **Local Caching**: Computes unique image hashes to cache analysis results, preventing redundant network requests and saving on API costs.
7. **Concurrency Controls**: Allows configuring parallel requests limits to balance extraction speed and avoid Gemini API rate limits (HTTP 429).
8. **Smart Downscaling**: Option to downscale large uploaded files to a maximum dimension of 1600px, reducing upload bandwidth usage by up to 98%.
9. **EXIF & GPS Injection**: Natively embeds metadata (`DateTimeOriginal` and GPS tags) into output copies (or overwrites originals) without requiring heavy external dependencies.

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
