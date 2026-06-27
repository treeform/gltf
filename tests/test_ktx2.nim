import
  std/[json, os, osproc, strutils],
  gltf,
  opengl,
  pixie,
  pixie/fileformats/png,
  windy,
  vmath

const
  GlTextureWidth = 0x1000.GLenum
  GlTextureHeight = 0x1001.GLenum
  GlTextureInternalFormat = 0x1003.GLenum
  GlTextureCompressedImageSize = 0x86A0.GLenum
  GlTextureCompressed = 0x86A1.GLenum

  GlCompressedRgbS3tcDxt1Ext = 0x83F0.GLenum
  GlCompressedSrgbS3tcDxt1Ext = 0x8C4C.GLenum
  GlCompressedRgbaS3tcDxt3Ext = 0x83F2.GLenum
  GlCompressedRgbaS3tcDxt5Ext = 0x83F3.GLenum
  GlCompressedRedRgtc1 = 0x8DBB.GLenum
  GlCompressedRgRgtc2 = 0x8DBD.GLenum

type
  Ktx2Case = object
    name: string
    format: string
    expectedFormatName: string
    expectedInternalFormat: GLenum
    expectedBlockBytes: GLint
    rawBytes: seq[byte]

proc quoteArg(value: string): string =
  ## Quotes one shell argument for the test helper.
  "\"" & value.replace("\"", "\"\"") & "\""

proc runChecked(command: string) =
  ## Runs a shell command and asserts success.
  let (output, exitCode) = execCmdEx(command)
  doAssert exitCode == 0, output

proc findKtxExe(): string =
  ## Returns a KTX tool executable path.
  result = findExe("ktx")
  if result.len == 0:
    let fallback = joinPath(
      getEnv("LOCALAPPDATA"),
      "Programs",
      "KTX-Software",
      "bin",
      "ktx.exe"
    )
    if fileExists(fallback):
      return fallback
  doAssert result.len > 0, "ktx.exe was not found on PATH"

proc writeBytes(path: string, bytes: openArray[byte]) =
  ## Writes raw bytes to a file.
  var data = newString(bytes.len)
  for i, value in bytes:
    data[i] = char(value)
  writeFile(path, data)

