# Fast Mission Control

Fast Mission Control is an open-source macOS app that **makes Mission Control feel fast again**, especially on 4K+, 5K, ultra-wide, high refresh-rate and multi-monitor setups where Apple's default Mission Control often feels **laggy and slow**.

If you found this repo because you searched Google or Reddit for "How to speed up animations on macOS" or "Speed up Mission Control animations in macOS", the old terminal tweak:

```sh
defaults write com.apple.dock expose-animation-duration -float 0.1
```

does not fix the problem on current macOS versions. This project exists because people still get sent to outdated Dock commands every day even though Mission Control is still slow for many setups.

https://tomeraviv.github.io/FastMissionControl/

## What It Does

- Opens a fast custom Mission Control-style overview **that Does Not Stutter**.
- Has better window selector layout than Mission Control, **reducing mouse travel**.
- Shows the **Full Window Title, Name and Icon** without having to mouse over.
- Shows still and low-FPS live previews for windows.
- Includes a desktop action and app shelf behavior.
- Fixes decade old known Mission Control bug where closing / opening windows while animating cause ghost selector boxes and layout shifts

## Status

This repo is publishable as an open-source alpha. The app builds locally in Xcode and the layout tests run from the command line. It is not yet a polished end-user release because there is no signed/notarized distribution and a few workflow features are still missing.

## Common Issues

- **Moving windows causes stutters**: Known macOS issue when resuming from sleep multiple times.
  **Potential Fix**: Reboot to resolve.
- **Random stutter & frame drops across all apps & video playback**: Known macOS issue.
  **Potential Fix**: Disconnect & Replace bad headphones cable. Disable Bluetooth / WiFi.
- **Very long input delay / window move delayed & trailing mouse**: Known macOS issue.
  **Potential Fix**: Stop screen sharing / mirroring. Check for CPU / GPU over-temp throttling. Change main display assignment in Display settings.
- **Consistent frame timing jitter**: Known macOS issue when connecting and disconnecting 2 or more displays with different refresh rates.
  **Potential Fix**: Reboot. Close any Metal apps that are rendering a full-screen overlay. (for Brightintosh / Vivid / BrightXDR) Change audio output format using 'Audio MIDI Setup'.

## Still Missing

- [ ] Global keyboard shortcuts / hotkeys
- [ ] Add Metal rendering for faster performance
- [ ] Add demo video
- [ ] Clean up main interface
- [ ] Fix missing preview cache on first open & fast re-opens
- [ ] Fix slow settings form UI
- [ ] Moving real windows between displays or spaces from the overview
- [ ] Dragging that repositions actual windows, not just overview thumbnails
- [ ] Better first-run onboarding for Screen Recording and Accessibility permissions
- [ ] Signed and notarized release builds
- [ ] Broader automated coverage beyond layout-focused tests

## Build

Open `FastMissionControl.xcodeproj` in Xcode and run the `FastMissionControl` scheme.

Preferred CLI workflow:

```sh
make build
make release-zip
make install
make clean
```

The `make build` target writes the app to `./build/Build/Products/Release/FastMissionControl.app`, and
`make release-zip` packages a universal macOS app bundle into `./build/FastMissionControl-macOS.zip`.
`make install` copies the stable build to `/Applications/FastMissionControl.app`.

## GitHub Releases

Publishing a GitHub release triggers `.github/workflows/release.yml`, which builds the macOS app on `macos-latest`,
packages a universal `arm64 + x86_64` `.app` bundle as a zip, and uploads it to the release assets.

The uploaded asset is currently an **unsigned / non-notarized** build intended for alpha distribution.

CLI checks:

```sh
make test XCODEBUILD_FLAGS='CODE_SIGNING_ALLOWED=NO'
make build XCODEBUILD_FLAGS='CODE_SIGNING_ALLOWED=NO'
```

## Permissions

The app needs:

- Screen Recording
- Accessibility

## License

MIT

## Donate ❤️

https://buymeacoffee.com/tomer789

## GitHub Pages

A simple project site lives in `docs/`. After publishing the repo, enable GitHub Pages and point it at the `docs/` folder on your default branch.
