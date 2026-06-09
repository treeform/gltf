import
  gltf/draco/attributes {.all.},
  helpers

proc testOctInitialization() =
  ## Checks octahedral helper quantization setup.
  var tool: OctTool
  tool.setMaxQuantizedValue(15)
  doAssert tool.integerVectorToOct([7'i32, 0, 0]) == [7'i32, 7]
  doAssert approx(tool.octToUnit(7, 7), [1.0'f, 0.0'f, 0.0'f])

  expectDracoError:
    tool.setMaxQuantizedValue(14)
  expectDracoError:
    tool.setOctBits(1)
  expectDracoError:
    tool.setOctBits(31)

proc testCanonicalization() =
  ## Checks canonicalized octahedral edge coordinates.
  var tool: OctTool
  tool.setOctBits(4)
  doAssert tool.canonicalizeOctahedralCoords(0, 0) == [14'i32, 14]
  doAssert tool.canonicalizeOctahedralCoords(0, 14) == [14'i32, 14]
  doAssert tool.canonicalizeOctahedralCoords(14, 0) == [14'i32, 14]
  doAssert tool.canonicalizeOctahedralCoords(0, 10) == [0'i32, 4]
  doAssert tool.canonicalizeOctahedralCoords(14, 4) == [14'i32, 10]
  doAssert tool.canonicalizeOctahedralCoords(4, 14) == [10'i32, 14]
  doAssert tool.canonicalizeOctahedralCoords(10, 0) == [4'i32, 0]

proc checkRotate(
  sIn, tIn: int32,
  count: int,
  expected: array[2, int32]
) =
  ## Checks one octahedral quarter-turn rotation.
  let rotated = rotatePoint(sIn, tIn, count)
  doAssert [rotated.s, rotated.t] == expected

proc testCanonicalRotation() =
  ## Checks canonicalized octahedral rotation helpers.
  doAssert isBottomLeft(0, 0)
  doAssert isBottomLeft(-1, -1)
  doAssert isBottomLeft(-7, -7)
  doAssert not isBottomLeft(1, 1)
  doAssert not isBottomLeft(-1, 1)
  doAssert not isBottomLeft(1, -1)

  doAssert rotationCount(1, 2) == 2
  doAssert rotationCount(-1, 2) == 3
  doAssert rotationCount(1, -2) == 1
  doAssert rotationCount(-1, -2) == 0
  doAssert rotationCount(0, 2) == 3
  doAssert rotationCount(0, -2) == 1
  doAssert rotationCount(2, 0) == 2
  doAssert rotationCount(-2, 0) == 0
  doAssert rotationCount(0, 0) == 0

  checkRotate(1, 2, 3, [-2'i32, 1])
  checkRotate(-1, -2, 3, [2'i32, -1])
  checkRotate(1, 1, 2, [-1'i32, -1])
  checkRotate(-1, -2, 2, [1'i32, 2])
  checkRotate(1, 2, 1, [2'i32, -1])
  checkRotate(1, -2, 1, [-2'i32, -1])
  checkRotate(-1, 2, 0, [-1'i32, 2])

proc testIntegerVectorToOct() =
  ## Checks integer normal conversion to octahedral coordinates.
  var tool: OctTool
  tool.setOctBits(4)
  doAssert tool.integerVectorToOct([7'i32, 0, 0]) == [7'i32, 7]
  doAssert tool.integerVectorToOct([-7'i32, 0, 0]) == [14'i32, 14]
  doAssert tool.integerVectorToOct([0'i32, 7, 0]) == [14'i32, 7]
  doAssert tool.integerVectorToOct([0'i32, 0, 7]) == [7'i32, 14]

proc testOctToUnit() =
  ## Checks octahedral coordinates converted back to unit vectors.
  var tool: OctTool
  tool.setOctBits(4)
  doAssert approx(tool.octToUnit(7, 7), [1.0'f, 0.0'f, 0.0'f])
  doAssert approx(tool.octToUnit(14, 14), [-1.0'f, 0.0'f, 0.0'f])
  doAssert approx(tool.octToUnit(14, 7), [0.0'f, 1.0'f, 0.0'f])
  doAssert approx(tool.octToUnit(7, 14), [0.0'f, 0.0'f, 1.0'f])

proc runOctTests*() =
  ## Runs Draco octahedral transform tests.
  echo "Testing Draco octahedral transforms"
  testOctInitialization()
  testCanonicalization()
  testCanonicalRotation()
  testIntegerVectorToOct()
  testOctToUnit()
