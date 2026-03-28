import
  std/json,
  gltf,
  vmath

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

echo "Testing node matrix transforms."
let expectedMatrix = mat4(
  1.0, 0.0, 0.0, 0.0,
  0.0, 0.0, -1.0, 0.0,
  0.0, 1.0, 0.0, 0.0,
  1.5, 2.5, 3.5, 1.0
)
let model = loadModelJson(
  %*{
    "asset": {"version": "2.0"},
    "buffers": [],
    "bufferViews": [],
    "accessors": [],
    "images": [],
    "textures": [],
    "samplers": [],
    "materials": [],
    "meshes": [],
    "nodes": [
      {
        "name": "MatrixNode",
        "matrix": [
          1.0, 0.0, 0.0, 0.0,
          0.0, 0.0, -1.0, 0.0,
          0.0, 1.0, 0.0, 0.0,
          1.5, 2.5, 3.5, 1.0
        ]
      }
    ],
    "scenes": [{"nodes": [0]}],
    "scene": 0,
    "animations": []
  },
  ".",
  @[]
)
let matrixNode = model["MatrixNode"]
doAssert matrixNode != nil
doAssert matrixNode.pos == vec3(1.5, 2.5, 3.5)
doAssert matrixNode.trs ~= expectedMatrix
