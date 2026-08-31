# Station Artwork

This directory contains compact local station logos used by the Standalone Radio Now Playing screen. The six PNGs are constrained to a maximum of 180 by 110 pixels for the Squeezebox Radio's limited memory and display.

They are installed with the applet and loaded locally with SqueezePlay's `Surface:loadImage()` API; the radio never fetches artwork at runtime. Replace an image with a small PNG using the same filename to customize its station artwork.
