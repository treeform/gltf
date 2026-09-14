## Portable CPU representation of the reference renderer's prefiltered lighting.
import std/[json, os, strutils, tables]

type
  FloatTextureLevel* = object
    width*: int
    bytes*: string
  FloatTexture* = object
    cube*: bool
    levels*: int
    subresources*: seq[FloatTextureLevel] # Face-major, then mip level.
  IblEnvironment* = object
    mipCount*: int
    intensityScale*: float32
    textures*: Table[string, FloatTexture]

proc loadIblEnvironment*(directory: string): IblEnvironment =
  when cpuEndian != littleEndian:
    {.error: "IBL float asset loading requires little endian".}
  let manifest = parseFile(directory / "environment.json")
  if manifest["version"].getInt != 1 or manifest["format"].getStr != "rgba32f-le" or
      manifest["rowOrder"].getStr != "bottom-up":
    raise newException(ValueError, "Unsupported IBL environment format")
  result.mipCount = manifest["mipCount"].getInt
  result.intensityScale = manifest["intensityScale"].getFloat.float32
  if result.mipCount notin 1 .. 13:
    raise newException(ValueError, "Invalid IBL mip count")
  for item in manifest["textures"]:
    let name = item["name"].getStr
    let file = item["file"].getStr
    let face = item["face"].getInt
    let level = item["level"].getInt
    let width = item["width"].getInt
    let cube = name in ["diffuse", "specular", "charlie"]
    let levels = if name in ["specular", "charlie"]: result.mipCount else: 1
    if name notin ["diffuse", "specular", "ggx-lut", "charlie", "charlie-lut", "sheen-energy-lut"] or
        file != extractFilename(file) or ":" in file or file in [".", ".."] or
        width notin 1 .. 4096 or level notin 0 ..< levels or
        face notin 0 ..< (if cube: 6 else: 1):
      raise newException(ValueError, "Invalid IBL texture entry")
    if name notin result.textures:
      result.textures[name] = FloatTexture(cube: cube, levels: levels,
        subresources: newSeq[FloatTextureLevel](levels * (if cube: 6 else: 1)))
    let index = face * levels + level
    if result.textures[name].subresources[index].width != 0:
      raise newException(ValueError, "Duplicate IBL texture entry")
    let bytes = readFile(directory / file)
    if bytes.len != width * width * 16:
      raise newException(ValueError, "Incorrect IBL texture byte count: " & file)
    result.textures[name].subresources[index] = FloatTextureLevel(width: width, bytes: bytes)
  for name in ["diffuse", "specular", "ggx-lut", "charlie", "charlie-lut", "sheen-energy-lut"]:
    if name notin result.textures:
      raise newException(ValueError, "Missing IBL texture: " & name)
    let texture = result.textures[name]
    for i, part in texture.subresources:
      if part.width != max(1, texture.subresources[0].width shr (i mod texture.levels)):
        raise newException(ValueError, "Incomplete or inconsistent IBL mip chain: " & name)
