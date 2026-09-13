import
  std/[base64, json, os, strformat, strutils],
  chroma, flatty/binny, pixie, vmath, webby,
  common, draco, internal, meshopt, models, tangents, texture_images

export common

const SupportedExtensions = [
  "KHR_texture_transform",
  "KHR_materials_transmission",
  "KHR_materials_diffuse_transmission",
  "KHR_lights_punctual",
  "KHR_materials_emissive_strength",
  "KHR_materials_anisotropy",
  "KHR_materials_clearcoat",
  "KHR_materials_iridescence",
  "KHR_materials_specular",
  "KHR_materials_sheen",
  "KHR_materials_pbrSpecularGlossiness",
  "KHR_materials_volume",
  "KHR_materials_ior",
  "KHR_materials_unlit",
  "KHR_node_visibility",
  "KHR_animation_pointer",
  "KHR_texture_basisu",
  "EXT_texture_webp",
  "KHR_draco_mesh_compression",
  "KHR_mesh_quantization",
  "EXT_meshopt_compression",
  "EXT_mesh_gpu_instancing"
]

const
  GltfArrayBufferTarget = 34962
  GltfElementArrayBufferTarget = 34963

proc parseComponentType(value: int): ComponentType =
  case value
  of ByteComponent.int:
    ByteComponent
  of UnsignedByteComponent.int:
    UnsignedByteComponent
  of ShortComponent.int:
    ShortComponent
  of UnsignedShortComponent.int:
    UnsignedShortComponent
  of UnsignedIntComponent.int:
    UnsignedIntComponent
  of FloatComponent.int:
    FloatComponent
  else:
    raise newException(GltfError, &"Invalid accessor componentType {value}")

proc parseTextureMagFilter(value: int): TextureMagFilter =
  case value
  of NearestMagFilter.int:
    NearestMagFilter
  of LinearMagFilter.int:
    LinearMagFilter
  else:
    raise newException(GltfError, &"Invalid texture magFilter {value}")

proc parseTextureMinFilter(value: int): TextureMinFilter =
  case value
  of NearestMinFilter.int:
    NearestMinFilter
  of LinearMinFilter.int:
    LinearMinFilter
  of NearestMipmapNearestMinFilter.int:
    NearestMipmapNearestMinFilter
  of LinearMipmapNearestMinFilter.int:
    LinearMipmapNearestMinFilter
  of NearestMipmapLinearMinFilter.int:
    NearestMipmapLinearMinFilter
  of LinearMipmapLinearMinFilter.int:
    LinearMipmapLinearMinFilter
  else:
    raise newException(GltfError, &"Invalid texture minFilter {value}")

proc parseTextureWrap(value: int): TextureWrap =
  case value
  of ClampToEdgeWrap.int:
    ClampToEdgeWrap
  of MirroredRepeatWrap.int:
    MirroredRepeatWrap
  of RepeatWrap.int:
    RepeatWrap
  else:
    raise newException(GltfError, &"Invalid texture wrap mode {value}")

proc parsePrimitiveMode(value: int): PrimitiveMode =
  case value
  of PointsMode.int:
    PointsMode
  of LinesMode.int:
    LinesMode
  of LineLoopMode.int:
    LineLoopMode
  of LineStripMode.int:
    LineStripMode
  of TrianglesMode.int:
    TrianglesMode
  of TriangleStripMode.int:
    TriangleStripMode
  of TriangleFanMode.int:
    TriangleFanMode
  else:
    raise newException(GltfError, &"Invalid primitive mode {value}")

proc unsupportedUsedExtensions(jsonRoot: JsonNode): seq[string] =
  ## Returns used extensions we do not currently support.
  if "extensionsUsed" notin jsonRoot:
    return
  for extension in jsonRoot["extensionsUsed"]:
    let name = extension.getStr()
    if name notin SupportedExtensions and name notin result:
      result.add(name)

proc readFloat32(data: string, offset: int): float32 =
  ## Reads a float32 from a byte string.
  cast[ptr float32](data[offset].unsafeAddr)[]

proc componentSize(componentType: ComponentType): int =
  ## Returns the byte size of one accessor component.
  case componentType
  of ByteComponent, UnsignedByteComponent:
    1
  of ShortComponent, UnsignedShortComponent:
    2
  of UnsignedIntComponent, FloatComponent:
    4

proc readAccessorComponent(
  accessor: Accessor,
  data: string,
  offset: int
): float32 =
  ## Reads one accessor component, applying glTF integer normalization.
  case accessor.componentType
  of ByteComponent:
    let value = cast[int8](data[offset])
    if accessor.normalized:
      max(value.float32 / 127.0'f32, -1.0'f32)
    else:
      value.float32
  of UnsignedByteComponent:
    let value = data.readUint8(offset)
    if accessor.normalized:
      value.float32 / 255.0'f32
    else:
      value.float32
  of ShortComponent:
    let value = cast[int16](data.readUint16(offset))
    if accessor.normalized:
      max(value.float32 / 32767.0'f32, -1.0'f32)
    else:
      value.float32
  of UnsignedShortComponent:
    let value = data.readUint16(offset)
    if accessor.normalized:
      value.float32 / 65535.0'f32
    else:
      value.float32
  of UnsignedIntComponent:
    data.readUint32(offset).float32
  of FloatComponent:
    readFloat32(data, offset)

