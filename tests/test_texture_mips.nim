import pixie, gltf/backends/texture_mips

block:
  let checker = TextureMip(width: 2, height: 2, pixels: @[
    rgbx(0, 0, 0, 255), rgbx(255, 255, 255, 255),
    rgbx(255, 255, 255, 255), rgbx(0, 0, 0, 255)])
  # Half the light is sRGB 188, while a linear data map averages to 128.
  doAssert checker.downsampleTexture(true).pixels == @[rgbx(188, 188, 188, 255)]
  doAssert checker.downsampleTexture(false).pixels == @[rgbx(128, 128, 128, 255)]

block:
  let transparent = TextureMip(width: 2, height: 1,
    pixels: @[rgbx(255, 0, 0, 0), rgbx(0, 0, 255, 255)])
  doAssert transparent.downsampleTexture(true).pixels == @[rgbx(188, 0, 188, 128)]

block:
  # Odd dimensions and one-pixel axes must retain every source texel.
  let odd = TextureMip(width: 1, height: 3,
    pixels: @[rgbx(0, 0, 0, 0), rgbx(0, 0, 0, 0), rgbx(255, 255, 255, 255)])
  let mip = odd.downsampleTexture()
  doAssert mip.width == 1 and mip.height == 1
  doAssert mip.pixels == @[rgbx(85, 85, 85, 85)]
  # A constant color survives the sRGB decode/encode round trip exactly.
  for value in 0 .. 255:
    let pixel = rgbx(value.uint8, value.uint8, value.uint8, value.uint8)
    doAssert TextureMip(width: 1, height: 1, pixels: @[pixel]).downsampleTexture(true).pixels == @[pixel]

echo "Texture mipmaps: linear-light color, linear data, straight alpha and odd sizes passed"
