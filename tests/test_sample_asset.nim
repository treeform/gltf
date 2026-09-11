import
  std/[json, os, sequtils, strformat],
  ../src/gltf/[models, reader]

let params = commandLineParams()
doAssert params.len == 2, "expected SAMPLE_PATH REQUIRED_EXTENSION"

let
  samplePath = params[0]
  requiredExtension = params[1]
  sampleJson = parseFile(samplePath)

doAssert sampleJson["extensionsRequired"].getElems().anyIt(
  it.getStr() == requiredExtension
)

let sample = readGltfFile(samplePath)
doAssert sample.root != nil
doAssert sample.root.hasGeometry()
doAssert requiredExtension notin sample.unsupportedUsedExtensions

var
  primitiveCount = 0
  pointCount = 0
for node in sample.root.walkNodes():
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      inc primitiveCount
      pointCount += primitive.points.len

doAssert primitiveCount > 0
doAssert pointCount > 0
echo &"Loaded {samplePath}: {primitiveCount} primitives, {pointCount} points"
