#[
Nim adaptation of MikkTSpace's default triangle tangent generation.
Original: https://github.com/mmikk/MikkTSpace
Revision: 3e895b49d05ea07e4c2133156cfa94369e19e409.

Copyright (C) 2011 by Morten S. Mikkelsen

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
]#

import
  std/[algorithm, math, tables],
  vmath,
  common

const MinNormal = 1.1754943508222875e-38'f

type
  Triangle = object
    vertices: array[3, int]
    neighbors, groups: array[3, int]
    offset: int
    tangent, bitangent: Vec3
    valid, preserving: bool

  Edge = object
    first, last, face, corner: int

  Group = object
    vertex, first, count: int
    preserving: bool

proc usable(value: float32): bool {.inline, raises: [].} =
  ## Match the reference algorithm's minimum normal float threshold.
  abs(value) > MinNormal

proc usable(value: Vec3): bool {.inline, raises: [].} =
  ## Check components before normalizing a tangent or projected edge.
  usable(value.x) or usable(value.y) or usable(value.z)

proc project(direction, normal: Vec3): Vec3 {.raises: [].} =
  ## Project a direction onto the vertex's tangent plane and normalize it.
  result = direction - dot(normal, direction) * normal
  if usable(result):
    result *= 1.0'f / length(result)

proc weld(
  primitive: Primitive,
  corners: seq[uint32]
): seq[int] {.raises: [].} =
  ## Match identical positions, normals and UVs across separate indices.
  var vertices: Table[array[8, uint32], int]
  result = newSeq[int](corners.len)
  for i, source in corners:
    let
      vertex = source.int
      position = primitive.points[vertex]
      normal = primitive.normals[vertex]
      uv = primitive.uvs[vertex]
      components = [position.x, position.y, position.z,
        normal.x, normal.y, normal.z, uv.x, uv.y]
    var key: array[8, uint32]
    for j, value in components:
      # Positive and negative zero compare equal in the reference algorithm.
      if value != 0:
        key[j] = cast[uint32](value)
    result[i] = vertices.mgetOrPut(key, vertex)

proc triangles(
  primitive: Primitive,
  welded: seq[int]
): seq[Triangle] {.raises: [].} =
  ## Keep geometric degenerates last while preserving valid face order.
  var degenerates: seq[Triangle]
  for i in 0 ..< welded.len div 3:
    var triangle = Triangle(
      vertices: [welded[i * 3], welded[i * 3 + 1], welded[i * 3 + 2]],
      neighbors: [-1, -1, -1],
      groups: [-1, -1, -1],
      offset: i * 3
    )
    let
      position0 = primitive.points[triangle.vertices[0]]
      position1 = primitive.points[triangle.vertices[1]]
      position2 = primitive.points[triangle.vertices[2]]
    if position0 == position1 or position0 == position2 or
      position1 == position2:
        degenerates.add(triangle)
        continue
    let
      uv0 = primitive.uvs[triangle.vertices[0]]
      uv1 = primitive.uvs[triangle.vertices[1]] - uv0
      uv2 = primitive.uvs[triangle.vertices[2]] - uv0
      edge1 = position1 - position0
      edge2 = position2 - position0
      area = uv1.x * uv2.y - uv1.y * uv2.x
      tangent = uv2.y * edge1 - uv1.y * edge2
      bitangent = -uv2.x * edge1 + uv1.x * edge2
    triangle.preserving = area > 0
    if usable(area):
      let
        tangentLength = length(tangent)
        bitangentLength = length(bitangent)
        sign =
          if triangle.preserving:
            1.0'f
          else:
            -1.0'f
      if usable(tangentLength):
        triangle.tangent = (sign / tangentLength) * tangent
      if usable(bitangentLength):
        triangle.bitangent = (sign / bitangentLength) * bitangent
      triangle.valid = usable(tangentLength / abs(area)) and
        usable(bitangentLength / abs(area))
    result.add(triangle)
  result.add(degenerates)

proc connect(triangles: var seq[Triangle], count: int) {.raises: [].} =
  ## Pair oppositely directed welded edges, choosing earlier faces first.
  var edges = newSeqOfCap[Edge](count * 3)
  for face in 0 ..< count:
    for corner in 0 ..< 3:
      let
        first = triangles[face].vertices[corner]
        last = triangles[face].vertices[(corner + 1) mod 3]
      edges.add(Edge(
        first: min(first, last),
        last: max(first, last),
        face: face,
        corner: corner
      ))
  proc compare(first, second: Edge): int {.raises: [].} =
    ## Order edge endpoints and resolve nonmanifold ties by face number.
    result = cmp(first.first, second.first)
    if result == 0:
      result = cmp(first.last, second.last)
    if result == 0:
      result = cmp(first.face, second.face)
  edges.sort(compare)
  for i, edge in edges:
    if triangles[edge.face].neighbors[edge.corner] >= 0:
      continue
    let first = triangles[edge.face].vertices[edge.corner]
    var j = i + 1
    while j < edges.len and edges[j].first == edge.first and
      edges[j].last == edge.last:
        let other = edges[j]
        if triangles[other.face].neighbors[other.corner] < 0 and
          triangles[other.face].vertices[other.corner] != first:
            triangles[edge.face].neighbors[edge.corner] = other.face
            triangles[other.face].neighbors[other.corner] = edge.face
            break
        inc j

