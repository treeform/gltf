import
  std/json,
  chroma, opengl, pixie, pixie/fileformats/png, vmath,
  models

type
  BufferView* = object
    buffer*: int
    byteOffset*, byteLength*, byteStride*: int

  AccessorKind* = enum
    atSCALAR, atVEC2, atVEC3, atVEC4, atMAT2, atMAT3, atMAT4

  Accessor* = object
    bufferView*: int
    byteOffset*, count*: int
    componentType*: GLenum
    kind*: AccessorKind

  Texture* = object
    source*: int
    sampler*: int

  Sampler* = object
    magFilter*, minFilter*, wrapS*, wrapT*: GLint

  MaterialTexture* = object
    index*: int
    texCoord*: int
    scale*: float32
    strength*: float32

  PbrMetallicRoughness* = object
    baseColorTexture*: MaterialTexture
    baseColorFactor*: Color
    metallicRoughnessTexture*: MaterialTexture
    metallicFactor*: float32
    roughnessFactor*: float32

  InnerMaterial* = object
    name*: string
    pbrMetallicRoughness*: PbrMetallicRoughness
    normalTexture*: MaterialTexture
    occlusionTexture*: MaterialTexture
    emissiveTexture*: MaterialTexture
    emissiveFactor*: Color
    alphaMode*: string
    alphaCutoff*: float32
    doubleSided*: bool

  Mesh* = object
    name*: string
    primitives*: seq[int]

  PrimitiveAttributes* = object
    position*, normal*, color0*, texcoord0*: int

  Primitive* = object
    attributes*: PrimitiveAttributes
    indices*, material*: int
    mode*: GLenum

  GltfFile* = ref object
    path*: string
    root*: Node

proc pad4*(data: var string) =
  while data.len mod 4 != 0:
    data.add(char(0))

proc writeUint32Le*(s: var string, v: uint32) =
  s.add(char(v and 0xFF))
  s.add(char((v shr 8) and 0xFF))
  s.add(char((v shr 16) and 0xFF))
  s.add(char((v shr 24) and 0xFF))

proc writeUint16AtLe*(s: var string, offset: int, v: uint16) =
  s[offset] = char(v and 0xFF)
  s[offset + 1] = char((v shr 8) and 0xFF)

proc writeUint32AtLe*(s: var string, offset: int, v: uint32) =
  s[offset + 0] = char(v and 0xFF)
  s[offset + 1] = char((v shr 8) and 0xFF)
  s[offset + 2] = char((v shr 16) and 0xFF)
  s[offset + 3] = char((v shr 24) and 0xFF)

proc readFloat32*(data: string, offset: int): float32 =
  cast[ptr float32](data[offset].unsafeAddr)[]

proc readAccessorFloats*(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[float32] =
  let accessor = accessors[accessorIdx]
  let view = bufferViews[accessor.bufferView]
  let buffer = buffers[view.buffer]
  let start = view.byteOffset + accessor.byteOffset
  let stride = if view.byteStride > 0: view.byteStride else: 4
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = readFloat32(buffer, off)

proc readAccessorVec3*(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Vec3] =
  let accessor = accessors[accessorIdx]
  let view = bufferViews[accessor.bufferView]
  let buffer = buffers[view.buffer]
  let start = view.byteOffset + accessor.byteOffset
  let stride = if view.byteStride > 0: view.byteStride else: 12
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = vec3(
      readFloat32(buffer, off),
      readFloat32(buffer, off + 4),
      readFloat32(buffer, off + 8)
    )

proc readAccessorQuat*(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Quat] =
  let accessor = accessors[accessorIdx]
  let view = bufferViews[accessor.bufferView]
  let buffer = buffers[view.buffer]
  let start = view.byteOffset + accessor.byteOffset
  let stride = if view.byteStride > 0: view.byteStride else: 16
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = quat(
      readFloat32(buffer, off),
      readFloat32(buffer, off + 4),
      readFloat32(buffer, off + 8),
      readFloat32(buffer, off + 12)
    ).normalize()

proc addView*(
  data: var string,
  payload: string,
  stride = 0
): BufferView =
  let offset = data.len
  data.add(payload)
  pad4(data)
  BufferView(
    buffer: 0,
    byteOffset: offset,
    byteLength: payload.len,
    byteStride: stride
  )

proc addAccessor*(
  accessors: var seq[Accessor],
  bufferViews: var seq[BufferView],
  data: var string,
  payload: string,
  kind: AccessorKind,
  component: GLenum,
  count: int,
  stride = 0
): int =
  bufferViews.add(addView(data, payload, stride))
  let viewIdx = bufferViews.len - 1
  let accessor = Accessor(
    bufferView: viewIdx,
    byteOffset: 0,
    count: count,
    componentType: component,
    kind: kind
  )
  accessors.add(accessor)
  accessors.len - 1

proc writeImagePng*(
  images: var seq[JsonNode],
  bufferViews: var seq[BufferView],
  data: var string,
  img: Image
) =
  let pngData = img.encodePng()
  bufferViews.add(addView(data, pngData))
  let viewIdx = bufferViews.len - 1
  var node = newJObject()
  node["bufferView"] = newJInt(viewIdx)
  node["mimeType"] = newJString("image/png")
  images.add(node)

proc assertRaise*(test: bool, msg: string) =
  ## Raises an exception when a glTF invariant is not met.
  if not test:
    raise newException(Exception, msg)
