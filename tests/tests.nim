import
  std/[json, os, osproc, strutils],
  gltf,
  opengl,
  pixie,
  windy,
  vmath

echo "Testing empty glTF file."
let gltfFile = GltfFile(
  path: "demo.glb",
  root: Node()
)
doAssert gltfFile.path == "demo.glb"
doAssert gltfFile.root != nil

echo "Testing bounding sphere defaults."
let bounds = gltfFile.root.getBoundingSphere()
doAssert bounds.radius == 0

echo "Testing node tree walking."
let nodes = gltfFile.root.walkNodes()
doAssert nodes.len == 1

echo "Testing node matrix transforms."
let expectedMatrix = mat4(
  1.0, 0.0, 0.0, 0.0,
  0.0, 0.0, -1.0, 0.0,
  0.0, 1.0, 0.0, 0.0,
  1.5, 2.5, 3.5, 1.0
)
let model = loadModelJson(
  %*{
    "asset": {"version": "2.0"},
    "buffers": [],
    "bufferViews": [],
    "accessors": [],
    "images": [],
    "textures": [],
    "samplers": [],
    "materials": [],
    "meshes": [],
    "nodes": [
      {
        "name": "MatrixNode",
        "matrix": [
          1.0, 0.0, 0.0, 0.0,
          0.0, 0.0, -1.0, 0.0,
          0.0, 1.0, 0.0, 0.0,
          1.5, 2.5, 3.5, 1.0
        ]
      }
    ],
    "scenes": [{"nodes": [0]}],
    "scene": 0,
    "animations": []
  },
  ".",
  @[]
)
let matrixNode = model["MatrixNode"]
doAssert matrixNode != nil
doAssert matrixNode.pos == vec3(1.5, 2.5, 3.5)
doAssert matrixNode.trs ~= expectedMatrix

echo "Testing KHR_node_visibility."
let visibilityBuffer =
  "\0\0\0\0" &
  "\0\0\x80\x3f" &
  "\x01\x00"
let visibilityModel = loadModelJson(
  %*{
    "asset": {"version": "2.0"},
    "extensionsRequired": ["KHR_node_visibility"],
    "extensionsUsed": ["KHR_node_visibility", "KHR_animation_pointer"],
    "buffers": [
      {
        "byteLength": 10
      }
    ],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 8},
      {"buffer": 0, "byteOffset": 8, "byteLength": 2}
    ],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"},
      {"bufferView": 1, "componentType": 5121, "count": 2, "type": "SCALAR"}
    ],
    "images": [],
    "textures": [],
    "samplers": [],
    "materials": [],
    "meshes": [],
    "nodes": [
      {"name": "RootVisibility", "children": [1, 2]},
      {
        "name": "InvisibleNode",
        "extensions": {"KHR_node_visibility": {"visible": false}}
      },
      {
        "name": "AnimatedNode",
        "extensions": {"KHR_node_visibility": {"visible": true}}
      }
    ],
    "animations": [
      {
        "channels": [
          {
            "sampler": 0,
            "target": {
              "extensions": {
                "KHR_animation_pointer": {
                  "pointer": "/nodes/2/extensions/KHR_node_visibility/visible"
                }
              }
            }
          }
        ],
        "samplers": [
          {"input": 0, "output": 1, "interpolation": "STEP"}
        ]
      }
    ],
    "scenes": [{"nodes": [0]}],
    "scene": 0
  },
  ".",
  @[visibilityBuffer]
)
var invisibleNode, animatedNode: Node
for node in visibilityModel.walkNodes():
  if node.name == "InvisibleNode":
    invisibleNode = node
  elif node.name == "AnimatedNode":
    animatedNode = node
doAssert invisibleNode != nil
doAssert animatedNode != nil
doAssert invisibleNode.visible == false
doAssert animatedNode.visible == true
applyClipAt(visibilityModel.animations[0], 0.75)
doAssert invisibleNode.visible == false
doAssert animatedNode.visible == true
applyClipAt(visibilityModel.animations[0], 1.0)
doAssert invisibleNode.visible == false
doAssert animatedNode.visible == false

echo "Testing glTF cameras."
let cameraModel = loadModelJson(
  %*{
    "asset": {"version": "2.0"},
    "buffers": [],
    "bufferViews": [],
    "accessors": [],
    "images": [],
    "textures": [],
    "samplers": [],
    "materials": [],
    "meshes": [],
    "cameras": [
      {
        "name": "PerspectiveCamera",
        "type": "perspective",
        "perspective": {
          "yfov": 0.78539816339,
          "znear": 0.1,
          "zfar": 50.0
        }
      },
      {
        "name": "OrthoCamera",
        "type": "orthographic",
        "orthographic": {
          "xmag": 2.0,
          "ymag": 1.5,
          "znear": 0.01,
          "zfar": 100.0
        }
      }
    ],
    "nodes": [
      {
        "name": "PerspectiveNode",
        "camera": 0
      },
      {
        "name": "OrthoNode",
        "camera": 1
      }
    ],
    "scenes": [{"nodes": [0, 1]}],
    "scene": 0,
    "animations": []
  },
  ".",
  @[]
)
let perspectiveNode = cameraModel["PerspectiveNode"]
let orthoNode = cameraModel["OrthoNode"]
doAssert perspectiveNode != nil
doAssert orthoNode != nil
doAssert perspectiveNode.camera != nil
doAssert orthoNode.camera != nil
doAssert perspectiveNode.camera.kind == ckPerspective
doAssert orthoNode.camera.kind == ckOrthographic
doAssert abs(perspectiveNode.camera.perspective.yfov - 0.7853982) < 0.0001
doAssert abs(orthoNode.camera.orthographic.xmag - 2.0) < 0.0001

