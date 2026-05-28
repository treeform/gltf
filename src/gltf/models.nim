import
  std/[strformat, math],
  vmath, chroma, pixie,
  common

proc trs*(node: Node): Mat4

proc shallowCopy*(node: Node): Node =
  ## Creates a shallow copy of a node.
  result = Node()
  result.name = node.name
  result.visible = node.visible
  result.pos = node.pos
  result.rot = node.rot
  result.scale = node.scale
  result.mat = node.mat

  result.baseVisible = node.baseVisible
  result.basePos = node.basePos
  result.baseRot = node.baseRot
  result.baseScale = node.baseScale

  result.animations = node.animations
  result.activeClips = node.activeClips
  result.animTime = node.animTime

  result.mesh = node.mesh
  result.skin = node.skin
  result.camera = node.camera
  result.nodes = node.nodes

proc defaultTextureSampler*(): TextureSampler =
  TextureSampler(
    magFilter: LinearMagFilter,
    minFilter: LinearMipmapLinearMinFilter,
    wrapS: RepeatWrap,
    wrapT: RepeatWrap
  )

proc wrapModeName(mode: TextureWrap): string =
  case mode
  of RepeatWrap:
    "repeat"
  of ClampToEdgeWrap:
    "clamp_to_edge"
  of MirroredRepeatWrap:
    "mirrored_repeat"

proc filterName(mode: TextureMagFilter): string =
  case mode
  of NearestMagFilter:
    "nearest"
  of LinearMagFilter:
    "linear"

proc filterName(mode: TextureMinFilter): string =
  case mode
  of NearestMinFilter:
    "nearest"
  of LinearMinFilter:
    "linear"
  of NearestMipmapNearestMinFilter:
    "nearest_mipmap_nearest"
  of LinearMipmapNearestMinFilter:
    "linear_mipmap_nearest"
  of NearestMipmapLinearMinFilter:
    "nearest_mipmap_linear"
  of LinearMipmapLinearMinFilter:
    "linear_mipmap_linear"

proc `$`*(sampler: TextureSampler): string =
  &"(magFilter: {filterName(sampler.magFilter)}, " &
  &"minFilter: {filterName(sampler.minFilter)}, " &
  &"wrapS: {wrapModeName(sampler.wrapS)}, " &
  &"wrapT: {wrapModeName(sampler.wrapT)})"

proc primitiveModeName*(mode: PrimitiveMode): string =
  ## Returns a readable primitive mode label.
  case mode
  of PointsMode:
    "POINTS"
  of LinesMode:
    "LINES"
  of LineLoopMode:
    "LINE_LOOP"
  of LineStripMode:
    "LINE_STRIP"
  of TrianglesMode:
    "TRIANGLES"
  of TriangleStripMode:
    "TRIANGLE_STRIP"
  of TriangleFanMode:
    "TRIANGLE_FAN"

proc updateTransforms*(
  node: Node,
  transform = mat4(),
  applyTrs = true
) =
  ## Updates world transforms for a node tree.
  if node == nil:
    return
  node.mat =
    if applyTrs:
      transform * node.trs
    else:
      transform
  for child in node.nodes:
    child.updateTransforms(node.mat)

proc hasGeometry*(primitive: Primitive): bool =
  primitive != nil and primitive.points.len > 0

proc hasGeometry*(mesh: Mesh): bool =
  if mesh == nil:
    return false
  for primitive in mesh.primitives:
    if primitive.hasGeometry():
      return true
  false

proc hasGeometry*(node: Node): bool =
  if node == nil:
    return false
  if node.mesh.hasGeometry():
    return true
  for child in node.nodes:
    if child.hasGeometry():
      return true
  false

proc markGeometryDirty*(primitive: Primitive) =
  ## Marks CPU geometry changed so the selected backend can refresh resources.
  if primitive != nil:
    inc primitive.geometryVersion

proc markMaterialDirty*(material: Material) =
  ## Marks CPU material data changed so the selected backend can refresh resources.
  if material != nil:
    inc material.materialVersion

proc markSceneDirty*(file: GltfFile) =
  ## Marks CPU scene data changed so the selected backend can refresh resources.
  if file != nil:
    inc file.sceneVersion

proc computeSmoothNormals*(prim: Primitive) =
  ## Generates smooth normals by accumulating face normals per vertex.
  if prim.normals.len > 0 or prim.points.len == 0:
    return
  prim.normals = newSeq[Vec3](prim.points.len)
  template accumulateTri(ia, ib, ic: int) =
    let
      a = prim.points[ia]
      b = prim.points[ib]
      c = prim.points[ic]
      n = cross(b - a, c - a)
    prim.normals[ia] += n
    prim.normals[ib] += n
    prim.normals[ic] += n
  if prim.indices32.len > 0:
    for i in countup(0, prim.indices32.len - 3, 3):
      accumulateTri(
        prim.indices32[i + 0].int,
        prim.indices32[i + 1].int,
        prim.indices32[i + 2].int
      )
  elif prim.indices16.len > 0:
    for i in countup(0, prim.indices16.len - 3, 3):
      accumulateTri(
        prim.indices16[i + 0].int,
        prim.indices16[i + 1].int,
        prim.indices16[i + 2].int
      )
  else:
    for i in countup(0, prim.points.len - 3, 3):
      accumulateTri(i, i + 1, i + 2)
  for i in 0 ..< prim.normals.len:
    let len = length(prim.normals[i])
    prim.normals[i] =
      if len <= 0.000001'f:
        vec3(0, 1, 0)
      else:
        prim.normals[i] / len

