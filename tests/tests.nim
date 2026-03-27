import
  gltf

echo "Testing default load options."
let options = initLoadOptions()
doAssert options.loadBuffers
doAssert options.loadImages
doAssert options.formatHint == gfJson

echo "Testing renderer defaults."
let rendererConfig = initRendererConfig()
doAssert rendererConfig.usePbr
doAssert rendererConfig.loadEnvironment

echo "Testing empty document layout."
let document = Document()
doAssert document.scenes.len == 0
doAssert document.nodes.len == 0
doAssert document.meshes.len == 0
