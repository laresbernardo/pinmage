# Agent instructions for Pinmage

Pinmage is a native macOS SwiftUI app (`PinmageApp/`) plus its landing site (`website/`, served at https://pinmage.bervos.org from Firebase project `pinmage-billio`).

## Deploy

- Merging a PR to `main` deploys automatically via `.github/workflows/deploy.yml`: a macOS runner builds `Pinmage.dmg` with `CI=true ./install.sh`, copies it into `website/`, and deploys Firebase Hosting + Firestore rules.
- Credentials: deploy-only service account `github-deploy@pinmage-billio.iam.gserviceaccount.com`, stored as the repo secret `FIREBASE_SERVICE_ACCOUNT_PINMAGE_BILLIO`. Never deploy with a personal login.
- Pull requests run the same build without deploying; the DMG is attached to the run as an artifact.
- `website/Pinmage.dmg` is gitignored on purpose. Never deploy `website/` without building the DMG first, or the download button breaks.
- Manual fallback only: `PINMAGE_DEPLOY=1 ./install.sh` on a Mac.

## Versioning

- `website/version.json` is the release version shown on the site; CI copies it into `PinmageApp/Info.plist` before building.
- Every PR bumps `website/version.json` (and keeps `CFBundleShortVersionString` in `PinmageApp/Info.plist` equal to it): patch for fix/docs, minor for feat, major for breaking.
- Local `./install.sh` runs still auto-increment the patch version; commit that bump if you ship it.

## Conventions

- Commits, branches and PR titles start with `fix:`, `feat:`, `docs:` or `recode:`.
- Code and docs in English.
