## MikkTSpace tangent generation, matching the convention used by glTF normal
## maps. The canonical C algorithm is compiled into the application; no DLL or
## runtime tool is required. See mikktspace/README.md for provenance/license.
import std/[os, tables, math], vmath, common

const MikkDir = currentSourcePath().parentDir / "mikktspace"
{.compile: MikkDir / "mikktspace.c".}
{.compile: MikkDir / "bridge.c".}

proc gltfGenerateMikkTangents(positions, normals, uvs: ptr float32,
  indices: ptr uint32, corners: cint, tangents: ptr float32): cint {.importc, cdecl.}

proc triangleCorners(primitive: Primitive): seq[uint32] =
  let count = if primitive.indices32.len > 0: primitive.indices32.len
    elif primitive.indices16.len > 0: primitive.indices16.len else: primitive.points.len
  template index(i: int): uint32 =
    if primitive.indices32.len > 0: primitive.indices32[i]
    elif primitive.indices16.len > 0: primitive.indices16[i].uint32 else: i.uint32
  case primitive.mode
  of TrianglesMode:
    if count mod 3 != 0:
      raise newException(GltfError, "Triangle vertex count must be divisible by three")
    for i in 0 ..< count: result.add(index(i))
  of TriangleStripMode:
    for i in 2 ..< count:
      if i mod 2 == 0: result.add([index(i - 2), index(i - 1), index(i)])
      else: result.add([index(i - 1), index(i - 2), index(i)])
  of TriangleFanMode:
    for i in 2 ..< count: result.add([index(0), index(i - 1), index(i)])
  else: discard

proc remap[T](values: seq[T], vertices: seq[int]): seq[T] =
  if values.len == 0: return
  result = newSeq[T](vertices.len)
  for i, source in vertices: result[i] = values[source]

proc generateTangents*(primitive: Primitive) =
  ## Fill missing tangents in the bind pose, using TEXCOORD_0 like the Khronos
  ## renderer. Authored tangents and non-triangle primitives remain untouched.
  ## Split only vertices whose per-corner tangent differs. All vertex streams,
  ## skin weights and morph targets follow that same remapping.
  if primitive == nil or primitive.tangents.len > 0 or
      primitive.points.len == 0 or primitive.normals.len == 0 or primitive.uvs.len == 0 or
      primitive.mode notin {TrianglesMode, TriangleStripMode, TriangleFanMode}:
    return
  let count = primitive.points.len
  template checkLength(values: untyped) =
    if values.len != 0 and values.len != count:
      raise newException(GltfError, "Vertex stream length differs from positions during tangent generation")
  checkLength(primitive.normals)
  checkLength(primitive.uvs)
  checkLength(primitive.uvs1)
  checkLength(primitive.colors)
  checkLength(primitive.jointIds)
  checkLength(primitive.jointWeights)
  checkLength(primitive.basePoints)
  checkLength(primitive.baseNormals)
  for target in primitive.morphTargets:
    checkLength(target.positionDeltas)
    checkLength(target.normalDeltas)
    checkLength(target.tangentDeltas)
  for i in 0 ..< count:
    for value in [primitive.points[i].x, primitive.points[i].y, primitive.points[i].z,
        primitive.normals[i].x, primitive.normals[i].y, primitive.normals[i].z,
        primitive.uvs[i].x, primitive.uvs[i].y]:
      if classify(value) in {fcNan, fcInf, fcNegInf}:
        raise newException(GltfError, "Non-finite vertex data in tangent generation")
  let corners = primitive.triangleCorners()
  if corners.len == 0: return
  if corners.len > high(cint).int:
    raise newException(GltfError, "Mesh exceeds MikkTSpace index range")
  for index in corners:
    if index.uint64 >= count.uint64:
      raise newException(GltfError, "Triangle index exceeds vertex count")
  static:
    doAssert sizeof(Vec2) == 2 * sizeof(float32)
    doAssert sizeof(Vec3) == 3 * sizeof(float32)
    doAssert sizeof(Vec4) == 4 * sizeof(float32)
  var generated = newSeq[Vec4](corners.len)
  if gltfGenerateMikkTangents(cast[ptr float32](primitive.points[0].addr),
      cast[ptr float32](primitive.normals[0].addr), cast[ptr float32](primitive.uvs[0].addr),
      corners[0].unsafeAddr, corners.len.cint, cast[ptr float32](generated[0].addr)) == 0:
    raise newException(GltfError, "MikkTSpace tangent generation failed")
  var
    vertices = newSeq[int](count)
    tangents = newSeq[Vec4](count)
    assigned = newSeq[bool](count)
    splitVertices: Table[(uint32, array[4, uint32]), uint32]
    indices = newSeq[uint32](corners.len)
  for i in 0 ..< count:
    vertices[i] = i
    tangents[i] = vec4(1, 0, 0, 1) # Unreferenced vertices have no tangent frame.
  for corner, original in corners:
    let tangent = generated[corner]
    let key = (original, [cast[uint32](tangent.x), cast[uint32](tangent.y),
      cast[uint32](tangent.z), cast[uint32](tangent.w)])
    if key in splitVertices:
      indices[corner] = splitVertices[key]
    else:
      var destination = original
      if assigned[original.int]:
        destination = vertices.len.uint32
        vertices.add(original.int)
        tangents.add(tangent)
      else:
        assigned[original.int] = true
        tangents[original.int] = tangent
      splitVertices[key] = destination
      indices[corner] = destination
  primitive.points = remap(primitive.points, vertices)
  primitive.normals = remap(primitive.normals, vertices)
  primitive.uvs = remap(primitive.uvs, vertices)
  primitive.uvs1 = remap(primitive.uvs1, vertices)
  primitive.colors = remap(primitive.colors, vertices)
  primitive.jointIds = remap(primitive.jointIds, vertices)
  primitive.jointWeights = remap(primitive.jointWeights, vertices)
  primitive.basePoints = remap(primitive.basePoints, vertices)
  primitive.baseNormals = remap(primitive.baseNormals, vertices)
  for i, target in primitive.morphTargets:
    primitive.morphTargets[i] = MorphTarget(
      positionDeltas: remap(target.positionDeltas, vertices),
      normalDeltas: remap(target.normalDeltas, vertices),
      tangentDeltas: remap(target.tangentDeltas, vertices))
  let unindexed = primitive.mode == TrianglesMode and
    primitive.indices16.len == 0 and primitive.indices32.len == 0
  if not unindexed:
    if primitive.indices32.len > 0 or vertices.len > 65536:
      primitive.indices32 = indices
      primitive.indices16.setLen(0)
    else:
      primitive.indices16 = newSeq[uint16](indices.len)
      for i, value in indices: primitive.indices16[i] = value.uint16
      primitive.indices32.setLen(0)
  primitive.mode = TrianglesMode
  primitive.tangents = tangents
  primitive.baseTangents = tangents
  inc primitive.geometryVersion