proc readSparseIndices(
  accessor: Accessor,
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[int] =
  ## Reads the sparse index list for an accessor.
  if not accessor.sparse.used or accessor.sparse.count == 0:
    return
  let
    view = bufferViews[accessor.sparse.indices.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.sparse.indices.byteOffset
  result.setLen(accessor.sparse.count)
  case accessor.sparse.indices.componentType
  of UnsignedByteComponent:
    for i in 0 ..< result.len:
      result[i] = buffer.readUint8(start + i).int
  of UnsignedShortComponent:
    for i in 0 ..< result.len:
      result[i] = buffer.readUint16(start + i * 2).int
  of UnsignedIntComponent:
    for i in 0 ..< result.len:
      result[i] = buffer.readUint32(start + i * 4).int
  else:
    raise newException(
      GltfError,
      "Unsupported sparse index component type"
    )

proc readAccessorFloats(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[float32] =
  ## Reads scalar accessor data as float32 values.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    elemSize = accessor.componentType.componentSize()
    stride = if view.byteStride > 0: view.byteStride else: elemSize
  if accessor.kind != atSCALAR:
    raise newException(GltfError, "Unsupported scalar accessor kind")
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = readAccessorComponent(accessor, buffer, off)
  if accessor.sparse.used:
    let
      indices = readSparseIndices(accessor, bufferViews, buffers)
      sparseView = bufferViews[accessor.sparse.values.bufferView]
      sparseBuffer = buffers[sparseView.buffer]
      sparseStart = sparseView.byteOffset + accessor.sparse.values.byteOffset
      sparseStride = elemSize
    for i, dstIndex in indices:
      let off = sparseStart + i * sparseStride
      result[dstIndex] = readAccessorComponent(accessor, sparseBuffer, off)

proc readAccessorVec3(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Vec3] =
  ## Reads vec3 accessor data.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    componentStride = accessor.componentType.componentSize()
    elemSize = componentStride * 3
    stride = if view.byteStride > 0: view.byteStride else: elemSize
  if accessor.kind != atVEC3:
    raise newException(GltfError, "Unsupported vec3 accessor kind")
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = vec3(
      readAccessorComponent(accessor, buffer, off),
      readAccessorComponent(accessor, buffer, off + componentStride),
      readAccessorComponent(accessor, buffer, off + componentStride * 2)
    )
  if accessor.sparse.used:
    let
      indices = readSparseIndices(accessor, bufferViews, buffers)
      sparseView = bufferViews[accessor.sparse.values.bufferView]
      sparseBuffer = buffers[sparseView.buffer]
      sparseStart = sparseView.byteOffset + accessor.sparse.values.byteOffset
      sparseStride =
        if sparseView.byteStride > 0: sparseView.byteStride else: elemSize
    for i, dstIndex in indices:
      let off = sparseStart + i * sparseStride
      result[dstIndex] = vec3(
        readAccessorComponent(accessor, sparseBuffer, off),
        readAccessorComponent(
          accessor,
          sparseBuffer,
          off + componentStride
        ),
        readAccessorComponent(
          accessor,
          sparseBuffer,
          off + componentStride * 2
        )
      )

proc readAccessorQuat(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Quat] =
  ## Reads quaternion accessor data.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    elemSize =
      case accessor.componentType
      of FloatComponent:
        16
      of ByteComponent:
        4
      of ShortComponent:
        8
      else:
        0
    stride = if view.byteStride > 0: view.byteStride else: elemSize
  if accessor.kind != atVEC4:
    raise newException(GltfError, "Unsupported quaternion accessor kind")
  if elemSize == 0:
    raise newException(GltfError, "Unsupported quaternion component type")
  if accessor.componentType in {ByteComponent, ShortComponent} and
     not accessor.normalized:
    raise newException(
      GltfError,
      "Integer quaternion accessors must be normalized"
    )

  proc quatValue(data: string, off, component: int): float32 =
    case accessor.componentType
    of FloatComponent:
      return readFloat32(data, off + component * 4)
    of ByteComponent:
      let value = cast[int8](data[off + component])
      return max(value.float32 / 127.0'f32, -1.0'f32)
    of ShortComponent:
      let value = cast[int16](data.readUint16(off + component * 2))
      return max(value.float32 / 32767.0'f32, -1.0'f32)
    else:
      raise newException(GltfError, "Unsupported quaternion component type")

  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = quat(
      quatValue(buffer, off, 0),
      quatValue(buffer, off, 1),
      quatValue(buffer, off, 2),
      quatValue(buffer, off, 3)
    )
  if accessor.sparse.used:
    let
      indices = readSparseIndices(accessor, bufferViews, buffers)
      sparseView = bufferViews[accessor.sparse.values.bufferView]
      sparseBuffer = buffers[sparseView.buffer]
      sparseStart = sparseView.byteOffset + accessor.sparse.values.byteOffset
    for i, dstIndex in indices:
      let off = sparseStart + i * elemSize
      result[dstIndex] = quat(
        quatValue(sparseBuffer, off, 0),
        quatValue(sparseBuffer, off, 1),
        quatValue(sparseBuffer, off, 2),
        quatValue(sparseBuffer, off, 3)
      )

proc assertRaise(test: bool, msg: string) =
  ## Raises an exception when a glTF invariant is not met.
  if not test:
    raise newException(GltfError, msg)

type
  MeshInstance = object
    pos: Vec3
    rot: Quat
    scale: Vec3

proc validateInstanceAccessor(
  accessorIdx: int,
  accessors: seq[Accessor],
  semantic: string,
  kind: AccessorKind,
  componentTypes: openArray[ComponentType],
  expectedCount: int
): int =
  ## Checks one EXT_mesh_gpu_instancing transform accessor.
  assertRaise(
    accessorIdx >= 0 and accessorIdx < accessors.len,
    &"Invalid EXT_mesh_gpu_instancing {semantic} accessor"
  )
  let accessor = accessors[accessorIdx]
  assertRaise(
    accessor.kind == kind,
    &"Unsupported EXT_mesh_gpu_instancing {semantic} accessor kind"
  )
  assertRaise(
    accessor.componentType in componentTypes,
    &"Unsupported EXT_mesh_gpu_instancing {semantic} component type"
  )
  if expectedCount >= 0:
    assertRaise(
      accessor.count == expectedCount,
      "EXT_mesh_gpu_instancing attribute counts must match"
    )
  return accessor.count

proc readMeshInstances(
  instancing: JsonNode,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[MeshInstance] =
  ## Reads EXT_mesh_gpu_instancing transforms.
  assertRaise(
    "attributes" in instancing,
    "EXT_mesh_gpu_instancing requires attributes"
  )
  let attributes = instancing["attributes"]
  var
    count = -1
    translations: seq[Vec3]
    rotations: seq[Quat]
    scales: seq[Vec3]

  if "TRANSLATION" in attributes:
    let accessorIdx = attributes["TRANSLATION"].getInt()
    count = validateInstanceAccessor(
      accessorIdx,
      accessors,
      "TRANSLATION",
      atVEC3,
      [FloatComponent],
      count
    )
    translations = readAccessorVec3(
      accessorIdx,
      accessors,
      bufferViews,
      buffers
    )

  if "ROTATION" in attributes:
    let accessorIdx = attributes["ROTATION"].getInt()
    count = validateInstanceAccessor(
      accessorIdx,
      accessors,
      "ROTATION",
      atVEC4,
      [FloatComponent, ByteComponent, ShortComponent],
      count
    )
    rotations = readAccessorQuat(
      accessorIdx,
      accessors,
      bufferViews,
      buffers
    )

  if "SCALE" in attributes:
    let accessorIdx = attributes["SCALE"].getInt()
    count = validateInstanceAccessor(
      accessorIdx,
      accessors,
      "SCALE",
      atVEC3,
      [FloatComponent],
      count
    )
    scales = readAccessorVec3(
      accessorIdx,
      accessors,
      bufferViews,
      buffers
    )

  assertRaise(
    count >= 0,
    "EXT_mesh_gpu_instancing requires at least one transform attribute"
  )

  result.setLen(count)
  for i in 0 ..< count:
    result[i].pos =
      if translations.len > 0:
        translations[i]
      else:
        vec3(0, 0, 0)
    result[i].rot =
      if rotations.len > 0:
        rotations[i]
      else:
        quat(0, 0, 0, 1)
    result[i].scale =
      if scales.len > 0:
        scales[i]
      else:
        vec3(1, 1, 1)

proc accessorComponentCount(kind: AccessorKind): int =
  ## Returns the number of components in one accessor element.
  case kind
  of atSCALAR:
    1
  of atVEC2:
    2
  of atVEC3:
    3
  of atVEC4:
    4
  of atMAT2:
    4
  of atMAT3:
    9
  of atMAT4:
    16

proc dracoAttributeId(draco: DracoInfo, name: string): int =
  ## Returns a Draco unique attribute id by glTF semantic name.
  for attr in draco.attributes:
    if attr.name == name:
      return attr.id
  raise newException(
    GltfError,
    &"Missing KHR_draco_mesh_compression attribute {name}"
  )

proc addDracoSpec(
  specs: var seq[DracoDecodeAttribute],
  draco: DracoInfo,
  accessors: seq[Accessor],
  name: string,
  accessorIdx: int
) =
  ## Adds one Draco decode request from a glTF accessor reference.
  if accessorIdx < 0:
    return
  let accessor = accessors[accessorIdx]
  specs.add(DracoDecodeAttribute(
    name: name,
    id: draco.dracoAttributeId(name),
    componentType: accessor.componentType
  ))

proc dracoSpecs(
  primInfo: PrimitiveInfo,
  accessors: seq[Accessor]
): seq[DracoDecodeAttribute] =
  ## Builds Draco decode requests for one compressed primitive.
  result.addDracoSpec(
    primInfo.draco,
    accessors,
    "POSITION",
    primInfo.attributes.position
  )
  result.addDracoSpec(
    primInfo.draco,
    accessors,
    "NORMAL",
    primInfo.attributes.normal
  )
  result.addDracoSpec(
    primInfo.draco,
    accessors,
    "TANGENT",
    primInfo.attributes.tangent
  )
  result.addDracoSpec(
    primInfo.draco,
    accessors,
    "COLOR_0",
    primInfo.attributes.color0
  )
  result.addDracoSpec(
    primInfo.draco,
    accessors,
    "TEXCOORD_0",
    primInfo.attributes.texcoord0
  )
  result.addDracoSpec(
    primInfo.draco,
    accessors,
    "TEXCOORD_1",
    primInfo.attributes.texcoord1
  )
  result.addDracoSpec(
    primInfo.draco,
    accessors,
    "JOINTS_0",
    primInfo.attributes.joints0
  )
  result.addDracoSpec(
    primInfo.draco,
    accessors,
    "WEIGHTS_0",
    primInfo.attributes.weights0
  )

proc clearDracoSourceAccessors(primInfo: var PrimitiveInfo) =
  ## Clears compressed accessor ids so uncompressed readers are skipped.
  primInfo.indices = -1
  primInfo.attributes.position = -1
  primInfo.attributes.normal = -1
  primInfo.attributes.tangent = -1
  primInfo.attributes.color0 = -1
  primInfo.attributes.texcoord0 = -1
  primInfo.attributes.texcoord1 = -1
  primInfo.attributes.joints0 = -1
  primInfo.attributes.weights0 = -1

proc dracoAttribute(
  decoded: DracoDecodeResult,
  name: string
): DracoAttributeData =
  ## Returns a decoded Draco attribute by glTF semantic name.
  for attr in decoded.attributes:
    if attr.name == name:
      return attr
  raise newException(GltfError, &"Decoded Draco attribute {name} is missing")

proc dracoFloatValue(
  attr: DracoAttributeData,
  index: int
): float32 =
  ## Reads one decoded Draco component as a float32.
  let offset = index * attr.componentType.componentSize()
  case attr.componentType
  of ByteComponent:
    cast[int8](attr.data[offset]).float32
  of UnsignedByteComponent:
    attr.data.readUint8(offset).float32
  of ShortComponent:
    cast[int16](attr.data.readUint16(offset)).float32
  of UnsignedShortComponent:
    attr.data.readUint16(offset).float32
  of UnsignedIntComponent:
    attr.data.readUint32(offset).float32
  of FloatComponent:
    readFloat32(attr.data, offset)

proc dracoRawUint(
  attr: DracoAttributeData,
  index: int
): uint32 =
  ## Reads one decoded Draco component as an unsigned integer.
  let offset = index * attr.componentType.componentSize()
  case attr.componentType
  of ByteComponent:
    cast[int8](attr.data[offset]).uint32
  of UnsignedByteComponent:
    attr.data.readUint8(offset).uint32
  of ShortComponent:
    cast[int16](attr.data.readUint16(offset)).uint32
  of UnsignedShortComponent:
    attr.data.readUint16(offset).uint32
  of UnsignedIntComponent:
    attr.data.readUint32(offset)
  of FloatComponent:
    readFloat32(attr.data, offset).uint32

proc dracoNormalizedValue(
  accessor: Accessor,
  attr: DracoAttributeData,
  index: int
): float32 =
  ## Reads one decoded Draco component with glTF normalization applied.
  let value = dracoFloatValue(attr, index)
  if not accessor.normalized:
    return value
  case accessor.componentType
  of ByteComponent:
    max(value / 127.0'f, -1.0'f)
  of UnsignedByteComponent:
    value / 255.0'f
  of ShortComponent:
    max(value / 32767.0'f, -1.0'f)
  of UnsignedShortComponent:
    value / 65535.0'f
  of UnsignedIntComponent:
    value / 4294967295.0'f
  of FloatComponent:
    value

proc byteColor(value: float32): uint8 =
  ## Converts a color component to an 8-bit channel.
  if value <= 0:
    return 0
  if value >= 255:
    return 255
  value.uint8

proc dracoColorByte(
  accessor: Accessor,
  attr: DracoAttributeData,
  index: int
): uint8 =
  ## Reads one decoded Draco color component as an 8-bit channel.
  let value = dracoNormalizedValue(accessor, attr, index)
  if accessor.normalized or accessor.componentType == FloatComponent:
    return byteColor(value * 255.0'f)
  if accessor.componentType == UnsignedShortComponent:
    return byteColor(value / 257.0'f)
  byteColor(value)

proc assertDracoAttribute(
  accessor: Accessor,
  attr: DracoAttributeData,
  componentCount: int
) =
  ## Checks a decoded Draco attribute against its accessor metadata.
  assertRaise(
    attr.componentCount == componentCount,
    &"Invalid Draco component count for {attr.name}"
  )
  assertRaise(
    attr.data.len == accessor.count * componentCount *
      attr.componentType.componentSize(),
    &"Invalid Draco data length for {attr.name}"
  )

proc readDracoVec2(
  decoded: DracoDecodeResult,
  accessors: seq[Accessor],
  name: string,
  accessorIdx: int
): seq[Vec2] =
  ## Reads a decoded Draco vec2 attribute.
  let
    accessor = accessors[accessorIdx]
    attr = decoded.dracoAttribute(name)
  assertRaise accessor.kind == atVEC2, &"Unsupported {name} kind"
  assertDracoAttribute(accessor, attr, 2)
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    result[i] = vec2(
      dracoNormalizedValue(accessor, attr, i * 2 + 0),
      dracoNormalizedValue(accessor, attr, i * 2 + 1)
    )

proc readDracoVec3(
  decoded: DracoDecodeResult,
  accessors: seq[Accessor],
  name: string,
  accessorIdx: int
): seq[Vec3] =
  ## Reads a decoded Draco vec3 attribute.
  let
    accessor = accessors[accessorIdx]
    attr = decoded.dracoAttribute(name)
  assertRaise accessor.kind == atVEC3, &"Unsupported {name} kind"
  assertDracoAttribute(accessor, attr, 3)
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    result[i] = vec3(
      dracoNormalizedValue(accessor, attr, i * 3 + 0),
      dracoNormalizedValue(accessor, attr, i * 3 + 1),
      dracoNormalizedValue(accessor, attr, i * 3 + 2)
    )

proc readDracoVec4(
  decoded: DracoDecodeResult,
  accessors: seq[Accessor],
  name: string,
  accessorIdx: int
): seq[Vec4] =
  ## Reads a decoded Draco vec4 attribute.
  let
    accessor = accessors[accessorIdx]
    attr = decoded.dracoAttribute(name)
  assertRaise accessor.kind == atVEC4, &"Unsupported {name} kind"
  assertDracoAttribute(accessor, attr, 4)
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    result[i] = vec4(
      dracoNormalizedValue(accessor, attr, i * 4 + 0),
      dracoNormalizedValue(accessor, attr, i * 4 + 1),
      dracoNormalizedValue(accessor, attr, i * 4 + 2),
      dracoNormalizedValue(accessor, attr, i * 4 + 3)
    )

proc readDracoColors(
  decoded: DracoDecodeResult,
  accessors: seq[Accessor],
  accessorIdx: int
): seq[ColorRGBX] =
  ## Reads a decoded Draco COLOR_0 attribute.
  let
    accessor = accessors[accessorIdx]
    attr = decoded.dracoAttribute("COLOR_0")
    componentCount = accessor.kind.accessorComponentCount()
  assertRaise(
    accessor.kind in {atVEC3, atVEC4},
    "Unsupported COLOR_0 kind"
  )
  assertDracoAttribute(accessor, attr, componentCount)
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let base = i * componentCount
    result[i] = rgbx(
      dracoColorByte(accessor, attr, base + 0),
      dracoColorByte(accessor, attr, base + 1),
      dracoColorByte(accessor, attr, base + 2),
      if componentCount == 4:
        dracoColorByte(accessor, attr, base + 3)
      else:
        255
    )

proc readDracoJointIds(
  decoded: DracoDecodeResult,
  accessors: seq[Accessor],
  accessorIdx: int
): seq[JointIds] =
  ## Reads a decoded Draco JOINTS_0 attribute.
  let
    accessor = accessors[accessorIdx]
    attr = decoded.dracoAttribute("JOINTS_0")
  assertRaise accessor.kind == atVEC4, "Unsupported JOINTS_0 kind"
  assertDracoAttribute(accessor, attr, 4)
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    result[i] = [
      dracoRawUint(attr, i * 4 + 0).uint16,
      dracoRawUint(attr, i * 4 + 1).uint16,
      dracoRawUint(attr, i * 4 + 2).uint16,
      dracoRawUint(attr, i * 4 + 3).uint16
    ]

proc readDracoWeights(
  decoded: DracoDecodeResult,
  accessors: seq[Accessor],
  accessorIdx: int
): seq[Vec4] =
  ## Reads a decoded Draco WEIGHTS_0 attribute.
  let
    accessor = accessors[accessorIdx]
    attr = decoded.dracoAttribute("WEIGHTS_0")
  assertRaise accessor.kind == atVEC4, "Unsupported WEIGHTS_0 kind"
  assertDracoAttribute(accessor, attr, 4)
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    result[i] = vec4(
      dracoNormalizedValue(accessor, attr, i * 4 + 0),
      dracoNormalizedValue(accessor, attr, i * 4 + 1),
      dracoNormalizedValue(accessor, attr, i * 4 + 2),
      dracoNormalizedValue(accessor, attr, i * 4 + 3)
    )

proc readDracoIndices(
  primitive: Primitive,
  decoded: DracoDecodeResult,
  accessors: seq[Accessor],
  accessorIdx: int
) =
  ## Reads decoded Draco triangle indices into a runtime primitive.
  if decoded.indices.len == 0:
    return
  let componentType =
    if accessorIdx >= 0:
      accessors[accessorIdx].componentType
    else:
      UnsignedIntComponent
  case componentType
  of UnsignedByteComponent, UnsignedShortComponent:
    primitive.indices16.setLen(decoded.indices.len)
    for i, value in decoded.indices:
      assertRaise value <= uint16.high.uint32, "Draco index exceeds uint16"
      primitive.indices16[i] = value.uint16
  of UnsignedIntComponent:
    primitive.indices32 = decoded.indices
  else:
    raise newException(
      GltfError,
      "Invalid Draco index component type: " & $componentType.int
    )

proc readDracoPrimitive(
  primitive: Primitive,
  primInfo: PrimitiveInfo,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
) =
  ## Reads one KHR_draco_mesh_compression primitive.
  let
    view = bufferViews[primInfo.draco.bufferView]
    buffer = buffers[view.buffer]
    payload = buffer[view.byteOffset ..< view.byteOffset + view.byteLength]
    decoded = decodeDraco(payload, dracoSpecs(primInfo, accessors))

  primitive.readDracoIndices(decoded, accessors, primInfo.indices)
  if primInfo.attributes.position >= 0:
    primitive.points = readDracoVec3(
      decoded,
      accessors,
      "POSITION",
      primInfo.attributes.position
    )
  if primInfo.attributes.normal >= 0:
    primitive.normals = readDracoVec3(
      decoded,
      accessors,
      "NORMAL",
      primInfo.attributes.normal
    )
  if primInfo.attributes.tangent >= 0:
    primitive.tangents = readDracoVec4(
      decoded,
      accessors,
      "TANGENT",
      primInfo.attributes.tangent
    )
  if primInfo.attributes.color0 >= 0:
    primitive.colors = readDracoColors(
      decoded,
      accessors,
      primInfo.attributes.color0
    )
  if primInfo.attributes.texcoord0 >= 0:
    primitive.uvs = readDracoVec2(
      decoded,
      accessors,
      "TEXCOORD_0",
      primInfo.attributes.texcoord0
    )
  if primInfo.attributes.texcoord1 >= 0:
    primitive.uvs1 = readDracoVec2(
      decoded,
      accessors,
      "TEXCOORD_1",
      primInfo.attributes.texcoord1
    )
  if primInfo.attributes.joints0 >= 0:
    primitive.jointIds = readDracoJointIds(
      decoded,
      accessors,
      primInfo.attributes.joints0
    )
  if primInfo.attributes.weights0 >= 0:
    primitive.jointWeights = readDracoWeights(
      decoded,
      accessors,
      primInfo.attributes.weights0
    )

proc readWeightFrames(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string],
  weightCount: int
): seq[seq[float32]] =
  ## Reads morph target weights as frames of float arrays.
  if weightCount <= 0:
    return
  let values = readAccessorFloats(
    accessorIdx,
    accessors,
    bufferViews,
    buffers
  )
  assertRaise(
    values.len mod weightCount == 0,
    "Invalid morph weight frame data"
  )
  result.setLen(values.len div weightCount)
  for i in 0 ..< result.len:
    result[i].setLen(weightCount)
    for j in 0 ..< weightCount:
      result[i][j] = values[i * weightCount + j]

proc readAccessorVec2(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Vec2] =
  ## Reads vec2 accessor data.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    componentStride = accessor.componentType.componentSize()
    elemSize = componentStride * 2
    stride = if view.byteStride > 0: view.byteStride else: elemSize
  assertRaise accessor.kind == atVEC2, "Unsupported vec2 accessor kind"
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = vec2(
      readAccessorComponent(accessor, buffer, off),
      readAccessorComponent(accessor, buffer, off + componentStride)
    )
  if accessor.sparse.used:
    let
      indices = readSparseIndices(accessor, bufferViews, buffers)
      sparseView = bufferViews[accessor.sparse.values.bufferView]
      sparseBuffer = buffers[sparseView.buffer]
      sparseStart = sparseView.byteOffset + accessor.sparse.values.byteOffset
      sparseStride =
        if sparseView.byteStride > 0: sparseView.byteStride else: elemSize
    for i, dstIndex in indices:
      let off = sparseStart + i * sparseStride
      result[dstIndex] = vec2(
        readAccessorComponent(accessor, sparseBuffer, off),
        readAccessorComponent(accessor, sparseBuffer, off + componentStride)
      )

proc readAccessorVec4(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Vec4] =
  ## Reads vec4 accessor data.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    componentStride = accessor.componentType.componentSize()
    elemSize = componentStride * 4
    stride = if view.byteStride > 0: view.byteStride else: elemSize
  assertRaise accessor.kind == atVEC4, "Unsupported vec4 accessor kind"
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = vec4(
      readAccessorComponent(accessor, buffer, off),
      readAccessorComponent(accessor, buffer, off + componentStride),
      readAccessorComponent(accessor, buffer, off + componentStride * 2),
      readAccessorComponent(accessor, buffer, off + componentStride * 3)
    )
  if accessor.sparse.used:
    let
      indices = readSparseIndices(accessor, bufferViews, buffers)
      sparseView = bufferViews[accessor.sparse.values.bufferView]
      sparseBuffer = buffers[sparseView.buffer]
      sparseStart = sparseView.byteOffset + accessor.sparse.values.byteOffset
      sparseStride =
        if sparseView.byteStride > 0: sparseView.byteStride else: elemSize
    for i, dstIndex in indices:
      let off = sparseStart + i * sparseStride
      result[dstIndex] = vec4(
        readAccessorComponent(accessor, sparseBuffer, off),
        readAccessorComponent(accessor, sparseBuffer, off + componentStride),
        readAccessorComponent(
          accessor,
          sparseBuffer,
          off + componentStride * 2
        ),
        readAccessorComponent(
          accessor,
          sparseBuffer,
          off + componentStride * 3
        )
      )

proc readAccessorMat4(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Mat4] =
  ## Reads mat4 accessor data.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    stride = if view.byteStride > 0: view.byteStride else: 64
  assertRaise accessor.kind == atMAT4, "Unsupported mat4 accessor kind"
  assertRaise accessor.componentType == FloatComponent,
    "Unsupported mat4 component type"
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = mat4(
      readFloat32(buffer, off + 0),
      readFloat32(buffer, off + 4),
      readFloat32(buffer, off + 8),
      readFloat32(buffer, off + 12),
      readFloat32(buffer, off + 16),
      readFloat32(buffer, off + 20),
      readFloat32(buffer, off + 24),
      readFloat32(buffer, off + 28),
      readFloat32(buffer, off + 32),
      readFloat32(buffer, off + 36),
      readFloat32(buffer, off + 40),
      readFloat32(buffer, off + 44),
      readFloat32(buffer, off + 48),
      readFloat32(buffer, off + 52),
      readFloat32(buffer, off + 56),
      readFloat32(buffer, off + 60)
    )

proc readAccessorJointIds(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[JointIds] =
  ## Reads JOINTS_0 accessor data.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    elemSize =
      case accessor.componentType
      of UnsignedByteComponent:
        4
      of UnsignedShortComponent:
        8
      else:
        0
    stride = if view.byteStride > 0: view.byteStride else: elemSize
  assertRaise accessor.kind == atVEC4, "Unsupported JOINTS_0 kind"
  assertRaise elemSize > 0, "Unsupported JOINTS_0 component type"
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    case accessor.componentType
    of UnsignedByteComponent:
      result[i] = [
        buffer.readUint8(off + 0).uint16,
        buffer.readUint8(off + 1).uint16,
        buffer.readUint8(off + 2).uint16,
        buffer.readUint8(off + 3).uint16
      ]
    of UnsignedShortComponent:
      result[i] = [
        buffer.readUint16(off + 0),
        buffer.readUint16(off + 2),
        buffer.readUint16(off + 4),
        buffer.readUint16(off + 6)
      ]
    else:
      discard

proc normalizedValue(
  accessor: Accessor,
  value: uint32
): float32 =
  ## Converts an accessor component into a normalized float.
  if not accessor.normalized:
    return value.float32
  case accessor.componentType
  of UnsignedByteComponent:
    value.float32 / 255.0'f32
  of UnsignedShortComponent:
    value.float32 / 65535.0'f32
  of UnsignedIntComponent:
    value.float32 / 4294967295.0'f32
  else:
    value.float32

proc readAccessorWeights(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Vec4] =
  ## Reads WEIGHTS_0 accessor data.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    elemSize =
      case accessor.componentType
      of FloatComponent:
        16
      of UnsignedByteComponent:
        4
      of UnsignedShortComponent:
        8
      else:
        0
    stride = if view.byteStride > 0: view.byteStride else: elemSize
  assertRaise accessor.kind == atVEC4, "Unsupported WEIGHTS_0 kind"
  assertRaise elemSize > 0, "Unsupported WEIGHTS_0 component type"
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    case accessor.componentType
    of FloatComponent:
      result[i] = vec4(
        readFloat32(buffer, off + 0),
        readFloat32(buffer, off + 4),
        readFloat32(buffer, off + 8),
        readFloat32(buffer, off + 12)
      )
    of UnsignedByteComponent:
      result[i] = vec4(
        normalizedValue(accessor, buffer.readUint8(off + 0)),
        normalizedValue(accessor, buffer.readUint8(off + 1)),
        normalizedValue(accessor, buffer.readUint8(off + 2)),
        normalizedValue(accessor, buffer.readUint8(off + 3))
      )
    of UnsignedShortComponent:
      result[i] = vec4(
        normalizedValue(accessor, buffer.readUint16(off + 0)),
        normalizedValue(accessor, buffer.readUint16(off + 2)),
        normalizedValue(accessor, buffer.readUint16(off + 4)),
        normalizedValue(accessor, buffer.readUint16(off + 6))
      )
    else:
      discard

proc defaultMaterialTexture(): MaterialTexture =
  ## Returns a material texture with default transform values.
  MaterialTexture(
    index: -1,
    texCoord: 0,
    offset: vec2(0, 0),
    uvScale: vec2(1, 1),
    rotation: 0,
    scale: 1,
    strength: 1
  )

proc readTextureTransform(entry: JsonNode, texInfo: var MaterialTexture) =
  ## Reads core and KHR_texture_transform texture info.
  if "texCoord" in entry:
    texInfo.texCoord = entry["texCoord"].getInt()

  if "extensions" in entry and
    "KHR_texture_transform" in entry["extensions"]:
    let transform = entry["extensions"]["KHR_texture_transform"]
    if "offset" in transform:
      texInfo.offset = vec2(
        transform["offset"][0].getFloat().float32,
        transform["offset"][1].getFloat().float32
      )
    if "scale" in transform:
      texInfo.uvScale = vec2(
        transform["scale"][0].getFloat().float32,
        transform["scale"][1].getFloat().float32
      )
    if "rotation" in transform:
      texInfo.rotation = transform["rotation"].getFloat().float32
    if "texCoord" in transform:
      texInfo.texCoord = transform["texCoord"].getInt()

proc defaultRuntimeMaterial(): Material =
  ## Returns the glTF default material for runtime rendering.
  result = Material()
  result.baseColorSampler = defaultTextureSampler()
  result.metallicRoughnessSampler = defaultTextureSampler()
  result.normalSampler = defaultTextureSampler()
  result.occlusionSampler = defaultTextureSampler()
  result.emissiveSampler = defaultTextureSampler()

  result.baseColor = newImage(1, 1)
  result.baseColor.fill(rgbx(255, 255, 255, 255))
  result.baseColorPlaceholder = true
  result.baseColorFactor = color(1, 1, 1, 1)
  result.baseColorTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.metallicRoughness = newImage(1, 1)
  result.metallicRoughness.fill(rgbx(255, 255, 255, 255))
  result.metallicRoughnessPlaceholder = true
  result.metallicFactor = 1.0
  result.roughnessFactor = 1.0
  result.metallicRoughnessTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.normal = newImage(1, 1)
  result.normal.fill(rgbx(128, 128, 255, 255))
  result.normalPlaceholder = true
  result.hasNormalTexture = false
  result.normalScale = 1.0
  result.normalTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.occlusion = newImage(1, 1)
  result.occlusion.fill(rgbx(255, 255, 255, 255))
  result.occlusionPlaceholder = true
  result.occlusionStrength = 1.0
  result.occlusionTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.emissive = newImage(1, 1)
  result.emissive.fill(rgbx(255, 255, 255, 255))
  result.emissivePlaceholder = true
  result.emissiveFactor = color(0, 0, 0, 1)
  result.emissiveStrength = 1
  result.emissiveTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.alphaMode = OpaqueAlphaMode
  result.alphaCutoff = -1.0
  result.doubleSided = false
  result.transmissionFactor = 0.0
  result.diffuseTransmissionColorFactor = vec3(1)
  result.diffuseTransmissionSampler = defaultTextureSampler()
  result.diffuseTransmissionColorSampler = defaultTextureSampler()
  result.diffuseTransmissionTransform = TextureTransform(scale: vec2(1))
  result.diffuseTransmissionColorTransform = TextureTransform(scale: vec2(1))
  result.anisotropySampler = defaultTextureSampler()
  result.anisotropyTransform = TextureTransform(scale: vec2(1))
  result.sheenColorSampler = defaultTextureSampler()
  result.sheenRoughnessSampler = defaultTextureSampler()
  result.sheenColorTransform = TextureTransform(scale: vec2(1))
  result.sheenRoughnessTransform = TextureTransform(scale: vec2(1))
  result.diffuseFactor = color(1, 1, 1, 1)
  result.specularGlossinessFactor = vec3(1)
  result.glossinessFactor = 1
  result.diffuseSampler = defaultTextureSampler()
  result.specularGlossinessSampler = defaultTextureSampler()
  result.diffuseTransform = TextureTransform(scale: vec2(1))
  result.specularGlossinessTransform = TextureTransform(scale: vec2(1))
  result.specularFactor = 1
  result.specularColorFactor = vec3(1)
  result.specularSampler = defaultTextureSampler()
  result.specularColorSampler = defaultTextureSampler()
  result.specularTransform = TextureTransform(scale: vec2(1))
  result.specularColorTransform = TextureTransform(scale: vec2(1))
  result.iridescenceIor = 1.3
  result.iridescenceThicknessMinimum = 100
  result.iridescenceThicknessMaximum = 400
  result.iridescenceSampler = defaultTextureSampler()
  result.iridescenceThicknessSampler = defaultTextureSampler()
  result.iridescenceTransform = TextureTransform(scale: vec2(1))
  result.iridescenceThicknessTransform = TextureTransform(scale: vec2(1))
  result.clearcoatNormalScale = 1
  result.clearcoatSampler = defaultTextureSampler()
  result.clearcoatRoughnessSampler = defaultTextureSampler()
  result.clearcoatNormalSampler = defaultTextureSampler()
  result.clearcoatTransform = TextureTransform(scale: vec2(1))
  result.clearcoatRoughnessTransform = TextureTransform(scale: vec2(1))
  result.clearcoatNormalTransform = TextureTransform(scale: vec2(1))
  result.ior = 1.5
  result.attenuationColor = vec3(1)
  result.transmissionSampler = defaultTextureSampler()
  result.thicknessSampler = defaultTextureSampler()
  result.transmissionTransform = TextureTransform(scale: vec2(1))
  result.thicknessTransform = TextureTransform(scale: vec2(1))

proc validateMeshAttribute(accessor: Accessor, semantic: string) =
  ## Checks core and KHR_mesh_quantization vertex attribute layouts.
  case semantic
  of "POSITION":
    assertRaise accessor.kind == atVEC3, "Unsupported position kind"
    assertRaise accessor.componentType in {
      FloatComponent,
      ByteComponent,
      UnsignedByteComponent,
      ShortComponent,
      UnsignedShortComponent,
      UnsignedIntComponent
    }, "Unsupported position component type"
  of "NORMAL":
    assertRaise accessor.kind == atVEC3, "Unsupported normal kind"
    assertRaise accessor.componentType in {
      FloatComponent,
      ByteComponent,
      ShortComponent
    }, "Unsupported normal component type"
    assertRaise accessor.componentType == FloatComponent or accessor.normalized,
      "Integer normal accessors must be normalized"
  of "TANGENT":
    assertRaise accessor.kind == atVEC4, "Unsupported tangent kind"
    assertRaise accessor.componentType in {
      FloatComponent,
      ByteComponent,
      ShortComponent
    }, "Unsupported tangent component type"
    assertRaise accessor.componentType == FloatComponent or accessor.normalized,
      "Integer tangent accessors must be normalized"
  of "TEXCOORD":
    assertRaise accessor.kind == atVEC2, "Unsupported texture coordinate kind"
    assertRaise accessor.componentType in {
      FloatComponent,
      ByteComponent,
      UnsignedByteComponent,
      ShortComponent,
      UnsignedShortComponent
    }, "Unsupported texture coordinate component type"
  else:
    raise newException(GltfError, "Unsupported mesh attribute " & semantic)

proc validateMorphAttribute(accessor: Accessor, semantic: string) =
  ## Checks core and KHR_mesh_quantization morph target layouts.
  assertRaise accessor.kind == atVEC3,
    "Unsupported morph " & semantic.toLowerAscii() & " kind"
  assertRaise accessor.componentType in {
    FloatComponent,
    ByteComponent,
    ShortComponent
  }, "Unsupported morph " & semantic.toLowerAscii() & " component type"
  if semantic in ["NORMAL", "TANGENT"]:
    assertRaise accessor.componentType == FloatComponent or accessor.normalized,
      "Integer morph " & semantic.toLowerAscii() &
      " accessors must be normalized"

proc parseInterpolation(name: string): AnimInterpolation =
  ## Converts a glTF interpolation name into a runtime enum.
  case name
  of "STEP":
    aiStep
  of "CUBICSPLINE":
    aiCubicSpline
  else:
    aiLinear

proc splitCubicVec2(channel: var AnimationChannel) =
  let triplets = channel.valuesVec2
  channel.valuesVec2.setLen(channel.times.len)
  channel.inTangentsVec2.setLen(channel.times.len)
  channel.outTangentsVec2.setLen(channel.times.len)
  for i in 0 ..< channel.times.len:
    channel.inTangentsVec2[i] = triplets[i * 3]
    channel.valuesVec2[i] = triplets[i * 3 + 1]
    channel.outTangentsVec2[i] = triplets[i * 3 + 2]

proc splitCubicVec3(channel: var AnimationChannel) =
  ## Splits vec3 cubic spline triplets into tangents and values.
  let triplets = channel.valuesVec3
  channel.valuesVec3.setLen(channel.times.len)
  channel.inTangentsVec3.setLen(channel.times.len)
  channel.outTangentsVec3.setLen(channel.times.len)
  for i in 0 ..< channel.times.len:
    channel.inTangentsVec3[i] = triplets[i * 3]
    channel.valuesVec3[i] = triplets[i * 3 + 1]
    channel.outTangentsVec3[i] = triplets[i * 3 + 2]

proc splitCubicVec4(channel: var AnimationChannel) =
  ## Splits vec4 cubic spline triplets without quaternion normalization.
  let triplets = channel.valuesVec4
  channel.valuesVec4.setLen(channel.times.len)
  channel.inTangentsVec4.setLen(channel.times.len)
  channel.outTangentsVec4.setLen(channel.times.len)
  for i in 0 ..< channel.times.len:
    channel.inTangentsVec4[i] = triplets[i * 3]
    channel.valuesVec4[i] = triplets[i * 3 + 1]
    channel.outTangentsVec4[i] = triplets[i * 3 + 2]

proc splitCubicQuat(channel: var AnimationChannel) =
  ## Splits quaternion cubic spline triplets into tangents and values.
  let triplets = channel.valuesQuat
  channel.valuesQuat.setLen(channel.times.len)
  channel.inTangentsQuat.setLen(channel.times.len)
  channel.outTangentsQuat.setLen(channel.times.len)
  for i in 0 ..< channel.times.len:
    channel.inTangentsQuat[i] = triplets[i * 3]
    channel.valuesQuat[i] = triplets[i * 3 + 1].normalize()
    channel.outTangentsQuat[i] = triplets[i * 3 + 2]

proc splitCubicFloat(channel: var AnimationChannel) =
  ## Splits scalar cubic spline triplets into tangents and values.
  let triplets = channel.valuesFloat
  channel.valuesFloat.setLen(channel.times.len)
  channel.inTangentsFloat.setLen(channel.times.len)
  channel.outTangentsFloat.setLen(channel.times.len)
  for i in 0 ..< channel.times.len:
    channel.inTangentsFloat[i] = triplets[i * 3]
    channel.valuesFloat[i] = triplets[i * 3 + 1]
    channel.outTangentsFloat[i] = triplets[i * 3 + 2]

proc loadPrimitive(
  primitiveIndex: int,
  primitiveDefs: seq[PrimitiveInfo],
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string],
  images: seq[Image],
  imageKtx2Data: seq[string],
  imageNames: seq[string],
  textures: seq[Texture],
  samplers: seq[Sampler],
  materials: seq[MaterialInfo]
): Primitive =
  ## Loads one glTF primitive into a runtime primitive.
  proc getTextureSampler(textureIndex: int): TextureSampler =
    result = defaultTextureSampler()
    if textureIndex < 0 or textureIndex >= textures.len:
      return
    let samplerIndex = textures[textureIndex].sampler
    if samplerIndex < 0 or samplerIndex >= samplers.len:
      return
    let sampler = samplers[samplerIndex]
    result.magFilter = sampler.magFilter
    result.minFilter = sampler.minFilter
    result.wrapS = sampler.wrapS
    result.wrapT = sampler.wrapT

  var primInfo = primitiveDefs[primitiveIndex]
  result = Primitive(mode: primInfo.mode)
  result.material = defaultRuntimeMaterial()
  if primInfo.material >= 0:
    let material = materials[primInfo.material]
    result.material.unlit = material.unlit

    let pbr = material.pbrMetallicRoughness
    if pbr.baseColorTexture.index >= 0:
      let imageIndex = textures[pbr.baseColorTexture.index].source
      result.material.baseColor = images[imageIndex]
      result.material.baseColorPlaceholder = false
      result.material.baseColorKtx2 = imageKtx2Data[imageIndex]
      result.material.baseColorName = imageNames[imageIndex]
      result.material.baseColorSampler =
        getTextureSampler(pbr.baseColorTexture.index)
    else:
      result.material.baseColor = newImage(1, 1)
      result.material.baseColor.fill(rgbx(255, 255, 255, 255))
      result.material.baseColorPlaceholder = true
    result.material.baseColorTransform = TextureTransform(
      texCoord: pbr.baseColorTexture.texCoord,
      offset: pbr.baseColorTexture.offset,
      scale: pbr.baseColorTexture.uvScale,
      rotation: pbr.baseColorTexture.rotation
    )
    result.material.baseColorFactor = pbr.baseColorFactor

    if pbr.metallicRoughnessTexture.index >= 0:
      let imageIndex = textures[pbr.metallicRoughnessTexture.index].source
      result.material.metallicRoughness = images[imageIndex]
      result.material.metallicRoughnessPlaceholder = false
      result.material.metallicRoughnessKtx2 = imageKtx2Data[imageIndex]
      result.material.metallicRoughnessName = imageNames[imageIndex]
      result.material.metallicRoughnessSampler =
        getTextureSampler(pbr.metallicRoughnessTexture.index)
    else:
      result.material.metallicRoughness = newImage(1, 1)
      result.material.metallicRoughness.fill(rgbx(255, 255, 255, 255))
      result.material.metallicRoughnessPlaceholder = true
    result.material.metallicRoughnessTransform = TextureTransform(
      texCoord: pbr.metallicRoughnessTexture.texCoord,
      offset: pbr.metallicRoughnessTexture.offset,
      scale: pbr.metallicRoughnessTexture.uvScale,
      rotation: pbr.metallicRoughnessTexture.rotation
    )
    result.material.metallicFactor = pbr.metallicFactor
    result.material.roughnessFactor = pbr.roughnessFactor

    if material.normalTexture.index >= 0:
      let imageIndex = textures[material.normalTexture.index].source
      result.material.normal = images[imageIndex]
      result.material.normalPlaceholder = false
      result.material.normalKtx2 = imageKtx2Data[imageIndex]
      result.material.normalName = imageNames[imageIndex]
      result.material.normalSampler =
        getTextureSampler(material.normalTexture.index)
      result.material.hasNormalTexture = true
      result.material.normalScale = material.normalTexture.scale
    else:
      result.material.normal = newImage(1, 1)
      result.material.normal.fill(rgbx(128, 128, 255, 255))
      result.material.normalPlaceholder = true
      result.material.hasNormalTexture = false
      result.material.normalScale = 1.0
    result.material.normalTransform = TextureTransform(
      texCoord: material.normalTexture.texCoord,
      offset: material.normalTexture.offset,
      scale: material.normalTexture.uvScale,
      rotation: material.normalTexture.rotation
    )

    if material.occlusionTexture.index >= 0:
      let imageIndex = textures[material.occlusionTexture.index].source
      result.material.occlusion = images[imageIndex]
      result.material.occlusionPlaceholder = false
      result.material.occlusionKtx2 = imageKtx2Data[imageIndex]
      result.material.occlusionName = imageNames[imageIndex]
      result.material.occlusionSampler =
        getTextureSampler(material.occlusionTexture.index)
    else:
      result.material.occlusion = newImage(1, 1)
      result.material.occlusion.fill(rgbx(255, 255, 255, 255))
      result.material.occlusionPlaceholder = true
    result.material.occlusionTransform = TextureTransform(
      texCoord: material.occlusionTexture.texCoord,
      offset: material.occlusionTexture.offset,
      scale: material.occlusionTexture.uvScale,
      rotation: material.occlusionTexture.rotation
    )
    result.material.occlusionStrength = material.occlusionTexture.strength

    if material.emissiveTexture.index >= 0:
      let imageIndex = textures[material.emissiveTexture.index].source
      result.material.emissive = images[imageIndex]
      result.material.emissivePlaceholder = false
      result.material.emissiveKtx2 = imageKtx2Data[imageIndex]
      result.material.emissiveName = imageNames[imageIndex]
      result.material.emissiveSampler =
        getTextureSampler(material.emissiveTexture.index)
    else:
      result.material.emissive = newImage(1, 1)
      result.material.emissive.fill(rgbx(255, 255, 255, 255))
      result.material.emissivePlaceholder = true
    result.material.emissiveTransform = TextureTransform(
      texCoord: material.emissiveTexture.texCoord,
      offset: material.emissiveTexture.offset,
      scale: material.emissiveTexture.uvScale,
      rotation: material.emissiveTexture.rotation
    )
    result.material.emissiveFactor = material.emissiveFactor
    result.material.hasEmissiveStrength = material.hasEmissiveStrength
    result.material.emissiveStrength = material.emissiveStrength
    result.material.transmissionFactor = material.transmissionFactor
    result.material.hasTransmission = material.hasTransmission
    result.material.hasVolume = material.hasVolume
    result.material.thicknessFactor = material.thicknessFactor
    result.material.attenuationColor = material.attenuationColor
    result.material.attenuationDistance = material.attenuationDistance
    result.material.ior = material.ior
    result.material.hasIor = material.hasIor
    template loadDataTexture(slot, info: untyped) =
      if info.index >= 0:
        let imageIndex = textures[info.index].source
        result.material.slot = images[imageIndex]
        result.material.`slot Ktx2` = imageKtx2Data[imageIndex]
        result.material.`slot Name` = imageNames[imageIndex]
        result.material.`slot Sampler` = getTextureSampler(info.index)
      result.material.`slot Transform` = TextureTransform(
        texCoord: info.texCoord, offset: info.offset,
        scale: info.uvScale, rotation: info.rotation)
    loadDataTexture(transmission, material.transmissionTexture)
    loadDataTexture(thickness, material.thicknessTexture)
    loadDataTexture(diffuseTransmission, material.diffuseTransmissionTexture)
    loadDataTexture(diffuseTransmissionColor, material.diffuseTransmissionColorTexture)
    loadDataTexture(anisotropy, material.anisotropyTexture)
    loadDataTexture(diffuse, material.diffuseTexture)
    loadDataTexture(specularGlossiness, material.specularGlossinessTexture)
    result.material.hasSpecularGlossiness = material.hasSpecularGlossiness
    result.material.diffuseFactor = material.diffuseFactor
    result.material.specularGlossinessFactor = material.specularGlossinessFactor
    result.material.glossinessFactor = material.glossinessFactor
    loadDataTexture(sheenColor, material.sheenColorTexture)
    loadDataTexture(sheenRoughness, material.sheenRoughnessTexture)
    result.material.hasSheen = material.hasSheen
    loadDataTexture(specular, material.specularTexture)
    loadDataTexture(specularColor, material.specularColorTexture)
    loadDataTexture(iridescence, material.iridescenceTexture)
    loadDataTexture(iridescenceThickness, material.iridescenceThicknessTexture)
    result.material.hasIridescence = material.hasIridescence
    result.material.iridescenceFactor = material.iridescenceFactor
    result.material.iridescenceIor = material.iridescenceIor
    result.material.iridescenceThicknessMinimum = material.iridescenceThicknessMinimum
    result.material.iridescenceThicknessMaximum = material.iridescenceThicknessMaximum
    loadDataTexture(clearcoat, material.clearcoatTexture)
    loadDataTexture(clearcoatRoughness, material.clearcoatRoughnessTexture)
    loadDataTexture(clearcoatNormal, material.clearcoatNormalTexture)
    result.material.hasClearcoat = material.hasClearcoat
    result.material.clearcoatFactor = material.clearcoatFactor
    result.material.clearcoatRoughnessFactor = material.clearcoatRoughnessFactor
    result.material.clearcoatNormalScale = material.clearcoatNormalTexture.scale
    result.material.hasAnisotropy = material.hasAnisotropy
    result.material.anisotropyStrength = material.anisotropyStrength
    result.material.anisotropyRotation = material.anisotropyRotation
    result.material.hasDiffuseTransmission = material.hasDiffuseTransmission
    result.material.diffuseTransmissionFactor = material.diffuseTransmissionFactor
    result.material.diffuseTransmissionColorFactor = material.diffuseTransmissionColorFactor
    result.material.hasSpecular = material.hasSpecular
    result.material.specularFactor = material.specularFactor
    result.material.specularColorFactor = material.specularColorFactor
    result.material.sheenColorFactor = material.sheenColorFactor
    result.material.sheenRoughnessFactor = material.sheenRoughnessFactor

    case material.alphaMode
    of "OPAQUE":
      result.material.alphaMode = OpaqueAlphaMode
      result.material.alphaCutoff = -1.0
    of "MASK":
      result.material.alphaMode = MaskAlphaMode
      result.material.alphaCutoff = material.alphaCutoff
    of "BLEND":
      result.material.alphaMode = BlendAlphaMode
      result.material.alphaCutoff = -1.0
    else:
      raise newException(GltfError, &"Invalid alpha mode {material.alphaMode}")

    result.material.doubleSided = material.doubleSided

  if primInfo.draco.used:
    result.readDracoPrimitive(
      primInfo,
      accessors,
      bufferViews,
      buffers
    )
    primInfo.clearDracoSourceAccessors()

  if primInfo.indices >= 0:
    let
      accessor = accessors[primInfo.indices]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    if accessor.componentType == UnsignedByteComponent:
      assertRaise accessor.kind == atSCALAR, "Unsupported index kind"
      assertRaise bufferView.byteStride == 0, "Unsupported index byteStride"
      result.indices16.setLen(accessor.count)
      for i in 0 ..< accessor.count:
        result.indices16[i] = buffer[start + i].uint8
    elif accessor.componentType == UnsignedShortComponent:
      assertRaise accessor.kind == atSCALAR, "Unsupported index kind"
      assertRaise bufferView.byteStride == 0, "Unsupported index byteStride"
      result.indices16.setLen(accessor.count)
      copyMem(result.indices16[0].addr, buffer[start].addr, accessor.count * 2)
    elif accessor.componentType == UnsignedIntComponent:
      assertRaise accessor.kind == atSCALAR, "Unsupported index kind"
      assertRaise bufferView.byteStride == 0, "Unsupported index byteStride"
      result.indices32.setLen(accessor.count)
      copyMem(result.indices32[0].addr, buffer[start].addr, accessor.count * 4)
    else:
      raise newException(
        GltfError,
        "Invalid index component type: " & $accessor.componentType.int
      )

  if primInfo.attributes.position >= 0:
    let accessor = accessors[primInfo.attributes.position]
    validateMeshAttribute(accessor, "POSITION")
    result.points = readAccessorVec3(
      primInfo.attributes.position,
      accessors,
      bufferViews,
      buffers
    )

  if primInfo.attributes.normal >= 0:
    validateMeshAttribute(
      accessors[primInfo.attributes.normal],
      "NORMAL"
    )
    result.normals = readAccessorVec3(
      primInfo.attributes.normal,
      accessors,
      bufferViews,
      buffers
    )

  if primInfo.attributes.tangent >= 0:
    validateMeshAttribute(
      accessors[primInfo.attributes.tangent],
      "TANGENT"
    )
    result.tangents = readAccessorVec4(
      primInfo.attributes.tangent,
      accessors,
      bufferViews,
      buffers
    )

  if primInfo.attributes.color0 >= 0:
    let
      accessor = accessors[primInfo.attributes.color0]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    if accessor.kind == atVEC4:
      if accessor.componentType == FloatComponent:
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 16
        for i in 0 ..< accessor.count:
          result.colors.add(rgba(
            (buffer.readFloat32(start + i * stride) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 4) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 8) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 12) * 255).uint8
          ).rgbx)
      elif accessor.componentType == UnsignedByteComponent:
        result.colors.setLen(accessor.count)
        if bufferView.byteStride == 0 or bufferView.byteStride == 4:
          copyMem(result.colors[0].addr, buffer[start].addr, accessor.count * 4)
        else:
          let stride = bufferView.byteStride
          for i in 0 ..< accessor.count:
            result.colors[i] = rgbx(
              buffer.readUint8(start + i * stride),
              buffer.readUint8(start + i * stride + 1),
              buffer.readUint8(start + i * stride + 2),
              buffer.readUint8(start + i * stride + 3)
            )
      elif accessor.componentType == UnsignedShortComponent:
        result.colors.setLen(accessor.count)
        let stride = if bufferView.byteStride == 0: 8 else: bufferView.byteStride
        for i in 0 ..< accessor.count:
          let base = start + i * stride
          # Normalize 16-bit components into the runtime's straight RGBA bytes.
          result.colors[i] = rgbx(
            (buffer.readUint16(base) div 257).uint8,
            (buffer.readUint16(base + 2) div 257).uint8,
            (buffer.readUint16(base + 4) div 257).uint8,
            (buffer.readUint16(base + 6) div 257).uint8
          )
      else:
        raise newException(
          GltfError,
          "Invalid color component type: " & $accessor.componentType.int
        )
    elif accessor.kind == atVEC3:
      if accessor.componentType == FloatComponent:
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 12
        for i in 0 ..< accessor.count:
          result.colors.add(rgbx(
            (buffer.readFloat32(start + i * stride) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 4) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 8) * 255).uint8,
            255
          ))
      elif accessor.componentType == UnsignedByteComponent:
        result.colors.setLen(accessor.count)
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 3
        for i in 0 ..< accessor.count:
          result.colors[i] = rgbx(
            buffer.readUint8(start + i * stride),
            buffer.readUint8(start + i * stride + 1),
            buffer.readUint8(start + i * stride + 2),
            255
          )
      elif accessor.componentType == UnsignedShortComponent:
        result.colors.setLen(accessor.count)
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 6
        for i in 0 ..< accessor.count:
          let base = start + i * stride
          let r = buffer.readUint16(base)
          let g = buffer.readUint16(base + 2)
          let b = buffer.readUint16(base + 4)
          result.colors[i] = rgbx(
            (r div 257).uint8,
            (g div 257).uint8,
            (b div 257).uint8,
            255
          )
    else:
      raise newException(
        GltfError,
        "Invalid color kind: " & $accessor.kind
      )

  if primInfo.attributes.texcoord0 >= 0:
    validateMeshAttribute(
      accessors[primInfo.attributes.texcoord0],
      "TEXCOORD"
    )
    result.uvs = readAccessorVec2(
      primInfo.attributes.texcoord0,
      accessors,
      bufferViews,
      buffers
    )

  if primInfo.attributes.texcoord1 >= 0:
    validateMeshAttribute(
      accessors[primInfo.attributes.texcoord1],
      "TEXCOORD"
    )
    result.uvs1 = readAccessorVec2(
      primInfo.attributes.texcoord1,
      accessors,
      bufferViews,
      buffers
    )

  if primInfo.attributes.joints0 >= 0:
    result.jointIds = readAccessorJointIds(
      primInfo.attributes.joints0,
      accessors,
      bufferViews,
      buffers
    )

  if primInfo.attributes.weights0 >= 0:
    result.jointWeights = readAccessorWeights(
      primInfo.attributes.weights0,
      accessors,
      bufferViews,
      buffers
    )

  for morphInfo in primInfo.morphTargets:
    var morphTarget = MorphTarget()
    if morphInfo.position >= 0:
      validateMorphAttribute(accessors[morphInfo.position], "POSITION")
      morphTarget.positionDeltas = readAccessorVec3(
        morphInfo.position,
        accessors,
        bufferViews,
        buffers
      )
    if morphInfo.normal >= 0:
      validateMorphAttribute(accessors[morphInfo.normal], "NORMAL")
      morphTarget.normalDeltas = readAccessorVec3(
        morphInfo.normal,
        accessors,
        bufferViews,
        buffers
      )
    if morphInfo.tangent >= 0:
      validateMorphAttribute(accessors[morphInfo.tangent], "TANGENT")
      morphTarget.tangentDeltas = readAccessorVec3(
        morphInfo.tangent,
        accessors,
        bufferViews,
        buffers
      )
    result.morphTargets.add(morphTarget)

  result.generateTangents()
  result.basePoints = result.points
  result.baseNormals = result.normals
  result.baseTangents = result.tangents

