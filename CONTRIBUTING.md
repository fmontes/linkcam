# Contributing

Thanks for your interest! This is a small, focused tool — contributions that
keep it simple and well-documented are very welcome.

## Building

You need the macOS **Command Line Tools** (`xcode-select --install`) — no full
Xcode required.

```bash
make          # builds universal (arm64 + x86_64) bin/uvc-util and bin/xu-probe
make clean
```

To build for just your architecture (faster):

```bash
make ARCHS="-arch arm64"     # or -arch x86_64
```

## Project layout

| Path | What |
|------|------|
| `linkcam` | the CLI — a bash wrapper that calls the two helpers |
| `bin/` | prebuilt universal binaries (committed) |
| `src/xu-probe.m` | raw vendor Extension Unit (XU) get/set/scan — this project |
| `src/vendor/` | [uvc-util](https://github.com/jtfrey/uvc-util) sources (MIT) |
| `Makefile` | builds the helpers |

`xu-probe` reuses uvc-util's `UVCController` (device discovery + IOKit
`ControlRequest`) and exposes its internal `getData:/setData:atUnitId:`
methods so we can talk to *raw* XU selectors that uvc-util doesn't model.

## Why IOKit and not libusb

On macOS the system camera driver claims the UVC interface, and libusb can't
detach it (`Access denied`). IOKit control transfers work *cooperatively*
alongside the driver, so the camera keeps working while we send controls.

## Adding support for another Insta360 camera

Different models expose different XU selectors. The method used to find the
Link 2's AI-tracking command (write `0x01`/`0x00` to unit 11, selector `0x02`)
generalizes:

1. **Find your camera's USB vendor:product id.**
   ```bash
   ioreg -p IOUSB -l -w 0 | grep -iA6 insta360 | grep -iE "idVendor|idProduct"
   ```
   Convert to hex (e.g. `0x2e1a:0x4c04`) and use it with `-V`.

2. **List the extension units** — the descriptor probe in the git history
   (`probe2.py`) prints the XU unit IDs and GUIDs. Insta360 cameras typically
   have 2–3 units.

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

5. **Confirm by writing.** The surviving selector should be a stable byte that
   flips `00`↔`01`. Verify it actually controls the feature:
   ```bash
   bin/xu-probe -V <vid:pid> set <unit> <sel> 01   # turn on
   bin/xu-probe -V <vid:pid> set <unit> <sel> 00   # turn off
   ```

6. **Wire it up** in `linkcam` (see the `AI_UNIT`/`AI_SEL` constants and the
   `ai)` case) and open a PR. Please note which model + firmware you tested.

The official app also logs verbosely to
`~/Library/Application Support/Insta360/.../log/<date>/*.log` (e.g.
`auto track clicked`, `exit track mode`), which is handy for confirming state
while probing.

## Style

- Keep `linkcam` POSIX-ish bash; it targets the system bash on macOS.
- Prefer matching the device by vendor:product id, not a device index.
- Document any new reverse-engineered command in the README table.

## Disclaimer

This project is reverse-engineered from observed behavior and is not affiliated
with Insta360. Only add commands you've verified on real hardware.
