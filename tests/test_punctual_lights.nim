import std/[json, os], flatty/binny, chroma, vmath, gltf

block punctualLightRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]:
    positions.writeFloat32(i * 4, value)
  let document = %*{
    "asset": {"version": "2.0"}, "extensionsRequired": ["KHR_lights_punctual"],
    "extensions": {"KHR_lights_punctual": {"lights": [
      {"type": "directional"}, {"type": "point", "name": "Bulb", "intensity": 12,
        "color": [0.25, 0.5, 1], "range": 7},
      {"type": "spot", "spot": {}},
      {"type": "spot", "spot": {"innerConeAngle": 0.3, "outerConeAngle": 0.6}, "range": 5}]}},
    "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
    "nodes": [{"mesh": 0},
      {"name": "Directional", "extensions": {"KHR_lights_punctual": {"light": 0}}},
      {"name": "Point", "extensions": {"KHR_lights_punctual": {"light": 1}}, "translation": [1, 2, 3]},
      {"name": "Spot defaults", "extensions": {"KHR_lights_punctual": {"light": 2}}},
      {"name": "Spot", "extensions": {"KHR_lights_punctual": {"light": 3}}}],
    "scenes": [{"nodes": [0, 1, 2, 3, 4]}], "scene": 0}
  let root = loadModelJson(document, ".", @[positions])
  let directional = root["Directional"].punctualLight
  doAssert directional.kind == DirectionalLightKind
  doAssert directional.color == color(1, 1, 1, 1) and directional.intensity == 1
  let point = root["Point"].punctualLight
  doAssert point.kind == PointLightKind and point.range == 7 and point.intensity == 12
  doAssert point.color == color(0.25, 0.5, 1, 1) and point.name == "Bulb"
  let spot = root["Spot defaults"].punctualLight
  doAssert spot.kind == SpotLightKind and spot.range == 0 and spot.innerConeAngle == 0
  doAssert abs(spot.outerConeAngle - 0.7853981633974483'f) < 0.000001'f
  doAssert root["Spot"].punctualLight.innerConeAngle == 0.3'f
  doAssert root["Spot"].punctualLight.outerConeAngle == 0.6'f
  let output = "tests/tmp/punctual-lights.glb"
  createDir(output.parentDir)
  writeGLB(root, output)
  let reread = readGltfFile(output).root
  for name in ["Directional", "Point", "Spot defaults", "Spot"]:
    let a = root[name].punctualLight
    let b = reread[name].punctualLight
    doAssert a.kind == b.kind and a.name == b.name and a.color == b.color
    doAssert a.intensity == b.intensity and a.range == b.range
    doAssert a.innerConeAngle == b.innerConeAngle and a.outerConeAngle == b.outerConeAngle
  echo "Punctual lights: required extension, all types/defaults, range/cones and GLB export passed"