proc ensureNormals*(node: Node) =
  ## Generates smooth normals for any primitive in the tree that lacks them.
  if node == nil:
    return
  if node.mesh != nil:
    for prim in node.mesh.primitives:
      prim.computeSmoothNormals()
  for child in node.nodes:
    child.ensureNormals()

proc trs*(node: Node): Mat4 =
  ## Get the transformation matrix of a node.
  translate(node.pos) *
    node.rot.mat4() *
    scale(node.scale)

proc findTransform*(
  node, target: Node,
  transform = mat4(),
  world: var Mat4
): bool =
  ## Finds the world transform for a node in a tree.
  if node == nil or target == nil:
    return false
  let current = transform * node.trs
  if node == target:
    world = current
    return true
  for child in node.nodes:
    if findTransform(child, target, current, world):
      return true
  false

proc skinMatrices*(root, node: Node): seq[Mat4] =
  ## Computes joint matrices for a skinned node.
  if root == nil or node == nil or node.skin == nil:
    return
  let inverseNode = node.mat.inverse
  result.setLen(node.skin.joints.len)
  for i, joint in node.skin.joints:
    let inverseBind =
      if i < node.skin.inverseBindMatrices.len:
        node.skin.inverseBindMatrices[i]
      else:
        mat4()
    result[i] = inverseNode * joint.mat * inverseBind

proc dumpTree*(node: Node, indent: string = "") =
  ## Prints the node tree for debugging.
  echo &"{indent}{node.name}"

  # Print the transform values.
  echo &"{indent}  pos: {node.pos}"
  let euler =
    node.rot
      .mat4()
      .toAngles()
      .toDegrees()
  echo &"{indent}  rot: {node.rot} ({euler})"
  echo &"{indent}  scale: {node.scale}"
  if node.camera != nil:
    echo &"{indent}  camera: {node.camera.name}"

  if node.mesh != nil:
    echo &"{indent}  mesh: {node.mesh.name}"
    echo &"{indent}  primitives: {node.mesh.primitives.len}"
    for i, primitive in node.mesh.primitives:
      let prefix = indent & &"    primitive[{i}]"
      if primitive.material != nil:
        echo &"{prefix} material: {primitive.material.name}"
        if primitive.material.baseColor != nil:
          echo &"{prefix} baseColor: {primitive.material.baseColor}"
          echo &"{prefix} baseColorFactor: {primitive.material.baseColorFactor}"
          echo &"{prefix} baseColorSampler: {primitive.material.baseColorSampler}"
        if primitive.material.metallicRoughness != nil:
          echo &"{prefix} metallicRoughness: {primitive.material.metallicRoughness}"
          echo &"{prefix} metallicRoughnessSampler: {primitive.material.metallicRoughnessSampler}"
        echo &"{prefix} metallicFactor: {primitive.material.metallicFactor}"
        echo &"{prefix} roughnessFactor: {primitive.material.roughnessFactor}"
        if primitive.material.normal != nil:
          echo &"{prefix} normal: {primitive.material.normal}"
          echo &"{prefix} normalSampler: {primitive.material.normalSampler}"
          echo &"{prefix} normalScale: {primitive.material.normalScale}"
        if primitive.material.occlusion != nil:
          echo &"{prefix} occlusion: {primitive.material.occlusion}"
          echo &"{prefix} occlusionSampler: {primitive.material.occlusionSampler}"
          echo &"{prefix} occlusionStrength: {primitive.material.occlusionStrength}"
        if primitive.material.emissive != nil:
          echo &"{prefix} emissive: {primitive.material.emissive}"
          echo &"{prefix} emissiveSampler: {primitive.material.emissiveSampler}"
          echo &"{prefix} emissiveFactor: {primitive.material.emissiveFactor}"
        if primitive.material.alphaMode == MaskAlphaMode:
          echo &"{prefix} alphaMode: Mask"
          echo &"{prefix} alphaCutoff: {primitive.material.alphaCutoff}"
        elif primitive.material.alphaMode == BlendAlphaMode:
          echo &"{prefix} alphaMode: Blend"
        else:
          echo &"{prefix} alphaMode: Opaque"
        echo &"{prefix} transmissionFactor: {primitive.material.transmissionFactor}"
        echo &"{prefix} doubleSided: {primitive.material.doubleSided}"

      if primitive.points.len > 0:
        echo &"{prefix} points: {primitive.points.len}"
      if primitive.uvs.len > 0:
        echo &"{prefix} uvs: {primitive.uvs.len}"
      if primitive.uvs1.len > 0:
        echo &"{prefix} uvs1: {primitive.uvs1.len}"
      if primitive.normals.len > 0:
        echo &"{prefix} normals: {primitive.normals.len}"
      if primitive.tangents.len > 0:
        echo &"{prefix} tangents: {primitive.tangents.len}"
      if primitive.colors.len > 0:
        echo &"{prefix} colors: {primitive.colors.len}"
      if primitive.indices16.len > 0:
        echo &"{prefix} indices (16bit): {primitive.indices16.len}"
      if primitive.indices32.len > 0:
        echo &"{prefix} indices (32bit): {primitive.indices32.len}"
      echo &"{prefix} mode: {primitiveModeName(primitive.mode)}"

  for n in node.nodes:
    n.dumpTree(indent & "  ")

