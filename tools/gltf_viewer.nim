import
  std/os,
  gltf

let params = commandLineParams()
if params.len == 0:
  quit("Usage: nim r tools/gltf_viewer.nim <model.gltf>", 1)

let path = params[0]
let options = initLoadOptions()
let config = initRendererConfig()

echo "glTF viewer scaffold."
echo "Model path: ", path
echo "Load buffers: ", options.loadBuffers
echo "Use PBR: ", config.usePbr
echo "Hook this up to the future window and renderer code."