proc corner(triangle: Triangle, vertex: int): int {.raises: [].} =
  ## Find a welded vertex within a nondegenerate triangle.
  for i in 0 ..< 3:
    if triangle.vertices[i] == vertex:
      return i
  raiseAssert "Tangent group vertex is absent from its triangle"

proc groupFaces(
  triangles: var seq[Triangle],
  count: int,
  members: var seq[int]
): seq[Group] {.raises: [].} =
  ## Walk connected corners with matching normals, UVs and orientation.
  var pending: seq[int]
  for face in 0 ..< count:
    for i in 0 ..< 3:
      if not triangles[face].valid or triangles[face].groups[i] >= 0:
        continue
      let
        groupIndex = result.len
        vertex = triangles[face].vertices[i]
        preserving = triangles[face].preserving
        first = members.len
      pending.add(face)
      while pending.len > 0:
        let
          current = pending.pop()
          index = corner(triangles[current], vertex)
        if triangles[current].groups[index] >= 0:
          continue
        # The first group reaching a collapsed UV triangle sets its sign.
        if not triangles[current].valid and
          triangles[current].groups == [-1, -1, -1]:
            triangles[current].preserving = preserving
        if triangles[current].preserving != preserving:
          continue
        triangles[current].groups[index] = groupIndex
        members.add(current)
        let
          left = triangles[current].neighbors[index]
          right = triangles[current].neighbors[(index + 2) mod 3]
        # Visit the left edge first, matching the reference traversal.
        if right >= 0:
          pending.add(right)
        if left >= 0:
          pending.add(left)
      result.add(Group(
        vertex: vertex,
        first: first,
        count: members.len - first,
        preserving: preserving
      ))

proc evaluate(
  primitive: Primitive,
  triangles: seq[Triangle],
  members: seq[int],
  vertex: int
): Vec3 {.raises: [].} =
  ## Average projected face tangents using the vertex's corner angles.
  let normal = primitive.normals[vertex]
  for face in members:
    let triangle = triangles[face]
    if not triangle.valid:
      continue
    let
      index = corner(triangle, vertex)
      position = primitive.points[vertex]
      previous = primitive.points[triangle.vertices[(index + 2) mod 3]]
      next = primitive.points[triangle.vertices[(index + 1) mod 3]]
      edge1 = project(previous - position, normal)
      edge2 = project(next - position, normal)
      cosine = clamp(dot(edge1, edge2), -1.0'f, 1.0'f)
      angle = arccos(cosine.float64).float32
    result += angle * project(triangle.tangent, normal)
  if usable(result):
    result *= 1.0'f / length(result)

