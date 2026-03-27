import
  std/os,
  gltf

let params = commandLineParams()
if params.len == 0:
  quit("Usage: nim r examples/load_model.nim <model.gltf>", 1)

let path = params[0]
let options = initLoadOptions()

echo "Example project scaffold."
echo "Model path: ", path
echo "Load buffers: ", options.loadBuffers
echo "Load images: ", options.loadImages
echo "Call gltf.loadDocument(path) when the loader is implemented."
