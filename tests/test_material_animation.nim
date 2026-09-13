import std/json, chroma, vmath, gltf

proc colorAnimation(
  interpolation: string,
  values: seq[Vec4],
  pointer = "/materials/0/pbrMetallicRoughness/baseColorFactor"
): Node =
  # Two nodes instance one mesh; another mesh also uses the animated material.
  var floats = @[0'f32, 0, 0, 1, 0, 0, 0, 1, 0, 0, 2, 4]
  for value in values:
    floats.add([value.x, value.y, value.z, value.w])
  var bytes = newString(floats.len * sizeof(float32))
  copyMem(bytes[0].addr, floats[0].addr, bytes.len)
  loadModelJson(%*{
    "asset": {"version": "2.0"},
    "extensionsRequired": ["KHR_animation_pointer"],
    "buffers": [{"byteLength": bytes.len}],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 36},
      {"buffer": 0, "byteOffset": 36, "byteLength": 12},
      {"buffer": 0, "byteOffset": 48, "byteLength": values.len * 16}
    ],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
      {"bufferView": 1, "componentType": 5126, "count": 3, "type": "SCALAR"},
      {"bufferView": 2, "componentType": 5126, "count": values.len, "type": "VEC4"}
    ],
    "materials": [
      {"pbrMetallicRoughness": {"baseColorFactor": [0.8, 0.1, 0.2, 0.75]}},
      {"pbrMetallicRoughness": {"baseColorFactor": [0.3, 0.4, 0.5, 1]}}
    ],
    "meshes": [
      {"primitives": [
        {"attributes": {"POSITION": 0}, "material": 0},
        {"attributes": {"POSITION": 0}, "material": 1}
      ]},
      {"primitives": [{"attributes": {"POSITION": 0}, "material": 0}]}
    ],
    "nodes": [{"mesh": 0}, {"mesh": 0}, {"mesh": 1}],
    "scenes": [{"nodes": [0, 1, 2]}], "scene": 0,
    "animations": [{
      "channels": [{"sampler": 0, "target": {
        "path": "pointer", "extensions": {
          "KHR_animation_pointer": {"pointer": pointer}
        }
      }}],
      "samplers": [{"input": 1, "output": 2, "interpolation": interpolation}]
    }]
  }, ".", @[bytes])

proc checkColors(root: Node, expected: Color) =
  for node in root.nodes:
    let actual = node.mesh.primitives[0].material.baseColorFactor
    doAssert abs(actual.r - expected.r) < 0.00001
    doAssert abs(actual.g - expected.g) < 0.00001
    doAssert abs(actual.b - expected.b) < 0.00001
    doAssert abs(actual.a - expected.a) < 0.00001
    if node.mesh.primitives.len > 1:
      doAssert node.mesh.primitives[1].material.baseColorFactor ==
        color(0.3, 0.4, 0.5, 1)

let keyColors = @[vec4(1, 0, 0, 0.25), vec4(0, 1, 0, 0.5), vec4(0, 0, 1, 1)]

block linearColor:
  let root = colorAnimation("LINEAR", keyColors)
  root.checkColors(color(0.8, 0.1, 0.2, 0.75))
  doAssert root.animations.len == 1, "Material color channel was discarded"
  doAssert root.animations[0].duration == 4
  root.updateAnimation(1)
  root.checkColors(color(0.5, 0.5, 0, 0.375))
  for node in root.nodes:
    doAssert node.mesh.primitives[0].material.materialVersion > 0
  root.updateAnimation(1)
  root.checkColors(color(0, 1, 0, 0.5))
  root.updateAnimation(1)
  root.checkColors(color(0, 0.5, 0.5, 0.75))
  root.updateAnimation(2) # Loop to the same interpolated color as t=1.
  root.checkColors(color(0.5, 0.5, 0, 0.375))
  root.activeClips = @[]
  root.updateAnimation(0)
  root.checkColors(color(0.8, 0.1, 0.2, 0.75))
  root.activeClips = @[0]
  root.animTime = 3
  root.updateAnimation(0)
  root.checkColors(color(0, 0.5, 0.5, 0.75))
  root.resetToBase()
  root.checkColors(color(0.8, 0.1, 0.2, 0.75))

block stepColor:
  let root = colorAnimation("STEP", keyColors)
  root.updateAnimation(1.99)
  root.checkColors(color(1, 0, 0, 0.25))
  root.animTime = 2
  root.updateAnimation(0) # Exact interior keyframes use the new STEP value.
  root.checkColors(color(0, 1, 0, 0.5))
  root.animTime = 4
  root.updateAnimation(0)
  root.checkColors(color(0, 0, 1, 1))

block cubicColor:
  let zero = vec4(0, 0, 0, 0)
  let root = colorAnimation("CUBICSPLINE", @[
    zero, keyColors[0], vec4(-0.2, 0.2, 0, 0.1),
    zero, keyColors[1], zero,
    zero, keyColors[2], zero
  ])
  root.updateAnimation(1)
  # Hermite midpoint with a two-second segment; RGBA must not be normalized.
  root.checkColors(color(0.45, 0.55, 0, 0.4))
  root.updateAnimation(2)
  root.checkColors(color(0, 0.5, 0.5, 0.75))

block invalidMaterialPointers:
  for pointer in [
    "/materials/99/pbrMetallicRoughness/baseColorFactor",
    "/materials/-1/pbrMetallicRoughness/baseColorFactor",
    "/materials/not-an-index/pbrMetallicRoughness/baseColorFactor",
    "/materials/0/unknownProperty"
  ]:
    let root = colorAnimation("LINEAR", keyColors, pointer)
    doAssert root.animations.len == 0
    root.updateAnimation(1)
    root.checkColors(color(0.8, 0.1, 0.2, 0.75))

echo "Material color animation: interpolation, shared materials, looping and reset passed"
