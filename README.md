# insta360-link-cli

A tiny macOS CLI to control the **Insta360 Link 2** webcam — recenter the
gimbal, pan/tilt/zoom, and toggle AI subject tracking — **without opening the
slow official app**.

```bash
linkcam            # recenter the gimbal (pan=0, tilt=0)
linkcam ai         # toggle AI subject tracking on/off
linkcam status     # show pan/tilt, zoom, and tracking state
```

The app doesn't even need to be running.

> **Why this exists:** the official Insta360 Link Controller is slow to open,
> and AI tracking often leaves the camera pointing off to the side. `linkcam`
> fixes that in one command. Its global hotkeys also tend to collide with other
> shortcuts — a CLI sidesteps that entirely.

---

## Install

Requires macOS on **Apple Silicon** (arm64) and an Insta360 Link 2.

```bash
git clone https://github.com/fmontes/insta360-link-cli.git
cd insta360-link-cli
./install.sh          # symlinks `linkcam` onto your PATH
linkcam status
```

Prebuilt binaries are committed, so there's nothing to compile. (To build them
yourself, see [Building](#building).)

## Usage

```bash
linkcam                  # center the gimbal (pan=0, tilt=0)   [default]
linkcam status           # show pan/tilt, zoom, and ai-tracking state
linkcam ai               # toggle AI subject tracking
linkcam ai on            # force AI tracking on
linkcam ai off           # force AI tracking off
linkcam zoom 150         # set zoom (100 = 1x)
linkcam pan -30000       # pan only (tilt unchanged)
linkcam tilt 20000       # tilt only (pan unchanged)
linkcam set 0 0          # set pan and tilt explicitly
```

Handy combo for the AI-drift problem: `linkcam ai off` stops tracking from
wandering the camera, and `linkcam` recenters it.

## How it works

The Link 2 is a standard **UVC** (USB Video Class) camera.

- **Gimbal / zoom** use *standard* UVC controls. Recentering is just setting
  **PanTilt Absolute** to its default `pan=0, tilt=0`.
- **AI tracking** is *not* standard — it's a proprietary **Extension Unit (XU)**
  command that had to be reverse-engineered (see below).

On macOS you **cannot** drive these with libusb/pyusb: the system camera driver
claims the USB interface and won't release it (`detach_kernel_driver` →
*Access denied*). The trick is to issue UVC control transfers through **IOKit**,
which works *cooperatively* alongside the camera driver. This project does that
via two small Objective-C helpers:

- **`uvc-util`** — [Jeffrey Frey's tool](https://github.com/jtfrey/uvc-util)
  (MIT), for standard controls.
- **`xu-probe`** — a small tool written for this project that adds *raw* XU
  get/set/scan by unit-id + selector, reusing uvc-util's IOKit plumbing.

### Reverse-engineering AI tracking

AI tracking isn't exposed as a standard control, so the on/off command was
found empirically:

1. **Scan** every XU control (`GET_CUR` across all selectors on all 3 extension
   units) with tracking **off**.
2. **Toggle** tracking on in the official app, then **re-scan** and **diff**.
3. **Filter out noise** — some registers (gimbal position, exposure) drift on
   their own, so a second idle scan identifies and removes them.
4. What remained was a single stable byte that flipped `00`↔`01` exactly with
   the toggle, then **confirmed** by writing it and watching the camera track.

**The result:**

> Writing `0x01` / `0x00` to **Extension Unit 11, selector `0x02`** turns the
> Link 2's AI subject tracking **on / off**. The camera self-acquires the
> subject — no target rectangle needed.

The three vendor extension units (from the USB descriptor):

| Unit | GUID | Role |
|------|------|------|
| 9  | `FAF1672D-B71B-4793-8C91-7B1C9B7F95F8` | device info / status |
| 10 | `E307E649-4618-A3FF-82FC-2D8B5F216773` | (image/AE params) |
| 11 | `A8BD5DF2-1A98-474E-8DD0-D92672D194FA` | **AI features** |

Explore further with the raw tool:

```bash
bin/xu-probe -V 0x2e1a:0x4c04 scan 11          # dump all controls on unit 11
bin/xu-probe -V 0x2e1a:0x4c04 get 11 0x02 1    # read AI-tracking state
bin/xu-probe -V 0x2e1a:0x4c04 set 11 0x02 01   # tracking on
```

## Building

Only the macOS **Command Line Tools** are needed (no full Xcode):

```bash
make            # builds bin/uvc-util and bin/xu-probe from src/
```

The uvc-util sources are MRC-era Objective-C, so the build uses `-fno-objc-arc`.

## Project layout

```
linkcam            the CLI (bash)
bin/               prebuilt arm64 helpers (uvc-util, xu-probe)
src/xu-probe.m     raw XU tool (this project)
src/vendor/        uvc-util sources, MIT (jtfrey/uvc-util)
Makefile           builds the helpers
install.sh         symlinks linkcam onto your PATH
```

## Compatibility & caveats

- **Apple Silicon only** in the prebuilt form (arm64). On Intel, run `make`.
- Tested against **Insta360 Link 2** (USB `0x2e1a:0x4c04`). Other Insta360
  cameras may use different XU selectors — `xu-probe scan` will help you find
  them.
- Reverse-engineered from observed behavior; not affiliated with or endorsed by
  Insta360. Use at your own risk.

## Credits

- [uvc-util](https://github.com/jtfrey/uvc-util) by Jeffrey Frey (MIT) — the
  IOKit UVC control foundation this builds on.

## License

MIT — see [LICENSE](LICENSE). Bundled uvc-util is also MIT
([src/vendor/LICENSE.uvc-util](src/vendor/LICENSE.uvc-util)).
