import std/[json, os], flatty/binny, chroma, vmath, gltf

block emissiveStrengthRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]:
    positions.writeFloat32(i * 4, value)
  let document = %*{
    "asset": {"version": "2.0"}, "extensionsRequired": ["KHR_materials_emissive_strength"],
    "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "materials": [
      {"emissiveFactor": [1, 0.5, 0.25], "extensions": {"KHR_materials_emissive_strength": {"emissiveStrength": 16}}},
      {"emissiveFactor": [1, 1, 1], "extensions": {"KHR_materials_emissive_strength": {"emissiveStrength": 0}}},
      {"emissiveFactor": [0.25, 0.5, 1], "extensions": {"KHR_materials_emissive_strength": {}}},
      {"emissiveFactor": [0.5, 0.25, 1]}, {}],
    "meshes": [{"primitives": [
      {"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1},
      {"attributes": {"POSITION": 0}, "material": 2},
      {"attributes": {"POSITION": 0}, "material": 3},
      {"attributes": {"POSITION": 0}, "material": 4}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
  let root = loadModelJson(document, ".", @[positions])
  let primitives = root.nodes[0].mesh.primitives
  doAssert primitives[0].material.emissiveRadiance == color(16, 8, 4, 1)
  doAssert primitives[1].material.emissiveRadiance == color(0, 0, 0, 1)
  for i in [2, 3, 4]: doAssert primitives[i].material.emissiveStrength == 1
  doAssert Material(emissiveFactor: color(0.5, 0.5, 0.5, 1)).emissiveRadiance == color(0.5, 0.5, 0.5, 1)
  let output = "tests/tmp/emissive-strength.glb"
  createDir(output.parentDir)
  writeGLB(root, output)
  let reread = readGltfFile(output).root.nodes[0].mesh.primitives
  for i, primitive in primitives:
    let a = primitive.material
    let b = reread[i].material
    doAssert a.emissiveFactor == b.emissiveFactor, "Textureless emission must survive export"
    doAssert a.hasEmissiveStrength == b.hasEmissiveStrength
    doAssert a.emissiveStrength == b.emissiveStrength
    doAssert a.emissiveRadiance == b.emissiveRadiance
  echo "Emissive strength: defaults, zero, unclamped HDR radiance and textureless GLB export passed"
