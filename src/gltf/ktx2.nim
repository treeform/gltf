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

  VkFormatR32Sfloat* = 100'u32
  VkFormatBc1RgbUnormBlock* = 131'u32
  VkFormatBc1RgbSrgbBlock* = 132'u32
  VkFormatBc1RgbaUnormBlock* = 133'u32
  VkFormatBc1RgbaSrgbBlock* = 134'u32
  VkFormatBc2UnormBlock* = 135'u32
  VkFormatBc2SrgbBlock* = 136'u32
  VkFormatBc3UnormBlock* = 137'u32
  VkFormatBc3SrgbBlock* = 138'u32
  VkFormatBc4UnormBlock* = 139'u32
  VkFormatBc4SnormBlock* = 140'u32
  VkFormatBc5UnormBlock* = 141'u32
  VkFormatBc5SnormBlock* = 142'u32

  GlR32f = 0x822E.GLenum

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
  GlTextureWidth = 0x1000.GLenum
  GlTextureHeight = 0x1001.GLenum
  GlTextureInternalFormat = 0x1003.GLenum
  GlTextureCompressedImageSize = 0x86A0.GLenum

  # Basic DFD blocks copied from libktx output so we can write valid KTX2
  # files without shelling out to the CLI at runtime.
  DfdBc1LinearWords = [
    0x0000002C'u32, 0x00000000'u32, 0x00280002'u32, 0x00010180'u32,
    0x00000303'u32, 0x00000008'u32, 0x00000000'u32, 0x003F0000'u32,
    0x00000000'u32, 0x00000000'u32, 0xFFFFFFFF'u32
  ]
  DfdBc3LinearWords = [
    0x0000003C'u32, 0x00000000'u32, 0x00380002'u32, 0x00010182'u32,
    0x00000303'u32, 0x00000010'u32, 0x00000000'u32, 0x0F3F0000'u32,
    0x00000000'u32, 0x00000000'u32, 0xFFFFFFFF'u32, 0x003F0040'u32,
    0x00000000'u32, 0x00000000'u32, 0xFFFFFFFF'u32
  ]
  DfdBc4LinearWords = [
    0x0000002C'u32, 0x00000000'u32, 0x00280002'u32, 0x00010183'u32,
    0x00000303'u32, 0x00000008'u32, 0x00000000'u32, 0x003F0000'u32,
    0x00000000'u32, 0x00000000'u32, 0xFFFFFFFF'u32
  ]
  DfdBc5LinearWords = [
    0x0000003C'u32, 0x00000000'u32, 0x00380002'u32, 0x00010184'u32,
    0x00000303'u32, 0x00000010'u32, 0x00000000'u32, 0x003F0000'u32,
    0x00000000'u32, 0x00000000'u32, 0xFFFFFFFF'u32, 0x013F0040'u32,
    0x00000000'u32, 0x00000000'u32, 0xFFFFFFFF'u32
  ]
  DfdR32SfloatWords = [
    0x0000002C'u32, 0x00000000'u32, 0x00280002'u32, 0x00010101'u32,
    0x00000000'u32, 0x00000004'u32, 0x00000000'u32, 0xC01F0000'u32,
    0x00000000'u32, 0xBF800000'u32, 0x3F800000'u32
  ]

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

