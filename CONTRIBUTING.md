# Contributing

Thanks for your interest! This is a small, focused tool — contributions that
keep it simple and well-documented are very welcome.

## Building

You need the macOS **Command Line Tools** (`xcode-select --install`) — no full
Xcode required.

```bash
make          # builds the universal CLI and diagnostic tools
make test     # runs parser and CLI regression tests
make app      # builds dist/LinkCam.app
make clean
```

To build for just your architecture (faster):

```bash
make ARCHS="-arch arm64"     # or -arch x86_64
```

## Project layout

| Path | What |
|------|------|
| `linkcam` | thin launcher for the native CLI |
| `bin/linkcam-cli` | native command-line interface |
| `src/core/` | shared camera-control API and strict value parsing |
| `src/cli/` | native CLI entry point |
| `src/app/` | AppKit status item, popover controls, and video preview |
| `app/` | app bundle metadata and entitlements |
| `src/xu-probe.m` | raw vendor Extension Unit (XU) get/set/scan — this project |
| `src/vendor/` | [uvc-util](https://github.com/jtfrey/uvc-util) sources (MIT) |
| `tests/` | parser and command-line regression tests |
| `Makefile` | builds and tests the CLI, app, and diagnostic tools |

`xu-probe` reuses uvc-util's `UVCController` (device discovery + IOKit
`ControlRequest`) and exposes its internal `getData:/setData:atUnitId:`
methods so we can talk to *raw* XU selectors that uvc-util doesn't model.

## Camera access on macOS

On current macOS releases, the system `UVCAssistant` extension exclusively owns
the UVC interface. LinkCam uses CoreMediaIO for standard pan, tilt, and zoom
controls, with the older IOKit implementation retained as a compatibility
fallback and for raw Extension Unit research. libusb cannot detach the system
camera driver (`Access denied`) and is not used.

## Adding support for another Insta360 camera

Different models expose different XU selectors. Link 2 tracking is bit 8 of the
two-byte feature mask at primary extension unit selector `0x1b`; the broader
discovery and verification method generalizes:

1. **Find your camera's USB vendor:product id.**
   ```bash
   ioreg -p IOUSB -l -w 0 | grep -iA6 insta360 | grep -iE "idVendor|idProduct"
   ```
   Convert to hex (e.g. `0x2e1a:0x4c04`) and use it with `-V`.

2. **Find the primary extension unit.** `xu-probe` reads the UVC descriptor:
   ```bash
   bin/xu-probe -V <vid:pid> units
   ```
   Insta360 cameras typically have 2–3 extension units, so scan the additional
   unit IDs as needed.

3. **Differential scan.** With the feature (e.g. tracking) **off**:
   ```bash
   for u in 9 10 11; do bin/xu-probe -V <vid:pid> scan $u; done > off.txt
   ```
   Toggle the feature **on** in the official app, then:
   ```bash
   for u in 9 10 11; do bin/xu-probe -V <vid:pid> scan $u; done > on.txt
   diff off.txt on.txt
   ```

4. **Filter noise.** Some registers (gimbal position, exposure) drift on their
   own. Take a second `off.txt` a few seconds apart and diff the two OFF scans;
   any selector that changes there is noise — ignore it.

5. **Confirm by writing.** Determine whether the value is a scalar or a bit in
   a feature mask. For masks, always read–modify–write the complete value so
   unrelated features are preserved. Verify the result on hardware.
   ```bash
   bin/xu-probe -V <vid:pid> get <unit> <sel> <length>
   bin/xu-probe -V <vid:pid> set <unit> <sel> <complete-updated-hex-value>
   ```

6. **Wire it up** in `src/core/LinkCamCore.m`, expose it through the relevant
   CLI or app surface, add tests, and open a PR. Please note which model and
   firmware you tested.

The official app also logs verbosely to
`~/Library/Application Support/Insta360/.../log/<date>/*.log` (e.g.
`auto track clicked`, `exit track mode`), which is handy for confirming state
while probing.

## Style

- Keep camera behavior in `src/core/` so the CLI and app cannot drift apart.
- Validate numeric CLI input strictly; never pass malformed values to a device.
- Prefer matching the device by vendor:product id, not a device index.
- Document any new reverse-engineered command in the README table.

## Disclaimer

This project is reverse-engineered from observed behavior and is not affiliated
with Insta360. Only add commands you've verified on real hardware.
