import std/[base64, json, os], flatty/binny, pixie, vmath, gltf

block sheenRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]: positions.writeFloat32(i * 4, value)
  let map = newImage(1, 1)
  map.fill(rgbx(128, 64, 255, 0))
  let document = %*{
    "asset": {"version": "2.0"}, "extensionsRequired": ["KHR_materials_sheen"],
    "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [{"uri": "data:image/png;base64," & encode(map.encodeStraightAlphaPng())}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33648, "wrapT": 33071}],
    "textures": [{"source": 0, "sampler": 0}],
    "materials": [{"extensions": {"KHR_materials_sheen": {
      "sheenRoughnessFactor": 0.7, "sheenColorFactor": [0.2, 0.4, 0.9],
      "sheenRoughnessTexture": {"index": 0, "extensions": {"KHR_texture_transform": {
        "texCoord": 1, "offset": [0.25, 0.5], "scale": [2, 3], "rotation": 0.4}}},
      "sheenColorTexture": {"index": 0, "texCoord": 1}}}},
      {"extensions": {"KHR_materials_sheen": {}}}, {}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1}, {"attributes": {"POSITION": 0}, "material": 2}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
  let root = loadModelJson(document, ".", @[positions])
  let primitives = root.nodes[0].mesh.primitives
  let m = primitives[0].material
  doAssert m.hasSheen and m.sheenRoughnessFactor == 0.7'f and m.sheenColorFactor == vec3(0.2, 0.4, 0.9)
  doAssert m.sheenRoughness[0, 0] == map[0, 0] and m.sheenColor[0, 0] == map[0, 0]
  doAssert m.sheenRoughnessTransform.texCoord == 1 and m.sheenRoughnessTransform.scale == vec2(2, 3)
  doAssert m.sheenRoughnessTransform.offset == vec2(0.25, 0.5) and m.sheenRoughnessTransform.rotation == 0.4'f
  for i in [1, 2]:
    doAssert primitives[i].material.hasSheen == (i == 1)
    doAssert primitives[i].material.sheenRoughnessFactor == 0 and primitives[i].material.sheenColorFactor == vec3(0)
  for mode in [iwmEmbedded, iwmExternal]:
    let output = "tests/tmp/sheen-" & $mode & ".glb"
    createDir(output.parentDir)
    writeGLB(root, output, mode)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives[0].material
    doAssert reread.hasSheen and reread.sheenRoughnessFactor == m.sheenRoughnessFactor
    doAssert reread.sheenColorFactor == m.sheenColorFactor
    doAssert reread.sheenRoughnessTransform == m.sheenRoughnessTransform
    doAssert reread.sheenColorTransform == m.sheenColorTransform
    doAssert reread.sheenRoughnessSampler == m.sheenRoughnessSampler and reread.sheenColorSampler == m.sheenColorSampler
    doAssert reread.sheenRoughness[0, 0] == map[0, 0] and reread.sheenColor[0, 0] == map[0, 0]
  echo "Sheen: defaults, required extension, color/roughness maps, UV transforms and GLB export passed"
