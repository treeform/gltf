import std/[base64, json, os], flatty/binny, pixie, vmath, gltf

block iridescenceRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]: positions.writeFloat32(i * 4, value)
  let map = newImage(1, 1)
  map.fill(rgbx(128, 64, 255, 0))
  let document = %*{
    "asset": {"version": "2.0"}, "extensionsRequired": ["KHR_materials_iridescence"],
    "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [{"uri": "data:image/png;base64," & encode(map.encodeStraightAlphaPng())}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33648, "wrapT": 33071}],
    "textures": [{"source": 0, "sampler": 0}],
    "materials": [{"extensions": {"KHR_materials_iridescence": {
      "iridescenceFactor": 0.7, "iridescenceIor": 1.7,
      "iridescenceThicknessMinimum": 600, "iridescenceThicknessMaximum": 200,
      "iridescenceTexture": {"index": 0, "extensions": {"KHR_texture_transform": {
        "texCoord": 1, "offset": [0.25, 0.5], "scale": [2, 3], "rotation": 0.4}}},
      "iridescenceThicknessTexture": {"index": 0, "texCoord": 1}}}},
      {"extensions": {"KHR_materials_iridescence": {}}}, {}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1}, {"attributes": {"POSITION": 0}, "material": 2}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
  let root = loadModelJson(document, ".", @[positions])
  let primitives = root.nodes[0].mesh.primitives
  let m = primitives[0].material
  doAssert m.hasIridescence and m.iridescenceFactor == 0.7'f and m.iridescenceIor == 1.7'f
  # A reversed thickness range is explicitly allowed by the extension.
  doAssert m.iridescenceThicknessMinimum == 600 and m.iridescenceThicknessMaximum == 200
  doAssert m.iridescence[0, 0] == map[0, 0] and m.iridescenceThickness[0, 0] == map[0, 0]
  doAssert m.iridescenceTransform.texCoord == 1 and m.iridescenceTransform.scale == vec2(2, 3)
  doAssert m.iridescenceTransform.offset == vec2(0.25, 0.5) and m.iridescenceTransform.rotation == 0.4'f
  for i in [1, 2]:
    let other = primitives[i].material
    doAssert other.hasIridescence == (i == 1) and other.iridescenceFactor == 0
    doAssert other.iridescenceIor == 1.3'f
    doAssert other.iridescenceThicknessMinimum == 100 and other.iridescenceThicknessMaximum == 400
  for mode in [iwmEmbedded, iwmExternal]:
    let output = "tests/tmp/iridescence-" & $mode & ".glb"
    createDir(output.parentDir)
    writeGLB(root, output, mode)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives[0].material
    doAssert reread.hasIridescence and reread.iridescenceFactor == m.iridescenceFactor
    doAssert reread.iridescenceIor == m.iridescenceIor
    doAssert reread.iridescenceThicknessMinimum == m.iridescenceThicknessMinimum
    doAssert reread.iridescenceThicknessMaximum == m.iridescenceThicknessMaximum
    doAssert reread.iridescenceTransform == m.iridescenceTransform
    doAssert reread.iridescenceThicknessTransform == m.iridescenceThicknessTransform
    doAssert reread.iridescenceSampler == m.iridescenceSampler
    doAssert reread.iridescenceThicknessSampler == m.iridescenceThicknessSampler
    doAssert reread.iridescence[0, 0] == map[0, 0] and reread.iridescenceThickness[0, 0] == map[0, 0]
  echo "Iridescence: required extension, defaults, reversed thickness range, linear maps, UV transforms and export passed"
