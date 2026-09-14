import std/[math, json, os], vmath, chroma,
  gltf/[common, reader, tangents, animations]

const PatchTangents = [
  vec4(0.51449573, 0, 0.8574929, -1),
  vec4(0.5994515, 0, -0.8004111, -1),
  vec4(0.9040572, 0, 0.42741153, -1),
  vec4(0.993122, 0, 0.11708446, -1),
  vec4(0.97987956, 0.09354092, -0.1763128, -1),
  vec4(0.957183, 0.15017736, 0.24748248, -1),
  vec4(0.5183045, 0, -0.8551961, -1),
  vec4(0.60415673, 0.1841859, 0.7752872, -1),
  vec4(0.83857596, 0.45460436, -0.30020875, -1)
]

proc triangle(): Primitive =
  ## Create an unindexed triangle with a simple UV mapping.
  Primitive(mode: TrianglesMode,
    points: @[vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0)],
    normals: @[vec3(0, 0, 1), vec3(0, 0, 1), vec3(0, 0, 1)],
    uvs: @[vec2(0, 0), vec2(1, 0), vec2(0, 1)])

proc checkFinite(primitive: Primitive) =
  ## Require finite unit tangents after generation and deformation.
  for tangent in primitive.tangents:
    for component in [tangent.x, tangent.y, tangent.z, tangent.w]:
      doAssert classify(component) notin {fcNan, fcInf, fcNegInf}
    doAssert abs(length(tangent.xyz) - 1) < 0.00001'f

proc curvedPatch(): Primitive =
  ## Build a curved patch with nonuniform tangent directions and angles.
  result = Primitive(mode: TrianglesMode)
  for y in 0 ..< 3:
    for x in 0 ..< 3:
      let
        u = x.float32 / 2
        v = y.float32 / 2
        height = sin(u * 5) * cos(v * 3)
        normal = vec3(
          -5 * cos(u * 5) * cos(v * 3) / 3,
          3 * sin(u * 5) * sin(v * 3) / 2,
          1
        )
      result.points.add(vec3(u * 3, v * 2, height))
      result.normals.add(normalize(normal))
      result.uvs.add(vec2(u, v))
  for y in 0 ..< 2:
    for x in 0 ..< 2:
      let i = (y * 3 + x).uint32
      result.indices32.add([i, i + 1, i + 3, i + 1, i + 4, i + 3])

proc checkPatch(primitive: Primitive, vertices: seq[uint32]) =
  ## Compare every corner with output captured from the original C version.
  primitive.generateTangents()
  for i, source in vertices:
    let index =
      if primitive.indices32.len > 0:
        primitive.indices32[i].int
      else:
        i
    let tangent = primitive.tangents[index]
    doAssert length(tangent - PatchTangents[source]) < 0.00001'f
  primitive.checkFinite()

block curvedTangents:
  # Golden values use MikkTSpace revision 3e895b49d05ea07e4c2133156cfa94369e19e409.
  let mesh = curvedPatch()
  mesh.checkPatch(mesh.indices32)

block reorderedFaces:
  let
    mesh = curvedPatch()
    original = mesh.indices32
  for i in 0 ..< original.len div 3:
    for j in 0 ..< 3:
      mesh.indices32[i * 3 + j] = original[original.len - 3 - i * 3 +
        (j + 1) mod 3]
  mesh.checkPatch(mesh.indices32)

block weldedCorners:
  let
    source = curvedPatch()
    mesh = Primitive(mode: TrianglesMode)
  for index in source.indices32:
    var position = source.points[index]
    if position.x == 0 and mesh.points.len mod 2 == 0:
      position.x = -0.0'f
    mesh.points.add(position)
    mesh.normals.add(source.normals[index])
    mesh.uvs.add(source.uvs[index])
  mesh.checkPatch(source.indices32)

