# Fast Mission Control

Fast Mission Control is an open-source macOS app that makes Mission Control feel fast again, especially on 4K+, 5K, ultrawide, and multi-monitor setups where Apple's default Mission Control often feels laggy and slow.

If you found this repo because you searched Google or Reddit for "How to speed up animations on macOS" or "Speed up Mission Control animations in macOS", the old terminal tweak:

```sh
defaults write com.apple.dock expose-animation-duration -float 0.1
```

does not fix the problem on current macOS versions. This project exists because people still get sent to outdated Dock commands every day even though Mission Control is still slow for many setups.

https://tomeraviv.github.io/FastMissionControl/

## What It Does

- Opens a fast custom Mission Control-style overview.
- Preserves window positions across multiple displays.
- Shows still and live previews for windows.
- Lets you select windows quickly and restore minimized windows.
- Includes a desktop action and app shelf behavior.
- Uses an extra mouse button trigger by default.

## Status

This repo is publishable as an open-source alpha. The app builds locally in Xcode and the layout tests run from the command line. It is not yet a polished end-user release because there is no signed/notarized distribution and a few workflow features are still missing.

## Still Missing

- [ ] Global keyboard shortcuts / hotkeys
- [ ] Add Metal rendering for faster perfornamce
- [ ] Add demo video
- [ ] Clean up main interface
- [ ] Fix missing cache on first open
- [ ] Fix slow settings form ui
- [ ] Moving real windows between displays or spaces from the overview
- [ ] Dragging that repositions actual windows, not just overview thumbnails
- [ ] Better first-run onboarding for Screen Recording and Accessibility permissions
- [ ] Signed and notarized release builds
- [ ] Broader automated coverage beyond layout-focused tests

## Build

Open `FastMissionControl.xcodeproj` in Xcode and run the `FastMissionControl` scheme.

CLI checks:

```sh
xcodebuild test -project FastMissionControl.xcodeproj -scheme FastMissionControl -configuration Debug -destination 'platform=macOS' -only-testing:FastMissionControlTests CODE_SIGNING_ALLOWED=NO
xcodebuild build -project FastMissionControl.xcodeproj -scheme FastMissionControl -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Permissions

The app needs:

- Screen Recording
- Accessibility

## GitHub Pages

A simple project site lives in `docs/`. After publishing the repo, enable GitHub Pages and point it at the `docs/` folder on your default branch.
