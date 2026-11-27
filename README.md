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

USB support is a JavaScript (WebUSB) port of
[elksmart-comm](https://git.janouch.name/p/usb-drivers) by Přemysl Eric Janouch (0BSD).

Not affiliated with Ocrustar or ElkSmart.
