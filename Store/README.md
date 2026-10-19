# Sandboxed Mac App Store configuration

`Canopy.xcodeproj` contains the native `CanopyAppStore` target and a static `CanopyCore` target. The minimum is macOS 26, with Apple silicon and Intel architectures. The Store compilation condition is `CANOPY_APP_STORE`.

The repository contains source and reference metadata, not the maintainer's signing credentials, private App Review conversations, provisioning profiles, or upload packages. App Store approval is pending. A source build is not an approved or notarized installer.

## Configure your own distribution

1. Use your own registered App ID and bundle identifiers. Set the team and product bundle identifier in `Store.xcconfig` / Xcode Signing & Capabilities. Direct-build identifiers live in `Resources/Info.plist` and `ProductBrand.swift`.
2. Replace the support/privacy URLs, publisher details and reference listing metadata for your distribution. The checked-in public pages describe the original Canopy app; forks must not claim its support or privacy commitments unchanged.
3. Regenerate the project after changing source files with `python3 scripts/generate-store-project.py`.
4. Run `python3 scripts/check-store-readiness.py`, then test your sandboxed build on physical supported Macs.
5. Archive with your signing team and live public URLs:

```sh
CANOPY_TEAM_ID=YOURTEAMID \
CANOPY_PRIVACY_POLICY_URL=https://your-domain.example/privacy \
CANOPY_SUPPORT_URL=https://your-domain.example/support \
./scripts/archive-app-store.sh
```

Use actual public URLs, not the example addresses above. In Xcode Organizer validate the archive and export for App Store Connect. Review your own privacy answers, metadata, screenshots, permissions, content rights, and current Apple requirements before submission.

## Store screenshot design

Capture / Control–Option–S uses public ScreenCaptureKit and saves the selected region directly inside the sandbox library. It reveals the compact top shelf without invoking the macOS Screenshot utility. Screen-capture access is requested for this action. Escape cancels.

Optional ordinary screenshot detection uses an explicitly selected folder and security-scoped bookmark. Originals stay in that folder. The Store app does not read or write `com.apple.screencapture`, change the destination or floating thumbnail, or request temporary sandbox exceptions. The direct-edition preferences adapter is compiled out.

Upgrade policy clears old routing flags while preserving local captures, notes, and pending app-owned inbox imports. Permission pre-prompts use Continue; recovery after refusal offers Open Settings. Microphone is optional and granting a permission never starts recording.

See `docs/VALIDATION.md` for the current test scope and outstanding physical checks. Apple Preview's edited-copy behavior is unchanged and deferred.