proc walkNodes*(node: Node): seq[Node] =
  ## Walk the nodes tree and return a flat list of nodes.
  proc innerWalk(node: Node, arr: var seq[Node]) =
    arr.add(node)
    for n in node.nodes:
      innerWalk(n, arr)
  innerWalk(node, result)

proc center*(a: AABounds): Vec3 =
  ## Get the center of the axis-aligned bounding box.
  result = (a.min + a.max) / 2

proc radius*(a: AABounds): float =
  ## Get the radius of the axis-aligned bounding box.
  result = length(a.max - a.min) / 2

proc merge*(a, b: AABounds): AABounds =
  ## Merge two axis-aligned bounding boxes.
  result.min = min(a.min, b.min)
  result.max = max(a.max, b.max)

proc merge*(a, b: BoundingSphere): BoundingSphere =
  ## Merge two bounding spheres.
  var d = length(a.center - b.center)
  if d + b.radius <= a.radius:
    return a
  if d + a.radius <= b.radius:
    return b
  var r = (a.radius + d + b.radius) / 2
  return BoundingSphere(center: (a.center + b.center) / 2, radius: r)

proc getAABoundsNode*(node: Node, trs = mat4()): AABounds =
  ## Get the axis-aligned bounding box of the node.
  var bounds = AABounds()
  bounds.min = vec3(float32.high, float32.high, float32.high)
  bounds.max = vec3(float32.low, float32.low, float32.low)
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      for p in primitive.points:
        bounds.min = min(bounds.min, trs * p)
        bounds.max = max(bounds.max, trs * p)
  return bounds

proc getAABounds*(node: Node, trs = mat4()): AABounds =
  ## Get the axis-aligned bounding box of the node and its children.
  var bounds = getAABoundsNode(node, trs * node.trs)
  for n in node.nodes:
    bounds = bounds.merge(getAABounds(n, trs * node.trs))
  return bounds

proc computeBounds*(node: Node, trs = mat4()): Bounds =
  ## Computes a stable center, size, and radius for a node tree.
  let aabb = node.getAABounds(trs)
  if aabb.min.x > aabb.max.x or
     aabb.min.y > aabb.max.y or
     aabb.min.z > aabb.max.z:
    return Bounds(
      center: vec3(0, 0, 0),
      size: vec3(0, 0, 0),
      radius: 0
    )

  let size = aabb.max - aabb.min
  Bounds(
    center: aabb.center,
    size: size,
    radius: length(size) / 2
  )

proc getBoundingSphereNode*(node: Node, trs = mat4()): BoundingSphere =
  ## Get the bounding sphere of the node.
  if node.mesh == nil or not node.mesh.hasGeometry():
    return BoundingSphere(center: vec3(0, 0, 0), radius: 0)
  var center = vec3(0, 0, 0)
  var pointCount = 0
  for primitive in node.mesh.primitives:
    for p in primitive.points:
      center += trs * p
      inc pointCount
  if pointCount == 0:
    return BoundingSphere(center: vec3(0, 0, 0), radius: 0)
  center /= pointCount.float32
  var radius = 0.float32
  for primitive in node.mesh.primitives:
    for p in primitive.points:
      radius = max(radius, length(trs * p - center))
  return BoundingSphere(center: center, radius: radius)

proc getBoundingSphere*(node: Node, trs = mat4()): BoundingSphere =
  ## Get the bounding sphere of the node and its children.
  var bounds = getBoundingSphereNode(node, trs * node.trs)
  for n in node.nodes:
    bounds = bounds.merge(getBoundingSphere(n, trs * node.trs))
  return bounds

iterator triangles*(node: Node): (Vec3, Vec3, Vec3) =
  ## Triangles iterator for a node.
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      for i in 0 ..< primitive.indices16.len div 3:
        yield (
          primitive.points[primitive.indices16[i * 3 + 0]],
          primitive.points[primitive.indices16[i * 3 + 1]],
          primitive.points[primitive.indices16[i * 3 + 2]]
        )
      for i in 0 ..< primitive.indices32.len div 3:
        yield (
          primitive.points[primitive.indices32[i * 3 + 0]],
          primitive.points[primitive.indices32[i * 3 + 1]],
          primitive.points[primitive.indices32[i * 3 + 2]]
        )

proc `[]`*(node: Node, name: string): Node =
  ## Get a child node by name.
  for n in node.nodes:
    if n.name == name:
      return n
