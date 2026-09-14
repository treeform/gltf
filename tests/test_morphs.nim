import std/json, vmath, gltf

block staticMorphWeights:
  # A mesh's default weights apply even when the glTF has no animations.
  # Each primitive has a different target, so both must receive the weight.
  var values = @[
    0'f32, 0, 0, 1, 0, 0, 0, 1, 0,
    0'f32, 0, 2, 0, 0, 2, 0, 0, 2,
    0'f32, 0, 4, 0, 0, 4, 0, 0, 4
  ]
  var bytes = newString(values.len * sizeof(float32))
  copyMem(bytes[0].addr, values[0].addr, bytes.len)
  let root = loadModelJson(%*{
    "asset": {"version": "2.0"},
    "buffers": [{"byteLength": 108}],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 36},
      {"buffer": 0, "byteOffset": 36, "byteLength": 36},
      {"buffer": 0, "byteOffset": 72, "byteLength": 36}
    ],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
      {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"},
      {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC3"}
    ],
    "images": [], "textures": [], "samplers": [], "materials": [],
    "meshes": [{"weights": [0.5], "primitives": [
      {"attributes": {"POSITION": 0}, "targets": [{"POSITION": 1}]},
      {"attributes": {"POSITION": 0}, "targets": [{"POSITION": 2}]}
    ]}],
    "nodes": [{"children": [1]}, {"mesh": 0}],
    "scenes": [{"nodes": [0]}], "scene": 0
  }, ".", @[bytes])
  let node = root.nodes[0].nodes[0]
  let basePoints = @[vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0)]
  doAssert root.animations.len == 0
  doAssert node.morphWeights == @[0.5'f32]
  for weight in [0.5'f32, 0.5, 1, 0]:
    node.morphWeights[0] = weight
    root.updateAnimation(0.1)
    for i, primitive in node.mesh.primitives:
      doAssert primitive.basePoints == basePoints
      for j, point in primitive.points:
        doAssert point == basePoints[j] + vec3(0, 0, (i + 1).float32 * 2 * weight),
          "Static morph not applied to primitive " & $i
      doAssert primitive.geometryVersion > 0
  doAssert root.animTime == 0 # No timeline to advance.

echo "Static morph defaults: nested nodes, multiple primitives and repeated updates passed"
