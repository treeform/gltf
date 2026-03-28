import
  std/[algorithm, os, strformat, strutils, times],
  opengl, windy, chroma, silky, silky/atlas, jsony, pixie,
  pixie/fileformats/png, vmath,
  ../src/gltf/[models, pbr, reader]

const
  AtlasPng = staticRead("dist/atlas.png")
  VerticalFov = 45'f32
  FitPadding = 1.25'f32

let
  debugViewOptions = @[
    "Lit",
    "Unlit",
    "Normals",
    "AO Bake",
    "Metallic",
    "Specular"
  ]

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

let
  atlasImage = decodePng(AtlasPng).convertToImage()
  atlasData = extractAtlasJsonFromPng(AtlasPng).fromJson(SilkyAtlas)

var
  sk = newSilky(window, atlasImage, atlasData)
  gltfFile: GltfFile
  model: Node
  modelBounds: Bounds
  loaded = false
  showControls = true
  useLighting = true
  useShadows = true
  lightFollowCamera = true
  debugViewName = "Lit"
  skyboxOptions = @["Solid Color"]
  skyboxPatterns: seq[(string, string)]
  selectedSkybox = "Solid Color"
  lastSkybox = ""
  skyboxLod: float32 = 7.0
  modelPath = params[0]
  camCenter = vec3(0, 0, 0)
  camRotation = mat4()
  camDolly = 10'f32
  backgroundColor = color(0.03, 0.035, 0.05, 1.0)
  lastBackgroundColor = color(-1.0, -1.0, -1.0, 1.0)
  ambientLightColor = color(0.32, 0.36, 0.46, 0.18)
  sunLightDirection = normalize(vec3(1, 4, 2))
  sunLightColor = color(0.95, 0.96, 1.0, 1.0)
  rimLightDirection = normalize(vec3(-1.0, 1.0, -2.0))
  rimLightColor = color(0.95, 0.72, 0.46, 0.25)
  aspectRatio = window.size.x.float32 / window.size.y.float32
  proj = perspective(VerticalFov, aspectRatio, 0.1, 200)
  lastTime = epochTime()

window.runeInputEnabled = true
window.onRune = proc(rune: Rune) =
  sk.inputRunes.add(rune)

proc applyTheme(sk: Silky) =
  ## Applies the viewer theme colors and spacing.
  sk.theme.padding = 10
  sk.theme.spacing = 8
  sk.theme.border = 10
  sk.theme.textPadding = 5
  sk.theme.headerHeight = 30
  sk.theme.defaultTextColor = rgbx(232, 240, 255, 255)
  sk.theme.disabledTextColor = rgbx(136, 146, 168, 255)
  sk.theme.errorTextColor = rgbx(255, 156, 172, 255)
  sk.theme.buttonHoverColor = rgbx(255, 255, 255, 48)
  sk.theme.buttonDownColor = rgbx(190, 216, 255, 76)
  sk.theme.iconButtonHoverColor = rgbx(255, 255, 255, 40)
  sk.theme.iconButtonDownColor = rgbx(190, 216, 255, 64)
  sk.theme.dropdownHoverBgColor = rgbx(60, 74, 100, 255)
  sk.theme.dropdownBgColor = rgbx(34, 42, 58, 255)
  sk.theme.dropdownPopupBgColor = rgbx(28, 36, 50, 245)
  sk.theme.textColor = rgbx(224, 234, 255, 255)
  sk.theme.textH1Color = rgbx(250, 252, 255, 255)
  sk.theme.headerBgColor = rgbx(38, 46, 62, 255)
  sk.theme.menuRootHoverColor = rgbx(86, 102, 134, 160)
  sk.theme.menuItemHoverColor = rgbx(74, 90, 120, 160)
  sk.theme.menuItemBgColor = rgbx(40, 48, 66, 140)
  sk.theme.menuPopupHoverColor = rgbx(84, 102, 134, 180)
  sk.theme.menuPopupSelectedColor = rgbx(68, 84, 112, 140)

proc safeNormalize(v, fallback: Vec3): Vec3 =
  ## Normalizes a vector and falls back when its length is too small.
  if v.lengthSq <= 0.000001:
    return fallback
  normalize(v)

proc drawColorControls(id, title: string, value: var Color) =
  ## Draws four scrubbers for one RGBA color.
  text(title)
  scrubber(id & "_r", value.r, 0.0'f32, 1.0'f32, "R")
  scrubber(id & "_g", value.g, 0.0'f32, 1.0'f32, "G")
  scrubber(id & "_b", value.b, 0.0'f32, 1.0'f32, "B")
  scrubber(id & "_a", value.a, 0.0'f32, 10.0'f32, "Strength")

proc drawRgbControls(id, title: string, value: var Color) =
  ## Draws rgb-only controls without a strength slider.
  text(title)
  scrubber(id & "_r", value.r, 0.0'f32, 1.0'f32, "R")
  scrubber(id & "_g", value.g, 0.0'f32, 1.0'f32, "G")
  scrubber(id & "_b", value.b, 0.0'f32, 1.0'f32, "B")
  value.a = 1.0

