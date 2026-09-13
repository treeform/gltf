import std/[json, os], flatty/binny, gltf, chroma

block unlitMaterialRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]:
    positions.writeFloat32(i * 4, value)
  let document = %*{
    "asset": {"version": "2.0"},
    "extensionsUsed": ["KHR_materials_unlit"],
    "buffers": [{"byteLength": 36}],
    "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "materials": [
      {"pbrMetallicRoughness": {"baseColorFactor": [0.2, 0.4, 0.8, 0.25]},
       "extensions": {"KHR_materials_unlit": {}}, "emissiveFactor": [1, 0, 0]},
      {},
      {"extensions": {"KHR_materials_unlit": {}}, "alphaMode": "MASK",
       "alphaCutoff": 0.35, "doubleSided": true},
      {"extensions": {"KHR_materials_unlit": {}}, "alphaMode": "BLEND"}
    ],
    "meshes": [{"primitives": [
      {"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1},
      {"attributes": {"POSITION": 0}, "material": 2},
      {"attributes": {"POSITION": 0}, "material": 3}
    ]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0
  }
  for required in [false, true]:
    if required: document["extensionsRequired"] = %*["KHR_materials_unlit"]
    let root = loadModelJson(document, ".", @[positions])
    let primitives = root.nodes[0].mesh.primitives
    doAssert primitives[0].material.unlit
    doAssert not primitives[1].material.unlit
    doAssert primitives[2].material.unlit
    doAssert primitives[3].material.unlit
    doAssert primitives[0].material.baseColorFactor == color(0.2, 0.4, 0.8, 0.25)
    doAssert primitives[2].material.alphaMode == MaskAlphaMode
    doAssert primitives[2].material.doubleSided
    doAssert primitives[3].material.alphaMode == BlendAlphaMode
    let output = "tests/tmp/unlit-roundtrip.glb"
    createDir(output.parentDir)
    writeGLB(root, output)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives
    for i in 0 ..< primitives.len:
      doAssert reread[i].material.unlit == primitives[i].material.unlit
      doAssert reread[i].material.baseColorFactor == primitives[i].material.baseColorFactor
      doAssert reread[i].material.alphaMode == primitives[i].material.alphaMode
      doAssert reread[i].material.doubleSided == primitives[i].material.doubleSided
    doAssert abs(reread[2].material.alphaCutoff - 0.35'f32) < 0.00001'f32
  echo "Unlit material loading, required/optional extension and GLB round-trip passed"
