import std/[base64, json, os], pixie, gltf

let textureFixtureDir = currentSourcePath().parentDir() / "data" / "straight_alpha"
let textureAlphaDir = currentSourcePath().parentDir() / "tmp" / "straight_alpha"
createDir(textureAlphaDir)
let expectedTexturePixels = @[
  rgbx(64, 128, 192, 0), rgbx(64, 128, 192, 1),
  rgbx(64, 128, 192, 64), rgbx(64, 128, 192, 128), rgbx(64, 128, 192, 255)
]
let texturePng = readFile(textureFixtureDir / "rgba.png")
doAssert decodeStraightAlphaImage(texturePng).data == expectedTexturePixels
doAssert decodeImage(texturePng).data[0] == rgbx(0, 0, 0, 0)
doAssert loadStraightAlphaImage(textureFixtureDir / "palette.png").data ==
  @[rgbx(0, 255, 0, 0), rgbx(64, 128, 192, 128)]
doAssert loadStraightAlphaImage(textureFixtureDir / "gray_alpha.png").data ==
  @[rgbx(128, 128, 128, 0), rgbx(192, 192, 192, 64)]
doAssert loadStraightAlphaImage(textureFixtureDir / "rgba16.png").data ==
  @[rgbx(18, 171, 86, 0), rgbx(255, 128, 64, 128)]
for file in ["lossless.webp", "lossy.webp", "rgb.jpg"]:
  let actual = loadStraightAlphaImage(textureFixtureDir / file)
  let expected = readFile(textureFixtureDir / (file & ".rgba"))
  doAssert actual.data.len * 4 == expected.len
  for i, pixel in actual.data:
    let channels = [pixel.r, pixel.g, pixel.b, pixel.a]
    for c in 0 .. 3:
      let tolerance = if c == 3 or file == "lossless.webp": 0 else: 2
      doAssert abs(channels[c].int - expected[i * 4 + c].ord) <= tolerance,
        file & " pixel=" & $i & " channel=" & $c
doAssert loadStraightAlphaImage(textureFixtureDir / "lossless.webp").data == expectedTexturePixels
for invalid in ["", "RIFF", "not an image"]:
  var rejected = false
  try: discard decodeStraightAlphaImage(invalid)
  except PixieError: rejected = true
  doAssert rejected

proc textureFixture(image: JsonNode): JsonNode =
  %*{
    "asset": {"version": "2.0"},
    "buffers": [{"byteLength": 36}, {"byteLength": texturePng.len}],
    "bufferViews": [{"buffer": 0, "byteLength": 36},
      {"buffer": 1, "byteLength": texturePng.len}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [image], "textures": [{"source": 0}],
    "materials": [{
      "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
        "metallicRoughnessTexture": {"index": 0}},
      "normalTexture": {"index": 0}, "occlusionTexture": {"index": 0},
      "emissiveTexture": {"index": 0}
    }],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0
  }

proc checkTextureSlots(root: Node) =
  let m = root.nodes[0].mesh.primitives[0].material
  for (name, image) in [("baseColor", m.baseColor), ("metallicRoughness", m.metallicRoughness),
      ("normal", m.normal), ("occlusion", m.occlusion), ("emissive", m.emissive)]:
    doAssert image.data == expectedTexturePixels, name & ": " & $image.data

writeFile(textureAlphaDir / "texture.png", texturePng)
for index, source in [
  %*{"uri": "texture.png"},
  %*{"uri": "data:image/png;base64," & base64.encode(texturePng)},
  %*{"bufferView": 1, "mimeType": "image/png"}
]:
  let root = loadModelJson(textureFixture(source), textureAlphaDir, @[newString(36), texturePng])
  echo "Texture input route ", index
  checkTextureSlots(root)
  for mode in [iwmEmbedded, iwmExternal]:
    let outPath = textureAlphaDir / ($index & "-" & $mode & ".glb")
    writeGLB(root, outPath, mode)
    echo "Texture round trip ", index, " ", mode
    checkTextureSlots(loadModel(outPath))

echo "Straight-alpha textures: PNG/JPEG/WebP, all image routes and slots, and GLB/PNG export passed"
