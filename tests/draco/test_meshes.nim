import
  std/[algorithm],
  gltf/draco/meshes {.all.},
  gltf/draco/types

proc makeSquareTable(): CornerTable =
  ## Builds a two-triangle corner table with one shared edge.
  CornerTable(
    faceCount: 2,
    cornerToVertex: @[0, 1, 2, 0, 2, 3],
    opposites: @[
      InvalidCorner, 5, InvalidCorner,
      InvalidCorner, InvalidCorner, 1
    ],
    vertexCorners: @[0, 1, 2, 5],
    vertexCount: 4
  )

proc testCornerNavigation() =
  ## Checks basic corner table navigation helpers.
  let table = makeSquareTable()
  doAssert table.cornerCount() == 6
  doAssert nextCorner(0) == 1
  doAssert nextCorner(2) == 0
  doAssert previousCorner(0) == 2
  doAssert previousCorner(2) == 1
  doAssert face(5) == 1
  doAssert table.vertex(3) == 0
  doAssert table.opposite(1) == 5
  doAssert table.leftMostCorner(3) == 5
  doAssert nextCorner(InvalidCorner) == InvalidCorner
  doAssert table.vertex(100) == InvalidVertex

proc testSwings() =
  ## Checks vertex swings across the shared square edge.
  let table = makeSquareTable()
  doAssert table.swingLeft(0) == 3
  doAssert table.swingRight(3) == 0
  doAssert table.swingLeft(3) == InvalidCorner
  doAssert table.swingRight(0) == InvalidCorner

proc testTraversalSequence() =
  ## Checks traversal order bookkeeping for attribute decoding.
  let table = makeSquareTable()
  var
    mesh = DracoMesh(
      pointCount: 4,
      faceCount: 2,
      faces: @[0'u32, 1, 2, 0, 2, 3]
    )
    data = EncodingData(vertexToValue: newSeq[int](4))
    sequence = table.generateSequence(mesh, data)
  sequence.sort()
  doAssert sequence == @[0, 1, 2, 3]
  doAssert data.valueCount == 4
  doAssert data.valueToCorner.len == 4

  var attr = DracoAttribute()
  attr.applyPointMap(table, mesh, data)
  doAssert attr.identityMap == false
  doAssert attr.pointMap.len == 4

proc runMeshTests*() =
  ## Runs Draco mesh connectivity tests.
  echo "Testing Draco meshes"
  testCornerNavigation()
  testSwings()
  testTraversalSequence()
