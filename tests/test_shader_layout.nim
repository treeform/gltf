import shady, vmath, gltf/backends/shader_layout
import pixie, gltf/backends/pbr_uniforms

var
  basis: Uniform[Mat3]
  tail: Uniform[float32]
  values: Uniform[array[2, Vec3]]
  after: Uniform[float32]

proc packed(normal: Vec3, fragColor: var Vec4) =
  let transformed: Vec3 = basis * normal
  fragColor = vec4(transformed * tail + values[0] + values[1] * after, 1.0'f)

const
  hlsl = shaderLayout(toShader(packed, hlslDX12, shaderFragment), hlslPacking)
  std140 = shaderLayout(toShader(packed, vulkanGlsl450, shaderFragment), std140Packing)

# ABI offsets in 32-bit words. HLSL reuses a matrix/array's last padding word;
# std140 starts the following uniform after the complete stride.
doAssert hlsl.field("basis").offset == 0
doAssert hlsl.field("tail").offset == 11
doAssert hlsl.field("values").offset == 12
doAssert hlsl.field("after").offset == 19
doAssert std140.field("tail").offset == 12
doAssert std140.field("values").offset == 16
doAssert std140.field("after").offset == 24

for layout in [hlsl, std140]:
  var data = newUniformData(layout)
  data.put("basis", mat3(vec3(1, 2, 3), vec3(4, 5, 6), vec3(7, 8, 9)))
  data.put("tail", 10'f)
  data.put("values", vec3(11, 12, 13), 0)
  data.put("values", vec3(14, 15, 16), 1)
  data.put("after", 17'f)
  doAssert cast[float32](data.words[0]) == 1
  doAssert cast[float32](data.words[4]) == 4
  doAssert cast[float32](data.words[10]) == 9
  doAssert cast[float32](data.words[layout.field("tail").offset]) == 10
  doAssert cast[float32](data.words[layout.field("values").offset + 4]) == 14
  doAssert cast[float32](data.words[layout.field("after").offset]) == 17
echo "Shader uniform ABI tests passed"

# Separate loader placeholders must share a binding, while changed pixels,
# samplers and explicitly invalidated materials must get new bindings.
block:
  let whiteA = newImage(1, 1)
  let whiteB = newImage(1, 1)
  whiteA.fill(rgbx(255, 255, 255, 255))
  whiteB.fill(rgbx(255, 255, 255, 255))
  var first = MaterialTextureInput(name: "baseColor", image: whiteA, srgb: true)
  var second = MaterialTextureInput(name: "baseColor", image: whiteB, srgb: true)
  let original = materialBindingKey([first], true, 1, 0)
  doAssert original == materialBindingKey([second], true, 1, 0)
  second.transform.offset = vec2(0.2, 0.3)
  doAssert original == materialBindingKey([second], true, 1, 0)
  doAssert original != materialBindingKey([first], true, 1, 1)
  doAssert original != materialBindingKey([first], true, 2, 0)
  whiteB.fill(rgbx(255, 0, 0, 255))
  doAssert original != materialBindingKey([second], true, 1, 0)
echo "Material binding sharing tests passed"
