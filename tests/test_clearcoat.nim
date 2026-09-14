import std/[base64, json, os], flatty/binny, pixie, vmath, gltf

block clearcoatRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]: positions.writeFloat32(i * 4, value)
  let map = newImage(1, 1)
  map.fill(rgbx(128, 64, 255, 0))
  let document = %*{
    "asset": {"version": "2.0"}, "extensionsRequired": ["KHR_materials_clearcoat"],
    "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [{"uri": "data:image/png;base64," & encode(map.encodeStraightAlphaPng())}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33648, "wrapT": 33071}],
    "textures": [{"source": 0, "sampler": 0}],
    "materials": [{"extensions": {"KHR_materials_clearcoat": {
      "clearcoatFactor": 0.7, "clearcoatRoughnessFactor": 0.9,
      "clearcoatTexture": {"index": 0, "extensions": {"KHR_texture_transform": {
        "texCoord": 1, "offset": [0.25, 0.5], "scale": [2, 3], "rotation": 0.4}}},
      "clearcoatRoughnessTexture": {"index": 0, "texCoord": 1},
      "clearcoatNormalTexture": {"index": 0, "scale": 0.25}}}},
      {"extensions": {"KHR_materials_clearcoat": {}}}, {}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1}, {"attributes": {"POSITION": 0}, "material": 2}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
  let root = loadModelJson(document, ".", @[positions])
  let primitives = root.nodes[0].mesh.primitives
  let m = primitives[0].material
  doAssert m.hasClearcoat and m.clearcoatFactor == 0.7'f and m.clearcoatRoughnessFactor == 0.9'f
  doAssert m.clearcoatNormalScale == 0.25'f
  doAssert m.clearcoat[0, 0] == map[0, 0] and m.clearcoatNormal[0, 0] == map[0, 0]
  doAssert m.clearcoatTransform.texCoord == 1 and m.clearcoatTransform.scale == vec2(2, 3)
  doAssert m.clearcoatTransform.offset == vec2(0.25, 0.5) and m.clearcoatTransform.rotation == 0.4'f
  for i in [1, 2]:
    doAssert primitives[i].material.hasClearcoat == (i == 1)
    doAssert primitives[i].material.clearcoatFactor == 0 and primitives[i].material.clearcoatRoughnessFactor == 0
    doAssert primitives[i].material.clearcoatNormalScale == 1
  for mode in [iwmEmbedded, iwmExternal]:
    let output = "tests/tmp/clearcoat-" & $mode & ".glb"
    createDir(output.parentDir)
    writeGLB(root, output, mode)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives[0].material
    doAssert reread.hasClearcoat and reread.clearcoatFactor == m.clearcoatFactor
    doAssert reread.clearcoatRoughnessFactor == m.clearcoatRoughnessFactor
    doAssert reread.clearcoatNormalScale == m.clearcoatNormalScale
    doAssert reread.clearcoatTransform == m.clearcoatTransform
    doAssert reread.clearcoatRoughnessTransform == m.clearcoatRoughnessTransform
    doAssert reread.clearcoatNormalTransform == m.clearcoatNormalTransform
    doAssert reread.clearcoatSampler == m.clearcoatSampler and reread.clearcoatNormalSampler == m.clearcoatNormalSampler
    doAssert reread.clearcoat[0, 0] == map[0, 0] and reread.clearcoatRoughness[0, 0] == map[0, 0]
    doAssert reread.clearcoatNormal[0, 0] == map[0, 0]
  echo "Clearcoat: defaults, required extension, all maps, normal scale, UV transforms and GLB export passed"
