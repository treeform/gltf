These tiny fixtures were generated for the straight-alpha texture tests.
Run `nim r tests/data/straight_alpha/generate.nim` from the repository root
to reproduce them. The generator needs `cwebp`, `dwebp`, `cjpeg` and `djpeg`
on PATH; these tools are not needed to run the Nim tests. The JPEG/WebP
`.rgba` files are independently decoded by libjpeg/libwebp and contain
straight RGBA bytes. An optional argument selects another output directory.

PNG cases cover RGBA, palette transparency, grayscale alpha and 16-bit RGBA.
WebP cases cover lossy and lossless alpha, including colors at zero alpha.
