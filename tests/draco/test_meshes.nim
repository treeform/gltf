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

proc makeGridTable(): CornerTable =
  ## Builds a 3x3 triangulated grid where traversal methods differ.
  CornerTable(
    faceCount: 18,
    cornerToVertex: @[
      0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6,
      4, 5, 9, 4, 9, 8, 5, 6, 10, 5, 10, 9, 6, 7, 11, 6, 11, 10,
      8, 9, 13, 8, 13, 12, 9, 10, 14, 9, 14, 13, 10, 11, 15, 10, 15, 14
    ],
    opposites: @[
      10, 5, -1, 20, -1, 1, 16, 11, -1, 26, 0, 7, -1, 17, -1, 32,
      6, 13, 28, 23, 3, 38, -1, 19, 34, 29, 9, 44, 18, 25, -1, 35,
      15, 50, 24, 31, 46, 41, 21, -1, -1, 37, 52, 47, 27, -1, 36,
      43, -1, 53, 33, -1, 42, 49
    ],
    vertexCorners: @[
      3, 9, 15, 13, 21, 27, 33, 31, 39, 45, 51, 49, 41, 47, 53, 52
    ],
    vertexCount: 16
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

proc testPredictionDegreeTraversal() =
  ## Checks the alternate traversal used by some edgebreaker attributes.
  let table = makeGridTable()
  var
    mesh = DracoMesh(
      pointCount: 16,
      faceCount: 18,
      faces: @[
        0'u32, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6,
        4, 5, 9, 4, 9, 8, 5, 6, 10, 5, 10, 9, 6, 7, 11, 6, 11, 10,
        8, 9, 13, 8, 13, 12, 9, 10, 14, 9, 14, 13, 10, 11, 15, 10, 15, 14
      ]
    )
    predictionData = EncodingData(vertexToValue: newSeq[int](16))
    predictionSequence =
      table.generateSequence(mesh, predictionData, TraversalPredictionDegree)

  doAssert predictionSequence == @[
    1, 5, 0, 4, 9, 10, 6, 2, 7, 11, 15, 14, 13, 8, 12, 3
  ]
  doAssert predictionData.valueCount == 16
  doAssert predictionData.valueToCorner.len == 16

proc runMeshTests*() =
  ## Runs Draco mesh connectivity tests.
  echo "Testing Draco meshes"
  testCornerNavigation()
  testSwings()
  testTraversalSequence()
  testPredictionDegreeTraversal()
