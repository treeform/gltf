import
  std/[json, os],
  metal4,
  ../../common

type IblEnvironment* = object
  diffuse*, specular*, lut*, charlie*, charlieLut*, sheenEnergyLut*: MTLTexture
  mipCount*: int
  intensityScale*: float32

objc:
  proc setTextureType*(self: MTLTextureDescriptor, x: uint)
  proc setMipmapLevelCount*(self: MTLTextureDescriptor, x: uint)
  proc replaceRegion*(self: MTLTexture, x: MTLRegion,
    mipmapLevel: uint, slice: uint, withBytes: pointer,
    bytesPerRow: uint, bytesPerImage: uint)
  proc release*(self: NSObject)

proc freeMetal*[T](value: var T) =
  ## Releases an owned Objective-C resource and clears the handle.
  if not value.isNil:
    cast[NSObject](value).release()
    value = default(T)

proc destroy*(environment: var IblEnvironment) =
  ## Releases all uploaded lighting textures.
  environment.diffuse.freeMetal()
  environment.specular.freeMetal()
  environment.lut.freeMetal()
  environment.charlie.freeMetal()
  environment.charlieLut.freeMetal()
  environment.sheenEnergyLut.freeMetal()
  environment = IblEnvironment()

proc loadIblEnvironment*(directory: string): IblEnvironment =
  ## Uploads the pinned floating-point lighting export to the default device.
  let device = MTLCreateSystemDefaultDevice()
  try:
    let manifest = parseFile(directory / "environment.json")
    if manifest["version"].getInt() != 1 or
      manifest["format"].getStr() != "rgba32f-le" or
      manifest["rowOrder"].getStr() != "bottom-up":
        raise newException(GltfError, "Unsupported IBL environment format")
    result.mipCount = manifest["mipCount"].getInt()
    result.intensityScale = manifest["intensityScale"].getFloat().float32
    for item in manifest["textures"]:
      let
        name = item["name"].getStr()
        level = item["level"].getInt()
        face = item["face"].getInt()
        width = item["width"].getInt()
        filename = item["file"].getStr()
        cube = name in ["diffuse", "specular", "charlie"]
        levels = if name in ["specular", "charlie"]: result.mipCount else: 1
      if filename != filename.extractFilename() or width < 1 or
        width > 4096 or level < 0 or level >= levels or
        face < 0 or face >= (if cube: 6 else: 1):
          raise newException(GltfError, "Invalid IBL texture entry")
      let target = case name
        of "diffuse": result.diffuse.addr
        of "specular": result.specular.addr
        of "ggx-lut": result.lut.addr
        of "charlie": result.charlie.addr
        of "charlie-lut": result.charlieLut.addr
        of "sheen-energy-lut": result.sheenEnergyLut.addr
        else:
          raise newException(GltfError, "Unknown IBL texture: " & name)
      if target[].isNil:
        let descriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(
          MTLPixelFormatRGBA32Float,
          (width shl level).uint,
          (width shl level).uint,
          levels > 1
        )
        if cube:
          descriptor.setTextureType(5)
        descriptor.setMipmapLevelCount(levels.uint)
        descriptor.setUsage(MTLTextureUsageShaderRead)
        target[] = device.newTextureWithDescriptor(descriptor)
        checkNil(target[], "Could not create IBL texture")
      let bytes = readFile(directory / filename)
      if bytes.len != width * width * 16:
        raise newException(GltfError, "Incorrect IBL texture size: " & filename)
      target[].replaceRegion(
        MTLRegion(
          origin: MTLOrigin(x: 0, y: 0, z: 0),
          size: MTLSize(width: width.uint, height: width.uint, depth: 1)
        ),
        level.uint, face.uint, bytes[0].unsafeAddr,
        (width * 16).uint, bytes.len.uint
      )
  except CatchableError as error:
    result.destroy()
    raise newException(GltfError, "Could not load IBL: " & error.msg)
