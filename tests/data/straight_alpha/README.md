These tiny fixtures were generated for the straight-alpha texture tests.
`generate.py` reproduces them using Python and Pillow; Pillow is not needed to
run the Nim tests. The JPEG/WebP `.rgba` files are independently decoded by
Pillow (libjpeg/libwebp) and contain straight RGBA bytes.

PNG cases cover RGBA, palette transparency, grayscale alpha and 16-bit RGBA.
WebP cases cover lossy and lossless alpha, including colors at zero alpha.
