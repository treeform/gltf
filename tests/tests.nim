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

echo "Testing KHR_node_visibility."
let visibilityBuffer =
  "\0\0\0\0" &
  "\0\0\x80\x3f" &
  "\x01\x00"
let visibilityModel = loadModelJson(
  %*{
    "asset": {"version": "2.0"},
    "extensionsRequired": ["KHR_node_visibility"],
    "extensionsUsed": ["KHR_node_visibility", "KHR_animation_pointer"],
    "buffers": [
      {
        "byteLength": 10
      }
    ],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 8},
      {"buffer": 0, "byteOffset": 8, "byteLength": 2}
    ],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"},
      {"bufferView": 1, "componentType": 5121, "count": 2, "type": "SCALAR"}
    ],
    "images": [],
    "textures": [],
    "samplers": [],
    "materials": [],
    "meshes": [],
    "nodes": [
      {"name": "RootVisibility", "children": [1, 2]},
      {
        "name": "InvisibleNode",
        "extensions": {"KHR_node_visibility": {"visible": false}}
      },
      {
        "name": "AnimatedNode",
        "extensions": {"KHR_node_visibility": {"visible": true}}
      }
    ],
    "animations": [
      {
        "channels": [
          {
            "sampler": 0,
            "target": {
              "extensions": {
                "KHR_animation_pointer": {
                  "pointer": "/nodes/2/extensions/KHR_node_visibility/visible"
                }
              }
            }
          }
        ],
        "samplers": [
          {"input": 0, "output": 1, "interpolation": "STEP"}
        ]
      }
    ],
    "scenes": [{"nodes": [0]}],
    "scene": 0
  },
  ".",
  @[visibilityBuffer]
)
var invisibleNode, animatedNode: Node
for node in visibilityModel.walkNodes():
  if node.name == "InvisibleNode":
    invisibleNode = node
  elif node.name == "AnimatedNode":
    animatedNode = node
doAssert invisibleNode != nil
doAssert animatedNode != nil
doAssert invisibleNode.visible == false
doAssert animatedNode.visible == true
applyClipAt(visibilityModel.animations[0], 0.75)
doAssert invisibleNode.visible == false
doAssert animatedNode.visible == true
applyClipAt(visibilityModel.animations[0], 1.0)
doAssert invisibleNode.visible == false
doAssert animatedNode.visible == false

echo "Testing glTF cameras."
let cameraModel = loadModelJson(
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
    "cameras": [
      {
        "name": "PerspectiveCamera",
        "type": "perspective",
        "perspective": {
          "yfov": 0.78539816339,
          "znear": 0.1,
          "zfar": 50.0
        }
      },
      {
        "name": "OrthoCamera",
        "type": "orthographic",
        "orthographic": {
          "xmag": 2.0,
          "ymag": 1.5,
          "znear": 0.01,
          "zfar": 100.0
        }
      }
    ],
    "nodes": [
      {
        "name": "PerspectiveNode",
        "camera": 0
      },
      {
        "name": "OrthoNode",
        "camera": 1
      }
    ],
    "scenes": [{"nodes": [0, 1]}],
    "scene": 0,
    "animations": []
  },
  ".",
  @[]
)
let perspectiveNode = cameraModel["PerspectiveNode"]
let orthoNode = cameraModel["OrthoNode"]
doAssert perspectiveNode != nil
doAssert orthoNode != nil
doAssert perspectiveNode.camera != nil
doAssert orthoNode.camera != nil
doAssert perspectiveNode.camera.kind == ckPerspective
doAssert orthoNode.camera.kind == ckOrthographic
doAssert abs(perspectiveNode.camera.perspective.yfov - 0.7853982) < 0.0001
doAssert abs(orthoNode.camera.orthographic.xmag - 2.0) < 0.0001

echo "Testing primitive mode parsing."
let primitiveModeBuffer =
  "\0\0\0\0" &
  "\0\0\0\0" &
  "\0\0\0\0" &
  "\0\0\x80\x3f" &
  "\0\0\0\0" &
  "\0\0\0\0"
let primitiveModeModel = loadModelJson(
  %*{
    "asset": {"version": "2.0"},
    "buffers": [
      {
        "byteLength": 24
      }
    ],
    "bufferViews": [
      {"buffer": 0, "byteOffset": 0, "byteLength": 24}
    ],
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 2, "type": "VEC3"}
    ],
    "images": [],
    "textures": [],
    "samplers": [],
    "materials": [],
    "meshes": [
      {
        "name": "LineStripMesh",
        "primitives": [
          {
            "attributes": {
              "POSITION": 0
            },
            "mode": 3
          }
        ]
      }
    ],
    "nodes": [
      {
        "name": "LineStripNode",
        "mesh": 0
      }
    ],
    "scenes": [{"nodes": [0]}],
    "scene": 0,
    "animations": []
  },
  ".",
  @[primitiveModeBuffer]
)
let lineStripNode = primitiveModeModel["LineStripNode"]
doAssert lineStripNode != nil
doAssert lineStripNode.mesh != nil
doAssert lineStripNode.mesh.primitives.len == 1
doAssert lineStripNode.mesh.primitives[0].mode.int == 3