proc writeUint32Le(data: var string, offset: int, value: uint32) =
  ## Writes a little-endian uint32 into a test byte string.
  data[offset] = char(value and 0xFF'u32)
  data[offset + 1] = char((value shr 8) and 0xFF'u32)
  data[offset + 2] = char((value shr 16) and 0xFF'u32)
  data[offset + 3] = char((value shr 24) and 0xFF'u32)

proc writeUint64Le(data: var string, offset: int, value: uint64) =
  ## Writes a little-endian uint64 into a test byte string.
  for i in 0 .. 7:
    data[offset + i] = char((value shr (i * 8)) and 0xFF'u64)

proc expectKtx2Error(data, message: string) =
  ## Asserts that KTX2 parsing raises the expected error.
  try:
    discard parseKtx2(data)
    doAssert false, "KTX2 parser should have rejected the data"
  except GltfError as error:
    doAssert error.msg.contains(message), error.msg

proc createKtx2Fixture(
  ktxExe, outDir: string,
  testCase: Ktx2Case
): string =
  ## Creates one KTX2 fixture with KTX-Software.
  let rawPath = joinPath(outDir, testCase.name & ".bin")
  result = joinPath(outDir, testCase.name & ".ktx2")
  writeBytes(rawPath, testCase.rawBytes)
  runChecked(
    quoteArg(ktxExe) &
    " create --testrun --format " & testCase.format &
    " --raw --width 4 --height 4 " &
    quoteArg(rawPath) & " " & quoteArg(result)
  )

proc textureLevelParam(textureId: GLuint, pname: GLenum): GLint =
  ## Reads one OpenGL texture level parameter.
  glBindTexture(GL_TEXTURE_2D, textureId)
  glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, pname, result.addr)

proc readTextureFloats(textureId: GLuint, width, height: int): seq[float32] =
  ## Reads one R32 texture level back as floats.
  result.setLen(width * height)
  glBindTexture(GL_TEXTURE_2D, textureId)
  glGetTexImage(
    GL_TEXTURE_2D,
    0,
    GL_RED,
    cGL_FLOAT,
    result[0].addr
  )

proc readTextureRgbx(textureId: GLuint, width, height: int): seq[ColorRGBX] =
  ## Reads one RGBA texture level back as pixels.
  var bytes = newSeq[uint8](width * height * 4)
  glBindTexture(GL_TEXTURE_2D, textureId)
  glGetTexImage(
    GL_TEXTURE_2D,
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    bytes[0].addr
  )
  result.setLen(width * height)
  for i in 0 ..< result.len:
    let offset = i * 4
    result[i] = rgbx(
      bytes[offset],
      bytes[offset + 1],
      bytes[offset + 2],
      bytes[offset + 3]
    )

proc assertImageSimilar(
  expected: Image,
  actual: seq[ColorRGBX],
  maxChannelDiff: int,
  maxAverageDiff: float32
) =
  ## Asserts that a texture readback is close to an image.
  doAssert actual.len == expected.width * expected.height
  var
    totalDiff = 0
    maxDiff = 0
  for i, expectedPixel in expected.data:
    let actualPixel = actual[i]
    let diffs = [
      abs(expectedPixel.r.int - actualPixel.r.int),
      abs(expectedPixel.g.int - actualPixel.g.int),
      abs(expectedPixel.b.int - actualPixel.b.int),
      abs(expectedPixel.a.int - actualPixel.a.int)
    ]
    for diff in diffs:
      totalDiff += diff
      maxDiff = max(maxDiff, diff)

  let averageDiff =
    totalDiff.float32 / (actual.len.float32 * 4.0'f32)
  doAssert maxDiff <= maxChannelDiff, "max channel diff was " & $maxDiff
  doAssert averageDiff <= maxAverageDiff, "average diff was " & $averageDiff

proc assertRedFloatsSimilar(
  expected: Image,
  actual: seq[float32],
  maxDiff: float32
) =
  ## Asserts that R32 texture readback matches the image red channel.
  doAssert actual.len == expected.width * expected.height
  for i, expectedPixel in expected.data:
    let expectedValue = expectedPixel.r.float32 / 255.0'f32
    doAssert abs(actual[i] - expectedValue) <= maxDiff

let
  tmpRoot = "tmp"
  tmpDir = joinPath(tmpRoot, "test_ktx2")
if not dirExists(tmpRoot):
  createDir(tmpRoot)
if dirExists(tmpDir):
  removeDir(tmpDir)
createDir(tmpDir)

let ktxExe = findKtxExe()

echo "Testing glTF external KTX2 write mode."
let
  imageModeDir = joinPath(tmpDir, "image_modes")
  externalKtx2Path = joinPath(imageModeDir, "external_ktx2.glb")
  externalKtx2ImagePath = joinPath(imageModeDir, "named_diffuse.ktx2")
createDir(imageModeDir)

var image = newImage(1, 1)
image[0, 0] = rgbx(255, 0, 0, 255)

let material = Material(
  name: "TestMaterial",
  baseColor: image,
  baseColorName: "named_diffuse.png"
)
let primitive = Primitive(
  points: @[vec3(0, 0, 0)],
  material: material
)
let mesh = Mesh(
  name: "TestMesh",
  primitives: @[primitive]
)
let rootNode = Node(
  name: "Root",
  visible: true,
  pos: vec3(0, 0, 0),
  rot: quat(0, 0, 0, 1),
  scale: vec3(1, 1, 1),
  mesh: mesh
)

writeGLB(rootNode, externalKtx2Path, iwmExternalKtx2)
doAssert fileExists(externalKtx2Path)
doAssert fileExists(externalKtx2ImagePath)
let externalKtx2Info = readKtx2File(externalKtx2ImagePath)
doAssert externalKtx2Info.vkFormat == VkFormatBc3SrgbBlock
doAssert externalKtx2Info.width == 1
doAssert externalKtx2Info.height == 1
runChecked(quoteArg(ktxExe) & " validate " & quoteArg(externalKtx2ImagePath))
let externalKtx2Model = readGltfFile(externalKtx2Path)
doAssert externalKtx2Model.root.nodes.len == 1
let externalKtx2Primitive =
  externalKtx2Model.root.nodes[0].mesh.primitives[0]
doAssert externalKtx2Primitive.material.baseColorName == "named_diffuse.ktx2"
doAssert externalKtx2Primitive.material.baseColorKtx2.len > 0

let ktxOutDir = joinPath(tmpDir, "out_ktx2")
createDir(ktxOutDir)

echo "Testing KTX2 parser validation."
let validBc1Data = encodeKtx2(
  VkFormatBc1RgbUnormBlock,
  4,
  4,
  @["\0\0\0\0\0\0\0\0"]
)
let validBc1Info = parseKtx2(validBc1Data)
doAssert validBc1Info.width == 4
doAssert validBc1Info.height == 4
doAssert validBc1Info.levels[0].byteLength == 8

var badLevelLengthData = validBc1Data
writeUint64Le(badLevelLengthData, 88, 7'u64)
expectKtx2Error(badLevelLengthData, "does not match expected")

var badTypeSizeData = validBc1Data
writeUint32Le(badTypeSizeData, 16, 4'u32)
expectKtx2Error(badTypeSizeData, "typeSize")

var basisLikeData = validBc1Data
writeUint32Le(basisLikeData, 12, 0'u32)
writeUint32Le(basisLikeData, 44, 1'u32)
expectKtx2Error(basisLikeData, "supercompressed")

echo "Testing native KTX2 image writer."
var nativeImage = newImage(4, 4)
for y in 0 ..< nativeImage.height:
  for x in 0 ..< nativeImage.width:
    nativeImage[x, y] = rgbx(
      (x * 64).uint8,
      (y * 64).uint8,
      ((x + y) * 32).uint8,
      (255 - x * 20).uint8
    )

let
  nativeValidateDir = joinPath(ktxOutDir, "native_validate")
  nativeBc1RgbaPath = joinPath(nativeValidateDir, "bc1_rgba.ktx2")
  nativeBc2Path = joinPath(nativeValidateDir, "bc2.ktx2")
  nativeBc3Path = joinPath(nativeValidateDir, "bc3.ktx2")
  nativeBc4Path = joinPath(nativeValidateDir, "bc4.ktx2")
  nativeBc5Path = joinPath(nativeValidateDir, "bc5.ktx2")
  nativeR32Path = joinPath(nativeValidateDir, "r32.ktx2")
createDir(nativeValidateDir)
writeKtx2ImageFile(
  nativeBc1RgbaPath,
  nativeImage,
  VkFormatBc1RgbaSrgbBlock,
  false
)
writeKtx2ImageFile(nativeBc2Path, nativeImage, VkFormatBc2SrgbBlock, false)
writeKtx2ImageFile(nativeBc3Path, nativeImage, VkFormatBc3SrgbBlock, false)
writeKtx2ImageFile(nativeBc4Path, nativeImage, VkFormatBc4UnormBlock, false)
writeKtx2ImageFile(nativeBc5Path, nativeImage, VkFormatBc5UnormBlock, false)
writeKtx2R32SfloatFile(
  nativeR32Path,
  2,
  2,
  [0.0'f32, 0.25'f32, 0.5'f32, 1.0'f32]
)
for path in [
  nativeBc1RgbaPath,
  nativeBc2Path,
  nativeBc3Path,
  nativeBc4Path,
  nativeBc5Path,
  nativeR32Path
]:
  runChecked(quoteArg(ktxExe) & " validate " & quoteArg(path))

let nativeBc1Data = encodeKtx2Image(
  nativeImage,
  VkFormatBc1RgbUnormBlock,
  false
)
let nativeBc1Info = parseKtx2(nativeBc1Data)
doAssert nativeBc1Info.vkFormat == VkFormatBc1RgbUnormBlock
doAssert nativeBc1Info.levelCount == 1
doAssert nativeBc1Info.levels[0].byteLength == 8

let nativeBc3Data = encodeKtx2Image(
  nativeImage,
  VkFormatBc3SrgbBlock,
  false
)
let nativeBc3Info = parseKtx2(nativeBc3Data)
doAssert nativeBc3Info.vkFormat == VkFormatBc3SrgbBlock
doAssert nativeBc3Info.levels[0].byteLength == 16

let nativeBc5Data = encodeKtx2Image(
  nativeImage,
  VkFormatBc5UnormBlock,
  false
)
let nativeBc5Info = parseKtx2(nativeBc5Data)
doAssert nativeBc5Info.vkFormat == VkFormatBc5UnormBlock
doAssert nativeBc5Info.levels[0].byteLength == 16

let nativeR32Data = encodeKtx2R32Sfloat(
  2,
  2,
  [0.0'f32, 0.25'f32, 0.5'f32, 1.0'f32]
)
let nativeR32Info = parseKtx2(nativeR32Data)
doAssert nativeR32Info.vkFormat == VkFormatR32Sfloat
doAssert nativeR32Info.levels[0].byteLength == 16

let
  pngRoundTripDir = joinPath(ktxOutDir, "png_roundtrip")
  pngRoundTripPath = joinPath(pngRoundTripDir, "source.png")
  pngBc3Path = joinPath(pngRoundTripDir, "source_bc3.ktx2")
  pngR32Path = joinPath(pngRoundTripDir, "source_r32.ktx2")
createDir(pngRoundTripDir)
var pngSourceImage = newImage(8, 8)
for y in 0 ..< pngSourceImage.height:
  for x in 0 ..< pngSourceImage.width:
    let blockIndex = (x div 4) + (y div 4) * 2
    pngSourceImage[x, y] =
      case blockIndex
      of 0:
        rgbx(32, 64, 128, 255)
      of 1:
        rgbx(96, 160, 48, 255)
      of 2:
        rgbx(192, 80, 120, 255)
      else:
        rgbx(224, 200, 32, 255)
writeFile(pngRoundTripPath, pngSourceImage.encodePng())
let pngReadImage = readImage(pngRoundTripPath)
writeKtx2ImageFile(pngBc3Path, pngReadImage, VkFormatBc3UnormBlock, false)
writeKtx2ImageFile(pngR32Path, pngReadImage, VkFormatR32Sfloat, false)
runChecked(quoteArg(ktxExe) & " validate " & quoteArg(pngBc3Path))
runChecked(quoteArg(ktxExe) & " validate " & quoteArg(pngR32Path))

let ktxCases = [
  Ktx2Case(
    name: "bc1",
    format: "BC1_RGB_UNORM_BLOCK",
    expectedFormatName: "VK_FORMAT_BC1_RGB_UNORM_BLOCK",
    expectedInternalFormat: GlCompressedRgbS3tcDxt1Ext,
    expectedBlockBytes: 8,
    rawBytes: @[0x00'u8, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70]
  ),
  Ktx2Case(
    name: "bc2",
    format: "BC2_UNORM_BLOCK",
    expectedFormatName: "VK_FORMAT_BC2_UNORM_BLOCK",
    expectedInternalFormat: GlCompressedRgbaS3tcDxt3Ext,
    expectedBlockBytes: 16,
    rawBytes: @[
      0x00'u8, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
      0x08'u8, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
    ]
  ),
  Ktx2Case(
    name: "bc3",
    format: "BC3_UNORM_BLOCK",
    expectedFormatName: "VK_FORMAT_BC3_UNORM_BLOCK",
    expectedInternalFormat: GlCompressedRgbaS3tcDxt5Ext,
    expectedBlockBytes: 16,
    rawBytes: @[
      0x10'u8, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
      0x18'u8, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
    ]
  ),
  Ktx2Case(
    name: "bc4",
    format: "BC4_UNORM_BLOCK",
    expectedFormatName: "VK_FORMAT_BC4_UNORM_BLOCK",
    expectedInternalFormat: GlCompressedRedRgtc1,
    expectedBlockBytes: 8,
    rawBytes: @[0x21'u8, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28]
  ),
  Ktx2Case(
    name: "bc5",
    format: "BC5_UNORM_BLOCK",
    expectedFormatName: "VK_FORMAT_BC5_UNORM_BLOCK",
    expectedInternalFormat: GlCompressedRgRgtc2,
    expectedBlockBytes: 16,
    rawBytes: @[
      0x31'u8, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
      0x39'u8, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40
    ]
  )
]

var ktxWindow = newWindow("gltf ktx2 tests", ivec2(32, 32))
makeContextCurrent(ktxWindow)
loadExtensions()

echo "Testing PNG to native KTX2 roundtrips."
block:
  let pngTextureId = loadKtx2TextureFile(pngBc3Path)
  doAssert pngTextureId != 0
  let roundTripPixels = readTextureRgbx(
    pngTextureId,
    pngReadImage.width,
    pngReadImage.height
  )
  assertImageSimilar(pngReadImage, roundTripPixels, 8, 4.0'f32)
  glDeleteTextures(1, pngTextureId.addr)

block:
  let pngR32TextureId = loadKtx2TextureFile(pngR32Path)
  doAssert pngR32TextureId != 0
  let roundTripFloats = readTextureFloats(
    pngR32TextureId,
    pngReadImage.width,
    pngReadImage.height
  )
  assertRedFloatsSimilar(pngReadImage, roundTripFloats, 0.00001'f32)
  glDeleteTextures(1, pngR32TextureId.addr)

echo "Testing KTX2 writer roundtrips."
let writerOutDir = joinPath(tmpDir, "out_ktx2_writer")
createDir(writerOutDir)

block:
  var colorTextureId: GLuint
  glGenTextures(1, colorTextureId.addr)
  glBindTexture(GL_TEXTURE_2D, colorTextureId)
  let colorPixels = @[
    255'u8, 0, 0, 255,
    0'u8, 255, 0, 255,
    0'u8, 0, 255, 255,
    255'u8, 255, 0, 255,
    255'u8, 128, 0, 255,
    0'u8, 255, 255, 255,
    255'u8, 0, 255, 255,
    255'u8, 255, 255, 255,
    0'u8, 0, 0, 255,
    64'u8, 64, 64, 255,
    128'u8, 128, 128, 255,
    192'u8, 192, 192, 255,
    32'u8, 64, 96, 255,
    160'u8, 32, 224, 255,
    12'u8, 200, 88, 255,
    90'u8, 30, 210, 255
  ]
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_RGBA8.GLint,
    4,
    4,
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    colorPixels[0].unsafeAddr
  )
  let bc1WriterPath = joinPath(writerOutDir, "writer_bc1.ktx2")
  writeKtx2TextureFile(
    GL_TEXTURE_2D,
    colorTextureId,
    bc1WriterPath,
    VkFormatBc1RgbSrgbBlock,
    GL_RGBA,
    GL_UNSIGNED_BYTE
  )
  let bc1Info = readKtx2File(bc1WriterPath)
  doAssert bc1Info.vkFormat == VkFormatBc1RgbSrgbBlock
  doAssert bc1Info.width == 4
  doAssert bc1Info.height == 4
  doAssert bc1Info.levelCount == 1
  doAssert bc1Info.glInternalFormat == GlCompressedSrgbS3tcDxt1Ext

  let bc1TextureId = loadKtx2TextureFile(bc1WriterPath)
  doAssert bc1TextureId != 0
  doAssert textureLevelParam(bc1TextureId, GlTextureWidth) == 4
  doAssert textureLevelParam(bc1TextureId, GlTextureHeight) == 4
  doAssert textureLevelParam(bc1TextureId, GlTextureCompressed) == 1
  doAssert textureLevelParam(bc1TextureId, GlTextureInternalFormat) ==
    GlCompressedSrgbS3tcDxt1Ext.GLint
  doAssert textureLevelParam(bc1TextureId, GlTextureCompressedImageSize) > 0
  glDeleteTextures(1, bc1TextureId.addr)
  glDeleteTextures(1, colorTextureId.addr)

block:
  var floatTextureId: GLuint
  glGenTextures(1, floatTextureId.addr)
  glBindTexture(GL_TEXTURE_2D, floatTextureId)
  let floatPixels = @[0.0'f32, 1.5'f32, -2.25'f32, 42.0'f32]
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_R32F.GLint,
    2,
    2,
    0,
    GL_RED,
    cGL_FLOAT,
    floatPixels[0].unsafeAddr
  )
  let r32WriterPath = joinPath(writerOutDir, "writer_r32.ktx2")
  writeKtx2TextureFile(GL_TEXTURE_2D, floatTextureId, r32WriterPath)
  let r32Info = readKtx2File(r32WriterPath)
  doAssert r32Info.vkFormat == VkFormatR32Sfloat
  doAssert r32Info.width == 2
  doAssert r32Info.height == 2
  doAssert r32Info.levelCount == 1
  doAssert r32Info.glInternalFormat == GL_R32F

  let r32TextureId = loadKtx2TextureFile(r32WriterPath)
  doAssert r32TextureId != 0
  doAssert textureLevelParam(r32TextureId, GlTextureWidth) == 2
  doAssert textureLevelParam(r32TextureId, GlTextureHeight) == 2
  doAssert textureLevelParam(r32TextureId, GlTextureCompressed) == 0
  doAssert textureLevelParam(r32TextureId, GlTextureInternalFormat) ==
    GL_R32F.GLint
  let roundTripFloats = readTextureFloats(r32TextureId, 2, 2)
  doAssert roundTripFloats.len == floatPixels.len
  for i, expected in floatPixels:
    doAssert abs(roundTripFloats[i] - expected) < 0.00001'f32
  glDeleteTextures(1, r32TextureId.addr)
  glDeleteTextures(1, floatTextureId.addr)

for testCase in ktxCases:
  let texturePath = createKtx2Fixture(ktxExe, ktxOutDir, testCase)
  let info = readKtx2File(texturePath)
  doAssert vkFormatName(info.vkFormat) == testCase.expectedFormatName
  doAssert info.width == 4
  doAssert info.height == 4
  doAssert info.levelCount == 1
  doAssert info.glInternalFormat == testCase.expectedInternalFormat

  let textureId = loadKtx2TextureFile(texturePath)
  doAssert textureId != 0
  doAssert textureLevelParam(textureId, GlTextureWidth) == 4
  doAssert textureLevelParam(textureId, GlTextureHeight) == 4
  doAssert textureLevelParam(textureId, GlTextureCompressed) == 1
  doAssert textureLevelParam(textureId, GlTextureInternalFormat) ==
    testCase.expectedInternalFormat.GLint
  doAssert textureLevelParam(textureId, GlTextureCompressedImageSize) ==
    testCase.expectedBlockBytes
  glDeleteTextures(1, textureId.addr)

echo "Testing KHR_texture_basisu support."
discard createKtx2Fixture(ktxExe, ktxOutDir, ktxCases[0])
let basisGltfPath = joinPath(ktxOutDir, "basisu_test.gltf")
let basisBufferPath = joinPath(ktxOutDir, "basisu_test.bin")
writeBytes(
  basisBufferPath,
  @[
    0x00'u8, 0x00, 0x00, 0x00,
    0x00'u8, 0x00, 0x00, 0x00,
    0x00'u8, 0x00, 0x00, 0x00
  ]
)
writeFile(
  basisGltfPath,
  $(%*{
    "asset": {"version": "2.0"},
    "extensionsRequired": ["KHR_texture_basisu"],
    "extensionsUsed": ["KHR_texture_basisu"],
    "buffers": [
      {
        "byteLength": 12,
        "uri": "basisu_test.bin"
      }
    ],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 12}
    ],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 1, "type": "VEC3"}
    ],
    "images": [
      {
        "uri": "bc1.ktx2",
        "name": "basisColor"
      }
    ],
    "textures": [
      {
        "extensions": {
          "KHR_texture_basisu": {
            "source": 0
          }
        }
      }
    ],
    "samplers": [],
    "materials": [
      {
        "pbrMetallicRoughness": {
          "baseColorTexture": {
            "index": 0
          }
        }
      }
    ],
    "meshes": [
      {
        "primitives": [
          {
            "attributes": {
              "POSITION": 0
            },
            "material": 0
          }
        ]
      }
    ],
    "nodes": [
      {
        "name": "BasisNode",
        "mesh": 0
      }
    ],
    "scenes": [{"nodes": [0]}],
    "scene": 0,
    "animations": []
  })
)
let basisFile = readGltfFile(basisGltfPath)
let basisNode = basisFile.root["BasisNode"]
doAssert basisNode != nil
doAssert basisNode.mesh != nil
doAssert basisNode.mesh.primitives.len == 1
let basisMaterial = basisNode.mesh.primitives[0].material
doAssert basisMaterial != nil
doAssert basisMaterial.baseColorName == "basisColor"
doAssert basisMaterial.baseColor == nil
doAssert basisMaterial.baseColorKtx2.len > 0