block collapsedUvNeighbor:
  let mesh = triangle()
  mesh.points.add(vec3(1, 1, 0))
  mesh.normals.add(vec3(0, 0, 1))
  mesh.uvs.add(vec2(1, 0))
  mesh.indices32 = @[0'u32, 1, 2, 1, 3, 2]
  mesh.generateTangents()
  for i in [0, 1, 2, 3, 5]:
    doAssert mesh.tangents[mesh.indices32[i]] == vec4(1, 0, 0, -1)
  doAssert mesh.tangents[mesh.indices32[4]] == vec4(1, 0, 0, 1)

block collapsedGeometry:
  let mesh = triangle()
  mesh.indices32 = @[0'u32, 0, 1, 0, 1, 2, 2, 2, 1]
  mesh.generateTangents()
  for index in mesh.indices32:
    doAssert mesh.tangents[index] == vec4(1, 0, 0, -1)

block isolatedDegenerate:
  let mesh = triangle()
  mesh.points[1] = mesh.points[0]
  mesh.generateTangents()
  for tangent in mesh.tangents:
    doAssert tangent == vec4(1, 0, 0, 1)

block opposingTangents:
  let mesh = triangle()
  mesh.points.add(vec3(1, 0, 0))
  mesh.normals.add(vec3(0, 0, 1))
  mesh.uvs.add(vec2(-1, 0))
  mesh.indices32 = @[0'u32, 1, 2, 0, 2, 3]
  mesh.generateTangents()
  doAssert mesh.points.len == 6
  for i in 0 ..< 3:
    doAssert mesh.tangents[mesh.indices32[i]] == vec4(1, 0, 0, -1)
    doAssert mesh.tangents[mesh.indices32[i + 3]] == vec4(-1, 0, 0, -1)

block hardNormals:
  let mesh = triangle()
  for i in 0 ..< 3:
    mesh.points.add(mesh.points[i])
    mesh.normals.add(normalize(vec3(1, 0, 1)))
    mesh.uvs.add(mesh.uvs[i])
  mesh.generateTangents()
  for i in 0 ..< 3:
    doAssert mesh.tangents[i] == vec4(1, 0, 0, -1)
    doAssert length(mesh.tangents[i + 3].xyz -
      normalize(vec3(1, 0, -1))) < 0.00001'f

block nonmanifoldEdge:
  # Four faces share one edge; pair opposite directions in face order.
  let mesh = Primitive(
    mode: TrianglesMode,
    points: @[vec3(0, 1, 0), vec3(0.5, -1, 0), vec3(1, 2, 0),
      vec3(-0.5, -1, 0), vec3(0, 0, 0), vec3(1, 0, 0)],
    normals: @[vec3(0, 0, 1), vec3(0, 0, 1), vec3(0, 0, 1),
      vec3(0, 0, 1), vec3(0, 0, 1), vec3(0, 0, 1)],
    uvs: @[vec2(0, 1), vec2(0, -1), vec2(0, 1), vec2(0, -1),
      vec2(0, 0), vec2(1, 1)],
    indices32: @[0'u32, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3,
      4, 5, 0, 5, 4, 1, 4, 5, 2, 5, 4, 3]
  )
  mesh.generateTangents()
  for i in [12, 16]:
    doAssert length(mesh.tangents[mesh.indices32[i]] -
      vec4(0.7623611, -0.6471518, 0, -1)) < 0.00001'f
  for i in [18, 22]:
    doAssert length(mesh.tangents[mesh.indices32[i]] -
      vec4(0.2968487, -0.9549246, 0, -1)) < 0.00001'f

block nonIndexed:
  let mesh = triangle()
  mesh.generateTangents()
  doAssert mesh.indices16.len == 0 and mesh.indices32.len == 0
  for tangent in mesh.tangents: doAssert tangent == vec4(1, 0, 0, -1)
  doAssert mesh.baseTangents == mesh.tangents
  let previousVersion = mesh.geometryVersion
  mesh.generateTangents()
  doAssert mesh.geometryVersion == previousVersion # Authored/existing data is preserved.

block mirroredSeam:
  # The two triangles share an index but need opposite tangent frames.
  let mesh = Primitive(mode: TrianglesMode,
    points: @[vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0), vec3(-1, 0, 0)],
    normals: @[vec3(0, 0, 1), vec3(0, 0, 1), vec3(0, 0, 1), vec3(0, 0, 1)],
    uvs: @[vec2(0, 0), vec2(1, 0), vec2(0, 1), vec2(1, 0)],
    uvs1: @[vec2(10, 0), vec2(11, 0), vec2(12, 0), vec2(13, 0)],
    indices16: @[0'u16, 1, 2, 0, 2, 3],
    colors: @[rgbx(10, 0, 0, 255), rgbx(11, 0, 0, 255), rgbx(12, 0, 0, 255), rgbx(13, 0, 0, 255)],
    jointIds: @[[0'u16, 1, 2, 3], [1'u16, 2, 3, 4], [2'u16, 3, 4, 5], [3'u16, 4, 5, 6]],
    jointWeights: @[vec4(1, 0, 0, 0), vec4(0, 1, 0, 0), vec4(0, 0, 1, 0), vec4(0, 0, 0, 1)],
    morphTargets: @[MorphTarget(positionDeltas: @[vec3(0, 0, 1), vec3(0, 0, 2), vec3(0, 0, 3), vec3(0, 0, 4)])])
  mesh.generateTangents()
  doAssert mesh.points.len == 6
  doAssert mesh.indices16[0] != mesh.indices16[3]
  doAssert mesh.tangents[mesh.indices16[0]].w == -mesh.tangents[mesh.indices16[3]].w
  for i in 0 ..< mesh.points.len:
    let original = mesh.uvs1[i].x.int - 10
    doAssert mesh.colors[i].r.int == original + 10
    doAssert mesh.jointIds[i][0].int == original
    doAssert mesh.jointWeights[i][original] == 1
    doAssert mesh.morphTargets[0].positionDeltas[i].z == (original + 1).float32
  mesh.basePoints = mesh.points
  mesh.baseNormals = mesh.normals
  let node = Node(mesh: Mesh(primitives: @[mesh]), morphWeights: @[0.5'f])
  node.updateAnimation(0)
  doAssert mesh.tangents.len == 6 and mesh.baseTangents.len == 6
  for i in 0 ..< 6:
    doAssert mesh.tangents[i] == mesh.baseTangents[i]
    doAssert mesh.points[i].z == mesh.morphTargets[0].positionDeltas[i].z * 0.5'f
  mesh.checkFinite()

block degenerateUvs:
  let mesh = triangle()
  mesh.uvs = @[vec2(0), vec2(0), vec2(0)]
  mesh.generateTangents()
  mesh.checkFinite()

for mode in [TriangleStripMode, TriangleFanMode]:
  let mesh = triangle()
  mesh.points.add(vec3(1, 1, 0))
  mesh.normals.add(vec3(0, 0, 1))
  mesh.uvs.add(vec2(1, 1))
  mesh.mode = mode
  mesh.generateTangents()
  doAssert mesh.mode == TrianglesMode and mesh.indices16.len == 6
  mesh.checkFinite()

block invalidIndices:
  let mesh = triangle()
  mesh.indices32 = @[0'u32, 1, 100]
  var rejected = false
  try: mesh.generateTangents()
  except GltfError: rejected = true
  doAssert rejected and mesh.tangents.len == 0

block authored:
  let mesh = triangle()
  mesh.tangents = @[vec4(0, 1, 0, 1), vec4(0, 1, 0, -1), vec4(0, 1, 0, 1)]
  let original = mesh.tangents
  mesh.generateTangents()
  doAssert mesh.tangents == original

block readerMorphBase:
  # Generation must happen before the reader saves bind-pose attributes.
  # Otherwise the first morph update restores an empty tangent array.
  var data = @[0'f, 0, 0, 1, 0, 0, 0, 1, 0,
    0'f, 0, 1, 0, 0, 1, 0, 0, 1,
    0'f, 0, 1, 0, 0, 1,
    0'f, 0, 0.1, 0, 0, 0.2, 0, 0, 0.3]
  var buffer = newString(data.len * 4)
  copyMem(buffer[0].addr, data[0].addr, buffer.len)
  let root = loadModelJson(%*{
    "asset": {"version": "2.0"}, "buffers": [{"byteLength": 132}],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 36},
      {"buffer": 0, "byteOffset": 36, "byteLength": 36},
      {"buffer": 0, "byteOffset": 72, "byteLength": 24},
      {"buffer": 0, "byteOffset": 96, "byteLength": 36}],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
      {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"},
      {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2"},
      {"bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [], "textures": [], "samplers": [], "materials": [],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
      "targets": [{"POSITION": 3}]}], "weights": [0.5]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0,
    "animations": []}, ".", @[buffer])
  let mesh = root.nodes[0].mesh.primitives[0]
  doAssert mesh.baseTangents.len == 3 and mesh.tangents == mesh.baseTangents
  root.updateAnimation(0)
  doAssert mesh.tangents.len == 3
  mesh.checkFinite()

if paramCount() == 2:
  # Optional integration check against the pinned renderer's WASM output.
  let gltf = readGltfFile(paramStr(1))
  let oracle = parseFile(paramStr(2))
  var primitive: Primitive
  proc visit(node: Node) =
    if node.mesh != nil: primitive = node.mesh.primitives[0]
    for child in node.nodes: visit(child)
  visit(gltf.root)
  var maxDifference = 0.0'f
  for i, reference in oracle["tangents"].elems:
    let index = if primitive.indices32.len > 0: primitive.indices32[i].int
      elif primitive.indices16.len > 0: primitive.indices16[i].int else: i
    for channel in 0 ..< 4:
      maxDifference = max(maxDifference, abs(primitive.tangents[index][channel] - reference[channel].getFloat().float32))
  doAssert maxDifference < 0.00001'f, "Tangent differs from Khronos: " & $maxDifference
  echo "Khronos tangent oracle: ", oracle["tangents"].len, " corners, max difference ", maxDifference
echo "Tangent generation: seams, signs, morphs, topology, authored data and degeneracy passed"
