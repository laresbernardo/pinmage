# Test fixtures

## Committed (Tests/Fixtures/pngsuite/)
PngSuite 16-bit and interlaced PNGs (basn2c16, basi2c16, basn0g16, cdun2c08) -
freeware (Willem van Schaik, license verbatim in pngsuite/LICENSE.txt), SHA-256
pinned at import.

## Fetched in CI (not committed)
Camera sample images from the ianare/exif-py project (tests/resources/),
released under CC BY-SA 4.0 (per the predecessor ianare/exif-samples README:
"User-contributed images will be released under the Attribution-ShareAlike 4.0
International license"). Attribution: ianare/exif-py (exif-samples) project,
CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/).

Fetched by .github/workflows/deploy.yml with SHA-256 verification into
$PINMAGE_FIXTURES_DIR:

| File | SHA-256 | Exercise |
|---|---|---|
| DSCN0010.jpg | 17307b1207eb6487d7908e9d154890b46e3d2e0192369cfd3f4c33d5a5af4035 | Nikon MakerNote: intentional refusal |
| HMD_Nokia_8.3_5G.jpg | 9be023624ccd5846beeb5b02d9b571251ef5bd8ed820389a430d114029f58eda | no MakerNote, rich GPS: B1/B2 must-pass |
| iphone_13_pro_max.heic | e760c80eed310e4f27c092d5487693ca8e104e7cc01d25ba4828deb28f679676 | Apple MakerNote HEIC: refusal acceptable |
| Canon_40D.jpg | 6bfdabd4fc33d112283c147acccc574e770bbe6fbdbc3d4da968ba7b606ecc2f | rich ExifIFD + ICC: B2 must-pass |
| Tless0.tiff | 32f6aab90dc2d284a83040debe379e01333107b83a98c1aa2e6dabf56790b48a | TIFF without compression: transport |
| Arbitro.tiff | 26f4b11c45ad3e56a530d03967ff4627892b3264183b85fefba194ff1fe3e08e | TIFF with XMP tag 700 |

The IPTC Photo Metadata Standard reference image is deliberately NOT used
(no published license terms, checked 2026-11-03); synthetic self-authored IIM
fixtures take its place.