type
  LoadResult = object
    root: Node
    scenes: seq[Scene]
    sceneId: int
    cameras: seq[Camera]
    skins: seq[Skin]

proc loadModelJsonInternal(
  jsonRoot: JsonNode,
  modelDir: string,
  externalBuffers: seq[string]
): LoadResult =
  ## Loads a 3D model from a parsed glTF json tree.
  if "extensionsRequired" in jsonRoot:
    for extension in jsonRoot["extensionsRequired"]:
      if extension.getStr() notin SupportedExtensions:
        raise newException(
          GltfError,
          &"Unsupported extension required: {extension}"
        )

  var meshoptTargetBuffers: seq[int]
  if "bufferViews" in jsonRoot:
    for entry in jsonRoot["bufferViews"]:
      if "extensions" in entry and
        "EXT_meshopt_compression" in entry["extensions"]:
          let bufferIndex = entry["buffer"].getInt()
          if bufferIndex notin meshoptTargetBuffers:
            meshoptTargetBuffers.add(bufferIndex)

  var buffers: seq[string]
  var bufferIndex = 0
  for jsonBufferIndex in 0 ..< jsonRoot["buffers"].len:
    let entry = jsonRoot["buffers"][jsonBufferIndex]
    var data: string
    let declaredByteLength = entry["byteLength"].getInt()
    let explicitFallback =
      "extensions" in entry and
      "EXT_meshopt_compression" in entry["extensions"] and
      entry["extensions"]["EXT_meshopt_compression"]{"fallback"}.getBool()
    var hasData = true
    if explicitFallback:
      hasData = false
    elif "uri" in entry:
      let uri = entry["uri"].getStr()
      if uri.startsWith("data:application/"):
        data = decode(uri.split(',')[1])
      else:
        data = readFile(joinPath(modelDir, uri))
    elif bufferIndex < externalBuffers.len:
      data = externalBuffers[bufferIndex]
      inc bufferIndex
    elif jsonBufferIndex in meshoptTargetBuffers:
      hasData = false
    else:
      raise newException(GltfError, "Missing external buffer data")
    if hasData:
      assertRaise data.len >= declaredByteLength,
        "Buffer length is shorter than declared byteLength"
      if data.len > declaredByteLength:
        data = data[0 ..< declaredByteLength]
    buffers.add(data)

  var bufferViews: seq[BufferView]
  for entry in jsonRoot["bufferViews"]:
    var bufferView = BufferView()
    bufferView.buffer = entry["buffer"].getInt()
    bufferView.byteOffset = entry{"byteOffset"}.getInt()
    bufferView.byteLength = entry["byteLength"].getInt()
    bufferView.byteStride = entry{"byteStride"}.getInt()

    if "extensions" in entry and
      "EXT_meshopt_compression" in entry["extensions"]:
        let extension = entry["extensions"]["EXT_meshopt_compression"]
        let
          sourceBufferIndex = extension["buffer"].getInt()
          sourceOffset = extension{"byteOffset"}.getInt()
          sourceLength = extension["byteLength"].getInt()
          stride = extension["byteStride"].getInt()
          count = extension["count"].getInt()
          mode = extension["mode"].getStr()
          filter = extension{"filter"}.getStr()
        assertRaise(
          bufferView.byteStride == 0 or bufferView.byteStride == stride,
          "EXT_meshopt_compression byteStride does not match bufferView"
        )
        assertRaise(
          bufferView.byteLength == stride * count,
          "EXT_meshopt_compression output length does not match bufferView"
        )
        assertRaise(
          sourceBufferIndex >= 0 and sourceBufferIndex < buffers.len,
          "Invalid EXT_meshopt_compression source buffer"
        )
        let sourceBuffer = buffers[sourceBufferIndex]
        assertRaise(
          sourceOffset >= 0 and sourceLength >= 0 and
          sourceOffset + sourceLength <= sourceBuffer.len,
          "EXT_meshopt_compression source range exceeds buffer"
        )
        let decoded = decodeMeshopt(
          sourceBuffer[sourceOffset ..< sourceOffset + sourceLength],
          count,
          stride,
          mode,
          filter
        )
        buffers.add(decoded)
        bufferView.buffer = buffers.high
        bufferView.byteOffset = 0

    if "target" in entry:
      let target = entry["target"].getInt()
      if target notin @[GltfArrayBufferTarget, GltfElementArrayBufferTarget]:
        raise newException(GltfError, &"Invalid bufferView target {target}")

    bufferViews.add(bufferView)

  var accessors: seq[Accessor]
  for entry in jsonRoot["accessors"]:
    var accessor = Accessor()
    accessor.bufferView = -1
    if "bufferView" in entry:
      accessor.bufferView = entry["bufferView"].getInt()
    if "byteOffset" in entry:
      accessor.byteOffset = entry{"byteOffset"}.getInt()
    accessor.count = entry["count"].getInt()
    accessor.componentType = parseComponentType(entry["componentType"].getInt())
    accessor.normalized = entry{"normalized"}.getBool()
    if "sparse" in entry:
      let sparse = entry["sparse"]
      accessor.sparse.used = true
      accessor.sparse.count = sparse["count"].getInt()
      accessor.sparse.indices.bufferView =
        sparse["indices"]["bufferView"].getInt()
      accessor.sparse.indices.byteOffset =
        sparse["indices"]{"byteOffset"}.getInt()
      accessor.sparse.indices.componentType =
        parseComponentType(sparse["indices"]["componentType"].getInt())
      accessor.sparse.values.bufferView =
        sparse["values"]["bufferView"].getInt()
      accessor.sparse.values.byteOffset =
        sparse["values"]{"byteOffset"}.getInt()
    let accessorKind = entry["type"].getStr()
    case accessorKind
    of "SCALAR":
      accessor.kind = atSCALAR
    of "VEC2":
      accessor.kind = atVEC2
    of "VEC3":
      accessor.kind = atVEC3
    of "VEC4":
      accessor.kind = atVEC4
    of "MAT2":
      accessor.kind = atMAT2
    of "MAT3":
      accessor.kind = atMAT3
    of "MAT4":
      accessor.kind = atMAT4
    else:
      raise newException(
        GltfError,
        &"Invalid accessor type {accessorKind}"
      )
    accessors.add(accessor)

  var textures: seq[Texture]
  if "textures" in jsonRoot:
    for entry in jsonRoot["textures"]:
      var texture = Texture()
      texture.source = -1
      if "extensions" in entry:
        let extensions = entry["extensions"]
        if "KHR_texture_basisu" in extensions:
          texture.source = extensions["KHR_texture_basisu"]["source"].getInt()
        elif "EXT_texture_webp" in extensions:
          texture.source = extensions["EXT_texture_webp"]["source"].getInt()
      if texture.source < 0 and "source" in entry:
        texture.source = entry["source"].getInt()
      if texture.source < 0:
        raise newException(GltfError, "Texture is missing a source image")
      if "sampler" in entry:
        texture.sampler = entry["sampler"].getInt()
      else:
        texture.sampler = -1
      textures.add(texture)

  var images: seq[Image]
  var imageKtx2Data: seq[string]
  var imageNames: seq[string]
  if "images" in jsonRoot:
    for entry in jsonRoot["images"]:
      var
        image: Image
        imageName = entry{"name"}.getStr()
        ktx2Data: string
      if "uri" in entry:
        let uri = entry["uri"].getStr().decodeUriComponent()
        if imageName.len == 0:
          imageName = extractFilename(uri)
        if uri.startsWith("data:image/png") or
           uri.startsWith("data:image/jpeg") or
           uri.startsWith("data:image/webp"):
          image = decodeStraightAlphaImage(decode(uri.split(',')[1]))
        elif uri.startsWith("data:image/ktx2"):
          ktx2Data = decode(uri.split(',')[1])
        elif uri.endsWith(".png") or
             uri.endsWith(".jpg") or
             uri.endsWith(".jpeg") or
             uri.endsWith(".webp"):
          image = loadStraightAlphaImage(joinPath(modelDir, uri))
        elif uri.endsWith(".ktx2"):
          ktx2Data = readFile(joinPath(modelDir, uri))
        else:
          raise newException(GltfError, &"Unsupported file extension {uri}")
      elif "bufferView" in entry:
        let
          bufferViewIndex = entry["bufferView"].getInt()
          bv = bufferViews[bufferViewIndex]
          ib = buffers[bv.buffer]
          imageData = ib[bv.byteOffset ..< bv.byteOffset + bv.byteLength]
        let mimeType = entry{"mimeType"}.getStr()
        if mimeType == "image/ktx2":
          ktx2Data = imageData
        else:
          image = decodeStraightAlphaImage(imageData)
      else:
        raise newException(GltfError, "Unsupported image type")
      images.add(image)
      imageKtx2Data.add(ktx2Data)
      imageNames.add(imageName)

  var samplers: seq[Sampler]
  if "samplers" in jsonRoot:
    for entry in jsonRoot["samplers"]:
      var sampler = Sampler()
      if "magFilter" in entry:
        sampler.magFilter = parseTextureMagFilter(entry["magFilter"].getInt())
      else:
        sampler.magFilter = LinearMagFilter
      if "minFilter" in entry:
        sampler.minFilter = parseTextureMinFilter(entry["minFilter"].getInt())
      else:
        sampler.minFilter = LinearMipmapLinearMinFilter
      if "wrapS" in entry:
        sampler.wrapS = parseTextureWrap(entry["wrapS"].getInt())
      else:
        sampler.wrapS = RepeatWrap
      if "wrapT" in entry:
        sampler.wrapT = parseTextureWrap(entry["wrapT"].getInt())
      else:
        sampler.wrapT = RepeatWrap
      samplers.add(sampler)

  var materials: seq[MaterialInfo]
  if "materials" in jsonRoot:
    for entry in jsonRoot["materials"]:
      var material = MaterialInfo()
      material.pbrMetallicRoughness.baseColorTexture = defaultMaterialTexture()
      material.pbrMetallicRoughness.metallicRoughnessTexture =
        defaultMaterialTexture()
      material.normalTexture = defaultMaterialTexture()
      material.occlusionTexture = defaultMaterialTexture()
      material.emissiveTexture = defaultMaterialTexture()
      material.transmissionTexture = defaultMaterialTexture()
      material.thicknessTexture = defaultMaterialTexture()
      material.diffuseTransmissionTexture = defaultMaterialTexture()
      material.diffuseTransmissionColorTexture = defaultMaterialTexture()
      material.anisotropyTexture = defaultMaterialTexture()
      material.diffuseTexture = defaultMaterialTexture()
      material.specularGlossinessTexture = defaultMaterialTexture()
      material.diffuseFactor = color(1, 1, 1, 1)
      material.specularGlossinessFactor = vec3(1)
      material.glossinessFactor = 1
      material.sheenColorTexture = defaultMaterialTexture()
      material.sheenRoughnessTexture = defaultMaterialTexture()
      material.specularTexture = defaultMaterialTexture()
      material.specularColorTexture = defaultMaterialTexture()
      material.iridescenceTexture = defaultMaterialTexture()
      material.iridescenceThicknessTexture = defaultMaterialTexture()
      material.iridescenceIor = 1.3
      material.iridescenceThicknessMinimum = 100
      material.iridescenceThicknessMaximum = 400
      material.clearcoatTexture = defaultMaterialTexture()
      material.clearcoatRoughnessTexture = defaultMaterialTexture()
      material.clearcoatNormalTexture = defaultMaterialTexture()
      material.clearcoatNormalTexture.scale = 1
      if "name" in entry:
        material.name = entry["name"].getStr()

      if "pbrMetallicRoughness" in entry:
        let pbrMetallicRoughness = entry["pbrMetallicRoughness"]
        if "baseColorTexture" in pbrMetallicRoughness:
          let baseColorTexture = pbrMetallicRoughness["baseColorTexture"]
          material.pbrMetallicRoughness.baseColorTexture.index =
            baseColorTexture["index"].getInt()
          readTextureTransform(
            baseColorTexture,
            material.pbrMetallicRoughness.baseColorTexture
          )
        else:
          material.pbrMetallicRoughness.baseColorTexture.index = -1

        if "baseColorFactor" in pbrMetallicRoughness:
          let
            r = pbrMetallicRoughness["baseColorFactor"][0].getFloat()
            g = pbrMetallicRoughness["baseColorFactor"][1].getFloat()
            b = pbrMetallicRoughness["baseColorFactor"][2].getFloat()
            a = pbrMetallicRoughness["baseColorFactor"][3].getFloat()
          material.pbrMetallicRoughness.baseColorFactor = color(r, g, b, a)
        else:
          material.pbrMetallicRoughness.baseColorFactor = color(1, 1, 1, 1)

        if "metallicRoughnessTexture" in pbrMetallicRoughness:
          let metallicRoughnessTexture =
            pbrMetallicRoughness["metallicRoughnessTexture"]
          material.pbrMetallicRoughness.metallicRoughnessTexture.index =
            metallicRoughnessTexture["index"].getInt()
          readTextureTransform(
            metallicRoughnessTexture,
            material.pbrMetallicRoughness.metallicRoughnessTexture
          )
        else:
          material.pbrMetallicRoughness.metallicRoughnessTexture.index = -1

        if "metallicFactor" in pbrMetallicRoughness:
          material.pbrMetallicRoughness.metallicFactor =
            pbrMetallicRoughness["metallicFactor"].getFloat().float32
        else:
          material.pbrMetallicRoughness.metallicFactor = 1.0

        if "roughnessFactor" in pbrMetallicRoughness:
          material.pbrMetallicRoughness.roughnessFactor =
            pbrMetallicRoughness["roughnessFactor"].getFloat().float32
        else:
          material.pbrMetallicRoughness.roughnessFactor = 1.0
      else:
        material.pbrMetallicRoughness.baseColorTexture.index = -1
        material.pbrMetallicRoughness.metallicRoughnessTexture.index = -1
        material.pbrMetallicRoughness.baseColorFactor = color(1, 1, 1, 1)
        material.pbrMetallicRoughness.metallicFactor = 1.0
        material.pbrMetallicRoughness.roughnessFactor = 1.0

      if "normalTexture" in entry:
        let normalTexture = entry["normalTexture"]
        material.normalTexture.index = normalTexture["index"].getInt()
        readTextureTransform(normalTexture, material.normalTexture)
        if "scale" in normalTexture:
          material.normalTexture.scale =
            normalTexture["scale"].getFloat().float32
        else:
          material.normalTexture.scale = 1.0
      else:
        material.normalTexture.index = -1
        material.normalTexture.scale = 1.0

      if "occlusionTexture" in entry:
        let occlusionTexture = entry["occlusionTexture"]
        material.occlusionTexture.index = occlusionTexture["index"].getInt()
        readTextureTransform(occlusionTexture, material.occlusionTexture)
        if "strength" in occlusionTexture:
          material.occlusionTexture.strength =
            occlusionTexture["strength"].getFloat().float32
        else:
          material.occlusionTexture.strength = 1.0
      else:
        material.occlusionTexture.index = -1
        material.occlusionTexture.strength = 1.0

      if "emissiveTexture" in entry:
        let emissiveTexture = entry["emissiveTexture"]
        material.emissiveTexture.index = emissiveTexture["index"].getInt()
        readTextureTransform(emissiveTexture, material.emissiveTexture)
      else:
        material.emissiveTexture.index = -1

      if "emissiveFactor" in entry:
        let
          r = entry["emissiveFactor"][0].getFloat()
          g = entry["emissiveFactor"][1].getFloat()
          b = entry["emissiveFactor"][2].getFloat()
        material.emissiveFactor = color(r, g, b, 1)
      else:
        material.emissiveFactor = color(0, 0, 0, 1)

      if "alphaMode" in entry:
        material.alphaMode = entry["alphaMode"].getStr()
      else:
        material.alphaMode = "OPAQUE"

      if "alphaCutoff" in entry:
        material.alphaCutoff = entry["alphaCutoff"].getFloat().float32
      else:
        material.alphaCutoff = 0.5

      if "doubleSided" in entry:
        material.doubleSided = entry["doubleSided"].getBool()
      else:
        material.doubleSided = false

      material.transmissionFactor = 0
      material.emissiveStrength = 1
      material.diffuseTransmissionColorFactor = vec3(1)
      material.ior = 1.5
      material.attenuationColor = vec3(1)
      material.specularFactor = 1
      material.specularColorFactor = vec3(1)
      if "extensions" in entry:
        let extensions = entry["extensions"]
        if "KHR_materials_emissive_strength" in extensions:
          material.hasEmissiveStrength = true
          material.emissiveStrength = extensions["KHR_materials_emissive_strength"]{"emissiveStrength"}.getFloat(1).float32
        if "KHR_materials_pbrSpecularGlossiness" in extensions:
          let sg = extensions["KHR_materials_pbrSpecularGlossiness"]
          material.hasSpecularGlossiness = true
          material.glossinessFactor = sg{"glossinessFactor"}.getFloat(1).float32
          if "diffuseFactor" in sg:
            let c = sg["diffuseFactor"]
            material.diffuseFactor = color(c[0].getFloat(), c[1].getFloat(), c[2].getFloat(), c[3].getFloat())
          if "specularFactor" in sg:
            let c = sg["specularFactor"]
            material.specularGlossinessFactor = vec3(c[0].getFloat(), c[1].getFloat(), c[2].getFloat())
          template readSpecGlossTexture(slot: untyped) =
            if astToStr(slot) in sg:
              let texture = sg[astToStr(slot)]
              material.slot.index = texture["index"].getInt()
              readTextureTransform(texture, material.slot)
          readSpecGlossTexture(diffuseTexture)
          readSpecGlossTexture(specularGlossinessTexture)
        if "KHR_materials_specular" in extensions:
          let specular = extensions["KHR_materials_specular"]
          material.hasSpecular = true
          material.specularFactor = specular{"specularFactor"}.getFloat(1).float32
          if "specularColorFactor" in specular:
            let c = specular["specularColorFactor"]
            material.specularColorFactor = vec3(c[0].getFloat(), c[1].getFloat(), c[2].getFloat())
          template readSpecularTexture(slot: untyped) =
            if astToStr(slot) in specular:
              let texture = specular[astToStr(slot)]
              material.slot.index = texture["index"].getInt()
              readTextureTransform(texture, material.slot)
          readSpecularTexture(specularTexture)
          readSpecularTexture(specularColorTexture)
        if "KHR_materials_sheen" in extensions:
          let sheen = extensions["KHR_materials_sheen"]
          material.hasSheen = true
          material.sheenRoughnessFactor = sheen{"sheenRoughnessFactor"}.getFloat().float32
          if "sheenColorFactor" in sheen:
            let c = sheen["sheenColorFactor"]
            material.sheenColorFactor = vec3(c[0].getFloat(), c[1].getFloat(), c[2].getFloat())
          template readSheenTexture(slot: untyped) =
            if astToStr(slot) in sheen:
              let texture = sheen[astToStr(slot)]
              material.slot.index = texture["index"].getInt()
              readTextureTransform(texture, material.slot)
          readSheenTexture(sheenColorTexture)
          readSheenTexture(sheenRoughnessTexture)
        material.unlit = "KHR_materials_unlit" in extensions
        if "KHR_materials_iridescence" in extensions:
          let film = extensions["KHR_materials_iridescence"]
          material.hasIridescence = true
          material.iridescenceFactor = film{"iridescenceFactor"}.getFloat().float32
          material.iridescenceIor = film{"iridescenceIor"}.getFloat(1.3).float32
          material.iridescenceThicknessMinimum = film{"iridescenceThicknessMinimum"}.getFloat(100).float32
          material.iridescenceThicknessMaximum = film{"iridescenceThicknessMaximum"}.getFloat(400).float32
          template readFilmTexture(slot: untyped) =
            if astToStr(slot) in film:
              let texture = film[astToStr(slot)]
              material.slot.index = texture["index"].getInt()
              readTextureTransform(texture, material.slot)
          readFilmTexture(iridescenceTexture)
          readFilmTexture(iridescenceThicknessTexture)
        if "KHR_materials_clearcoat" in extensions:
          let coat = extensions["KHR_materials_clearcoat"]
          material.hasClearcoat = true
          material.clearcoatFactor = coat{"clearcoatFactor"}.getFloat().float32
          material.clearcoatRoughnessFactor = coat{"clearcoatRoughnessFactor"}.getFloat().float32
          template readCoatTexture(slot: untyped) =
            if astToStr(slot) in coat:
              let texture = coat[astToStr(slot)]
              material.slot.index = texture["index"].getInt()
              material.slot.scale = texture{"scale"}.getFloat(1).float32
              readTextureTransform(texture, material.slot)
          readCoatTexture(clearcoatTexture)
          readCoatTexture(clearcoatRoughnessTexture)
          readCoatTexture(clearcoatNormalTexture)
        if "KHR_materials_anisotropy" in extensions:
          let anisotropy = extensions["KHR_materials_anisotropy"]
          material.hasAnisotropy = true
          material.anisotropyStrength = anisotropy{"anisotropyStrength"}.getFloat().float32
          material.anisotropyRotation = anisotropy{"anisotropyRotation"}.getFloat().float32
          if "anisotropyTexture" in anisotropy:
            let texture = anisotropy["anisotropyTexture"]
            material.anisotropyTexture.index = texture["index"].getInt()
            readTextureTransform(texture, material.anisotropyTexture)
        if "KHR_materials_diffuse_transmission" in extensions:
          let diffuse = extensions["KHR_materials_diffuse_transmission"]
          material.hasDiffuseTransmission = true
          material.diffuseTransmissionFactor = diffuse{"diffuseTransmissionFactor"}.getFloat().float32
          if "diffuseTransmissionColorFactor" in diffuse:
            let c = diffuse["diffuseTransmissionColorFactor"]
            material.diffuseTransmissionColorFactor = vec3(c[0].getFloat(), c[1].getFloat(), c[2].getFloat())
          template readDiffuseTexture(slot: untyped) =
            if astToStr(slot) in diffuse:
              let texture = diffuse[astToStr(slot)]
              material.slot.index = texture["index"].getInt()
              readTextureTransform(texture, material.slot)
          readDiffuseTexture(diffuseTransmissionTexture)
          readDiffuseTexture(diffuseTransmissionColorTexture)
        if "KHR_materials_transmission" in extensions:
          let transmission = extensions["KHR_materials_transmission"]
          material.hasTransmission = true
          if "transmissionFactor" in transmission:
            material.transmissionFactor =
              transmission["transmissionFactor"].getFloat().float32
          if "transmissionTexture" in transmission:
            let texture = transmission["transmissionTexture"]
            material.transmissionTexture.index = texture["index"].getInt()
            readTextureTransform(texture, material.transmissionTexture)
        if "KHR_materials_volume" in extensions:
          let volume = extensions["KHR_materials_volume"]
          material.hasVolume = true
          material.thicknessFactor = volume{"thicknessFactor"}.getFloat().float32
          material.attenuationDistance = volume{"attenuationDistance"}.getFloat().float32
          if "attenuationColor" in volume:
            let c = volume["attenuationColor"]
            material.attenuationColor = vec3(c[0].getFloat(), c[1].getFloat(), c[2].getFloat())
          if "thicknessTexture" in volume:
            let texture = volume["thicknessTexture"]
            material.thicknessTexture.index = texture["index"].getInt()
            readTextureTransform(texture, material.thicknessTexture)
        if "KHR_materials_ior" in extensions:
          material.hasIor = true
          material.ior = extensions["KHR_materials_ior"]{"ior"}.getFloat(1.5).float32

      materials.add(material)

  var cameras: seq[Camera]
  if "cameras" in jsonRoot:
    for entry in jsonRoot["cameras"]:
      var camera = Camera()
      if "name" in entry:
        camera.name = entry["name"].getStr()
      let cameraType = entry["type"].getStr()
      case cameraType
      of "perspective":
        camera.kind = PerspectiveLens
        let perspectiveInfo = entry["perspective"]
        camera.perspective.yfov =
          perspectiveInfo["yfov"].getFloat().float32
        camera.perspective.znear =
          perspectiveInfo["znear"].getFloat().float32
        if "aspectRatio" in perspectiveInfo:
          camera.perspective.aspectRatio =
            perspectiveInfo["aspectRatio"].getFloat().float32
        else:
          camera.perspective.aspectRatio = 0.0
        if "zfar" in perspectiveInfo:
          camera.perspective.zfar =
            perspectiveInfo["zfar"].getFloat().float32
        else:
          camera.perspective.zfar = 0.0
      of "orthographic":
        camera.kind = OrthographicLens
        let orthographicInfo = entry["orthographic"]
        camera.orthographic.xmag =
          orthographicInfo["xmag"].getFloat().float32
        camera.orthographic.ymag =
          orthographicInfo["ymag"].getFloat().float32
        camera.orthographic.znear =
          orthographicInfo["znear"].getFloat().float32
        camera.orthographic.zfar =
          orthographicInfo["zfar"].getFloat().float32
      else:
        raise newException(GltfError, &"Invalid camera type {cameraType}")
      cameras.add(camera)

  var
    meshDefs: seq[MeshInfo]
    primitiveDefs: seq[PrimitiveInfo]
  for entry in jsonRoot["meshes"]:
    var mesh = MeshInfo()
    if "name" in entry:
      mesh.name = entry["name"].getStr()
    if "weights" in entry:
      for weight in entry["weights"]:
        mesh.weights.add(weight.getFloat().float32)
    if "extras" in entry and "targetNames" in entry["extras"]:
      for name in entry["extras"]["targetNames"]:
        mesh.targetNames.add(name.getStr())
    mesh.primitives = @[]
    for primitive in entry["primitives"]:
      var prim = PrimitiveInfo()
      assertRaise "attributes" in primitive, "Missing primitive attributes"
      let attributes = primitive["attributes"]
      if "POSITION" in attributes:
        prim.attributes.position = attributes["POSITION"].getInt()
      else:
        prim.attributes.position = -1
      if "NORMAL" in attributes:
        prim.attributes.normal = attributes["NORMAL"].getInt()
      else:
        prim.attributes.normal = -1
      if "TANGENT" in attributes:
        prim.attributes.tangent = attributes["TANGENT"].getInt()
      else:
        prim.attributes.tangent = -1
      if "COLOR_0" in attributes:
        prim.attributes.color0 = attributes["COLOR_0"].getInt()
      else:
        prim.attributes.color0 = -1
      if "TEXCOORD_0" in attributes:
        prim.attributes.texcoord0 = attributes["TEXCOORD_0"].getInt()
      else:
        prim.attributes.texcoord0 = -1
      if "TEXCOORD_1" in attributes:
        prim.attributes.texcoord1 = attributes["TEXCOORD_1"].getInt()
      else:
        prim.attributes.texcoord1 = -1
      if "JOINTS_0" in attributes:
        prim.attributes.joints0 = attributes["JOINTS_0"].getInt()
      else:
        prim.attributes.joints0 = -1
      if "WEIGHTS_0" in attributes:
        prim.attributes.weights0 = attributes["WEIGHTS_0"].getInt()
      else:
        prim.attributes.weights0 = -1
      if "indices" in primitive:
        prim.indices = primitive["indices"].getInt()
      else:
        prim.indices = -1
      if "material" in primitive:
        prim.material = primitive["material"].getInt()
      else:
        prim.material = -1
      if "mode" in primitive:
        prim.mode = parsePrimitiveMode(primitive["mode"].getInt())
      else:
        prim.mode = TrianglesMode
      if "extensions" in primitive and
        "KHR_draco_mesh_compression" in primitive["extensions"]:
          let draco = primitive["extensions"]["KHR_draco_mesh_compression"]
          prim.draco.used = true
          prim.draco.bufferView = draco["bufferView"].getInt()
          for name, attrId in draco["attributes"]:
            prim.draco.attributes.add(DracoAttributeInfo(
              name: name,
              id: attrId.getInt()
            ))
      if "targets" in primitive:
        for target in primitive["targets"]:
          var morphTarget = MorphTargetInfo(
            position: -1,
            normal: -1,
            tangent: -1
          )
          if "POSITION" in target:
            morphTarget.position = target["POSITION"].getInt()
          if "NORMAL" in target:
            morphTarget.normal = target["NORMAL"].getInt()
          if "TANGENT" in target:
            morphTarget.tangent = target["TANGENT"].getInt()
          prim.morphTargets.add(morphTarget)
      primitiveDefs.add(prim)
      mesh.primitives.add(primitiveDefs.len - 1)
    meshDefs.add(mesh)

  var skinInfos: seq[SkinInfo]
  if "skins" in jsonRoot:
    for entry in jsonRoot["skins"]:
      var skin = SkinInfo()
      if "name" in entry:
        skin.name = entry["name"].getStr()
      if "inverseBindMatrices" in entry:
        skin.inverseBindMatrices =
          entry["inverseBindMatrices"].getInt()
      else:
        skin.inverseBindMatrices = -1
      if "skeleton" in entry:
        skin.skeleton = entry["skeleton"].getInt()
      else:
        skin.skeleton = -1
      for joint in entry["joints"]:
        skin.joints.add(joint.getInt())
      skinInfos.add(skin)

  var
    nodes: seq[Node]
    nodeMeshes: seq[int]
    nodeSkins: seq[int]
    nodeCameras: seq[int]
    nodeChildren: seq[seq[int]]
    nodeInstances: seq[seq[MeshInstance]]
  for entry in jsonRoot["nodes"]:
    var node = Node()
    if "name" in entry:
      node.name = entry["name"].getStr()
    else:
      node.name = "node_" & $nodes.len
    node.visible = true
    if "extensions" in entry:
      let extensions = entry["extensions"]
      if "KHR_lights_punctual" in extensions:
        let
          index = extensions["KHR_lights_punctual"]["light"].getInt()
          lights = jsonRoot{"extensions", "KHR_lights_punctual", "lights"}
        assertRaise lights != nil and index >= 0 and index < lights.len,
          "Invalid punctual light index"
        let light = lights[index]
        let kind = case light["type"].getStr()
          of "directional": DirectionalLightKind
          of "point": PointLightKind
          of "spot": SpotLightKind
          else: raise newException(GltfError, "Invalid punctual light type")
        node.punctualLight = PunctualLight(kind: kind, name: light{"name"}.getStr(),
          color: color(1, 1, 1, 1), intensity: light{"intensity"}.getFloat(1).float32,
          range: light{"range"}.getFloat().float32,
          innerConeAngle: light{"spot", "innerConeAngle"}.getFloat().float32,
          outerConeAngle: light{"spot", "outerConeAngle"}.getFloat(0.7853981633974483).float32)
        if "color" in light:
          let c = light["color"]
          node.punctualLight.color = color(c[0].getFloat(), c[1].getFloat(), c[2].getFloat(), 1)
      if "KHR_node_visibility" in extensions:
        let visibility = extensions["KHR_node_visibility"]
        if "visible" in visibility:
          node.visible = visibility["visible"].getBool()

    var instances: seq[MeshInstance]
    if "extensions" in entry:
      let extensions = entry["extensions"]
      if "EXT_mesh_gpu_instancing" in extensions:
        instances = readMeshInstances(
          extensions["EXT_mesh_gpu_instancing"],
          accessors,
          bufferViews,
          buffers
        )

    var meshId = -1
    if "mesh" in entry:
      meshId = entry["mesh"].getInt()
    var skinId = -1
    if "skin" in entry:
      skinId = entry["skin"].getInt()
      assertRaise(
        skinId >= 0 and skinId < skinInfos.len,
        &"Invalid skin index {skinId}"
      )
    var cameraId = -1
    if "camera" in entry:
      cameraId = entry["camera"].getInt()
      assertRaise(
        cameraId >= 0 and cameraId < cameras.len,
        &"Invalid camera index {cameraId}"
      )

    if "matrix" in entry and entry["matrix"].len >= 16:
      let matrix = entry["matrix"]
      let localMat = mat4(
        matrix[0].getFloat().float32,
        matrix[1].getFloat().float32,
        matrix[2].getFloat().float32,
        matrix[3].getFloat().float32,
        matrix[4].getFloat().float32,
        matrix[5].getFloat().float32,
        matrix[6].getFloat().float32,
        matrix[7].getFloat().float32,
        matrix[8].getFloat().float32,
        matrix[9].getFloat().float32,
        matrix[10].getFloat().float32,
        matrix[11].getFloat().float32,
        matrix[12].getFloat().float32,
        matrix[13].getFloat().float32,
        matrix[14].getFloat().float32,
        matrix[15].getFloat().float32
      )

      node.pos = localMat.pos
      let
        sx = vec3(localMat[0, 0], localMat[0, 1], localMat[0, 2]).length()
        sy = vec3(localMat[1, 0], localMat[1, 1], localMat[1, 2]).length()
        sz = vec3(localMat[2, 0], localMat[2, 1], localMat[2, 2]).length()
      node.scale = vec3(sx, sy, sz)

      var rotationMat = localMat.rotationOnly()
      if sx != 0: rotationMat[0, 0] /= sx; rotationMat[0, 1] /= sx; rotationMat[0, 2] /= sx
      if sy != 0: rotationMat[1, 0] /= sy; rotationMat[1, 1] /= sy; rotationMat[1, 2] /= sy
      if sz != 0: rotationMat[2, 0] /= sz; rotationMat[2, 1] /= sz; rotationMat[2, 2] /= sz
      node.rot = rotationMat.quat()
    elif "translation" in entry:
      let translation = entry["translation"]
      node.pos = vec3(
        translation[0].getFloat().float32,
        translation[1].getFloat().float32,
        translation[2].getFloat().float32
      )
      if "rotation" in entry:
        let rotation = entry["rotation"]
        node.rot = quat(
          rotation[0].getFloat().float32,
          rotation[1].getFloat().float32,
          rotation[2].getFloat().float32,
          rotation[3].getFloat().float32
        )
      else:
        node.rot = quat(0, 0, 0, 1)
      if "scale" in entry and entry["scale"].len >= 3:
        let scale = entry["scale"]
        node.scale = vec3(
          scale[0].getFloat().float32,
          scale[1].getFloat().float32,
          scale[2].getFloat().float32
        )
      else:
        node.scale = vec3(1, 1, 1)
    else:
      node.pos = vec3(0, 0, 0)
      if "rotation" in entry:
        let rotation = entry["rotation"]
        node.rot = quat(
          rotation[0].getFloat().float32,
          rotation[1].getFloat().float32,
          rotation[2].getFloat().float32,
          rotation[3].getFloat().float32
        )
      else:
        node.rot = quat(0, 0, 0, 1)

      if "scale" in entry and entry["scale"].len >= 3:
        let scale = entry["scale"]
        node.scale = vec3(
          scale[0].getFloat().float32,
          scale[1].getFloat().float32,
          scale[2].getFloat().float32
        )
      else:
        node.scale = vec3(1, 1, 1)

    node.baseVisible = node.visible
    node.basePos = node.pos
    node.baseRot = node.rot
    node.baseScale = node.scale

    var children: seq[int]
    if "children" in entry:
      for child in entry["children"]:
        children.add(child.getInt())

    nodes.add(node)
    nodeMeshes.add(meshId)
    nodeSkins.add(skinId)
    nodeCameras.add(cameraId)
    nodeChildren.add(children)
    nodeInstances.add(instances)

  var skins: seq[Skin]
  for skinInfo in skinInfos:
    var skin = Skin()
    skin.name = skinInfo.name
    if skinInfo.inverseBindMatrices >= 0:
      skin.inverseBindMatrices = readAccessorMat4(
        skinInfo.inverseBindMatrices,
        accessors,
        bufferViews,
        buffers
      )
    for jointId in skinInfo.joints:
      assertRaise(
        jointId >= 0 and jointId < nodes.len,
        &"Invalid skin joint index {jointId}"
      )
      skin.joints.add(nodes[jointId])
    if skin.inverseBindMatrices.len == 0:
      skin.inverseBindMatrices.setLen(skin.joints.len)
      for i in 0 ..< skin.inverseBindMatrices.len:
        skin.inverseBindMatrices[i] = mat4()
    if skinInfo.skeleton >= 0:
      assertRaise(
        skinInfo.skeleton >= 0 and skinInfo.skeleton < nodes.len,
        &"Invalid skin skeleton index {skinInfo.skeleton}"
      )
      skin.skeleton = nodes[skinInfo.skeleton]
    skins.add(skin)

  var clips: seq[AnimationClip]
  var materialChannels: seq[tuple[channel: AnimationChannel, materialIdx: int]]
  if "animations" in jsonRoot:
    for animEntry in jsonRoot["animations"]:
      var clip = AnimationClip()
      if "name" in animEntry:
        clip.name = animEntry["name"].getStr()
      else:
        clip.name = "anim_" & $clips.len

      type
        AnimSampler = object
          input, output: int
          interpolation: string
          times: seq[float32]

      var samplers: seq[AnimSampler]
      if "samplers" in animEntry:
        for s in animEntry["samplers"]:
          var sampler = AnimSampler()
          sampler.input = s["input"].getInt()
          sampler.output = s["output"].getInt()
          if "interpolation" in s:
            sampler.interpolation = s["interpolation"].getStr()
          else:
            sampler.interpolation = "LINEAR"
          if sampler.input >= 0 and sampler.input < accessors.len:
            sampler.times = readAccessorFloats(sampler.input, accessors, bufferViews, buffers)
          samplers.add(sampler)

      if "channels" in animEntry:
        for ch in animEntry["channels"]:
          if not ("sampler" in ch):
            continue
          let samplerIdx = ch["sampler"].getInt()
          if samplerIdx < 0 or samplerIdx >= samplers.len:
            continue
          let sampler = samplers[samplerIdx]
          if sampler.times.len > 0: clip.duration = max(clip.duration, sampler.times[^1])
          if not ("target" in ch):
            continue
          let target = ch["target"]
          var
            nodeIdx = -1
            materialIdx = -1
            textureSlot: MaterialTextureSlot
            textureComponent = 0
            path: AnimPath
            isPath = true

          if "extensions" in target and
             "KHR_animation_pointer" in target["extensions"]:
            let pointer =
              target["extensions"]["KHR_animation_pointer"]["pointer"].getStr()
            if pointer.startsWith("/nodes/") and
               pointer.endsWith("/extensions/KHR_node_visibility/visible"):
              let suffix = "/extensions/KHR_node_visibility/visible"
              let remainder =
                pointer.substr(
                  "/nodes/".len,
                  pointer.len - suffix.len - 1
                )
              try:
                nodeIdx = parseInt(remainder)
                path = AnimVisibility
              except ValueError:
                isPath = false
            elif pointer.startsWith("/materials/") and
                 pointer.endsWith("/pbrMetallicRoughness/baseColorFactor"):
              let suffix = "/pbrMetallicRoughness/baseColorFactor"
              let remainder = pointer.substr(
                "/materials/".len, pointer.len - suffix.len - 1
              )
              try:
                materialIdx = parseInt(remainder)
                path = AnimBaseColorFactor
              except ValueError:
                isPath = false
            elif pointer.startsWith("/materials/"):
              isPath = false
              var parts = pointer.split('/')
              # Component pointers target one element of offset or scale.
              if parts.len > 2 and parts[^1] in ["0", "1"] and parts[^2] in ["offset", "scale"]:
                textureComponent = parseInt(parts[^1]) + 1
                parts.setLen(parts.len - 1)
              if parts.len >= 7 and parts[^3] == "extensions" and parts[^2] == "KHR_texture_transform":
                let texturePath = parts[3 .. ^4].join("/")
                try:
                  materialIdx = parseInt(parts[2])
                  if materialIdx >= 0 and materialIdx < materials.len:
                    # Defaults are valid targets only when their enclosing object exists.
                    var parent = jsonRoot["materials"][materialIdx]
                    for token in parts[3 .. ^2]:
                      if parent.kind == JObject and token in parent: parent = parent[token]
                      else: parent = newJNull()
                    if parent.kind == JObject:
                      for slot in MaterialTextureSlot:
                        if texturePath == MaterialTexturePaths[slot]:
                          textureSlot = slot
                          case parts[^1]
                          of "offset": path = AnimTextureOffset; isPath = true
                          of "scale": path = AnimTextureScale; isPath = true
                          of "rotation": path = AnimTextureRotation; isPath = true
                          else: discard
                except ValueError: discard
            else:
              isPath = false
          else:
            if not ("node" in target) or not ("path" in target):
              continue
            nodeIdx = target["node"].getInt()
            let pathStr = target["path"].getStr()
            case pathStr
            of "translation":
              path = AnimTranslation
            of "rotation":
              path = AnimRotation
            of "scale":
              path = AnimScale
            of "weights":
              path = AnimWeights
            else:
              isPath = false

          if not isPath:
            echo "[gltf] skipping unsupported animation target"
            continue
          if path in {AnimBaseColorFactor, AnimTextureOffset, AnimTextureScale, AnimTextureRotation}:
            if materialIdx < 0 or materialIdx >= materials.len:
              continue
          elif nodeIdx < 0 or nodeIdx >= nodes.len:
            continue

          let times = sampler.times
          if times.len == 0:
            echo "[gltf] animation sampler missing times"
            continue

          var channel = AnimationChannel()
          if path == AnimBaseColorFactor:
            channel.baseColorFactor = materials[materialIdx].pbrMetallicRoughness.baseColorFactor
          elif path in {AnimTextureOffset, AnimTextureScale, AnimTextureRotation}:
            channel.textureSlot = textureSlot
            channel.textureComponent = textureComponent
          else:
            channel.target = nodes[nodeIdx]
          channel.path = path
          channel.interpolation = parseInterpolation(sampler.interpolation)
          channel.times = times

          case path
          of AnimTextureOffset, AnimTextureScale, AnimTextureRotation:
            if path != AnimTextureRotation and textureComponent == 0:
              channel.valuesVec2 = readAccessorVec2(sampler.output, accessors, bufferViews, buffers)
            else:
              channel.valuesFloat = readAccessorFloats(sampler.output, accessors, bufferViews, buffers)
          of AnimBaseColorFactor:
            channel.valuesVec4 = readAccessorVec4(
              sampler.output, accessors, bufferViews, buffers
            )
          of AnimTranslation, AnimScale:
            channel.valuesVec3 =
              readAccessorVec3(
                sampler.output,
                accessors,
                bufferViews,
                buffers
              )
          of AnimRotation:
            channel.valuesQuat =
              readAccessorQuat(
                sampler.output,
                accessors,
                bufferViews,
                buffers
              )
          of AnimVisibility:
            channel.valuesFloat =
              readAccessorFloats(
                sampler.output,
                accessors,
                bufferViews,
                buffers
              )
          of AnimWeights:
            let
              meshId = nodeMeshes[nodeIdx]
              weightCount =
                if meshId >= 0 and meshId < meshDefs.len:
                  meshDefs[meshId].weights.len
                else:
                  0
            if weightCount == 0:
              echo "[gltf] animation target weights missing morph weights"
              continue
            channel.valuesWeights = readWeightFrames(
              sampler.output,
              accessors,
              bufferViews,
              buffers,
              weightCount
            )

          if channel.times.len == 0:
            continue
          if channel.interpolation == aiCubicSpline:
            case path
            of AnimTextureOffset, AnimTextureScale, AnimTextureRotation:
              if path != AnimTextureRotation and textureComponent == 0:
                if channel.valuesVec2.len != channel.times.len * 3: continue
                splitCubicVec2(channel)
              else:
                if channel.valuesFloat.len != channel.times.len * 3: continue
                splitCubicFloat(channel)
            of AnimBaseColorFactor:
              if channel.valuesVec4.len != channel.times.len * 3:
                echo "[gltf] animation sampler length mismatch"
                continue
              splitCubicVec4(channel)
            of AnimTranslation, AnimScale:
              if channel.valuesVec3.len != channel.times.len * 3:
                echo "[gltf] animation sampler length mismatch"
                continue
              splitCubicVec3(channel)
            of AnimRotation:
              if channel.valuesQuat.len != channel.times.len * 3:
                echo "[gltf] animation sampler length mismatch"
                continue
              splitCubicQuat(channel)
            of AnimVisibility:
              if channel.valuesFloat.len != channel.times.len * 3:
                echo "[gltf] animation sampler length mismatch"
                continue
              splitCubicFloat(channel)
            of AnimWeights:
              if channel.valuesWeights.len != channel.times.len * 3:
                echo "[gltf] animation sampler length mismatch"
                continue
              let triplets = channel.valuesWeights
              channel.valuesWeights.setLen(channel.times.len)
              channel.inTangentsWeights.setLen(channel.times.len)
              channel.outTangentsWeights.setLen(channel.times.len)
              for i in 0 ..< channel.times.len:
                channel.inTangentsWeights[i] = triplets[i * 3]
                channel.valuesWeights[i] = triplets[i * 3 + 1]
                channel.outTangentsWeights[i] = triplets[i * 3 + 2]
          elif channel.times.len != channel.valuesVec2.len and
             channel.times.len != channel.valuesVec3.len and
             channel.times.len != channel.valuesVec4.len and
             channel.times.len != channel.valuesQuat.len and
             channel.times.len != channel.valuesFloat.len and
             channel.times.len != channel.valuesWeights.len:
            echo "[gltf] animation sampler length mismatch"
            continue

          if channel.times.len > 0:
            clip.duration = max(clip.duration, channel.times[^1])
          clip.channels.add(channel)
          if path in {AnimBaseColorFactor, AnimTextureOffset, AnimTextureScale, AnimTextureRotation}:
            materialChannels.add((channel, materialIdx))

      # Keep source indices and timing even if every channel is unsupported.
      clips.add(clip)

  var sceneRoots: seq[seq[int]]
  var scenes: seq[Scene]
  var sceneId = 0
  if "scene" in jsonRoot:
    sceneId = jsonRoot["scene"].getInt()
  for entry in jsonRoot["scenes"]:
    var scene = Scene()
    if "name" in entry:
      scene.name = entry["name"].getStr()
    var roots: seq[int]
    for n in entry["nodes"]:
      roots.add(n.getInt())
    scenes.add(scene)
    sceneRoots.add(roots)

  var runtimeMaterials = newSeq[seq[Material]](materials.len)

  proc processNode(nodeId: int): Node =
    var n = nodes[nodeId]
    let meshId = nodeMeshes[nodeId]
    let skinId = nodeSkins[nodeId]
    let cameraId = nodeCameras[nodeId]
    let instances = nodeInstances[nodeId]
    if meshId >= 0:
      let meshInfo = meshDefs[meshId]
      let runtimeMesh = Mesh(name: meshInfo.name)
      runtimeMesh.targetNames = meshInfo.targetNames
      for primitiveIndex in meshInfo.primitives:
        runtimeMesh.primitives.add(loadPrimitive(
          primitiveIndex,
          primitiveDefs,
          accessors,
          bufferViews,
          buffers,
          images,
          imageKtx2Data,
          imageNames,
          textures,
          samplers,
          materials
        ))
        let materialIdx = primitiveDefs[primitiveIndex].material
        if materialIdx >= 0:
          runtimeMaterials[materialIdx].add(runtimeMesh.primitives[^1].material)
      n.mesh = runtimeMesh
      n.morphWeights = meshInfo.weights
      n.baseMorphWeights = meshInfo.weights
    if skinId >= 0:
      n.skin = skins[skinId]
    if cameraId >= 0:
      n.camera = cameras[cameraId]

    for childId in nodeChildren[nodeId]:
      n.nodes.add(processNode(childId))

    if instances.len > 0:
      assertRaise(
        n.mesh != nil,
        "EXT_mesh_gpu_instancing requires a node mesh"
      )
      let
        instanceMesh = n.mesh
        instanceMorphWeights = n.morphWeights
        instanceBaseMorphWeights = n.baseMorphWeights
        instanceSkin = n.skin
      n.mesh = nil
      n.morphWeights.setLen(0)
      n.baseMorphWeights.setLen(0)
      n.skin = nil
      for i, instance in instances:
        n.nodes.add(Node(
          name: &"{n.name}_instance_{i}",
          visible: true,
          pos: instance.pos,
          rot: instance.rot,
          scale: instance.scale,
          baseVisible: true,
          basePos: instance.pos,
          baseRot: instance.rot,
          baseScale: instance.scale,
          mesh: instanceMesh,
          morphWeights: instanceMorphWeights,
          baseMorphWeights: instanceBaseMorphWeights,
          skin: instanceSkin
        ))

    return n

  # Keep one convenience tree for the selected scene.
  result.root = Node()
  result.root.visible = true
  result.root.name = "Root"
  result.root.pos = vec3(0, 0, 0)
  result.root.rot = quat(0, 0, 0, 1)
  result.root.scale = vec3(1, 1, 1)
  result.root.baseVisible = result.root.visible
  result.root.basePos = result.root.pos
  result.root.baseRot = result.root.rot
  result.root.baseScale = result.root.scale
  for i, scene in scenes:
    for nodeId in sceneRoots[i]:
      scene.nodes.add(processNode(nodeId))
  # Primitives and mesh instances own separate runtime material copies.
  for (channel, materialIdx) in materialChannels:
    channel.materialTargets = runtimeMaterials[materialIdx]
    if channel.path in {AnimTextureOffset, AnimTextureScale, AnimTextureRotation} and
        channel.materialTargets.len > 0:
      channel.baseTextureTransform = channel.materialTargets[0].textureTransform(channel.textureSlot)
  if scenes.len > 0:
    let selectedScene = max(0, min(sceneId, scenes.high))
    for sceneNode in scenes[selectedScene].nodes:
      result.root.nodes.add(sceneNode)
  result.root.animations = clips
  result.root.activeClips.setLen(clips.len)
  for i in 0 ..< clips.len:
    result.root.activeClips[i] = i
  result.root.animTime = 0
  result.scenes = scenes
  result.cameras = cameras
  result.skins = skins
  result.sceneId =
    if scenes.len > 0:
      max(0, min(sceneId, scenes.high))
    else:
      0

