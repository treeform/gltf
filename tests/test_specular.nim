import std/[base64, json, os], flatty/binny, pixie, vmath, gltf

block specularRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]: positions.writeFloat32(i * 4, value)
  let map = newImage(1, 1)
  map.fill(rgbx(128, 64, 255, 0))
  let document = %*{
    "asset": {"version": "2.0"}, "extensionsRequired": ["KHR_materials_specular"],
    "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [{"uri": "data:image/png;base64," & encode(map.encodeStraightAlphaPng())}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33648, "wrapT": 33071}],
    "textures": [{"source": 0, "sampler": 0}],
    "materials": [{"extensions": {"KHR_materials_specular": {
      "specularFactor": 0.7, "specularColorFactor": [0.2, 0.4, 0.9],
      "specularTexture": {"index": 0, "extensions": {"KHR_texture_transform": {
        "texCoord": 1, "offset": [0.25, 0.5], "scale": [2, 3], "rotation": 0.4}}},
      "specularColorTexture": {"index": 0, "texCoord": 1}}}},
      {"extensions": {"KHR_materials_specular": {}}}, {}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1}, {"attributes": {"POSITION": 0}, "material": 2}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
  let root = loadModelJson(document, ".", @[positions])
  let primitives = root.nodes[0].mesh.primitives
  let m = primitives[0].material
  doAssert m.hasSpecular and m.specularFactor == 0.7'f and m.specularColorFactor == vec3(0.2, 0.4, 0.9)
  doAssert m.specular[0, 0] == map[0, 0] and m.specularColor[0, 0] == map[0, 0]
  doAssert m.specularTransform.texCoord == 1 and m.specularTransform.scale == vec2(2, 3)
  doAssert m.specularTransform.offset == vec2(0.25, 0.5) and m.specularTransform.rotation == 0.4'f
  for i in [1, 2]:
    doAssert primitives[i].material.hasSpecular == (i == 1)
    doAssert primitives[i].material.specularFactor == 1 and primitives[i].material.specularColorFactor == vec3(1)
  for mode in [iwmEmbedded, iwmExternal]:
    let output = "tests/tmp/specular-" & $mode & ".glb"
    createDir(output.parentDir)
    writeGLB(root, output, mode)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives[0].material
    doAssert reread.hasSpecular and reread.specularFactor == m.specularFactor
    doAssert reread.specularColorFactor == m.specularColorFactor
    doAssert reread.specularTransform == m.specularTransform
    doAssert reread.specularColorTransform == m.specularColorTransform
    doAssert reread.specularSampler == m.specularSampler and reread.specularColorSampler == m.specularColorSampler
    doAssert reread.specular[0, 0] == map[0, 0] and reread.specularColor[0, 0] == map[0, 0]
  echo "Specular: defaults, required extension, strength/color maps, UV transforms and GLB export passed"
