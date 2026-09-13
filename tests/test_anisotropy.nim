import std/[base64, json, os], flatty/binny, pixie, vmath, gltf

block anisotropyRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]: positions.writeFloat32(i * 4, value)
  let map = newImage(1, 1)
  map.fill(rgbx(255, 128, 64, 0))
  let document = %*{
    "asset": {"version": "2.0"}, "extensionsRequired": ["KHR_materials_anisotropy"],
    "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [{"uri": "data:image/png;base64," & encode(map.encodeStraightAlphaPng())}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33648, "wrapT": 33071}],
    "textures": [{"source": 0, "sampler": 0}],
    "materials": [{"extensions": {"KHR_materials_anisotropy": {
      "anisotropyStrength": 0.7, "anisotropyRotation": 0.9,
      "anisotropyTexture": {"index": 0, "extensions": {"KHR_texture_transform": {
        "texCoord": 1, "offset": [0.25, 0.5], "scale": [2, 3], "rotation": 0.4}}}}}},
      {"extensions": {"KHR_materials_anisotropy": {}}}, {}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1}, {"attributes": {"POSITION": 0}, "material": 2}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
  let root = loadModelJson(document, ".", @[positions])
  let primitives = root.nodes[0].mesh.primitives
  let m = primitives[0].material
  doAssert m.hasAnisotropy and m.anisotropyStrength == 0.7'f and m.anisotropyRotation == 0.9'f
  doAssert m.anisotropy[0, 0] == map[0, 0]
  doAssert m.anisotropyTransform.texCoord == 1 and m.anisotropyTransform.scale == vec2(2, 3)
  doAssert m.anisotropyTransform.offset == vec2(0.25, 0.5) and m.anisotropyTransform.rotation == 0.4'f
  doAssert m.anisotropySampler.wrapS == MirroredRepeatWrap
  for i in [1, 2]:
    doAssert primitives[i].material.hasAnisotropy == (i == 1)
    doAssert primitives[i].material.anisotropyStrength == 0 and primitives[i].material.anisotropyRotation == 0
    doAssert primitives[i].material.anisotropy == nil
  for mode in [iwmEmbedded, iwmExternal]:
    let output = "tests/tmp/anisotropy-" & $mode & ".glb"
    createDir(output.parentDir)
    writeGLB(root, output, mode)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives[0].material
    doAssert reread.hasAnisotropy and reread.anisotropyStrength == m.anisotropyStrength
    doAssert reread.anisotropyRotation == m.anisotropyRotation
    doAssert reread.anisotropyTransform == m.anisotropyTransform and reread.anisotropySampler == m.anisotropySampler
    doAssert reread.anisotropy[0, 0] == map[0, 0]
  echo "Anisotropy: defaults, required extension, straight RGB data, UV transforms, sampler and GLB export passed"
