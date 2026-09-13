import std/[base64, json, strutils], flatty/binny, pixie, vmath, gltf

proc fixture(texturePath, property: string, values: seq[float32],
    interpolation = "LINEAR", signedNormalized = false): Node =
  let components = if property in ["offset", "scale"]: 2 else: 1
  var bytes = newString(48 + values.len * (if signedNormalized: 2 else: 4))
  for i, value in [-1'f, -1, 0, 1, -1, 0, 0, 1, 0, 0, 2, 4]:
    bytes.writeFloat32(i * 4, value)
  for i, value in values:
    if signedNormalized: bytes.writeInt16(48 + i * 2, (value * 32767).int16)
    else: bytes.writeFloat32(48 + i * 4, value)
  let map = newImage(1, 1)
  map.fill(rgbx(255, 255, 255, 255))
  let mat = newJObject()
  let parts = texturePath.split('/')
  var parent = mat
  for token in parts[0 .. ^2]:
    parent[token] = newJObject()
    parent = parent[token]
  parent[parts[^1]] = %*{"index": 0, "extensions": {"KHR_texture_transform": {
    "offset": [0.25, 0.75], "scale": [2, 3], "rotation": 0.4, "texCoord": 1}}}
  let pointer = "/materials/0/" & texturePath & "/extensions/KHR_texture_transform/" & property
  let doc = %*{
    "asset": {"version": "2.0"}, "extensionsRequired": ["KHR_animation_pointer"],
    "buffers": [{"byteLength": bytes.len}],
    "bufferViews": [{"buffer": 0, "byteLength": 36},
      {"buffer": 0, "byteOffset": 36, "byteLength": 12},
      {"buffer": 0, "byteOffset": 48, "byteLength": bytes.len - 48}],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
      {"bufferView": 1, "componentType": 5126, "count": 3, "type": "SCALAR"},
      {"bufferView": 2, "componentType": (if signedNormalized: 5122 else: 5126),
        "normalized": signedNormalized, "count": values.len div components,
        "type": (if components == 2: "VEC2" else: "SCALAR")}],
    "images": [{"uri": "data:image/png;base64," & encode(map.encodeStraightAlphaPng())}],
    "textures": [{"source": 0}], "materials": [mat, {}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1}]}],
    "nodes": [{"mesh": 0}, {"mesh": 0}], "scenes": [{"nodes": [0, 1]}], "scene": 0,
    "animations": [
      {"name": "Unsupported first clip", "samplers": [{"input": 1, "output": 2}],
        "channels": [{"sampler": 0, "target": {"path": "pointer", "extensions": {
          "KHR_animation_pointer": {"pointer": "/materials/0/extras/unsupported"}}}}]},
      {"name": "UV clip", "samplers": [{"input": 1, "output": 2, "interpolation": interpolation}],
        "channels": [{"sampler": 0, "target": {"path": "pointer", "extensions": {
          "KHR_animation_pointer": {"pointer": pointer}}}}]}]}
  result = loadModelJson(doc, ".", @[bytes])
  result.activeClips = @[1]

proc check(root: Node, slot: MaterialTextureSlot, property: string, expected: Vec2) =
  for node in root.nodes:
    let m = node.mesh.primitives[0].material
    let transform = m.textureTransform(slot)
    let actual = case property
      of "offset": transform.offset
      of "scale": transform.scale
      else: vec2(transform.rotation, 0)
    doAssert length(actual - expected) < 0.0001, property & ": " & $actual & " != " & $expected
    doAssert transform.texCoord == 1
    doAssert node.mesh.primitives[1].material.textureTransform(slot).offset == vec2(0)

block textureTargets:
  for slot in MaterialTextureSlot:
    for property in ["offset", "scale", "rotation"]:
      let values = if property == "rotation": @[0'f, 2, 4] else: @[0'f, 2, 2, 4, 4, 6]
      let root = fixture(MaterialTexturePaths[slot], property, values)
      doAssert root.animations.len == 2 and root.animations[0].channels.len == 0
      doAssert root.animations[0].duration == 4 and root.animations[1].duration == 4
      doAssert root.animations[1].channels.len == 1
      root.updateAnimation(1)
      root.check(slot, property, if property == "rotation": vec2(1, 0) else: vec2(1, 3))
      for node in root.nodes: doAssert node.mesh.primitives[0].material.materialVersion > 0
      root.updateAnimation(4) # Loop to t=1; do not accumulate the transform.
      root.check(slot, property, if property == "rotation": vec2(1, 0) else: vec2(1, 3))
      root.activeClips = @[]
      root.updateAnimation(0)
      root.check(slot, property, case property
        of "offset": vec2(0.25, 0.75)
        of "scale": vec2(2, 3)
        else: vec2(0.4, 0))

block interpolation:
  let path = "normalTexture"
  let step = fixture(path, "offset", @[0'f, 2, 2, 4, 4, 6], "STEP")
  step.updateAnimation(1.9)
  step.check(NormalTextureSlot, "offset", vec2(0, 2))
  step.animTime = 2
  step.updateAnimation(0)
  step.check(NormalTextureSlot, "offset", vec2(2, 4))
  let cubic = fixture(path, "scale", @[0'f, 0, 0, 2, 2, 4,
    0, 0, 2, 4, 0, 0, 0, 0, 4, 6, 0, 0], "CUBICSPLINE")
  cubic.updateAnimation(1)
  cubic.check(NormalTextureSlot, "scale", vec2(1.5, 4))
  let scalarCubic = fixture(path, "rotation", @[0'f, 0, 2, 0, 2, 0, 0, 4, 0], "CUBICSPLINE")
  scalarCubic.updateAnimation(1)
  scalarCubic.check(NormalTextureSlot, "rotation", vec2(1.5, 0))

block componentsAndNormalization:
  let root = fixture("normalTexture", "offset/1", @[-1'f, 0, 1], signedNormalized = true)
  root.updateAnimation(1)
  root.check(NormalTextureSlot, "offset", vec2(0.25, -0.5))
  root.resetToBase()
  root.check(NormalTextureSlot, "offset", vec2(0.25, 0.75))
  let vector = fixture("normalTexture", "offset", @[-1'f, 0, 0, 1, 1, 0], signedNormalized = true)
  vector.updateAnimation(1)
  vector.check(NormalTextureSlot, "offset", vec2(-0.5, 0.5))

block simultaneousProperties:
  let offset = fixture("normalTexture", "offset", @[0'f, 2, 2, 4, 4, 6])
  let scale = fixture("normalTexture", "scale", @[1'f, 1, 3, 5, 5, 9])
  let extra = scale.animations[1].channels[0]
  extra.materialTargets = offset.animations[1].channels[0].materialTargets
  offset.animations[1].channels.add(extra)
  offset.updateAnimation(1)
  offset.check(NormalTextureSlot, "offset", vec2(1, 3))
  offset.check(NormalTextureSlot, "scale", vec2(2, 3))
  offset.resetToBase()
  offset.check(NormalTextureSlot, "offset", vec2(0.25, 0.75))
  offset.check(NormalTextureSlot, "scale", vec2(2, 3))

echo "Texture animation: all slots/properties, components, interpolation, normalized data, clip indices, sharing and reset passed"
