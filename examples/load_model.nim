import
  std/os,
  gltf

let params = commandLineParams()
if params.len == 0:
  quit("Usage: nim r examples/load_model.nim <model.gltf>", 1)

let path = params[0]
let gltfFile = readGltfFile(path)

echo "Loaded glTF file."
echo "Model path: ", gltfFile.path
echo "Root node name: ", gltfFile.root.name
echo "Child count: ", gltfFile.root.nodes.len
