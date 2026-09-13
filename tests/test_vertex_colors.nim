import std/json, flatty/binny, chroma, gltf

block normalized16BitColors:
  # Exercise RGB and RGBA with offsets and both packed and interleaved storage.
  # RGBA retains RGB when alpha is zero; vertex colors are straight RGBA.
  let values = [
    [65535'u16, 0, 32768, 65535],
    [0'u16, 65535, 257, 32768],
    [257'u16, 32768, 65535, 0]
  ]
  for components in [4, 3]:
    for padding in (if components == 4: [0, 4] else: [2, 6]):
      let
        stride = components * 2 + padding
        viewOffset = 40
        accessorOffset = 4
      var bytes = newString(viewOffset + accessorOffset + stride * values.len)
      for i, value in [0'f32, 0, 0, 1, 0, 0, 0, 1, 0]:
        bytes.writeFloat32(i * 4, value)
      for i, value in values:
        for component in 0 ..< components:
          bytes.writeUint16(
            viewOffset + accessorOffset + i * stride + component * 2,
            value[component]
          )
      let document = %*{
        "asset": {"version": "2.0"},
        "buffers": [{"byteLength": bytes.len}],
        "bufferViews": [
          {"buffer": 0, "byteOffset": 0, "byteLength": 36},
          {"buffer": 0, "byteOffset": viewOffset,
           "byteLength": bytes.len - viewOffset}
        ],
        "accessors": [
          {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
          {"bufferView": 1, "byteOffset": accessorOffset, "componentType": 5123,
           "normalized": true, "count": 3, "type": "VEC" & $components}
        ],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "COLOR_0": 1}}]}],
        "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0
      }
      if padding > 0:
        document["bufferViews"][1]["byteStride"] = %stride
      let primitive = loadModelJson(document, ".", @[bytes]).nodes[0].mesh.primitives[0]
      doAssert primitive.colors.len == values.len
      for i, value in values:
        let expected = rgbx(
          (value[0] div 257).uint8,
          (value[1] div 257).uint8,
          (value[2] div 257).uint8,
          if components == 4: (value[3] div 257).uint8 else: 255'u8
        )
        doAssert primitive.colors[i] == expected,
          "Incorrect normalized 16-bit vertex color at vertex " & $i

echo "16-bit vertex colors: RGB/RGBA, offsets, strides and straight alpha passed"
