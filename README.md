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

USB support is a JavaScript (WebUSB) port of
[elksmart-comm](https://git.janouch.name/p/usb-drivers) by Přemysl Eric Janouch (0BSD).

Not affiliated with Ocrustar or ElkSmart.
