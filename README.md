# LinkCam

[![build](https://github.com/fmontes/linkcam/actions/workflows/build.yml/badge.svg)](https://github.com/fmontes/linkcam/actions/workflows/build.yml)

A lightweight macOS menu-bar app and CLI for the **Insta360 Link 2** webcam —
live preview, recenter, pan/tilt/zoom, and AI subject tracking — without opening
the full official controller.

```bash
linkcam            # recenter the gimbal (pan=0, tilt=0)
linkcam ai         # toggle AI subject tracking on/off
linkcam status     # show pan/tilt, zoom, and tracking state
```

The CLI and menu-bar app share the same native camera-control core.

> **Why this exists:** the official Insta360 Link Controller is slow to open,
> and AI tracking often leaves the camera pointing off to the side. `linkcam`
> fixes that in one command. Its global hotkeys also tend to collide with other
> shortcuts — a CLI sidesteps that entirely.

---

## Install

Requires macOS (Apple Silicon or Intel — the binaries are universal) and an
Insta360 Link 2.

```bash
git clone https://github.com/fmontes/linkcam.git
cd linkcam
./install.sh          # symlinks `linkcam` onto your PATH
linkcam status
```

Prebuilt binaries are committed, so there's nothing to compile. (To build them
yourself, see [Building](#building).)

## Menu-bar app

Build the development app bundle and launch it:

```bash
make app
open dist/LinkCam.app
```

Click the video-camera icon in the macOS menu bar to open a compact controller
with a live preview, adjustable pan/tilt nudges, recenter, an AI tracking
switch, camera modes, and a 1×–4× zoom slider. The preview source lists only
Insta360 cameras, including the physical Link 2 and Insta360 Virtual Camera.
Pan, tilt, and zoom always control the physical Insta360 Link 2.
Preview capture starts only while the popover is open, and the selected source
is remembered between launches.

On first use, the preview explains why camera access is needed before showing
the macOS permission dialog. If access is denied, it provides a direct button
to Privacy & Security settings and refreshes when you return. Pan, tilt, and
zoom controls remain available without preview permission. The development
bundle is ad-hoc signed so macOS can associate permission with the correct app
identifier.

### DMG downloads

Create a universal disk image for local testing:

```bash
make dmg
```

This produces `dist/LinkCam-0.2.0-universal-unnotarized.dmg` and a `.sha256`
checksum file. The image includes LinkCam, an Applications shortcut, and install
instructions. Users drag LinkCam to Applications, eject the image, and launch
the app from Applications. Requires macOS 13 or later; supports Apple Silicon
and Intel. This test build is ad-hoc signed, so Gatekeeper can block downloads.

For public downloads, install a **Developer ID Application** certificate with
its private key in your macOS keychain (an Apple Development certificate does
not qualify). Set up a notarization profile once; `notarytool` prompts for your
Apple ID, team ID, and app-specific password and stores them in your keychain:

```bash
xcrun notarytool store-credentials LinkCam-notary
```

Then create the signed and notarized release:

```bash
export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='LinkCam-notary'
make release
```

The release command signs a copy of the app with the hardened runtime, notarizes
and staples the app and DMG, and checks Gatekeeper acceptance. It leaves the
development app unchanged and stops on signing or notarization errors. Upload
`dist/LinkCam-0.2.0-universal.dmg` and its `.sha256` file to your website after
testing installation on another Mac. The version in each filename comes from
`app/Info.plist`; update both bundle version fields for subsequent releases.

Signing and notarization require Apple Developer Program credentials and
internet access. See Apple's [Developer ID distribution guide](https://developer.apple.com/developer-id/).

### GitHub releases

The [release workflow](.github/workflows/release.yml) runs after every push to
`main`, including merged pull requests. It rebuilds and tests the universal binaries, packages the app
as a DMG, and attaches the DMG, CLI archive, and SHA-256 checksums to a GitHub
Release with generated release notes. Each automatic release gets a unique tag
such as `v0.2.0-build.42` and uses the workflow run number as the app's build
number. These builds are always prereleases and do not replace the latest
stable release. No version bump, signing secrets, or repository variables are
needed for automatic unnotarized builds.

Every release includes a **Download LinkCam for macOS** link in its notes.
The workflow run's summary also links directly to the DMG and release page.
Find all downloads on the [Releases page](https://github.com/fmontes/linkcam/releases).

You can also release a version tag such as `v0.2.0`. The tag must match
`CFBundleShortVersionString` in `app/Info.plist`. Commit the packaging and
workflow files before creating a tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```

For subsequent releases, update both version fields in `app/Info.plist`, commit
the changes, and push a new matching tag. You can also run **Actions → release →
Run workflow** and supply an existing version tag.

With no signing secrets, the workflow creates an **unnotarized prerelease**,
with `-unnotarized` in the DMG filename and a warning in the release notes.
It is not marked as the latest stable release. To publish signed and notarized
DMGs, add all six repository secrets under **Settings → Secrets and variables →
Actions**:

| Secret | Value |
| --- | --- |
| `SIGNING_CERTIFICATE_BASE64` | Base64-encoded `.p12` export of the Developer ID Application certificate **and private key** |
| `SIGNING_CERTIFICATE_PASSWORD` | Password used to protect that `.p12` export |
| `SIGNING_IDENTITY` | Full Developer ID Application certificate name or SHA-1 hash |
| `APPLE_ID` | Apple Developer account email |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |

Export the certificate and private key from Keychain Access as a
password-protected `.p12`, then copy its encoded contents for the secret:

```bash
base64 -i /path/to/DeveloperID.p12 | pbcopy
```

The workflow imports credentials into a temporary keychain and removes it at
the end of the job, following GitHub's [certificate setup guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
Partially configured credentials, signing errors, and notarization failures stop
the release; they never fall back to an unnotarized build. With all secrets
configured, successful version-tag releases are published as the latest stable
version; automatic builds from `main` remain prereleases.
Link your website's download button to the DMG asset on the release page.

## Usage

```bash
linkcam                  # center the gimbal (pan=0, tilt=0)   [default]
linkcam status           # show pan/tilt, zoom, and ai-tracking state
linkcam status --json    # stable machine-readable status
linkcam ai               # toggle AI subject tracking
linkcam ai on            # force AI tracking on
linkcam ai off           # force AI tracking off
linkcam zoom 1.5         # set zoom, 1x .. 4x
linkcam pan -30          # pan only, in degrees (tilt unchanged)
linkcam tilt 20          # tilt only, in degrees (pan unchanged)
linkcam set 0 0          # set pan and tilt explicitly
```

Manual pan, tilt, and recenter commands turn AI tracking off and return the
camera to normal video mode first, preventing the tracking loop from pulling
the camera back to its previous subject. You can
also manage it explicitly with `linkcam ai on|off`.

### Pan/tilt units and range

Pan and tilt take **degrees** (`30`, `-12.5`). Append `u` to pass raw
1/3600-degree UVC units instead (`linkcam pan 108000u`).

Two hardware quirks the CLI handles for you:

- **1-degree steps.** The control's step size is 3600 units = 1°, and the
  camera rounds any write to a multiple of it. A raw write of `1000`
  quantizes to `0` and looks like nothing happened.
- **The advertised range is wrong.** The USB descriptor claims ±648000
  (±180°), but the gimbal physically stops earlier and silently clamps.
  Measured travel is **pan ±145°**, **tilt −90° to +100°**. Out-of-range
  values are clamped, and the printed result is what the gimbal actually did.

### Zoom units and range

Zoom takes a **multiplier** from `1` to `4` (`linkcam zoom 1.5`, or `1.5x`). Raw control values are accepted too — the underlying UVC `zoom-abs` control runs from `100` (1x) to `400` (4x) — and since the two ranges don't overlap, `linkcam zoom 150` and `linkcam zoom 1.5` mean the same thing.

The CLI resolves and clamps the value before writing it, because `uvc-util` silently writes the control's **maximum** for anything it can't parse: a bare `linkcam zoom 1.1` used to slam the camera to 4x.

## How it works

The Link 2 is a standard **UVC** (USB Video Class) camera.

- **Gimbal / zoom** use *standard* UVC controls. Recentering is just setting
  **PanTilt Absolute** to its default `pan=0, tilt=0`.
- **AI tracking** is *not* standard — it's a proprietary **Extension Unit (XU)**
  command that had to be reverse-engineered (see below).

On current macOS releases, the system `UVCAssistant` extension owns the USB
video-control interface. The shared Objective-C core therefore uses:

- **CoreMediaIO** for standard pan, tilt, and zoom controls through the system
  camera service.
- **`UVCController`** from
  [Jeffrey Frey's uvc-util](https://github.com/jtfrey/uvc-util) (MIT) as the
  legacy IOKit fallback and for vendor-specific Extension Unit commands.
- **`LinkCamCore`** as the typed API shared by the CLI and app.

Direct libusb/pyusb access is not used because macOS claims the camera's USB
interface and does not allow a user process to detach the system driver.

The standalone **`uvc-util`** and **`xu-probe`** binaries remain available as
diagnostic tools for exploring standard and vendor-specific controls.

### Reverse-engineering AI tracking

AI tracking isn't exposed as a standard control. The current protocol was
confirmed against the official controller and on real Link 2 hardware:

1. **Scan** every XU control (`GET_CUR` across all selectors on all 3 extension
   units) with tracking **off**.
2. **Toggle** tracking on in the official app, then **re-scan** and **diff**.
3. **Filter out noise** — some registers (gimbal position, exposure) drift on
   their own, so a second idle scan identifies and removes them.
4. Compare that evidence with the official controller's implementation, then
   confirm the candidate by writing it and reading the state back on hardware.

**The result:**

> **Extension Unit 9, selector `0x1b`** is a two-byte feature mask. Bit 8
> controls Link 2 AI subject tracking (`1` = on, `0` = off). LinkCam performs a
> read–modify–write so the other feature bits are preserved.

The three vendor extension units (from the USB descriptor):

| Unit | GUID | Role |
|------|------|------|
| 9  | `FAF1672D-B71B-4793-8C91-7B1C9B7F95F8` | device info, status, feature mask |
| 10 | `E307E649-4618-A3FF-82FC-2D8B5F216773` | (image/AE params) |
| 11 | `A8BD5DF2-1A98-474E-8DD0-D92672D194FA` | legacy AI-related controls |

Explore further with the raw tool:

```bash
bin/xu-probe -V 0x2e1a:0x4c04 units             # show the primary XU id
bin/xu-probe -V 0x2e1a:0x4c04 scan 9            # dump primary XU controls
bin/xu-probe -V 0x2e1a:0x4c04 get 9 0x1b 2      # read the feature mask
```

## Building

Only the macOS **Command Line Tools** are needed (no full Xcode):

```bash
make            # builds the universal CLI and diagnostic tools
make test       # runs parser and command-line tests
make app        # builds dist/LinkCam.app
make dmg        # packages a local, unnotarized universal DMG
make release    # signs and notarizes a DMG (requires credentials above)
```

The project builds universal `arm64` + `x86_64` binaries. The uvc-util sources
are MRC-era Objective-C, so the native targets use `-fno-objc-arc`.

## Project layout

```
linkcam            thin launcher for bin/linkcam-cli
app/               bundle metadata and camera entitlement
bin/               universal CLI and diagnostic binaries
src/app/           AppKit menu-bar app and AVFoundation preview
src/cli/           native command-line entry point
src/core/          shared camera-control API and value parsing
src/xu-probe.m     raw XU diagnostic tool
src/vendor/        uvc-util sources, MIT (jtfrey/uvc-util)
tests/             parser and CLI regression tests
Makefile           builds and tests all native targets
```

## Compatibility & caveats

- Prebuilt binaries are **universal** (arm64 + x86_64), so they run on both
  Apple Silicon and Intel Macs.
- Tested against **Insta360 Link 2** (USB `0x2e1a:0x4c04`). Other Insta360
  cameras may use different XU selectors — see
  [CONTRIBUTING.md](CONTRIBUTING.md) for how to find them with `xu-probe scan`.
- On current macOS versions where `UVCAssistant` owns the UVC interface,
  standard controls use CoreMediaIO while the cooperative IOKit request path is
  retained for vendor XU commands such as AI tracking.
- Reverse-engineered from observed behavior; not affiliated with or endorsed by
  Insta360. Use at your own risk.

## Contributing

PRs welcome — especially support for other Insta360 cameras. See
[CONTRIBUTING.md](CONTRIBUTING.md), which documents the differential-scan method
used to reverse-engineer the AI-tracking command.

## Credits

- [uvc-util](https://github.com/jtfrey/uvc-util) by Jeffrey Frey (MIT) — the
  IOKit UVC control foundation this builds on.

## License

MIT — see [LICENSE](LICENSE). Bundled uvc-util is also MIT
([src/vendor/LICENSE.uvc-util](src/vendor/LICENSE.uvc-util)).
