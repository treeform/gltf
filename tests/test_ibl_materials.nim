import std/[json, os], flatty/binny, chroma, vmath, gltf

block velvetMaterialRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]:
    positions.writeFloat32(i * 4, value)
  let document = %*{
    "asset": {"version": "2.0"},
    "extensionsUsed": ["KHR_materials_specular", "KHR_materials_sheen", "KHR_lights_punctual"],
    "extensions": {"KHR_lights_punctual": {"lights": [
      {"type": "directional", "intensity": 3, "color": [0.5, 0.75, 1]},
      {"type": "directional"}
    ]}},
    "buffers": [{"byteLength": 36}],
    "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "materials": [
      {"extensions": {
        "KHR_materials_specular": {"specularFactor": 0.7, "specularColorFactor": [0.1, 0.34, 1]},
        "KHR_materials_sheen": {"sheenColorFactor": [0.05, 0.17, 0.5], "sheenRoughnessFactor": 0.6}
      }},
      {"extensions": {"KHR_materials_specular": {}, "KHR_materials_sheen": {}}},
      {},
      {"extensions": {"KHR_materials_specular": {"specularFactor": 0}}}
    ],
    "meshes": [{"primitives": [
      {"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1},
      {"attributes": {"POSITION": 0}, "material": 2},
      {"attributes": {"POSITION": 0}, "material": 3}
    ]}],
    "nodes": [{"mesh": 0},
      {"name": "Light parent", "rotation": [0, 0.70710678, 0, 0.70710678], "children": [2]},
      {"name": "Tinted light", "extensions": {"KHR_lights_punctual": {"light": 0}}},
      {"name": "Default light", "extensions": {
        "KHR_lights_punctual": {"light": 1}, "KHR_node_visibility": {"visible": false}}}
    ],
    "scenes": [{"nodes": [0, 1, 3]}], "scene": 0
  }
  let root = loadModelJson(document, ".", @[positions])
  let materials = root.nodes[0].mesh.primitives
  doAssert materials[0].material.hasSpecular
  doAssert materials[0].material.specularColorFactor == vec3(0.1, 0.34, 1)
  doAssert materials[0].material.sheenColorFactor == vec3(0.05, 0.17, 0.5)
  doAssert materials[0].material.sheenRoughnessFactor == 0.6'f
  doAssert materials[1].material.specularFactor == 1
  doAssert materials[1].material.specularColorFactor == vec3(1)
  doAssert materials[1].material.sheenColorFactor == vec3(0)
  doAssert not materials[2].material.hasSpecular
  doAssert materials[3].material.hasSpecular and materials[3].material.specularFactor == 0
  root.updateTransforms()
  let light = root["Light parent"]["Tinted light"]
  doAssert light.directionalLight.color == color(0.5, 0.75, 1, 1)
  doAssert light.directionalLight.intensity == 3
  doAssert ((light.mat * vec4(0, 0, -1, 0)).xyz - vec3(-1, 0, 0)).length < 0.00001
  doAssert root["Default light"].directionalLight.intensity == 1
  doAssert root["Default light"].directionalLight.color == color(1, 1, 1, 1)
  let output = "tests/tmp/velvet-roundtrip.glb"
  createDir(output.parentDir)
  writeGLB(root, output)
  let reread = readGltfFile(output).root
  let roundTrip = reread.nodes[0].mesh.primitives
  for i, primitive in materials:
    let a = primitive.material
    let b = roundTrip[i].material
    doAssert a.hasSpecular == b.hasSpecular
    doAssert a.specularFactor == b.specularFactor
    doAssert a.specularColorFactor == b.specularColorFactor
    doAssert a.sheenColorFactor == b.sheenColorFactor
    doAssert a.sheenRoughnessFactor == b.sheenRoughnessFactor
  doAssert reread["Light parent"]["Tinted light"].directionalLight.intensity == 3
  doAssert not reread["Default light"].visible
  echo "Sheen/specular factors, directional lights, defaults and GLB round-trip passed"
