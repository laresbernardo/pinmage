# Pinmage — AI-Powered Photo Date & Location Injector

Pinmage is a native **macOS SwiftUI** utility that automatically restores historical metadata to your photo library. It uses Gemini AI (Gemini 3.5 Flash) to extract dates and locations from scanned pages or photos, then embeds them natively.

---

## 🛠️ How It Works

1. **AI Date & Location Extraction**: Scans images to read captions, notes, or landmarks, returning structured date and location info.
2. **Chronological Interpolation**: Sorts files alphabetically. If a scanned photo doesn't have an identifiable date, it inherits the date of the previous image.
3. **CoreLocation Geocoding**: Resolves text place-names (e.g. "Paris, France") into precise GPS coordinates.
4. **EXIF & GPS Injection**: Natively embeds metadata (`DateTimeOriginal` and GPS tags) into copied images without any external libraries.

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
