import
  gltf/draco/attributes {.all.},
  gltf/draco/bitstreams,
  gltf/draco/meshes {.all.},
  gltf/draco/types

proc makePredictionGridTable(): CornerTable =
  ## Builds a grid where depth-first and prediction-degree traversal differ.
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

proc makePredictionGridMesh(): DracoMesh =
  ## Builds point ids matching the prediction-degree grid corner table.
  DracoMesh(
    pointCount: 16,
    faceCount: 18,
    faces: @[
      0'u32, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6,
      4, 5, 9, 4, 9, 8, 5, 6, 10, 5, 10, 9, 6, 7, 11, 6, 11, 10,
      8, 9, 13, 8, 13, 12, 9, 10, 14, 9, 14, 13, 10, 11, 15, 10, 15, 14
    ]
  )

proc testEdgebreakerControllerPredictionDegree() =
  ## Checks that edgebreaker attribute controllers preserve traversal method.
  var
    stream = initDracoStream(
      "\xff" & char(MeshVertexAttribute) & char(TraversalPredictionDegree)
    )
    state = EdgebreakerMesh(
      mesh: makePredictionGridMesh(),
      cornerTable: makePredictionGridTable(),
      posEncoding: EncodingData(vertexToValue: newSeq[int](16))
    )
    controller = readEdgebreakerController(stream, state, 0)

  controller.prepareController(state.mesh, state)
  var pointIds: seq[int]
  for corner in state.posEncoding.valueToCorner:
    pointIds.add(state.mesh.faces[corner].int)
  doAssert state.posDataDecoderId == 0
  doAssert pointIds == @[
    1, 5, 0, 4, 9, 10, 6, 2, 7, 11, 15, 14, 13, 8, 12, 3
  ]

proc runAttributeTests*() =
  ## Runs Draco attribute controller tests.
  echo "Testing Draco attributes"
  testEdgebreakerControllerPredictionDegree()