proc colorToRgbx(value: Color): ColorRGBX =
  ## Converts a float color into an 8-bit color.
  rgbx(
    clamp((value.r * 255).int, 0, 255).uint8,
    clamp((value.g * 255).int, 0, 255).uint8,
    clamp((value.b * 255).int, 0, 255).uint8,
    255
  )

proc drawDirectionControls(id, title: string, value: var Vec3) =
  ## Draws three scrubbers for a direction vector.
  text(title)
  scrubber(id & "_x", value.x, -1.0'f32, 1.0'f32, "X")
  scrubber(id & "_y", value.y, -1.0'f32, 1.0'f32, "Y")
  scrubber(id & "_z", value.z, -1.0'f32, 1.0'f32, "Z")

applyTheme(sk)

proc skyboxPattern(path: string): string =
  ## Converts one cubemap face path into a wildcard pattern.
  for face in ["px", "nx", "py", "ny", "pz", "nz"]:
    let token = "." & face & "."
    if token in path:
      return path.replace(token, ".*.")
  path

proc skyboxName(pattern: string): string =
  ## Extracts a readable skybox name from a wildcard pattern.
  pattern.splitFile.name.replace(".*", "")

proc selectedSkyboxPattern(): string =
  ## Looks up the selected skybox pattern by name.
  for (name, pattern) in skyboxPatterns:
    if name == selectedSkybox:
      return pattern
  ""

proc discoverSkyboxes() =
  ## Scans the skybox folder for cubemap patterns.
  skyboxOptions = @[]
  skyboxPatterns.setLen(0)
  if not dirExists("tools/skybox"):
    skyboxOptions = @["Solid Color"]
    return

  for path in walkDirRec("tools/skybox"):
    let lower = path.toLowerAscii()
    if not (lower.endsWith(".png") or
            lower.endsWith(".jpg") or
            lower.endsWith(".jpeg")):
      continue
    let pattern = skyboxPattern(path.replace("\\", "/"))
    if pattern == path:
      continue
    let name = skyboxName(pattern)
    var known = false
    for (_, knownPattern) in skyboxPatterns:
      if knownPattern == pattern:
        known = true
        break
    if not known:
      skyboxPatterns.add((name, pattern))
      skyboxOptions.add(name)

  skyboxOptions.sort()
  skyboxOptions.insert("Solid Color", 0)

proc updateEnvironmentMap(force = false) =
  ## Reloads the environment map when the selection changes.
  if selectedSkybox == "Solid Color":
    if force or
       lastSkybox != selectedSkybox or
       backgroundColor.r != lastBackgroundColor.r or
       backgroundColor.g != lastBackgroundColor.g or
       backgroundColor.b != lastBackgroundColor.b:
      loadDefaultEnvironmentMap(colorToRgbx(backgroundColor))
      lastBackgroundColor = backgroundColor
      lastSkybox = selectedSkybox
    return

  if force or lastSkybox != selectedSkybox:
    let pattern = selectedSkyboxPattern()
    if pattern.len == 0:
      selectedSkybox = "Solid Color"
      updateEnvironmentMap(force = true)
      return
    loadEnvironmentMap(pattern)
    lastSkybox = selectedSkybox

proc hasModel(node: Node): bool =
  ## Returns true when the node tree has geometry to draw.
  if node == nil:
    return false
  if node.mesh != nil and node.mesh.primitives.len > 0:
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
  discoverSkyboxes()
  if selectedSkybox notin skyboxOptions:
    selectedSkybox = "Solid Color"
  updateEnvironmentMap(force = true)
  discard reloadFile()

proc withStrengthDisabled(value: Color, enabled: bool): Color =
  ## Keeps rgb but disables light output via alpha.
  if enabled:
    return value
  color(value.r, value.g, value.b, 0.0)

proc parseDebugView(name: string): DebugView =
  ## Maps the UI label to the renderer debug mode.
  case name
  of "Unlit":
    dvUnlit
  of "Normals":
    dvNormals
  of "AO Bake":
    dvAoBake
  of "Metallic":
    dvMetallic
  of "Specular":
    dvSpecular
  else:
    dvLit

