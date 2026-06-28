import
  std/math,
  chroma, windy, vmath,
  gltf

when not defined(emscripten):
  import opengl

const
  ModelPath = "examples/data/DamagedHelmet.glb"
  WindowSize = ivec2(1280, 800)
  VerticalFov = 45.0'f
  FitPadding = 1.25'f
  DragSpeed = 0.01'f
  ZoomSpeed = 0.92'f
  MinPitch = degToRad(-85.0'f)
  MaxPitch = degToRad(85.0'f)
  MinZoom = 0.25'f
  MaxZoom = 4.0'f
  BackgroundColor = color(0.7058824, 0.74509805, 0.8627451, 1.0)

type
  Orbit = object
    yaw: float32
    pitch: float32
    zoom: float32

var
  window: Window
  renderer: Renderer
  ctx: PbrContext
  gltfFile: GltfFile
  model: Node
  bounds: Bounds
  orbit = Orbit(
    yaw: degToRad(25.0'f),
    pitch: degToRad(18.0'f),
    zoom: 1.0'f
  )

proc safeNormalize(v, fallback: Vec3): Vec3 =
  ## Normalizes a vector and falls back when the length is too small.
  if v.lengthSq <= 0.000001'f:
    return fallback
  normalize(v)

proc fitCameraDolly(bounds: Bounds, aspectRatio: float32): float32 =
  ## Returns a camera dolly distance that fits bounds on screen.
  if bounds.radius <= 0:
    return 4
  let
    verticalHalfFov = degToRad(VerticalFov) / 2
    horizontalHalfFov = arctan(tan(verticalHalfFov) * aspectRatio)
    fitHalfFov = min(verticalHalfFov, horizontalHalfFov)
    fitDistance = bounds.radius / sin(fitHalfFov)
  max(0.01'f, fitDistance * FitPadding)

proc updateOrbit() =
  ## Updates the orbit camera from mouse drag and wheel input.
  if window.buttonDown[MouseLeft]:
    let delta = window.mouseDelta
    orbit.yaw += delta.x.float32 * DragSpeed
    orbit.pitch += delta.y.float32 * DragSpeed
    orbit.pitch = max(MinPitch, min(MaxPitch, orbit.pitch))

  let scroll = window.scrollDelta
  if scroll.y != 0:
    orbit.zoom *= pow(ZoomSpeed, scroll.y)
    orbit.zoom = max(MinZoom, min(MaxZoom, orbit.zoom))

proc renderFrame() =
  ## Renders one interactive frame.
  updateOrbit()
  let
    frameSize = ivec2(max(1, window.size.x), max(1, window.size.y))
    aspectRatio = frameSize.x.float32 / frameSize.y.float32
    cameraDolly = fitCameraDolly(bounds, aspectRatio) * orbit.zoom
    cameraMat =
      translate(vec3(0, 0, -cameraDolly)) *
      rotateX(orbit.pitch) *
      rotateY(orbit.yaw) *
      translate(-bounds.center)
    cameraPosition = vec3(cameraMat.inverse.pos)
    proj = perspective(VerticalFov, aspectRatio, 0.001, 2000)
    sunLightDirection = safeNormalize(
      vec3(1, -4, -2),
      vec3(1, -1, -1)
    )
    rimLightDirection = safeNormalize(
      vec3(-1, 1, -1),
      vec3(-1, 1, -1)
    )

  renderer.beginFrame(window, frameSize)
  renderer.clearScreen(BackgroundColor)
  ctx.size = frameSize
  ctx.clearColor = BackgroundColor
  ctx.transform = mat4()
  ctx.view = cameraMat
  ctx.proj = proj
  ctx.tint = color(1, 1, 1, 1)
  ctx.useTrs = true
  ctx.ambientLightColor = color(0.32, 0.36, 0.46, 0.18)
  ctx.sunLightDirection = sunLightDirection
  ctx.sunLightColor = color(0.95, 0.96, 1.0, 1.0)
  ctx.rimLightDirection = rimLightDirection
  ctx.rimLightColor = color(0.95, 0.72, 0.46, 0.25)
  ctx.debugView = dvLit
  ctx.cameraPosition = cameraPosition
  ctx.useShadows = false
  ctx.drawSkybox = false
  ctx.skyboxLod = 0
  ctx.vsync = false
  ctx.draw(model)
  renderer.endFrame()
  window.swapBuffers()

window = newWindow(
  "glTF Damaged Helmet",
  WindowSize,
  msaa = msaa4x
)
window.makeContextCurrent()
when not defined(emscripten):
  loadExtensions()

gltfFile = readGltfFile(ModelPath)
model = gltfFile.root
bounds = model.computeBounds()
renderer = newRenderer(window)
ctx = newPbrContext(renderer)
ctx.attachEnvironmentMap(loadDefaultEnvironmentMap())
window.onFrame = renderFrame

while not window.closeRequested:
  pollEvents()

if renderer != nil and model != nil:
  renderer.release(model)
if ctx != nil:
  ctx.destroy()
if renderer != nil:
  renderer.shutdown()