proc appendUint32Le(data: var string, value: uint32) =
  data.add(char(value and 0xFF'u32))
  data.add(char((value shr 8) and 0xFF'u32))
  data.add(char((value shr 16) and 0xFF'u32))
  data.add(char((value shr 24) and 0xFF'u32))

proc appendUint64Le(data: var string, value: uint64) =
  for shift in countup(0, 56, 8):
    data.add(char((value shr shift) and 0xFF'u64))

proc padTo(data: var string, alignment: int) =
  while data.len mod alignment != 0:
    data.add(char(0))

proc overwriteByte(data: var string, offset: int, value: byte) =
  data[offset] = char(value)

proc dfdFromWords(words: openArray[uint32]): string =
  for word in words:
    result.appendUint32Le(word)

proc textureLevelParam(target: GLenum, level: int, pname: GLenum): GLint =
  glGetTexLevelParameteriv(target, level.GLint, pname, result.addr)

proc clearGlErrors() =
  while glGetError() != GL_NO_ERROR:
    discard

proc mipDimension(size, level: int): int =
  max(1, size shr level)

proc isCompressedVkFormat*(vkFormat: uint32): bool =
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

proc vkFormatName*(vkFormat: uint32): string =
  case vkFormat
  of VkFormatR32Sfloat:
    "VK_FORMAT_R32_SFLOAT"
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
    VkFormatR32Sfloat,
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
  of VkFormatR32Sfloat:
    GlR32f
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

proc vkFormatForGlInternalFormat*(glInternalFormat: GLenum): uint32 =
  case glInternalFormat
  of GlR32f:
    VkFormatR32Sfloat
  of GlCompressedRgbS3tcDxt1Ext:
    VkFormatBc1RgbUnormBlock
  of GlCompressedSrgbS3tcDxt1Ext:
    VkFormatBc1RgbSrgbBlock
  of GlCompressedRgbaS3tcDxt1Ext:
    VkFormatBc1RgbaUnormBlock
  of GlCompressedSrgbAlphaS3tcDxt1Ext:
    VkFormatBc1RgbaSrgbBlock
  of GlCompressedRgbaS3tcDxt3Ext:
    VkFormatBc2UnormBlock
  of GlCompressedSrgbAlphaS3tcDxt3Ext:
    VkFormatBc2SrgbBlock
  of GlCompressedRgbaS3tcDxt5Ext:
    VkFormatBc3UnormBlock
  of GlCompressedSrgbAlphaS3tcDxt5Ext:
    VkFormatBc3SrgbBlock
  of GlCompressedRedRgtc1:
    VkFormatBc4UnormBlock
  of GlCompressedSignedRedRgtc1:
    VkFormatBc4SnormBlock
  of GlCompressedRgRgtc2:
    VkFormatBc5UnormBlock
  of GlCompressedSignedRgRgtc2:
    VkFormatBc5SnormBlock
  else:
    raiseKtx2Error("unsupported OpenGL internal format 0x" & toHex(glInternalFormat.int))

proc dfdForVkFormat(vkFormat: uint32): string =
  case vkFormat
  of VkFormatR32Sfloat:
    result = dfdFromWords(DfdR32SfloatWords)
  of VkFormatBc1RgbUnormBlock:
    result = dfdFromWords(DfdBc1LinearWords)
  of VkFormatBc1RgbSrgbBlock:
    result = dfdFromWords(DfdBc1LinearWords)
    result.overwriteByte(14, 2)
  of VkFormatBc1RgbaUnormBlock:
    result = dfdFromWords(DfdBc1LinearWords)
    result.overwriteByte(12, 0x80)
  of VkFormatBc1RgbaSrgbBlock:
    result = dfdFromWords(DfdBc1LinearWords)
    result.overwriteByte(12, 0x80)
    result.overwriteByte(14, 2)
  of VkFormatBc2UnormBlock:
    result = dfdFromWords(DfdBc3LinearWords)
    result.overwriteByte(12, 0x81)
  of VkFormatBc2SrgbBlock:
    result = dfdFromWords(DfdBc3LinearWords)
    result.overwriteByte(12, 0x81)
    result.overwriteByte(14, 2)
  of VkFormatBc3UnormBlock:
    result = dfdFromWords(DfdBc3LinearWords)
  of VkFormatBc3SrgbBlock:
    result = dfdFromWords(DfdBc3LinearWords)
    result.overwriteByte(14, 2)
  of VkFormatBc4UnormBlock:
    result = dfdFromWords(DfdBc4LinearWords)
  of VkFormatBc4SnormBlock:
    result = dfdFromWords(DfdBc4LinearWords)
    result.overwriteByte(31, 0x80)
    result.overwriteByte(38, 0x01)
  of VkFormatBc5UnormBlock:
    result = dfdFromWords(DfdBc5LinearWords)
  of VkFormatBc5SnormBlock:
    result = dfdFromWords(DfdBc5LinearWords)
    result.overwriteByte(31, 0x80)
    result.overwriteByte(38, 0x80)
    result.overwriteByte(47, 0x80)
    result.overwriteByte(54, 0x01)
  else:
    raiseKtx2Error("cannot build DFD for " & vkFormatName(vkFormat))

proc pixelFormatAndTypeForVkFormat(vkFormat: uint32): tuple[format: GLenum, pixelType: GLenum] =
  case vkFormat
  of VkFormatR32Sfloat:
    (GL_RED, cGL_FLOAT)
  else:
    raiseKtx2Error("no unpack format defined for " & vkFormatName(vkFormat))

proc bytesPerPixelForVkFormat(vkFormat: uint32): int =
  case vkFormat
  of VkFormatR32Sfloat:
    4
  else:
    raiseKtx2Error("no bytes-per-pixel defined for " & vkFormatName(vkFormat))

proc levelAlignmentForVkFormat(vkFormat: uint32): int =
  case vkFormat
  of VkFormatBc1RgbUnormBlock, VkFormatBc1RgbSrgbBlock,
     VkFormatBc1RgbaUnormBlock, VkFormatBc1RgbaSrgbBlock,
     VkFormatBc4UnormBlock, VkFormatBc4SnormBlock:
    8
  of VkFormatBc2UnormBlock, VkFormatBc2SrgbBlock,
     VkFormatBc3UnormBlock, VkFormatBc3SrgbBlock,
     VkFormatBc5UnormBlock, VkFormatBc5SnormBlock:
    16
  else:
    4

proc parseKtx2*(data: string): Ktx2TextureInfo =
  if data.len < Ktx2HeaderSize:
    raiseKtx2Error("file is too small for a KTX2 header")
  if data[0 ..< Ktx2Identifier.len] != Ktx2Identifier:
    raiseKtx2Error("invalid identifier")

  result.vkFormat = data.readUint32(12)
  discard data.readUint32(16) # typeSize
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

proc encodeKtx2*(vkFormat: uint32, width, height: int, levelsData: openArray[string]): string =
  if not isSupportedVkFormat(vkFormat):
    raiseKtx2Error("unsupported write format " & vkFormatName(vkFormat))
  if width <= 0 or height <= 0:
    raiseKtx2Error("width and height must be positive")
  if levelsData.len == 0:
    raiseKtx2Error("at least one mip level is required")

  let
    dfd = dfdForVkFormat(vkFormat)
    dfdOffset = Ktx2HeaderSize + levelsData.len * Ktx2LevelSize
    dfdLength = dfd.len
    kvdOffset = 0
    kvdLength = 0

  result = Ktx2Identifier
  result.appendUint32Le(vkFormat)
  result.appendUint32Le(
    if isCompressedVkFormat(vkFormat): 1'u32 else: bytesPerPixelForVkFormat(vkFormat).uint32
  )
  result.appendUint32Le(width.uint32)
  result.appendUint32Le(height.uint32)
  result.appendUint32Le(0)
  result.appendUint32Le(0)
  result.appendUint32Le(1)
  result.appendUint32Le(levelsData.len.uint32)
  result.appendUint32Le(Ktx2NoSupercompression)
  result.appendUint32Le(dfdOffset.uint32)
  result.appendUint32Le(dfdLength.uint32)
  result.appendUint32Le(kvdOffset.uint32)
  result.appendUint32Le(kvdLength.uint32)
  result.appendUint64Le(0)
  result.appendUint64Le(0)

  let levelAlignment = levelAlignmentForVkFormat(vkFormat)
  var payloadOffset = dfdOffset + dfdLength
  if payloadOffset mod levelAlignment != 0:
    payloadOffset += levelAlignment - (payloadOffset mod levelAlignment)
  for levelBytes in levelsData:
    result.appendUint64Le(payloadOffset.uint64)
    result.appendUint64Le(levelBytes.len.uint64)
    result.appendUint64Le(levelBytes.len.uint64)
    payloadOffset += levelBytes.len
    if payloadOffset mod levelAlignment != 0:
      payloadOffset += levelAlignment - (payloadOffset mod levelAlignment)

  result.add(dfd)
  result.padTo(levelAlignment)
  for levelBytes in levelsData:
    result.add(levelBytes)
    result.padTo(levelAlignment)

proc readTextureBytes(target: GLenum, level: int, format: GLenum, pixelType: GLenum, byteCount: int): string =
  result = newString(byteCount)
  if byteCount > 0:
    glGetTexImage(
      target,
      level.GLint,
      format,
      pixelType,
      cast[pointer](result[0].addr)
    )

proc readCompressedTextureBytes(target: GLenum, level: int, byteCount: int): string =
  result = newString(byteCount)
  if byteCount > 0:
    glGetCompressedTexImage(
      target,
      level.GLint,
      cast[pointer](result[0].addr)
    )

proc directTextureLevels(target: GLenum, texture: GLuint, vkFormat: uint32, levelCount: int): seq[string] =
  glBindTexture(target, texture)
  let compressed = isCompressedVkFormat(vkFormat)
  for level in 0 ..< levelCount:
    if compressed:
      let byteCount = textureLevelParam(target, level, GlTextureCompressedImageSize).int
      result.add(readCompressedTextureBytes(target, level, byteCount))
    else:
      let
        width = textureLevelParam(target, level, GlTextureWidth).int
        height = textureLevelParam(target, level, GlTextureHeight).int
        formatInfo = pixelFormatAndTypeForVkFormat(vkFormat)
        byteCount = width * height * bytesPerPixelForVkFormat(vkFormat)
      result.add(readTextureBytes(target, level, formatInfo.format, formatInfo.pixelType, byteCount))

proc compressTextureLevels(
  sourceTarget: GLenum,
  texture: GLuint,
  vkFormat: uint32,
  sourceFormat: GLenum,
  sourceType: GLenum,
  levelCount: int
): seq[string] =
  if not isCompressedVkFormat(vkFormat):
    raiseKtx2Error("compression helper requires a compressed target format")

  let glInternalFormat = glInternalFormatForVkFormat(vkFormat)
  clearGlErrors()

  var stagingTexture: GLuint
  glGenTextures(1, stagingTexture.addr)
  try:
    for level in 0 ..< levelCount:
      glBindTexture(sourceTarget, texture)
      let
        width = textureLevelParam(sourceTarget, level, GlTextureWidth).int
        height = textureLevelParam(sourceTarget, level, GlTextureHeight).int
        channelBytes =
          case sourceType
          of GL_UNSIGNED_BYTE:
            1
          of cGL_FLOAT:
            4
          else:
            raiseKtx2Error("unsupported source pixel type 0x" & toHex(sourceType.int))
        channelCount =
          case sourceFormat
          of GL_RED:
            1
          of GL_RG:
            2
          of GL_RGB:
            3
          of GL_RGBA:
            4
          else:
            raiseKtx2Error("unsupported source pixel format 0x" & toHex(sourceFormat.int))
        byteCount = width * height * channelCount * channelBytes
        sourceBytes = readTextureBytes(sourceTarget, level, sourceFormat, sourceType, byteCount)
      glBindTexture(GL_TEXTURE_2D, stagingTexture)
      glTexParameteri(GL_TEXTURE_2D, GlTextureBaseLevel, 0)
      glTexParameteri(GL_TEXTURE_2D, GlTextureMaxLevel, (levelCount - 1).GLint)
      glTexImage2D(
        GL_TEXTURE_2D,
        level.GLint,
        glInternalFormat.GLint,
        width.GLsizei,
        height.GLsizei,
        0,
        sourceFormat,
        sourceType,
        cast[pointer](sourceBytes[0].addr)
      )
      let err = glGetError()
      if err != GL_NO_ERROR:
        raiseKtx2Error(
          "OpenGL failed to compress " & vkFormatName(vkFormat) &
          " at level " & $level & " with error 0x" & toHex(err.int)
        )
      let compressedSize = textureLevelParam(GL_TEXTURE_2D, level, GlTextureCompressedImageSize).int
      result.add(readCompressedTextureBytes(GL_TEXTURE_2D, level, compressedSize))
    glBindTexture(GL_TEXTURE_2D, 0)
  finally:
    if stagingTexture != 0:
      glDeleteTextures(1, stagingTexture.addr)

proc writeKtx2TextureFile*(
  target: GLenum,
  texture: GLuint,
  file: string,
  vkFormat: uint32 = 0'u32,
  sourceFormat: GLenum = 0.GLenum,
  sourceType: GLenum = 0.GLenum,
  levelCount = -1
) =
  if texture == 0:
    raiseKtx2Error("cannot write texture 0")

  glBindTexture(target, texture)
  let
    width = textureLevelParam(target, 0, GlTextureWidth).int
    height = textureLevelParam(target, 0, GlTextureHeight).int
    sourceInternalFormat = textureLevelParam(target, 0, GlTextureInternalFormat).GLenum
    resolvedVkFormat =
      if vkFormat != 0:
        vkFormat
      else:
        vkFormatForGlInternalFormat(sourceInternalFormat)
    resolvedLevelCount =
      if levelCount > 0:
        levelCount
      else:
        1

  if width <= 0 or height <= 0:
    glBindTexture(target, 0)
    raiseKtx2Error("texture has no base level image")

  let levelBytes =
    if sourceInternalFormat == glInternalFormatForVkFormat(resolvedVkFormat):
      directTextureLevels(target, texture, resolvedVkFormat, resolvedLevelCount)
    else:
      if sourceFormat == 0.GLenum or sourceType == 0.GLenum:
        glBindTexture(target, 0)
        raiseKtx2Error(
          "sourceFormat and sourceType are required when writing " &
          vkFormatName(resolvedVkFormat) & " from texture internal format 0x" &
          toHex(sourceInternalFormat.int)
        )
      if isCompressedVkFormat(resolvedVkFormat):
        compressTextureLevels(
          target,
          texture,
          resolvedVkFormat,
          sourceFormat,
          sourceType,
          resolvedLevelCount
        )
      else:
        let byteCount = width * height * bytesPerPixelForVkFormat(resolvedVkFormat)
        @[readTextureBytes(target, 0, sourceFormat, sourceType, byteCount)]

  glBindTexture(target, 0)
  writeFile(file, encodeKtx2(resolvedVkFormat, width, height, levelBytes))

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
    if isCompressedVkFormat(info.vkFormat):
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
    else:
      let formatInfo = pixelFormatAndTypeForVkFormat(info.vkFormat)
      glTexImage2D(
        GL_TEXTURE_2D,
        level.GLint,
        info.glInternalFormat.GLint,
        width.GLsizei,
        height.GLsizei,
        0,
        formatInfo.format,
        formatInfo.pixelType,
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
