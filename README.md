# ElkSmart IR Hub

Unofficial IR remote for Ocrustar / ElkSmart USB-C IR blasters, right in the browser.

**Live site:** https://isaacbholm1-svg.github.io/elksmart-ir-hub/

- Browse 600+ brands and 3,000+ remotes from the open [IRDB](https://github.com/probonopd/irdb) project.
- **Blast over USB** with an Ocrustar / ElkSmart dongle (USB vendor `045C`) in Chrome on Android:
  plug it in, tap **Connect**, pick the blaster, then tap **Blast** on any button.
- Also works with Chrome / Edge on a computer. On Windows, install the WinUSB driver for the
  blaster first (for example with [Zadig](https://zadig.akeo.ie/)).
- iPhone / iPad browsers can't use USB devices, so there you can only look up and copy codes.
- Optional audio mode for headphone-jack IR blasters (19 kHz half-carrier, stereo inverted).
- Copy any button as Pronto hex or raw timings.

## iPhone / iPad app (sideload with KSign)

`ios/` holds a small native app that wraps this site and blasts through **audio-type**
ElkSmart / Ocrustar blasters (Lightning, USB-C audio or headphone-jack models).

- It shows whether a blaster is plugged in, warns about Bluetooth / AirPlay, and has a
  **Max volume** button (audio blasters only work at 100% volume).
- Sound plays even with the silent switch on.
- **USB-data blasters (the Android WebUSB kind) can't work on iPhone.** iOS gives apps no raw
  USB access, and re-signing doesn't change that. If the app says "No audio blaster detected"
  while yours is plugged in, you have a USB-data model.

**Get the app (free, no Mac):** every push builds an unsigned `IRHub.ipa` on GitHub Actions
(`.github/workflows/ios.yml`). Download it from the
[`ios-latest` release](../../releases/tag/ios-latest) (or the run's artifacts), open it in
KSign, sign it with your certificate, and install.

## 3D Scanner app (`scanner/`)

A separate iPhone / iPad app for making 3D models, also built free on GitHub Actions
(`.github/workflows/scanner.yml`). Download `Scanner3D.ipa` from the
[`scanner-latest` release](../../releases/tag/scanner-latest) and sign it with KSign.
Needs iOS 17+.

| Mode | What it makes | Needs |
| --- | --- | --- |
| **Object** | Guided Apple Object Capture, then on-device photogrammetry into a photo-textured USDZ. Photos can also be exported for full-detail processing on a computer. | LiDAR |
| **Space** | LiDAR mesh of rooms and big things, textured from automatically chosen sharp photos. Exports textured OBJ, USDZ, vertex-coloured PLY, coloured point cloud and camera poses. | LiDAR |
| **Room Plan** | RoomPlan scan of one or more rooms, merged into a 3D model plus a floor plan PNG with wall lengths, area, doors, windows and furniture. | LiDAR |
| **Photo Dataset** | Pose-tracked high-res photos, `transforms.json` (nerfstudio format) and a LiDAR point cloud, ready for Gaussian splats or NeRF. | Any ARKit iPhone |

Scans are listed in the app's Library (3D viewer, AR Quick Look, share/zip export) and appear
in the Files app under *On My iPhone → 3D Scanner*.

USB support is a JavaScript (WebUSB) port of
[elksmart-comm](https://git.janouch.name/p/usb-drivers) by Přemysl Eric Janouch (0BSD).

Not affiliated with Ocrustar or ElkSmart.
