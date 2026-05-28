import
  chroma, pixie, vmath, windy,
  ../../common,
  ../directx as impl

export
  impl.BackendName,
  impl.HasNativeRenderer,
  impl.VertexEntryPoint,
  impl.FragmentEntryPoint,
  impl.PbrVertexShader,
  impl.PbrFragmentShader,
  impl.SkyboxVertexShader,
  impl.SkyboxFragmentShader,
  impl.ShadowDepthVertexShader,
  impl.ShadowDepthFragmentShader,
  impl.perspectiveDxRh

type Renderer* = impl.DirectXRenderer

proc newRenderer*(window: Window): Renderer =
  impl.newDirectXRenderer(window)

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
  renderer.drawPbrFrame(
    node,
    params.size,
    params.clearColor,
    params.transform,
    params.view,
    params.proj,
    tint = params.tint,
    ambientLightColor = params.ambientLightColor,
    sunLightDirection = params.sunLightDirection,
    sunLightColor = params.sunLightColor,
    rimLightDirection = params.rimLightDirection,
    rimLightColor = params.rimLightColor,
    cameraPosition = params.cameraPosition,
    vsync = params.vsync
  )

proc render*(renderer: Renderer; file: GltfFile; params: RenderParams) =
  if file != nil:
    renderer.render(file.root, params)

proc endFrame*(renderer: Renderer) =
  discard renderer

proc captureScreenshot*(renderer: Renderer): Image =
  impl.captureScreenshot(renderer)

proc release*(renderer: Renderer; node: Node) =
  renderer.clearNode(node)

proc shutdown*(renderer: Renderer) =
  impl.shutdown(renderer)
