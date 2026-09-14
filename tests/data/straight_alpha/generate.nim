import
  std/[os, osproc, streams, strutils, tempfiles],
  pixie/fileformats/ppm, zippy, zippy/crc

const
  FixtureDirectory = currentSourcePath().parentDir()
  PamHeader = "P7\nWIDTH 5\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\n" &
    "TUPLTYPE RGB_ALPHA\nENDHDR\n"

type GeneratorError = object of CatchableError

proc addUint32(data: var string, value: uint32) =
  ## Appends a PNG integer in network byte order.
  for shift in [24, 16, 8, 0]:
    data.add(char((value shr shift) and 255))

proc addUint16(data: var string, value: uint16) =
  ## Appends one 16-bit PNG channel in network byte order.
  data.add(char(value shr 8))
  data.add(char(value and 255))

proc addChunk(png: var string, kind, data: string) =
  ## Appends a PNG chunk with its length and CRC.
  png.addUint32(data.len.uint32)
  png.add(kind)
  png.add(data)
  png.addUint32(crc32(kind & data))

proc writePng(
  path: string,
  width, depth, colorType: int,
  scanline: string,
  palette = "",
  transparency = ""
) =
  ## Writes a single-row PNG without converting its channels or color type.
  var
    png = "\x89PNG\r\n\x1a\n"
    header: string
  header.addUint32(width.uint32)
  header.addUint32(1)
  header.add(char(depth))
  header.add(char(colorType))
  header.add("\0\0\0")
  png.addChunk("IHDR", header)
  if palette.len > 0:
    png.addChunk("PLTE", palette)
  if transparency.len > 0:
    png.addChunk("tRNS", transparency)
  png.addChunk("IDAT", compress(scanline, 6, dfZlib))
  png.addChunk("IEND", "")
  writeFile(path, png)

proc runTool(name: string, args: openArray[string]) =
  ## Runs an independent codec tool and preserves its failure diagnostics.
  let executable = findExe(name)
  if executable.len == 0:
    raise newException(
      GeneratorError,
      "Missing " & name & "; install the libwebp and libjpeg-turbo tools"
    )
  let process = startProcess(
    executable,
    args = args,
    options = {poStdErrToStdOut}
  )
  defer:
    process.close()
  let
    output = process.outputStream.readAll()
    code = process.waitForExit()
  if code != 0:
    raise newException(GeneratorError, name & " failed: " & output)

proc writePngFixtures(directory: string) =
  ## Generates RGBA, palette, grayscale-alpha and 16-bit RGBA fixtures.
  var
    rgba = "\0"
    palette = newString(768)
    rgba16 = "\0"
  for alpha in [0, 1, 64, 128, 255]:
    rgba.add("\x40\x80\xc0")
    rgba.add(char(alpha))
  writePng(directory / "rgba.png", 5, 8, 6, rgba)
  palette[1] = '\xff'
  palette[3] = '\x40'
  palette[4] = '\x80'
  palette[5] = '\xc0'
  writePng(
    directory / "palette.png",
    2,
    8,
    3,
    "\0\0\1",
    palette,
    "\0\x80"
  )
  writePng(directory / "gray_alpha.png", 2, 8, 4, "\0\x80\0\xc0\x40")
  for channel in [0x1234'u16, 0xabcd, 0x5678, 0, 0xffff, 0x8000,
      0x4000, 0x8000]:
    rgba16.addUint16(channel)
  writePng(directory / "rgba16.png", 2, 16, 6, rgba16)

proc generate(directory: string) =
  ## Regenerates the fixtures and independently decoded JPEG/WebP references.
  createDir(directory)
  let scratch = createTempDir("gltf-straight-alpha-", "")
  defer:
    removeDir(scratch)
  writePngFixtures(directory)
  runTool(
    "cwebp",
    ["-quiet", "-lossless", "-exact", "-q", "80", "-m", "4",
      directory / "rgba.png", "-o", directory / "lossless.webp"]
  )
  runTool(
    "cwebp",
    ["-quiet", "-exact", "-q", "100", "-m", "4",
      directory / "rgba.png", "-o", directory / "lossy.webp"]
  )
  writeFile(
    scratch / "rgb.ppm",
    "P6\n5 1\n255\n" & "\x40\x80\xc0".repeat(5)
  )
  runTool(
    "cjpeg",
    ["-quality", "100", "-sample", "1x1",
      "-outfile", directory / "rgb.jpg", scratch / "rgb.ppm"]
  )
  for name in ["lossless.webp", "lossy.webp"]:
    let decoded = scratch / (name & ".pam")
    runTool("dwebp", ["-quiet", directory / name, "-pam", "-o", decoded])
    let pam = readFile(decoded)
    if not pam.startsWith(PamHeader) or pam.len != PamHeader.len + 20:
      raise newException(GeneratorError, "Unexpected decoded PAM: " & name)
    writeFile(directory / (name & ".rgba"), pam[PamHeader.len .. ^1])
  runTool(
    "djpeg",
    ["-rgb", "-pnm", "-outfile", scratch / "decoded.ppm",
      directory / "rgb.jpg"]
  )
  let decoded = decodePpm(readFile(scratch / "decoded.ppm"))
  if decoded.width != 5 or decoded.height != 1:
    raise newException(GeneratorError, "Unexpected decoded JPEG dimensions")
  var rgba: string
  for pixel in decoded.data:
    for channel in [pixel.r, pixel.g, pixel.b, pixel.a]:
      rgba.add(char(channel))
  writeFile(directory / "rgb.jpg.rgba", rgba)
  echo "Generated small PNG/JPEG/WebP fixtures with known straight-alpha pixels."

if paramCount() > 1:
  raise newException(GeneratorError, "Usage: generate [output-directory]")
generate(
  if paramCount() == 1:
    absolutePath(paramStr(1))
  else:
    FixtureDirectory
)
