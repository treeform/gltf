import
  std/[os, strformat, strutils, times],
  opengl, windy, chroma, silky, vmath,
  ../src/gltf/[models, pbr, reader]

const
  AtlasPath = "tools/dist/atlas.png"
  FontPath = "/System/Library/Fonts/Supplemental/Arial.ttf"
  VerticalFov = 45'f32
  FitPadding = 1.25'f32

let params = commandLineParams()
if params.len == 0 or not fileExists(params[0]):
  quit("Usage: nim r tools/gltf_viewer.nim <model.gltf|model.glb>", 1)

var window = newWindow(
  "glTF Viewer",
  ivec2(1000, 1000),
  msaa = msaa8x
)
makeContextCurrent(window)
loadExtensions()

createDir("tools/dist")

let builder = newAtlasBuilder(1024, 4)
builder.addFont(FontPath, "H1", 28.0)
builder.addFont(FontPath, "Default", 18.0)
builder.write(AtlasPath)

var
  sk = newSilky(window, AtlasPath)
  gltfFile: GltfFile
  model: Node
  modelBounds: Bounds
  loaded = false
  lightFollowCamera = true
  skyboxLod: float32 = 7.0
  modelPath = params[0]
  camCenter = vec3(0, 0, 0)
  camRotation = mat4()
  camDolly = 10'f32
  lightPosition = vec3(0, 0, 10)
  lightColor = color(1, 1, 1, 1)
  aspectRatio = window.size.x.float32 / window.size.y.float32
  proj = perspective(VerticalFov, aspectRatio, 0.1, 200)
  lastTime = epochTime()

window.runeInputEnabled = true
window.onRune = proc(rune: Rune) =
  sk.inputRunes.add(rune)

proc hasModel(node: Node): bool =
  ## Returns true when the node tree has geometry to draw.
  if node == nil:
    return false
  if node.points.len > 0:
    return true
  for child in node.nodes:
    if child.hasModel():
      return true
  false

proc fitCameraDolly(bounds: Bounds, aspectRatio: float32): float32 =
  ## Returns a camera dolly distance that fits bounds comfortably on screen.
  if bounds.radius <= 0:
    return 4

  let
    verticalHalfFov = degToRad(VerticalFov) / 2
    horizontalHalfFov = arctan(tan(verticalHalfFov) * aspectRatio)
    fitHalfFov = min(verticalHalfFov, horizontalHalfFov)
    fitDistance = bounds.radius / sin(fitHalfFov)
  max(0.01'f32, fitDistance * FitPadding)

proc reloadFile(): bool =
  ## Reloads the current glTF file.
  if model != nil:
    model.clearFromGpu()

  if modelPath.len == 0:
    model = Node()
    gltfFile = nil
    return false

  echo "========================================"
  echo modelPath

  try:
    gltfFile = readGltfFile(modelPath)
    model = gltfFile.root
    model.dumpTree()

    modelBounds = model.computeBounds()
    let boundingSphere = model.getBoundingSphere()
    echo "Bounds: ", modelBounds
    echo "Bounding sphere: ", boundingSphere
    echo "Model file path: ", gltfFile.path
    camCenter = modelBounds.center
    camDolly = fitCameraDolly(modelBounds, aspectRatio)
    return true
  except:
    echo "Failed to load model:"
    echo getCurrentException().getStackTrace()
    echo getCurrentExceptionMsg()
    gltfFile = nil
    model = Node()
    modelBounds = Bounds()
    return false

proc loadAssets() =
  ## Loads the renderer assets and the requested model.
  setupPbr()
  loadDefaultEnvironmentMap()
  discard reloadFile()

proc drawOverlay(cameraPosition: Vec3) =
  ## Draws a simple Silky text overlay.
  sk.beginUI(window, window.size)
  sk.at = vec2(16, 16)
  h1text("glTF Viewer")
  text("Mouse middle or Cmd+left drag: orbit")
  text("Scroll: dolly")
  text("3: toggle light follow camera")
  text("4: set light to camera")
  text("")

  if gltfFile != nil:
    text("Current file:")
    text(gltfFile.path)
  else:
    text("No glTF file loaded.")

  text(&"Camera dolly: {camDolly:>7.2f}")
  text(&"Camera center: {camCenter}")
  text(&"Bounds radius: {modelBounds.radius:>7.4f}")
  text(&"Camera position: {cameraPosition}")
  text(&"Skybox lod: {skyboxLod:>5.2f}")
  text(&"Light follow camera: {lightFollowCamera}")

  sk.endUi()

window.onFrame = proc() =
  let nowTime = epochTime()
  let dt = (nowTime - lastTime).float32
  lastTime = nowTime

  if window.buttonDown[MouseMiddle] or
     (window.buttonDown[MouseLeft] and window.buttonDown[KeyLeftSuper]):
    let rot = 300.0'f32
    if window.buttonDown[MouseRight]:
      camRotation = rotateZ(window.mouseDelta.x.float32 / rot) * camRotation
    else:
      camRotation = rotateY(-window.mouseDelta.x.float32 / rot) * camRotation
      camRotation = rotateX(-window.mouseDelta.y.float32 / rot) * camRotation

  let zoomAmount = 0.20'f32
  if window.scrollDelta.y > 0:
    camDolly *= 1 - zoomAmount
  if window.scrollDelta.y < 0:
    camDolly *= 1 + zoomAmount

  let cameraMat =
    translate(vec3(0, 0, -camDolly)) *
    camRotation *
    translate(-camCenter)
  let cameraPosition = vec3(cameraMat.inverse.pos)

  if not loaded:
    loaded = true
    loadAssets()

  if window.buttonPressed[Key4]:
    lightPosition = cameraPosition
    echo "Light position: ", lightPosition

  if window.buttonPressed[Key3]:
    lightFollowCamera = not lightFollowCamera

  if lightFollowCamera:
    lightPosition = cameraPosition
  let lightDir = normalize(camCenter - lightPosition)

  aspectRatio = window.size.x.float32 / window.size.y.float32
  proj = perspective(VerticalFov, aspectRatio, 0.001, 2000)

  if model != nil:
    model.updateAnimation(dt)

  glClearColor(0.0, 0.0, 0.0, 1.0)
  glClear(GL_DEPTH_BUFFER_BIT or GL_COLOR_BUFFER_BIT)
  glEnable(GL_MULTISAMPLE)
  glCullFace(GL_BACK)
  glFrontFace(GL_CCW)
  glEnable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)

  drawSkybox(cameraMat, proj, skyboxLod)

  if model.hasModel():
    model.drawPbrWithShadow(
      mat4(),
      cameraMat,
      proj,
      tint = color(1, 1, 1, 1),
      lightDir = lightDir,
      useTrs = true,
      lightColor = lightColor,
      lightAmbient = color(0.0, 0.0, 0.0, 0.0),
      cameraPosition = cameraPosition
    )

  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glDisable(GL_MULTISAMPLE)
  drawOverlay(cameraPosition)
  window.swapBuffers()

while not window.closeRequested:
  pollEvents()
