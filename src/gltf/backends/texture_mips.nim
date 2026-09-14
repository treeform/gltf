## CPU texture mipmaps for native uploads. glTF texels use straight alpha.
import std/math, pixie

type TextureMip* = object
  width*, height*: int
  pixels*: seq[ColorRGBX]

func srgbToLinear(value: float64): float64 =
  if value <= 0.04045: value / 12.92
  else: pow((value + 0.055) / 1.055, 2.4)

func linearToSrgb(value: float64): uint8 =
  let encoded = if value <= 0.0031308: value * 12.92
    else: 1.055 * pow(value, 1.0 / 2.4) - 0.055
  uint8(clamp(floor(encoded * 255.0 + 0.5), 0.0, 255.0))

const LinearColors = block:
  var values: array[256, float64]
  for i in 0 .. 255: values[i] = srgbToLinear(i.float64 / 255.0)
  values

proc downsampleTexture*(source: TextureMip, srgb = false): TextureMip =
  ## Average color in linear light; data maps and alpha stay linear bytes.
  ## Do not premultiply: even fully transparent texels retain their RGB.
  doAssert source.width > 0 and source.height > 0
  doAssert source.pixels.len == source.width * source.height
  result.width = max(1, source.width div 2)
  result.height = max(1, source.height div 2)
  result.pixels = newSeq[ColorRGBX](result.width * result.height)
  for y in 0 ..< result.height:
    let y0 = y * source.height div result.height
    let y1 = (y + 1) * source.height div result.height
    for x in 0 ..< result.width:
      let x0 = x * source.width div result.width
      let x1 = (x + 1) * source.width div result.width
      var r, g, b, a, count: uint32
      var linearR, linearG, linearB: float64
      for sy in y0 ..< y1:
        for sx in x0 ..< x1:
          let pixel = source.pixels[sy * source.width + sx]
          if srgb:
            linearR += LinearColors[pixel.r]
            linearG += LinearColors[pixel.g]
            linearB += LinearColors[pixel.b]
          else:
            r += pixel.r.uint32
            g += pixel.g.uint32
            b += pixel.b.uint32
          a += pixel.a.uint32
          inc count
      var pixel = rgbx(0, 0, 0, uint8((a + count div 2) div count))
      if srgb:
        pixel.r = linearToSrgb(linearR / count.float64)
        pixel.g = linearToSrgb(linearG / count.float64)
        pixel.b = linearToSrgb(linearB / count.float64)
      else:
        pixel.r = uint8((r + count div 2) div count)
        pixel.g = uint8((g + count div 2) div count)
        pixel.b = uint8((b + count div 2) div count)
      result.pixels[y * result.width + x] = pixel
