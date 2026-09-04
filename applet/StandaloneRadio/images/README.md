# Station Artwork

This directory contains `radio.png`, the compact generic fallback used by the Standalone Radio Now Playing screen, and `icon_internet_radio.png`, the Squeezebox Radio-sized Internet Radio Home-menu icon. Both are installed with the applet and loaded locally with SqueezePlay's `Surface:loadImage()` API.

Built-in presets use the generic fallback. The Home-menu icon is loaded through the applet's custom `hm_standaloneRadio` style, which preserves the active skin's layout while replacing its TuneIn artwork. Radio Browser stations can replace the generic Now Playing artwork with a supported favicon cached on the Radio after playback starts.
