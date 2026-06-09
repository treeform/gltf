import
  std/[strformat],
  attributes, bitstreams, meshes, types

proc expandAttribute(attr: DracoAttribute, pointCount: int): string =
  ## Expands a Draco attribute to point-order bytes.
  let stride = attr.byteStride
  if attr.identityMap and attr.values.len == pointCount * stride:
    return attr.values
  result.setLen(pointCount * stride)
  for point in 0 ..< pointCount:
    let entry =
      if attr.identityMap:
        point
      else:
        attr.pointMap[point]
    let
      src = entry * stride
      dst = point * stride
    if src < 0 or src + stride > attr.values.len:
      raise newException(DracoError, "Invalid Draco attribute point map")
    for i in 0 ..< stride:
      result[dst + i] = attr.values[src + i]

proc findAttribute(mesh: DracoMesh, uniqueId: int): int =
  ## Finds a decoded attribute by Draco unique id.
  for i, attr in mesh.attributes:
    if attr.uniqueId == uniqueId:
      return i
  -1

proc buildResult(
  mesh: DracoMesh,
  requested: seq[DracoDecodeAttribute]
): DracoDecodeResult =
  ## Builds the public Draco decode result.
  result.pointCount = mesh.pointCount
  result.faceCount = mesh.faceCount
  result.indices = mesh.faces
  for spec in requested:
    let attrId = mesh.findAttribute(spec.id)
    if attrId < 0:
      raise newException(
        DracoError,
        &"Decoded Draco attribute id {spec.id} is missing"
      )
    let attr = mesh.attributes[attrId]
    result.attributes.add(DracoAttributeData(
      name: spec.name,
      componentType: attr.componentType,
      componentCount: attr.numComponents,
      data: attr.expandAttribute(mesh.pointCount)
    ))

proc decodeDracoPayload*(
  payload: string,
  attributes: seq[DracoDecodeAttribute]
): DracoDecodeResult =
  ## Decodes one Draco payload into glTF-facing buffers.
  var stream = initDracoStream(payload)
  if stream.readString(5) != "DRACO":
    raise newException(DracoError, "Not a Draco payload")
  let
    major = stream.readUint8()
    minor = stream.readUint8()
    geometryType = stream.readUint8()
    meshMethod = stream.readUint8()
    flags = stream.readUint16()
  discard flags
  if major != 2 or minor != 2:
    raise newException(
      DracoError,
      &"Unsupported Draco bitstream version {major}.{minor}"
    )
  if geometryType != 1:
    raise newException(DracoError, "Only Draco mesh payloads are supported")
  var mesh: DracoMesh
  case meshMethod
  of 0:
    mesh = decodeSequentialMesh(stream)
    decodeSequentialAttributes(stream, mesh)
  of 1:
    let traversalKind = stream.readUint8().int
    var state = decodeEdgebreakerMesh(stream, traversalKind)
    when defined(dracoDebug):
      echo "Draco connectivity faces=", state.mesh.faceCount,
        " points=", state.mesh.pointCount,
        " attrs=", state.attributeData.len
    decodeEdgebreakerAttributes(stream, state)
    mesh = state.mesh
  else:
    raise newException(
      DracoError,
      &"Unsupported Draco mesh method {meshMethod}"
    )
  buildResult(mesh, attributes)