proc loadModelJson*(
  jsonRoot: JsonNode,
  modelDir: string,
  externalBuffers: seq[string]
): Node =
  ## Loads a 3D model from a parsed glTF json tree.
  result = loadModelJsonInternal(jsonRoot, modelDir, externalBuffers).root
  result.ensureNormals()

proc loadModelJsonFile*(file: string): Node =
  ## Loads a 3D model from a json glTF file.
  let
    jsonRoot = parseJson(readFile(file))
    modelDir = splitPath(file)[0]
  loadModelJson(jsonRoot, modelDir, @[])

proc loadModelBinaryFile*(file: string): Node =
  ## Loads a 3D model from a binary glTF file.
  let
    modelDir = splitPath(file)[0]
    data = readFile(file)
    magic = data.readUint32(0)
    version = data.readUint32(4)
    length = data.readUint32(8)

  assertRaise magic == 0x46546C67, "Invalid magic, this is not a glTF file"
  assertRaise version == 2, "Invalid version, only glTF 2.0 is supported"
  assertRaise length.int == data.len, "Length mismatch, the file is corrupted"

  var
    i = 12
    jsonData: string
    buffers: seq[string]
  while i < data.len:
    var
      chunkLength = data.readUint32(i)
      chunkType = data.readUint32(i + 4)
      chunkData = data.readStr(i + 8, chunkLength.int)
      isJson = chunkType == 0x4E4F534A
    i += 8 + chunkLength.int
    if isJson:
      jsonData = chunkData
    else:
      buffers.add(chunkData)

  loadModelJson(parseJson(jsonData), modelDir, buffers)