echo "Testing primitive mode parsing."
let primitiveModeBuffer =
  "\0\0\0\0" &
  "\0\0\0\0" &
  "\0\0\0\0" &
  "\0\0\x80\x3f" &
  "\0\0\0\0" &
  "\0\0\0\0"
let primitiveModeModel = loadModelJson(
  %*{
    "asset": {"version": "2.0"},
    "buffers": [
      {
        "byteLength": 24
      }
    ],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 24}
    ],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 2, "type": "VEC3"}
    ],
    "images": [],
    "textures": [],
    "samplers": [],
    "materials": [],
    "meshes": [
      {
        "name": "LineStripMesh",
        "primitives": [
          {
            "attributes": {
              "POSITION": 0
            },
            "mode": 3
          }
        ]
      }
    ],
    "nodes": [
      {
        "name": "LineStripNode",
        "mesh": 0
      }
    ],
    "scenes": [{"nodes": [0]}],
    "scene": 0,
    "animations": []
  },
  ".",
  @[primitiveModeBuffer]
)
let lineStripNode = primitiveModeModel["LineStripNode"]
doAssert lineStripNode != nil
doAssert lineStripNode.mesh != nil
doAssert lineStripNode.mesh.primitives.len == 1
doAssert lineStripNode.mesh.primitives[0].mode.int == 3

let tmpDir = "tmp"
if dirExists(tmpDir):
  removeDir(tmpDir)
createDir(tmpDir)

echo "Testing GLB image write modes."
let
  outDir = joinPath(tmpDir, "out_image_modes")
  externalPath = joinPath(outDir, "external.glb")
  embeddedPath = joinPath(outDir, "embedded.glb")
  externalImagePath = joinPath(outDir, "named_diffuse.png")
if dirExists(outDir):
  removeDir(outDir)
createDir(outDir)

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

writeGLB(rootNode, externalPath, iwmExternal)
doAssert fileExists(externalPath)
doAssert fileExists(externalImagePath)
let externalModel = readGltfFile(externalPath)
doAssert externalModel.root.nodes.len == 1
let externalPrimitive = externalModel.root.nodes[0].mesh.primitives[0]
doAssert externalPrimitive.material.baseColorName == "named_diffuse.png"

writeGLB(rootNode, embeddedPath, iwmEmbedded)
doAssert fileExists(embeddedPath)
let embeddedModel = readGltfFile(embeddedPath)
doAssert embeddedModel.root.nodes.len == 1
let embeddedPrimitive = embeddedModel.root.nodes[0].mesh.primitives[0]
doAssert embeddedPrimitive.material.baseColorName == "named_diffuse.png"

echo "Testing KTX2 BC1-BC5 uploads."

const
  GlTextureWidth = 0x1000.GLenum
  GlTextureHeight = 0x1001.GLenum
  GlTextureInternalFormat = 0x1003.GLenum
  GlTextureCompressedImageSize = 0x86A0.GLenum
  GlTextureCompressed = 0x86A1.GLenum

  GlCompressedRgbS3tcDxt1Ext = 0x83F0.GLenum
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
  "\"" & value.replace("\"", "\"\"") & "\""

proc runChecked(command: string) =
  let (output, exitCode) = execCmdEx(command)
  doAssert exitCode == 0, output

proc findKtxExe(): string =
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
  var data = newString(bytes.len)
  for i, value in bytes:
    data[i] = char(value)
  writeFile(path, data)

proc createKtx2Fixture(
  ktxExe, outDir: string,
  testCase: Ktx2Case
): string =
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
  glBindTexture(GL_TEXTURE_2D, textureId)
  glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, pname, result.addr)

let ktxExe = findKtxExe()
let ktxOutDir = joinPath(tmpDir, "out_ktx2")
if dirExists(ktxOutDir):
  removeDir(ktxOutDir)
createDir(ktxOutDir)

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
doAssert basisMaterial.baseColorId != 0
doAssert basisMaterial.baseColorName == "basisColor"
doAssert basisMaterial.baseColor == nil
glDeleteTextures(1, basisMaterial.baseColorId.addr)
basisMaterial.baseColorId = 0
