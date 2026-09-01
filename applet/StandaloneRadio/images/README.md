# Station Artwork

This directory contains compact packaged station logos used by the Standalone Radio Now Playing screen. The built-in preset PNGs are constrained to a maximum of 180 by 110 pixels for the Squeezebox Radio's limited memory and display.

They are installed with the applet and loaded locally with SqueezePlay's `Surface:loadImage()` API. `radio.png` is the generic fallback used when a Radio Browser station has no compatible cached favicon. Replace an image with a small PNG using the same filename to customize packaged artwork.
