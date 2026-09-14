## glTF texture Image buffers contain straight RGBA bytes. Use pixel access and
## GPU upload with these buffers, not Pixie's premultiplied drawing operations.
import pixie, pixie/fileformats/[png, jpeg]
from straight_webp import decodeStraightWebp

proc decodeStraightAlphaImage*(data: string): Image =
  ## Preserves RGB even where alpha is zero; unpremultiplying cannot recover it.
  if data.len >= 8 and equalMem(data[0].unsafeAddr, pngSignature[0].unsafeAddr, 8):
    let png = decodePng(data)
    result = newImage(png.width, png.height)
    if png.data.len > 0:
      copyMem(result.data[0].addr, png.data[0].addr, png.data.len * 4)
    else:
      when compiles(png.data16):
        for i, p in png.data16:
          template byte(v: uint16): uint8 =
            ((v.uint32 * 255 + 32767) div 65535).uint8
          result.data[i] = rgbx(byte(p.r), byte(p.g), byte(p.b), byte(p.a))
  elif data.len >= 2 and equalMem(data[0].unsafeAddr, jpegStartOfImage[0].unsafeAddr, 2):
    result = decodeJpeg(data) # JPEG has no alpha channel.
  elif data.len >= 12 and data[0 .. 3] == "RIFF" and data[8 .. 11] == "WEBP":
    result = decodeStraightWebp(data)
  else:
    raise newException(PixieError, "Unsupported glTF image; expected PNG, JPEG or WebP")

proc loadStraightAlphaImage*(path: string): Image =
  decodeStraightAlphaImage(readFile(path))

proc encodeStraightAlphaPng*(image: Image): string =
  ## Writes texture bytes without Pixie's Image-to-PNG unpremultiplication.
  encodePng(image.width, image.height, 4, image.data[0].addr, image.data.len * 4)