proc generateCorners(
  primitive: Primitive,
  corners: seq[uint32]
): seq[Vec4] {.raises: [].} =
  ## Generate the default MikkTSpace frame for every glTF triangle corner.
  let welded = weld(primitive, corners)
  var
    faces = triangles(primitive, welded)
    count = 0
    members: seq[int]
  while count < faces.len:
    let vertices = faces[count].vertices
    if primitive.points[vertices[0]] == primitive.points[vertices[1]] or
      primitive.points[vertices[0]] == primitive.points[vertices[2]] or
      primitive.points[vertices[1]] == primitive.points[vertices[2]]:
        break
    inc count
  connect(faces, count)
  let groups = groupFaces(faces, count, members)
  result = newSeq[Vec4](corners.len)
  for tangent in result.mitems:
    tangent = vec4(1, 0, 0, 1)
  var
    projectedTangents, projectedBitangents: seq[Vec3]
    subgroup: seq[int]
    subgroups: seq[seq[int]]
    tangents: seq[Vec3]
  for group in groups:
    let normal = primitive.normals[group.vertex]
    projectedTangents.setLen(group.count)
    projectedBitangents.setLen(group.count)
    subgroups.setLen(0)
    tangents.setLen(0)
    for i in 0 ..< group.count:
      let triangle = faces[members[group.first + i]]
      projectedTangents[i] = project(triangle.tangent, normal)
      projectedBitangents[i] = project(triangle.bitangent, normal)
    for i in 0 ..< group.count:
      let face = members[group.first + i]
      subgroup.setLen(0)
      for j in 0 ..< group.count:
        let other = members[group.first + j]
        # The default 180-degree threshold still separates opposing frames.
        if not faces[face].valid or not faces[other].valid or face == other or
          (dot(projectedTangents[i], projectedTangents[j]) > -1.0'f and
          dot(projectedBitangents[i], projectedBitangents[j]) > -1.0'f):
            subgroup.add(other)
      subgroup.sort()
      var index = 0
      while index < subgroups.len and subgroups[index] != subgroup:
        inc index
      if index == subgroups.len:
        subgroups.add(subgroup)
        tangents.add(evaluate(primitive, faces, subgroup, group.vertex))
      let
        offset = faces[face].offset + corner(faces[face], group.vertex)
        sign =
          if group.preserving:
            -1.0'f
          else:
            1.0'f
      # Negate MikkTSpace's sign for glTF's texture-coordinate convention.
      result[offset] = vec4(tangents[index], sign)
  var firstCorners = newSeq[int](primitive.points.len)
  for i in 0 ..< firstCorners.len:
    firstCorners[i] = -1
  for face in 0 ..< count:
    for i, vertex in faces[face].vertices:
      if firstCorners[vertex] < 0:
        firstCorners[vertex] = faces[face].offset + i
  for face in count ..< faces.len:
    for i, vertex in faces[face].vertices:
      let source = firstCorners[vertex]
      if source >= 0:
        result[faces[face].offset + i] = result[source]

proc triangleCorners(
  primitive: Primitive
): seq[uint32] {.raises: [GltfError].} =
  ## Expand indexed triangles, strips and fans into triangle corners.
  let count =
    if primitive.indices32.len > 0:
      primitive.indices32.len
    elif primitive.indices16.len > 0:
      primitive.indices16.len
    else:
      primitive.points.len
  template index(i: int): uint32 =
    ## Resolve a corner through the primitive's optional index stream.
    if primitive.indices32.len > 0:
      primitive.indices32[i]
    elif primitive.indices16.len > 0:
      primitive.indices16[i].uint32
    else:
      i.uint32
  case primitive.mode
  of TrianglesMode:
    if count mod 3 != 0:
      raise newException(
        GltfError,
        "Triangle vertex count must be divisible by three"
      )
    for i in 0 ..< count:
      result.add(index(i))
  of TriangleStripMode:
    for i in 2 ..< count:
      if i mod 2 == 0:
        result.add([index(i - 2), index(i - 1), index(i)])
      else:
        result.add([index(i - 1), index(i - 2), index(i)])
  of TriangleFanMode:
    for i in 2 ..< count:
      result.add([index(0), index(i - 1), index(i)])
  else:
    discard

proc remap[T](values: seq[T], vertices: seq[int]): seq[T] {.raises: [].} =
  ## Copy an attribute stream to the split vertex layout.
  if values.len == 0:
    return
  result = newSeq[T](vertices.len)
  for i, source in vertices:
    result[i] = values[source]

proc generateTangents*(primitive: Primitive) {.raises: [GltfError].} =
  ## Fill missing tangents in the bind pose, using TEXCOORD_0 like the Khronos
  ## renderer. Authored tangents and non-triangle primitives remain untouched.
  ## Split only vertices whose per-corner tangent differs. All vertex streams,
  ## skin weights and morph targets follow that same remapping.
  if primitive == nil or primitive.tangents.len > 0 or
    primitive.points.len == 0 or primitive.normals.len == 0 or
    primitive.uvs.len == 0 or
    primitive.mode notin {TrianglesMode, TriangleStripMode, TriangleFanMode}:
      return
  let count = primitive.points.len
  template checkLength(values: untyped) =
    ## Require populated attribute streams to match the position count.
    if values.len != 0 and values.len != count:
      raise newException(
        GltfError,
        "Vertex stream length differs from positions during tangent generation"
      )
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
    let
      position = primitive.points[i]
      normal = primitive.normals[i]
      uv = primitive.uvs[i]
    for value in [position.x, position.y, position.z,
      normal.x, normal.y, normal.z, uv.x, uv.y]:
      if classify(value) in {fcNan, fcInf, fcNegInf}:
        raise newException(
          GltfError,
          "Non-finite vertex data in tangent generation"
        )
  let corners = primitive.triangleCorners()
  if corners.len == 0:
    return
  for index in corners:
    if index.uint64 >= count.uint64:
      raise newException(GltfError, "Triangle index exceeds vertex count")
  let generated = generateCorners(primitive, corners)
  var
    vertices = newSeq[int](count)
    tangents = newSeq[Vec4](count)
    assigned = newSeq[bool](count)
    splitVertices: Table[(uint32, array[4, uint32]), uint32]
    indices = newSeq[uint32](corners.len)
  for i in 0 ..< count:
    vertices[i] = i
    # Unreferenced vertices have no tangent frame.
    tangents[i] = vec4(1, 0, 0, 1)
  for corner, original in corners:
    let tangent = generated[corner]
    let key = (original, [cast[uint32](tangent.x), cast[uint32](tangent.y),
      cast[uint32](tangent.z), cast[uint32](tangent.w)])
    if key in splitVertices:
      indices[corner] = splitVertices.getOrDefault(key)
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
      tangentDeltas: remap(target.tangentDeltas, vertices)
    )
  let unindexed = primitive.mode == TrianglesMode and
    primitive.indices16.len == 0 and primitive.indices32.len == 0
  if not unindexed:
    if primitive.indices32.len > 0 or vertices.len > 65536:
      primitive.indices32 = indices
      primitive.indices16.setLen(0)
    else:
      primitive.indices16 = newSeq[uint16](indices.len)
      for i, value in indices:
        primitive.indices16[i] = value.uint16
      primitive.indices32.setLen(0)
  primitive.mode = TrianglesMode
  primitive.tangents = tangents
  primitive.baseTangents = tangents
  inc primitive.geometryVersion