proc drawOverlay(
  cameraPosition,
  effectiveSunLightDirection,
  effectiveRimLightDirection: Vec3
) =
  ## Draws the themed viewer controls window.
  sk.beginUI(window, window.size)
  subWindow("glTF Viewer", showControls, vec2(20, 20), vec2(430, 760)):
    h1text("glTF Viewer")
    text("Mouse middle or Cmd+left drag: orbit")
    text("Scroll: dolly")
    text("Key 1 toggles this window")
    text("")

    if gltfFile != nil:
      text("Current file:")
      text(gltfFile.path)
    else:
      text("No glTF file loaded.")

    group(vec2(0, 0), LeftToRight):
      button("Reload File"):
        discard reloadFile()
      button("Refit View"):
        camCenter = modelBounds.center
        camDolly = fitCameraDolly(modelBounds, aspectRatio)

    text("")
    text("Scene")
    checkBox("Lighting", useLighting)
    checkBox("Shadows", useShadows)
    checkBox("Light follow camera", lightFollowCamera)
    text("Debug View")
    dropDown(debugViewName, debugViewOptions)
    text("Skybox")
    dropDown(selectedSkybox, skyboxOptions)
    if selectedSkybox == "Solid Color":
      drawRgbControls("background", "Background", backgroundColor)
    else:
      scrubber("skybox_lod", skyboxLod, 0.0'f32, 10.0'f32, "Skybox Blur")

    text("")
    text("Ambient Light")
    drawColorControls(
      "ambient_light",
      "Ambient Light Color",
      ambientLightColor
    )

    text("")
    text("Sun Light")
    if lightFollowCamera:
      text(&"Following camera dir: {effectiveSunLightDirection}")
    else:
      drawDirectionControls(
        "sun_light_dir",
        "Sun Light Direction",
        sunLightDirection
      )
    drawColorControls("sun_light", "Sun Light Color", sunLightColor)

    text("")
    text("Rim Light")
    text(&"Current rim dir: {effectiveRimLightDirection}")
    drawDirectionControls(
      "rim_light_dir",
      "Rim Light Direction",
      rimLightDirection
    )
    drawColorControls("rim_light", "Rim Light Color", rimLightColor)

    text("")
    text("View")
    text(&"Camera dolly: {camDolly:>7.2f}")
    text(&"Camera center: {camCenter}")
    text(&"Bounds radius: {modelBounds.radius:>7.4f}")
    text(&"Camera position: {cameraPosition}")
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

  if window.buttonPressed[Key1]:
    showControls = not showControls

  if window.buttonPressed[Key3]:
    lightFollowCamera = not lightFollowCamera

  let
    viewDir = safeNormalize(camCenter - cameraPosition, vec3(0, 0, 1))
    effectiveSunLightDirection =
      if lightFollowCamera:
        viewDir
      else:
        safeNormalize(sunLightDirection, vec3(1, 1, 1))
    effectiveRimLightDirection =
      safeNormalize(rimLightDirection, vec3(-1, 1, -1))
    effectiveAmbientLightColor =
      withStrengthDisabled(ambientLightColor, useLighting)
    effectiveSunLightColor =
      withStrengthDisabled(sunLightColor, useLighting)
    effectiveRimLightColor =
      withStrengthDisabled(rimLightColor, useLighting)
    selectedDebugView = parseDebugView(debugViewName)
    effectiveDebugView =
      if useLighting:
        selectedDebugView
      else:
        dvUnlit

  aspectRatio = window.size.x.float32 / window.size.y.float32
  proj = perspective(VerticalFov, aspectRatio, 0.001, 2000)

  updateEnvironmentMap()

  if model != nil:
    model.updateAnimation(dt)

  glClearColor(
    backgroundColor.r,
    backgroundColor.g,
    backgroundColor.b,
    1.0
  )
  glClear(GL_DEPTH_BUFFER_BIT or GL_COLOR_BUFFER_BIT)
  glEnable(GL_MULTISAMPLE)
  glCullFace(GL_BACK)
  glFrontFace(GL_CCW)
  glEnable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)

  drawSkybox(cameraMat, proj, skyboxLod)

  if model.hasModel():
    if useShadows and effectiveDebugView == dvLit:
      model.drawPbrWithShadow(
        mat4(),
        cameraMat,
        proj,
        tint = color(1, 1, 1, 1),
        sunLightDirection = effectiveSunLightDirection,
        useTrs = true,
        ambientLightColor = effectiveAmbientLightColor,
        sunLightColor = effectiveSunLightColor,
        rimLightDirection = effectiveRimLightDirection,
        rimLightColor = effectiveRimLightColor,
        debugView = effectiveDebugView,
        cameraPosition = cameraPosition
      )
    else:
      model.drawPbr(
        mat4(),
        cameraMat,
        proj,
        tint = color(1, 1, 1, 1),
        useTrs = true,
        ambientLightColor = effectiveAmbientLightColor,
        sunLightDirection = effectiveSunLightDirection,
        sunLightColor = effectiveSunLightColor,
        rimLightDirection = effectiveRimLightDirection,
        rimLightColor = effectiveRimLightColor,
        debugView = effectiveDebugView,
        cameraPosition = cameraPosition
      )

  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glDisable(GL_MULTISAMPLE)
  drawOverlay(
    cameraPosition,
    effectiveSunLightDirection,
    effectiveRimLightDirection
  )
  window.swapBuffers()

while not window.closeRequested:
  pollEvents()