proc loadModel*(file: string): Node =
  ## Loads a 3D model from a glTF file.
  if file.endsWith(".glb"):
    loadModelBinaryFile(file)
  else:
    loadModelJsonFile(file)

proc readGltfJsonFile*(file: string): GltfFile =
  ## Reads a glTF json file into a glTF file wrapper.
  let
    jsonRoot = parseJson(readFile(file))
    modelDir = splitPath(file)[0]
    loaded = loadModelJsonInternal(jsonRoot, modelDir, @[])
  GltfFile(
    path: file,
    root: loaded.root,
    scenes: loaded.scenes,
    scene: loaded.sceneId,
    cameras: loaded.cameras,
    skins: loaded.skins,
    unsupportedUsedExtensions: unsupportedUsedExtensions(jsonRoot)
  )

proc readGltfBinaryFile*(file: string): GltfFile =
  ## Reads a binary glTF file into a glTF file wrapper.
  let
    modelDir = splitPath(file)[0]
    data = readFile(file)
    magic = data.readUint32(0)
    version = data.readUint32(4)
    length = data.readUint32(8)

  assertRaise magic == 0x46546C67, "Invalid magic, this is not a glTF file"
  assertRaise version == 2, "Invalid version, only glTF 2.0 is supported"
  assertRaise length.int == data.len, "Length mismatch, the file is corrupted"

  var
    i = 12
    jsonData: string
    buffers: seq[string]
  while i < data.len:
    var
      chunkLength = data.readUint32(i)
      chunkType = data.readUint32(i + 4)
      chunkData = data.readStr(i + 8, chunkLength.int)
      isJson = chunkType == 0x4E4F534A
    i += 8 + chunkLength.int
    if isJson:
      jsonData = chunkData
    else:
      buffers.add(chunkData)

  let jsonRoot = parseJson(jsonData)
  let loaded = loadModelJsonInternal(jsonRoot, modelDir, buffers)
  GltfFile(
    path: file,
    root: loaded.root,
    scenes: loaded.scenes,
    scene: loaded.sceneId,
    cameras: loaded.cameras,
    skins: loaded.skins,
    unsupportedUsedExtensions: unsupportedUsedExtensions(jsonRoot)
  )

proc readGltfFile*(file: string): GltfFile =
  ## Reads a glTF file into a glTF file wrapper.
  if file.endsWith(".glb"):
    readGltfBinaryFile(file)
  else:
    readGltfJsonFile(file)
