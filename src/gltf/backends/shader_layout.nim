## Uniform layouts and resource bindings derived from generated shader sources.
## Keep uploads tied to shader declarations instead of hand-counted offsets.
import std/strutils, vmath, chroma

type
  UniformPacking* = enum hlslPacking, std140Packing
  UniformField* = object
    name*: string
    offset*, components*, columns*, count*, stride*: int # In 32-bit words.
  ShaderLayout* = object
    fields*: seq[UniformField]
    textures*: seq[string] # Indexed by shader register/binding.
    words*: int
  UniformData* = object
    layout*: ShaderLayout
    words*: seq[uint32]

func align(value, multiple: int): int =
  (value + multiple - 1) div multiple * multiple

func shaderLayout*(source: string, packing: UniformPacking): ShaderLayout =
  var inBuffer = false
  var cursor = 0
  for raw in source.splitLines:
    let line = raw.strip()
    if line.startsWith("cbuffer ") or (line.startsWith("layout(") and
        (" uniform ShadyUniforms" in line or " uniform ShadyPushConstants" in line)):
      inBuffer = true
      continue
    if inBuffer:
      if line.startsWith("}"):
        inBuffer = false
        continue
      let parts = line.strip(chars = {';'}).splitWhitespace()
      if parts.len != 2: raise newException(ValueError, "Unsupported shader uniform: " & line)
      let kind = parts[0]
      var field = UniformField(name: parts[1], components: 1, columns: 1, count: 1)
      let bracket = field.name.find('[')
      let isArray = bracket >= 0
      if isArray:
        field.count = parseInt(field.name[bracket + 1 ..< field.name.find(']')])
        field.name.setLen(bracket)
      case kind
      of "float", "int", "uint", "bool": discard
      of "vec2", "ivec2", "uvec2", "float2", "int2", "uint2": field.components = 2
      of "vec3", "ivec3", "uvec3", "float3", "int3", "uint3": field.components = 3
      of "vec4", "ivec4", "uvec4", "float4", "int4", "uint4": field.components = 4
      of "mat2", "float2x2": field.components = 2; field.columns = 2
      of "mat3", "float3x3": field.components = 3; field.columns = 3
      of "mat4", "float4x4": field.components = 4; field.columns = 4
      else: raise newException(ValueError, "Unsupported shader uniform type: " & kind)
      if isArray or field.columns > 1:
        cursor = align(cursor, 4)
      elif packing == std140Packing:
        cursor = align(cursor, if field.components >= 3: 4 else: field.components)
      elif cursor mod 4 + field.components > 4:
        cursor = align(cursor, 4)
      field.offset = cursor
      field.stride = if field.columns > 1: field.columns * 4
        elif isArray: 4 else: field.components
      cursor += field.stride * field.count
      # HLSL permits the next scalar/vector to use the final row's unused
      # components; std140 reserves the entire matrix/array stride.
      if packing == hlslPacking and (isArray or field.columns > 1):
        cursor -= 4 - field.components
      result.fields.add(field)
    elif line.startsWith("Texture") and " : register(t" in line:
      let index = parseInt(line.split("register(t")[1].split(')')[0])
      if result.textures.len <= index: result.textures.setLen(index + 1)
      result.textures[index] = line.splitWhitespace()[1]
    elif line.startsWith("layout(set = 0, binding = ") and "uniform " in line:
      let index = parseInt(line.split("binding = ")[1].split(')')[0])
      if result.textures.len <= index: result.textures.setLen(index + 1)
      result.textures[index] = line.splitWhitespace()[^1].strip(chars = {';'})
  result.words = align(cursor, 4)

func newUniformData*(layout: ShaderLayout): UniformData =
  UniformData(layout: layout, words: newSeq[uint32](layout.words))

func field*(layout: ShaderLayout, name: string): UniformField =
  for f in layout.fields:
    if f.name == name: return f
  raise newException(ValueError, "Shader has no uniform: " & name)

proc put*(data: var UniformData, name: string, value: openArray[float32], index = 0) =
  let f = data.layout.field(name)
  doAssert index >= 0 and index < f.count and value.len == f.components * f.columns,
    "Incorrect uniform shape: " & name
  for col in 0 ..< f.columns:
    for row in 0 ..< f.components:
      data.words[f.offset + index * f.stride + col * (if f.columns > 1: 4 else: 0) + row] =
        cast[uint32](value[col * f.components + row])

proc put*(data: var UniformData, name: string, value: float32) = data.put(name, [value])
proc put*(data: var UniformData, name: string, value: int) =
  let f = data.layout.field(name)
  doAssert f.components == 1 and f.columns == 1
  data.words[f.offset] = cast[uint32](value.int32)
proc put*(data: var UniformData, name: string, value: bool) = data.put(name, value.ord)
proc put*(data: var UniformData, name: string, value: Vec2) = data.put(name, [value.x, value.y])
proc put*(data: var UniformData, name: string, value: Vec3, index = 0) = data.put(name, [value.x, value.y, value.z], index)
proc put*(data: var UniformData, name: string, value: Vec4, index = 0) = data.put(name, [value.x, value.y, value.z, value.w], index)
proc put*(data: var UniformData, name: string, value: Color) = data.put(name, [value.r, value.g, value.b, value.a])
proc put*(data: var UniformData, name: string, value: Mat4, index = 0) =
  var values: array[16, float32]
  for col in 0 ..< 4:
    for row in 0 ..< 4: values[col * 4 + row] = value[col, row]
  data.put(name, values, index)
proc put*(data: var UniformData, name: string, value: Mat3) =
  var values: array[9, float32]
  for col in 0 ..< 3:
    for row in 0 ..< 3: values[col * 3 + row] = value[col, row]
  data.put(name, values)
