import
  std/strutils,
  flatty/binny,
  opengl,
  common

const
  Ktx2Identifier = "\xABKTX 20\xBB\r\n\x1A\n"
  Ktx2HeaderSize = 80
  Ktx2LevelSize = 24

  Ktx2NoSupercompression = 0'u32

  VkFormatBc1RgbUnormBlock = 131'u32
  VkFormatBc1RgbSrgbBlock = 132'u32
  VkFormatBc1RgbaUnormBlock = 133'u32
  VkFormatBc1RgbaSrgbBlock = 134'u32
  VkFormatBc2UnormBlock = 135'u32
  VkFormatBc2SrgbBlock = 136'u32
  VkFormatBc3UnormBlock = 137'u32
  VkFormatBc3SrgbBlock = 138'u32
  VkFormatBc4UnormBlock = 139'u32
  VkFormatBc4SnormBlock = 140'u32
  VkFormatBc5UnormBlock = 141'u32
  VkFormatBc5SnormBlock = 142'u32

  GlCompressedRgbS3tcDxt1Ext = 0x83F0.GLenum
  GlCompressedRgbaS3tcDxt1Ext = 0x83F1.GLenum
  GlCompressedRgbaS3tcDxt3Ext = 0x83F2.GLenum
  GlCompressedRgbaS3tcDxt5Ext = 0x83F3.GLenum
  GlCompressedSrgbS3tcDxt1Ext = 0x8C4C.GLenum
  GlCompressedSrgbAlphaS3tcDxt1Ext = 0x8C4D.GLenum
  GlCompressedSrgbAlphaS3tcDxt3Ext = 0x8C4E.GLenum
  GlCompressedSrgbAlphaS3tcDxt5Ext = 0x8C4F.GLenum
  GlCompressedRedRgtc1 = 0x8DBB.GLenum
  GlCompressedSignedRedRgtc1 = 0x8DBC.GLenum
  GlCompressedRgRgtc2 = 0x8DBD.GLenum
  GlCompressedSignedRgRgtc2 = 0x8DBE.GLenum

  GlTextureBaseLevel = 0x813C.GLenum
  GlTextureMaxLevel = 0x813D.GLenum

type
  Ktx2LevelInfo* = object
    byteOffset*: int
    byteLength*: int
    uncompressedByteLength*: int

  Ktx2TextureInfo* = object
    vkFormat*: uint32
    glInternalFormat*: GLenum
    width*: int
    height*: int
    depth*: int
    layerCount*: int
    faceCount*: int
    levelCount*: int
    supercompressionScheme*: uint32
    levels*: seq[Ktx2LevelInfo]

proc defaultKtx2Sampler(): TextureSampler =
  TextureSampler(
    magFilter: GL_LINEAR,
    minFilter: GL_LINEAR_MIPMAP_LINEAR,
    wrapS: GL_REPEAT,
    wrapT: GL_REPEAT
  )

proc raiseKtx2Error(message: string) {.noreturn.} =
  raise newException(GltfError, "KTX2: " & message)

proc vkFormatName*(vkFormat: uint32): string =
  case vkFormat
  of VkFormatBc1RgbUnormBlock:
    "VK_FORMAT_BC1_RGB_UNORM_BLOCK"
  of VkFormatBc1RgbSrgbBlock:
    "VK_FORMAT_BC1_RGB_SRGB_BLOCK"
  of VkFormatBc1RgbaUnormBlock:
    "VK_FORMAT_BC1_RGBA_UNORM_BLOCK"
  of VkFormatBc1RgbaSrgbBlock:
    "VK_FORMAT_BC1_RGBA_SRGB_BLOCK"
  of VkFormatBc2UnormBlock:
    "VK_FORMAT_BC2_UNORM_BLOCK"
  of VkFormatBc2SrgbBlock:
    "VK_FORMAT_BC2_SRGB_BLOCK"
  of VkFormatBc3UnormBlock:
    "VK_FORMAT_BC3_UNORM_BLOCK"
  of VkFormatBc3SrgbBlock:
    "VK_FORMAT_BC3_SRGB_BLOCK"
  of VkFormatBc4UnormBlock:
    "VK_FORMAT_BC4_UNORM_BLOCK"
  of VkFormatBc4SnormBlock:
    "VK_FORMAT_BC4_SNORM_BLOCK"
  of VkFormatBc5UnormBlock:
    "VK_FORMAT_BC5_UNORM_BLOCK"
  of VkFormatBc5SnormBlock:
    "VK_FORMAT_BC5_SNORM_BLOCK"
  else:
    "VK_FORMAT_" & $vkFormat

proc isSupportedVkFormat*(vkFormat: uint32): bool =
  case vkFormat
  of
    VkFormatBc1RgbUnormBlock,
    VkFormatBc1RgbSrgbBlock,
    VkFormatBc1RgbaUnormBlock,
    VkFormatBc1RgbaSrgbBlock,
    VkFormatBc2UnormBlock,
    VkFormatBc2SrgbBlock,
    VkFormatBc3UnormBlock,
    VkFormatBc3SrgbBlock,
    VkFormatBc4UnormBlock,
    VkFormatBc4SnormBlock,
    VkFormatBc5UnormBlock,
    VkFormatBc5SnormBlock:
    true
  else:
    false

