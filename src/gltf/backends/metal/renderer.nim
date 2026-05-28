import
  chroma, pixie, vmath, windy,
  ../../common,
  ../shaders as shaderSources

const
  VertexEntryPoint* = "vertexMain"
  FragmentEntryPoint* = "fragmentMain"

  PbrVertexShader* = shaderSources.PbrVertMsl
  PbrFragmentShader* = shaderSources.PbrFragMsl
  SkyboxVertexShader* = shaderSources.SkyboxVertMsl
  SkyboxFragmentShader* = shaderSources.SkyboxFragMsl
  ShadowDepthVertexShader* = shaderSources.ShadowDepthVertMsl
  ShadowDepthFragmentShader* = shaderSources.ShadowDepthFragMsl

type Renderer* = ref object
  window*: Window

proc newRenderer*(window: Window): Renderer =
  Renderer(window: window)

proc beginFrame*(renderer: Renderer; window: Window; size: IVec2) =
  discard renderer
  discard window
  discard size

proc clearScreen*(renderer: Renderer; color: ColorRGBX) =
  discard renderer
  discard color

proc clearScreen*(renderer: Renderer; color: Color) =
  discard renderer
  discard color

proc render*(renderer: Renderer; node: Node; params: RenderParams) =
  discard renderer
  discard node
  discard params

proc render*(renderer: Renderer; file: GltfFile; params: RenderParams) =
  discard renderer
  discard file
  discard params

proc endFrame*(renderer: Renderer) =
  discard renderer

proc captureScreenshot*(renderer: Renderer): Image =
  discard renderer
  raise newException(GltfError, "Metal renderer capture is not implemented yet")

proc release*(renderer: Renderer; node: Node) =
  discard renderer
  discard node

proc shutdown*(renderer: Renderer) =
  discard renderer
