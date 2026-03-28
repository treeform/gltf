import
  std/[algorithm, os, sequtils, strformat, strutils, tables, times],
  chroma, opengl, pixie, windy, vmath,
  gltf

const
  WindowSize = 512
  VerticalFov = 45'f
  FitPadding = 1.25'f
  OrbitYaw = -20.0'f
  OrbitPitch = -20.0'f
  MaxXrayScore = 2.0'f
  UpdateXrayScore = 0.5'f

type
  AssetResult = object
    modelPath: string
    screenshotPath: string
    baselinePath: string
    xrayPath: string
    status: string
    score: float32
    unsupportedUsedExtensions: seq[string]
    exceptionName: string
    message: string

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

proc safeNormalize(v, fallback: Vec3): Vec3 =
  ## Normalizes a vector and falls back when the length is too small.
  if v.lengthSq <= 0.000001:
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

proc defaultModelsDir(): string =
  ## Returns the default glTF sample assets model directory.
  let candidates = [
    joinPath(getCurrentDir(), "..", "glTF-Sample-Assets", "Models"),
    joinPath(getCurrentDir(), "..", "..", "glTF-Sample-Assets", "Models"),
    joinPath(getCurrentDir(), "glTF-Sample-Assets", "Models")
  ]
  for candidate in candidates:
    if dirExists(candidate):
      return candidate
  candidates[0]

proc defaultTmpDir(): string =
  ## Returns the default temporary output directory.
  let candidates = [
    joinPath(getCurrentDir(), "tests", "tmp"),
    joinPath(getCurrentDir(), "tmp")
  ]
  for candidate in candidates:
    let parentDir = candidate.parentDir()
    if dirExists(parentDir):
      return candidate
  candidates[0]

proc defaultMasterScreenshotsDir(): string =
  ## Returns the committed screenshot baseline directory.
  let candidates = [
    joinPath(getCurrentDir(), "tests", "screenshots"),
    joinPath(getCurrentDir(), "screenshots")
  ]
  for candidate in candidates:
    if dirExists(candidate):
      return candidate
  candidates[0]

proc resolvePath(path: string): string =
  ## Resolves a path relative to the current directory.
  if path.isAbsolute():
    return path
  joinPath(getCurrentDir(), path)

proc discoverModels(modelsPath: string): seq[string] =
  ## Discovers all glTF and GLB models under a path.
  let lower = modelsPath.toLowerAscii()
  if fileExists(modelsPath) and
    (lower.endsWith(".gltf") or lower.endsWith(".glb")):
    result.add(modelsPath)
    return

  for path in walkDirRec(modelsPath):
    let itemLower = path.toLowerAscii()
    if itemLower.endsWith(".gltf") or itemLower.endsWith(".glb"):
      result.add(path)
  result.sort()

proc sanitizeFileName(value: string): string =
  ## Converts a path into a safe screenshot file name.
  for c in value:
    if c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(c)
    else:
      result.add('_')

proc screenshotPath(
  screenshotsDir: string,
  modelsPath: string,
  modelPath: string,
  index: int
): string =
  ## Returns the output path for one screenshot.
  let rootDir =
    if dirExists(modelsPath):
      modelsPath
    else:
      modelsPath.parentDir()
  let relativeModelPath = relativePath(modelPath, rootDir)
  let safeName = sanitizeFileName(relativeModelPath)
  joinPath(screenshotsDir, safeName & ".png")

proc captureScreenshot(width, height: int): Image =
  ## Reads the back buffer into an image.
  var pixels = newSeq[uint8](width * height * 4)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadBuffer(GL_BACK)
  glReadPixels(
    0,
    0,
    width.GLsizei,
    height.GLsizei,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    cast[pointer](pixels[0].addr)
  )

  result = newImage(width, height)
  for y in 0 ..< height:
    let srcY = height - 1 - y
    for x in 0 ..< width:
      let
        src = (srcY * width + x) * 4
        dst = y * width + x
      result.data[dst] = rgbx(
        pixels[src + 0],
        pixels[src + 1],
        pixels[src + 2],
        pixels[src + 3]
      )

proc xray(
  image: Image,
  baselinePath: string,
  generatedPath: string,
  xrayPath: string
): float32 =
  ## Writes the generated image and xray, then returns the diff score.
  createDir(generatedPath.parentDir())
  createDir(xrayPath.parentDir())
  image.writeFile(generatedPath)
  let
    baseline = readImage(baselinePath)
    (score, xray) = diff(baseline, image)
  xray.writeFile(xrayPath)
  score