proc glInternalFormatForVkFormat*(vkFormat: uint32): GLenum =
  case vkFormat
  of VkFormatBc1RgbUnormBlock:
    GlCompressedRgbS3tcDxt1Ext
  of VkFormatBc1RgbSrgbBlock:
    GlCompressedSrgbS3tcDxt1Ext
  of VkFormatBc1RgbaUnormBlock:
    GlCompressedRgbaS3tcDxt1Ext
  of VkFormatBc1RgbaSrgbBlock:
    GlCompressedSrgbAlphaS3tcDxt1Ext
  of VkFormatBc2UnormBlock:
    GlCompressedRgbaS3tcDxt3Ext
  of VkFormatBc2SrgbBlock:
    GlCompressedSrgbAlphaS3tcDxt3Ext
  of VkFormatBc3UnormBlock:
    GlCompressedRgbaS3tcDxt5Ext
  of VkFormatBc3SrgbBlock:
    GlCompressedSrgbAlphaS3tcDxt5Ext
  of VkFormatBc4UnormBlock:
    GlCompressedRedRgtc1
  of VkFormatBc4SnormBlock:
    GlCompressedSignedRedRgtc1
  of VkFormatBc5UnormBlock:
    GlCompressedRgRgtc2
  of VkFormatBc5SnormBlock:
    GlCompressedSignedRgRgtc2
  else:
    raiseKtx2Error("unsupported vkFormat " & vkFormatName(vkFormat))

proc mipDimension(size, level: int): int =
  max(1, size shr level)

proc parseKtx2*(data: string): Ktx2TextureInfo =
  if data.len < Ktx2HeaderSize:
    raiseKtx2Error("file is too small for a KTX2 header")
  if data[0 ..< Ktx2Identifier.len] != Ktx2Identifier:
    raiseKtx2Error("invalid identifier")

  result.vkFormat = data.readUint32(12)
  discard data.readUint32(16) # typeSize, unused for block compressed uploads.
  result.width = data.readUint32(20).int
  result.height = data.readUint32(24).int
  result.depth = data.readUint32(28).int
  result.layerCount = data.readUint32(32).int
  result.faceCount = data.readUint32(36).int
  result.levelCount = data.readUint32(40).int
  result.supercompressionScheme = data.readUint32(44)
  result.glInternalFormat = glInternalFormatForVkFormat(result.vkFormat)

  if result.width <= 0 or result.height <= 0:
    raiseKtx2Error("only 2D textures with width and height are supported")
  if result.depth notin [0, 1]:
    raiseKtx2Error("3D KTX2 textures are not supported")
  if result.layerCount notin [0, 1]:
    raiseKtx2Error("array KTX2 textures are not supported")
  if result.faceCount != 1:
    raiseKtx2Error("cubemap KTX2 textures are not supported")
  if result.levelCount <= 0:
    raiseKtx2Error("KTX2 textures must include at least one mip level")
  if result.supercompressionScheme != Ktx2NoSupercompression:
    raiseKtx2Error("supercompressed KTX2 textures are not supported")

  let levelIndexEnd = Ktx2HeaderSize + result.levelCount * Ktx2LevelSize
  if levelIndexEnd > data.len:
    raiseKtx2Error("file is truncated before the level index")

  result.levels.setLen(result.levelCount)
  for level in 0 ..< result.levelCount:
    let offset = Ktx2HeaderSize + level * Ktx2LevelSize
    let byteOffset = data.readUint64(offset).int
    let byteLength = data.readUint64(offset + 8).int
    let uncompressedByteLength = data.readUint64(offset + 16).int
    if byteOffset < 0 or byteLength <= 0:
      raiseKtx2Error("invalid level index entry")
    if byteOffset + byteLength > data.len:
      raiseKtx2Error("level data extends past end of file")
    result.levels[level] = Ktx2LevelInfo(
      byteOffset: byteOffset,
      byteLength: byteLength,
      uncompressedByteLength: uncompressedByteLength
    )

proc readKtx2File*(file: string): Ktx2TextureInfo =
  parseKtx2(readFile(file))

proc clearGlErrors() =
  while glGetError() != GL_NO_ERROR:
    discard

proc uploadKtx2*(info: Ktx2TextureInfo, data: string, sampler = defaultKtx2Sampler()): GLuint =
  clearGlErrors()
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexParameteri(GL_TEXTURE_2D, GlTextureBaseLevel, 0)
  glTexParameteri(GL_TEXTURE_2D, GlTextureMaxLevel, (info.levelCount - 1).GLint)

  for level, levelInfo in info.levels:
    let
      width = mipDimension(info.width, level)
      height = mipDimension(info.height, level)
      levelPtr = unsafeAddr data[levelInfo.byteOffset]
    glCompressedTexImage2D(
      GL_TEXTURE_2D,
      level.GLint,
      info.glInternalFormat,
      width.GLsizei,
      height.GLsizei,
      0,
      levelInfo.byteLength.GLsizei,
      cast[pointer](levelPtr)
    )

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, sampler.magFilter)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, sampler.minFilter)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, sampler.wrapS)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, sampler.wrapT)

  let err = glGetError()
  glBindTexture(GL_TEXTURE_2D, 0)
  if err != GL_NO_ERROR:
    glDeleteTextures(1, result.addr)
    result = 0
    raiseKtx2Error("OpenGL rejected " & vkFormatName(info.vkFormat) &
      " with error 0x" & toHex(err.int))

proc loadKtx2Texture*(data: string, sampler = defaultKtx2Sampler()): GLuint =
  let info = parseKtx2(data)
  uploadKtx2(info, data, sampler)

proc loadKtx2TextureFile*(file: string, sampler = defaultKtx2Sampler()): GLuint =
  let data = readFile(file)
  loadKtx2Texture(data, sampler)
