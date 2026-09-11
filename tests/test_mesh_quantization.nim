import
  std/json,
  ../src/gltf/[models, reader],
  vmath

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, value in bytes:
    result[i] = char(value)

echo "Testing KHR_mesh_quantization."
let quantizedBuffer = bytesToString(@[
  # POSITION: signed short VEC3 with four-byte-aligned stride.
  0xfe'u8, 0xff, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
  0x0a, 0x00, 0x14, 0x00, 0x1e, 0x00, 0x00, 0x00,
  0x00, 0x80, 0xff, 0x7f, 0xff, 0xff, 0x00, 0x00,
  # NORMAL: normalized signed byte VEC3 with padded stride.
  0x80, 0x00, 0x7f, 0x00,
  0x00, 0x7f, 0x00, 0x00,
  0x40, 0xc0, 0x00, 0x00,
  # TANGENT: normalized signed short VEC4.
  0x00, 0x80, 0x00, 0x00, 0xff, 0x7f, 0xff, 0x7f,
  0x00, 0x00, 0xff, 0x7f, 0x00, 0x00, 0x00, 0x80,
  0x00, 0x40, 0x00, 0xc0, 0x00, 0x00, 0xff, 0x7f,
  # TEXCOORD_0: unnormalized signed byte VEC2.
  0x00, 0x01, 0xfe, 0x7f, 0x80, 0x03,
  # Morph POSITION: unnormalized signed byte VEC3 with padded stride.
  0x01, 0xff, 0x00, 0x00,
  0x02, 0xfe, 0x01, 0x00,
  0x80, 0x7f, 0x00, 0x00
])
let quantizedModel = loadModelJson(
  %*{
    "asset": {"version": "2.0"},
    "extensionsRequired": ["KHR_mesh_quantization"],
    "extensionsUsed": ["KHR_mesh_quantization"],
    "buffers": [{"byteLength": 78}],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 24, "byteStride": 8},
      {"buffer": 0, "byteOffset": 24, "byteLength": 12, "byteStride": 4},
      {"buffer": 0, "byteOffset": 36, "byteLength": 24, "byteStride": 8},
      {"buffer": 0, "byteOffset": 60, "byteLength": 6, "byteStride": 2},
      {"buffer": 0, "byteOffset": 66, "byteLength": 12, "byteStride": 4}
    ],
    "accessors": [
      {"bufferView": 0, "componentType": 5122, "count": 3, "type": "VEC3"},
      {
        "bufferView": 1,
        "componentType": 5120,
        "count": 3,
        "normalized": true,
        "type": "VEC3"
      },
      {
        "bufferView": 2,
        "componentType": 5122,
        "count": 3,
        "normalized": true,
        "type": "VEC4"
      },
      {"bufferView": 3, "componentType": 5120, "count": 3, "type": "VEC2"},
      {"bufferView": 4, "componentType": 5120, "count": 3, "type": "VEC3"}
    ],
    "images": [],
    "textures": [],
    "samplers": [],
    "materials": [],
    "meshes": [
      {
        "primitives": [
          {
            "attributes": {
              "POSITION": 0,
              "NORMAL": 1,
              "TANGENT": 2,
              "TEXCOORD_0": 3
            },
            "targets": [{"POSITION": 4}]
          }
        ]
      }
    ],
    "nodes": [{"name": "QuantizedNode", "mesh": 0}],
    "scenes": [{"nodes": [0]}],
    "scene": 0,
    "animations": []
  },
  ".",
  @[quantizedBuffer]
)
let quantizedPrimitive = quantizedModel["QuantizedNode"].mesh.primitives[0]
doAssert quantizedPrimitive.points[0] == vec3(-2, 0, 2)
doAssert quantizedPrimitive.points[2] == vec3(-32768, 32767, -1)
doAssert quantizedPrimitive.normals[0] ~= vec3(-1, 0, 1)
doAssert quantizedPrimitive.normals[2] ~= vec3(64 / 127, -64 / 127, 0)
doAssert quantizedPrimitive.tangents[0] ~= vec4(-1, 0, 1, 1)
doAssert quantizedPrimitive.tangents[1] ~= vec4(0, 1, 0, -1)
doAssert quantizedPrimitive.uvs[1] == vec2(-2, 127)
doAssert quantizedPrimitive.morphTargets[0].positionDeltas[2] ==
  vec3(-128, 127, 0)
