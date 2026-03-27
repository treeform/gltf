import
  gltf

echo "Testing empty glTF file."
let gltfFile = GltfFile(
  path: "demo.glb",
  root: Node()
)
doAssert gltfFile.path == "demo.glb"
doAssert gltfFile.root != nil

echo "Testing bounding sphere defaults."
let bounds = gltfFile.root.getBoundingSphere()
doAssert bounds.radius == 0

echo "Testing node tree walking."
let nodes = gltfFile.root.walkNodes()
doAssert nodes.len == 1
