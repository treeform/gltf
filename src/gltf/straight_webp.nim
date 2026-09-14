## Reuse Pixie's WebP decoding stages before they premultiply the RGBA bytes.
## Pixie currently exposes only the premultiplied Image entry point for WebP.
include pixie/fileformats/webp

proc decodeStraightWebp*(data: string): Image =
  let info = decodeWebpInfo(data)
  var bytes: seq[uint8]
  case info.compression
  of LosslessWebp:
    bytes = decodeLosslessData(data, info.vp8LOffset, info.vp8LSize,
      info.width, info.height, false)
    if not info.losslessAlpha:
      for i in countup(3, bytes.len - 1, 4): bytes[i] = 255
  of LossyWebp:
    bytes = frameToRgbaBytes(decodeVp8Frame(data, info.vp8Offset, info.vp8Size,
      info.width, info.height))
    if info.hasAlpha:
      if info.alphaOffset == 0: failInvalid("missing ALPH chunk")
      let alpha = decodeAlphaData(data, info)
      for i in 0 ..< info.width * info.height: bytes[i * 4 + 3] = alpha[i]
  of UnknownWebpCompression:
    raise newException(PixieError, "Animated WebP textures are unsupported")
  result = newImage(info.width, info.height)
  copyMem(result.data[0].addr, bytes[0].addr, bytes.len)