proc renderScene(window: Window, model: Node) =
  ## Renders one frame for a loaded model.
  let
    aspectRatio = window.size.x.float32 / window.size.y.float32
    bounds = model.computeBounds()
    camCenter = bounds.center
    camDolly = fitCameraDolly(bounds, aspectRatio)
    cameraMat =
      translate(vec3(0, 0, -camDolly)) *
      rotateX(degToRad(OrbitPitch)) *
      rotateY(degToRad(OrbitYaw)) *
      translate(-camCenter)
    cameraPosition = vec3(cameraMat.inverse.pos)
    proj = perspective(VerticalFov, aspectRatio, 0.001, 2000)
    # The shader negates this vector, so this points the incoming light from
    # the upper-left/front when shading the model.
    sunLightDirection = safeNormalize(vec3(1, -4, -2), vec3(1, -1, -1))
    rimLightDirection = safeNormalize(vec3(-1, 1, -1), vec3(-1, 1, -1))

  glViewport(0, 0, window.size.x, window.size.y)
  glClearColor(0.03, 0.035, 0.05, 1.0)
  glClear(GL_DEPTH_BUFFER_BIT or GL_COLOR_BUFFER_BIT)
  glCullFace(GL_BACK)
  glFrontFace(GL_CCW)
  glEnable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)

  drawSkybox(cameraMat, proj, 7.0'f)
  model.drawPbr(
    mat4(),
    cameraMat,
    proj,
    tint = color(1, 1, 1, 1),
    useTrs = true,
    ambientLightColor = color(0.32, 0.36, 0.46, 0.18),
    sunLightDirection = sunLightDirection,
    sunLightColor = color(0.95, 0.96, 1.0, 1.0),
    rimLightDirection = rimLightDirection,
    rimLightColor = color(0.95, 0.72, 0.46, 0.25),
    debugView = dvLit,
    cameraPosition = cameraPosition
  )

proc testModel(
  window: Window,
  modelsPath: string,
  generatedDir: string,
  masterScreenshotsDir: string,
  xrayDir: string,
  updateBaselines: bool,
  modelPath: string,
  index: int
): AssetResult =
  ## Loads one model, renders it, and saves a screenshot.
  result.modelPath = modelPath
  result.score = -1
  let
    outPath = screenshotPath(generatedDir, modelsPath, modelPath, index)
    baselinePath = screenshotPath(masterScreenshotsDir, modelsPath, modelPath, index)
    xrayPath = screenshotPath(xrayDir, modelsPath, modelPath, index)
  result.screenshotPath = outPath
  result.baselinePath = baselinePath
  result.xrayPath = xrayPath

  var
    model: Node
    loadStart = epochTime()
  try:
    echo "  phase: load"
    let gltfFile = readGltfFile(modelPath)
    let loadElapsed = epochTime() - loadStart
    echo &"  loaded in {loadElapsed:>7.3f}s"
    result.unsupportedUsedExtensions = gltfFile.unsupportedUsedExtensions
    if result.unsupportedUsedExtensions.len > 0:
      echo "  unsupported used extensions: ", result.unsupportedUsedExtensions.join(", ")
    model = gltfFile.root
    if not model.hasModel():
      result.status = "skip"
      result.message = "Loaded, but no renderable geometry was found."
      return
    let renderStart = epochTime()
    echo "  phase: render"
    for frame in 0 ..< 2:
      pollEvents()
      if window.closeRequested:
        result.status = "stop"
        result.message = "Window was closed."
        return
      model.updateAnimation(1.0'f / 60.0'f)
      renderScene(window, model)
      if frame == 1:
        echo "  phase: screenshot"
        let image = captureScreenshot(
          window.size.x.int,
          window.size.y.int
        )
        if fileExists(baselinePath):
          echo "  phase: xray"
          result.score = xray(image, baselinePath, outPath, xrayPath)
          if updateBaselines and result.score > UpdateXrayScore:
            echo "  phase: update"
            createDir(baselinePath.parentDir())
            copyFile(outPath, baselinePath)
            result.status = "ok"
            result.message =
              &"Rendered with xray score {result.score:0.3f}; updated baseline because it exceeded {UpdateXrayScore:0.3f}."
          elif updateBaselines:
            result.status = "ok"
            result.message =
              &"Rendered with xray score {result.score:0.3f}; baseline unchanged."
          elif result.score > MaxXrayScore:
            result.status = "diff_error"
            result.message = &"Rendered, but xray score {result.score:0.3f} exceeded {MaxXrayScore:0.3f}."
          else:
            result.status = "ok"
            result.message = &"Rendered with xray score {result.score:0.3f}."
        else:
          createDir(outPath.parentDir())
          image.writeFile(outPath)
          result.status = "ok"
          result.message = "Rendered successfully; baseline screenshot not found."
      window.swapBuffers()
    let renderElapsed = epochTime() - renderStart
    echo &"  rendered in {renderElapsed:>7.3f}s"
    if result.status.len == 0:
      result.status = "ok"
      result.message = "Rendered and captured successfully."
  except GltfError:
    result.status = "gltf_error"
    result.exceptionName = "GltfError"
    result.message = getCurrentExceptionMsg()
  except CatchableError:
    result.status = "error"
    result.exceptionName = "CatchableError"
    result.message = getCurrentExceptionMsg()
  finally:
    if model != nil:
      let clearStart = epochTime()
      echo "  phase: cleanup"
      model.clearFromGpu()
      let clearElapsed = epochTime() - clearStart
      echo &"  cleaned in {clearElapsed:>7.3f}s"

proc writeSummary(path: string, results: seq[AssetResult]) =
  ## Writes a text summary for the test run.
  var
    lines: seq[string]
    unsupportedExtensionCounts: CountTable[string]
  for result in results:
    lines.add(
      &"{result.status}\t{result.score:0.3f}\t{result.exceptionName}\t" &
      &"{result.modelPath}\t{result.screenshotPath}\t{result.baselinePath}\t" &
      &"{result.xrayPath}\t{result.message}"
    )
    for extension in result.unsupportedUsedExtensions:
      unsupportedExtensionCounts.inc(extension)

  if unsupportedExtensionCounts.len > 0:
    lines.add("")
    lines.add("unsupported_used_extensions_not_required\tcount")
    var extensions = toSeq(unsupportedExtensionCounts.pairs)
    extensions.sort(proc(a, b: (string, int)): int =
      if a[1] > b[1]: -1
      elif a[1] < b[1]: 1
      elif a[0] < b[0]: -1
      elif a[0] > b[0]: 1
      else: 0
    )
    for (extension, count) in extensions:
      lines.add(&"{extension}\t{count}")
  writeFile(path, lines.join("\n") & "\n")

let rawParams = commandLineParams()
var
  updateBaselines = false
  positionalParams: seq[string]
for param in rawParams:
  if param == "--update":
    updateBaselines = true
  else:
    positionalParams.add(param)

let
  modelsPath =
    if positionalParams.len > 0:
      resolvePath(positionalParams[0])
    else:
      defaultModelsDir()
  tmpDir =
    if positionalParams.len > 1:
      resolvePath(positionalParams[1])
    else:
      defaultTmpDir()
  masterScreenshotsDir =
    if positionalParams.len > 2:
      resolvePath(positionalParams[2])
    else:
      defaultMasterScreenshotsDir()

if not dirExists(modelsPath) and not fileExists(modelsPath):
  quit("Sample assets path not found: " & modelsPath, 1)

let
  generatedDir = joinPath(tmpDir, "generated")
  xrayDir = joinPath(tmpDir, "xray")
createDir(tmpDir)
createDir(generatedDir)
createDir(xrayDir)

let modelPaths = discoverModels(modelsPath)
if modelPaths.len == 0:
  quit("No .gltf or .glb files found under: " & modelsPath, 1)

echo "Found ", modelPaths.len, " sample assets."
echo "Models path: ", modelsPath
echo "Temp dir: ", tmpDir
echo "Generated dir: ", generatedDir
echo "Xray dir: ", xrayDir
echo "Baseline dir: ", masterScreenshotsDir
echo &"Max xray score: {MaxXrayScore:0.3f}"
echo "Update mode: ", updateBaselines
echo &"Update xray score: {UpdateXrayScore:0.3f}"

var window = newWindow(
  "glTF Sample Assets",
  ivec2(WindowSize, WindowSize),
  msaa = msaa8x
)
makeContextCurrent(window)
loadExtensions()
setupPbr()
loadDefaultEnvironmentMap(rgbx(180, 190, 220, 255))

var results: seq[AssetResult]
for i, modelPath in modelPaths:
  if window.closeRequested:
    echo "Window closed. Stopping early."
    break

  echo &"[{i + 1}/{modelPaths.len}] {modelPath}"
  let result = testModel(
    window,
    modelsPath,
    generatedDir,
    masterScreenshotsDir,
    xrayDir,
    updateBaselines,
    modelPath,
    i
  )
  results.add(result)
  echo "  ", result.status, ": ", result.message
  if result.status == "ok":
    echo "  screenshot: ", result.screenshotPath
    if result.score >= 0:
      echo &"  xray score: {result.score:0.3f}"

let summaryPath = joinPath(tmpDir, "summary.txt")
writeSummary(summaryPath, results)
echo "Wrote summary: ", summaryPath
var hasFailure = false
for result in results:
  if result.status notin ["ok", "skip"]:
    hasFailure = true
echo "done"
if hasFailure:
  quit(1)
