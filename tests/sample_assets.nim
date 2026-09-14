import
  std/[algorithm, json, math, os, sequtils, strformat, strutils, tables, times, xmltree],
  chroma, pixie, windy, vmath,
  gltf

when not defined(useDirectX) and not defined(useVulkan) and not defined(useMetal4):
  import opengl

const
  BackendName =
    when defined(useMetal4): "Metal"
    elif defined(useDirectX): "DirectX"
    elif defined(useVulkan): "Vulkan"
    else: "OpenGL"
  SupportsIbl = not defined(useDirectX) and not defined(useVulkan) and
    (not defined(useMetal4) or defined(macosx))
  WindowSize = 512
  VerticalFov = 45'f
  FitPadding = 1.25'f
  OrbitYaw = 20.0'f
  OrbitPitch = 20.0'f
  MaxXrayScore = 2.0'f
  UpdateXrayScore = 0.5'f
  BackgroundColor = color(0.7058824, 0.74509805, 0.8627451, 1.0)
  IgnoredModels = [
    "ABeautifulGame"
  ]

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
    caseId: string
    captureLabel: string
    animationTime: float32
    pixels: int
    differentPixels: int
    pixelsOverTolerance: int
    meanAbsoluteError: float64
    rootMeanSquareError: float64
    maxChannelError: int

var
  renderer: Renderer
  pbrContext: PbrContext
  referenceCase: JsonNode
  referenceSettings: JsonNode
  referenceRenderer: JsonNode
  iblDirectory: string

proc jsonVec3(value: JsonNode): Vec3 =
  vec3(value[0].getFloat().float32, value[1].getFloat().float32,
    value[2].getFloat().float32)

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

proc ignoredModelReason(modelPath: string): string =
  ## Returns the skip reason for a model path.
  for name in IgnoredModels:
    if name in modelPath:
      return "Ignored for now because it is too slow to load."
  ""

proc isExpectedSampleAssetGltfError(message: string): bool =
  ## Returns true for sample-asset failures caused by unsupported features.
  message.startsWith("Unsupported extension required:") or
  message.startsWith("KTX2: unsupported vkFormat")

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
  if referenceCase != nil:
    return joinPath(screenshotsDir, referenceCase["id"].getStr() & ".png")
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
  discard width
  discard height
  renderer.captureScreenshot()

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
  if readFile(baselinePath) == readFile(generatedPath):
    newImage(image.width, image.height).writeFile(xrayPath)
    return 0
  let
    baseline = readImage(baselinePath)
    (score, xray) = diff(baseline, image)
  xray.writeFile(xrayPath)
  score

proc measurePixels(result: var AssetResult, baseline, generated: Image) =
  ## Measures unaligned RGB bytes. A pixel differs if any RGB channel differs.
  if baseline.width != generated.width or baseline.height != generated.height:
    raise newException(ValueError, "Reference and generated dimensions differ")
  result.pixels = baseline.width * baseline.height
  var absoluteSum, squareSum: float64
  for i in 0 ..< result.pixels:
    let
      a = baseline.data[i]
      b = generated.data[i]
      dr = abs(a.r.int - b.r.int)
      dg = abs(a.g.int - b.g.int)
      db = abs(a.b.int - b.b.int)
      delta = max(dr, max(dg, db))
    if delta > 0:
      inc result.differentPixels
    if delta > 2:
      inc result.pixelsOverTolerance
    result.maxChannelError = max(result.maxChannelError, delta)
    absoluteSum += (dr + dg + db).float64
    squareSum += (dr * dr + dg * dg + db * db).float64
  result.meanAbsoluteError = absoluteSum / (result.pixels * 3).float64
  result.rootMeanSquareError = sqrt(squareSum / (result.pixels * 3).float64)

proc renderScene(window: Window, model: Node) =
  ## Renders one frame for a loaded model.
  var
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
    proj =
      when defined(useDirectX):
        perspectiveDxRh(VerticalFov, aspectRatio, 0.001, 2000)
      elif defined(useVulkan):
        perspectiveVkRh(VerticalFov, aspectRatio, 0.001, 2000)
      else:
        perspective(VerticalFov, aspectRatio, 0.001, 2000)
    # The shader negates this vector, so this points the incoming light from
    # the upper-left/front when shading the model.
    sunLightDirection = safeNormalize(vec3(1, -4, -2), vec3(1, -1, -1))
    rimLightDirection = safeNormalize(vec3(-1, 1, -1), vec3(-1, 1, -1))
    background = BackgroundColor

  if referenceCase != nil:
    let
      camera = referenceCase["camera"]
      eye = jsonVec3(camera["position"])
      target = jsonVec3(camera["target"])
      up = jsonVec3(camera["up"])
      fov = camera["verticalFovDegrees"].getFloat().float32
      near = camera["near"].getFloat().float32
      far = camera["far"].getFloat().float32
      clear = referenceSettings["rendering"]["clearColor"]
    cameraMat = lookAt(eye, target, up)
    cameraPosition = eye
    when defined(useDirectX):
      proj = perspectiveDxRh(fov, aspectRatio, near, far)
    elif defined(useVulkan):
      proj = perspectiveVkRh(fov, aspectRatio, near, far)
    else:
      proj = perspective(fov, aspectRatio, near, far)
    background = color(clear[0].getFloat(), clear[1].getFloat(),
      clear[2].getFloat(), clear[3].getFloat())

  renderer.beginFrame(window, window.size)
  renderer.clearScreen(background)
  pbrContext.size = window.size
  pbrContext.clearColor = background
  pbrContext.transform = mat4()
  pbrContext.view = cameraMat
  pbrContext.proj = proj
  pbrContext.tint = color(1, 1, 1, 1)
  pbrContext.useTrs = true
  pbrContext.ambientLightColor = color(0.32, 0.36, 0.46, 0.18)
  pbrContext.sunLightDirection = sunLightDirection
  pbrContext.sunLightColor = color(0.95, 0.96, 1.0, 1.0)
  pbrContext.rimLightDirection = rimLightDirection
  pbrContext.rimLightColor = color(0.95, 0.72, 0.46, 0.25)
  pbrContext.debugView = dvLit
  pbrContext.cameraPosition = cameraPosition
  pbrContext.useShadows = false
  pbrContext.drawSkybox = false
  pbrContext.skyboxLod = 0
  pbrContext.vsync = false
  when SupportsIbl:
    if iblDirectory.len > 0:
      pbrContext.sunLightColor = color(0, 0, 0, 0)
      pbrContext.environmentRotation = referenceSettings["rendering"]["environmentRotation"].getFloat().float32
      pbrContext.environmentMapStrength = referenceSettings["rendering"]["iblIntensity"].getFloat().float32 *
        pbrContext.iblEnvironment.intensityScale
      pbrContext.exposure = referenceSettings["rendering"]["exposure"].getFloat().float32
      pbrContext.beginIblFrame()
  pbrContext.draw(model)
  when SupportsIbl:
    if iblDirectory.len > 0:
      pbrContext.endIblFrame()
  renderer.endFrame()

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
  result.caseId = modelPath.extractFilename()
  result.captureLabel = "Default view"
  if referenceCase != nil:
    result.caseId = referenceCase["id"].getStr()
    result.animationTime = referenceCase["timeSeconds"].getFloat().float32
    let clips = referenceCase["animationIndices"]
    if clips.len == 0:
      result.captureLabel = "Rest pose"
    else:
      let animationName =
        if referenceCase.hasKey("animationName") and
            referenceCase["animationName"].getStr().len > 0:
          referenceCase["animationName"].getStr()
        else:
          "Animation " & clips.mapIt($(it.getInt() + 1)).join(", ")
      result.captureLabel = &"{animationName} · {result.animationTime:0.3f} seconds"
      if referenceCase.hasKey("animationEndSeconds") and
          result.animationTime > referenceCase["animationEndSeconds"].getFloat():
        result.captureLabel.add(" (looped)")
  result.score = -1
  let
    outPath = screenshotPath(generatedDir, modelsPath, modelPath, index)
    baselinePath = screenshotPath(masterScreenshotsDir, modelsPath, modelPath, index)
    xrayPath = screenshotPath(xrayDir, modelsPath, modelPath, index)
  result.screenshotPath = outPath
  result.baselinePath = baselinePath
  result.xrayPath = xrayPath

  let ignoreReason = ignoredModelReason(modelPath)
  if ignoreReason.len > 0:
    result.status = "skip"
    result.message = ignoreReason
    return

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
    if referenceCase != nil:
      let scene = referenceCase["scene"].getInt()
      if scene < 0 or scene >= gltfFile.scenes.len:
        raise newException(ValueError, "Reference scene is unavailable")
      model.nodes = gltfFile.scenes[scene].nodes
      model.activeClips.setLen(0)
      for clip in referenceCase["animationIndices"]:
        let index = clip.getInt()
        if index < 0 or index >= model.animations.len:
          raise newException(ValueError, "Reference animation is unavailable")
        model.activeClips.add(index)
      model.animTime = referenceCase["timeSeconds"].getFloat().float32
      model.updateAnimation(0)
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
      if referenceCase == nil:
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
          result.measurePixels(readImage(baselinePath), image)
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
          if referenceCase != nil:
            result.status = "missing_reference"
      when not defined(useDirectX) and not defined(useVulkan) and not defined(useMetal4):
        window.swapBuffers()
    let renderElapsed = epochTime() - renderStart
    echo &"  rendered in {renderElapsed:>7.3f}s"
    if result.status.len == 0:
      result.status = "ok"
      result.message = "Rendered and captured successfully."
  except GltfError:
    let message = getCurrentExceptionMsg()
    result.status =
      if message.isExpectedSampleAssetGltfError():
        "skip"
      else:
        "gltf_error"
    result.exceptionName = "GltfError"
    result.message = message
  except CatchableError:
    result.status = "error"
    result.exceptionName = "CatchableError"
    result.message = getCurrentExceptionMsg()
  finally:
    if model != nil:
      let clearStart = epochTime()
      echo "  phase: cleanup"
      renderer.release(model)
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

proc writeOverviewCard(
  path: string, results: seq[AssetResult]
): tuple[size, columns: int, indices: seq[int]] =
  ## Tile one rest-pose image per file above its matching X-ray.
  const tileSize = 64
  var
    groups = initOrderedTable[string, seq[int]]()
    worstScores = initTable[string, float32]()
  for i, item in results:
    if item.status notin ["ok", "diff_error"] or item.pixels == 0 or
        item.score < 0 or not fileExists(item.screenshotPath) or
        not fileExists(item.xrayPath):
      continue
    groups.mgetOrPut(item.modelPath, @[]).add(i)
    worstScores[item.modelPath] =
      max(worstScores.getOrDefault(item.modelPath, -1'f), item.score)
  let modelOrder = toSeq(groups.keys).sorted(proc(a, b: string): int =
    result = cmp(worstScores[b], worstScores[a])
    if result == 0:
      result = cmp(a, b)
  )
  for modelPath in modelOrder:
    let captures = groups[modelPath]
    # Prefer the first valid rest pose; use the first compared capture when a
    # file has no rest pose. The detailed report still contains every frame.
    var selected = captures[0]
    for index in captures:
      if results[index].caseId.endsWith("__rest"):
        selected = index
        break
    result.indices.add(selected)
  if result.indices.len == 0:
    if fileExists(path):
      removeFile(path)
    return
  # An even column count makes both halves an exact number of 64px rows.
  result.columns = ceil(sqrt(result.indices.len.float64 * 2)).int
  if result.columns mod 2 != 0:
    inc result.columns
  result.size = result.columns * tileSize
  let
    card = newImage(result.size, result.size)
    blackTile = newImage(tileSize, tileSize)
  card.fill(rgbx(24, 30, 40, 255))
  blackTile.fill(rgbx(0, 0, 0, 255))
  for slot, index in result.indices:
    let
      item = results[index]
      x = (slot mod result.columns) * tileSize
      y = (slot div result.columns) * tileSize
      renderPosition = translate(vec2(x.float32, y.float32))
      xrayPosition = translate(vec2(x.float32, (y + result.size div 2).float32))
    card.draw(readImage(item.screenshotPath).resize(tileSize, tileSize), renderPosition)
    # An exact match may have a transparent X-ray; show it as black like other
    # zero-error pixels instead of exposing the unused-slot background.
    card.draw(blackTile, xrayPosition)
    card.draw(readImage(item.xrayPath).resize(tileSize, tileSize), xrayPosition)
  card.writeFile(path)

proc writeReport(path: string, results: seq[AssetResult]) =
  ## Writes an HTML xray report with master/generated/xray images side by side.
  let reportDir = path.parentDir()
  var
    groups = initOrderedTable[string, seq[AssetResult]]()
    worstScores = initTable[string, float32]()
    unavailable = initTable[string, bool]()
    orderedResults: seq[AssetResult]
    entries: seq[string]
    currentModel: string
  for item in results:
    groups.mgetOrPut(item.modelPath, @[]).add(item)
    worstScores[item.modelPath] = max(worstScores.getOrDefault(item.modelPath, -1'f), item.score)
    unavailable[item.modelPath] = unavailable.getOrDefault(item.modelPath) or
      item.pixels == 0 or item.status notin ["ok", "diff_error"]
  let modelOrder = toSeq(groups.keys).sorted(proc(a, b: string): int =
    result = cmp(unavailable[b], unavailable[a])
    if result == 0:
      result = cmp(worstScores[b], worstScores[a])
    if result == 0:
      result = cmp(a, b)
  )
  for modelPath in modelOrder:
    # Keep manifest order within each model, including rest and looping poses.
    orderedResults.add(groups[modelPath])
  let card = writeOverviewCard(reportDir / "overview_card.png", orderedResults)
  var cardHtml: string
  if card.size > 0:
    var links: seq[string]
    let tilePercent = 100.0 / card.columns.float64
    for slot, index in card.indices:
      let
        item = orderedResults[index]
        fileLabel = relativePath(item.modelPath,
          getCurrentDir().parentDir()).replace('\\', '/')
        label = xmltree.escape(&"{fileLabel} · {item.captureLabel} · Pixie {item.score:0.3f}%")
        x = (slot mod card.columns).float64 * tilePercent
        y = (slot div card.columns).float64 * tilePercent
      for half in 0 .. 1:
        let top = y + half.float64 * 50
        links.add(&"""<a class="overview-tile" href="#capture-{index}" title="{label}" aria-label="{label}" style="left:{x:0.6f}%;top:{top:0.6f}%;width:{tilePercent:0.6f}%;height:{tilePercent:0.6f}%"></a>""")
    cardHtml = &"""<figure class="overview">
<div class="overview-image" style="width:{card.size}px">
<img src="overview_card.png" width="{card.size}" height="{card.size}" alt="Overview card: one capture per model, generated renders in the top half, matching X-rays in the bottom half; worst files first">
{links.join("\n")}
</div>
<figcaption><b>{card.indices.len} compared models</b> · one capture per model, preferring the first rest pose · 64×64 thumbnails · top: generated renders · bottom: matching X-rays.<br>Files run from worst to best by their worst capture score, left to right and then down. All animation frames remain in the detailed report. Click a tile for its comparison. <a href="overview_card.png">Open the full-size PNG</a>.</figcaption>
</figure>
"""
  for index, result in orderedResults:
    if result.modelPath != currentModel:
      if currentModel.len > 0:
        entries.add("</section>")
      currentModel = result.modelPath
      let
        fileLabel = xmltree.escape(relativePath(currentModel,
          getCurrentDir().parentDir()).replace('\\', '/'))
        captures = groups[currentModel]
        passed = captures.countIt(it.status == "ok")
        worst = worstScores[currentModel]
        worstLabel = if worst >= 0: &"{worst:0.3f}%" else: "unavailable"
      entries.add(&"""<section class="model-group" data-file="{fileLabel}">
<header class="model-heading"><h2>{fileLabel}</h2>
<p>{captures.len} captures · {passed} / {captures.len} ok · worst Pixie score {worstLabel}</p></header>""")
    if result.pixels == 0:
      let
        reason = xmltree.escape(result.message)
        referenceImage =
          if fileExists(result.baselinePath):
            let relBaseline = xmltree.escape(relativePath(result.baselinePath, reportDir))
            &"""<div class="tile"><div class="tile-label">Baseline</div><img src="{relBaseline}"></div>"""
          else: ""
      entries.add(&"""<div style="background:#fff3df;padding:16px">
<b>{xmltree.escape(result.captureLabel)}</b>
<p><b>Not compared ({xmltree.escape(result.status)}):</b> {reason}</p>
<div class="tiles">{referenceImage}</div></div>""")
      continue
    if not fileExists(result.screenshotPath):
      continue
    let
      bg = if result.score > MaxXrayScore: "#fee"
           elif result.score > 1: "#ffe"
           else: "#fff"
      relGenerated = relativePath(result.screenshotPath, reportDir)
      baseline =
        if fileExists(result.baselinePath):
          let relBaseline = relativePath(result.baselinePath, reportDir)
          &"""<div class="tile"><div class="tile-label">Baseline</div><img src="{relBaseline}"></div>"""
        else:
          "<div class=\"tile\"><div class=\"tile-label\">Baseline</div><div>(none)</div></div>"
      xrayImg =
        if fileExists(result.xrayPath):
          let relXray = relativePath(result.xrayPath, reportDir)
          &"""<div class="tile"><div class="tile-label">Xray</div><img src="{relXray}"></div>"""
        else:
          ""
    let
      exactPercent =
        if result.pixels > 0:
          100.0 * (result.pixels - result.differentPixels).float64 / result.pixels.float64
        else: 0.0
      tolerancePercent =
        if result.pixels > 0:
          100.0 * (result.pixels - result.pixelsOverTolerance).float64 / result.pixels.float64
        else: 0.0
    entries.add(&"""<div id="capture-{index}" class="capture" style="background:{bg};border:1px solid #ccc;padding:16px;break-inside:avoid">
<b>{xmltree.escape(result.captureLabel)}</b>
<div class="tiles">
{baseline}
<div class="tile"><div class="tile-label">Generated</div><img src="{relGenerated}"></div>
{xrayImg}
<div class="tile"><div class="tile-label">Statistics</div><div class="statistics">
<p>time {result.animationTime:0.6f}s · {result.status}</p>
<p>{result.differentPixels} / {result.pixels} pixels differ<br>{exactPercent:0.2f}% exact<br>{tolerancePercent:0.2f}% within ±2</p>
<p>RGB mean absolute error {result.meanAbsoluteError:0.3f} / 255<br>RMSE {result.rootMeanSquareError:0.3f}<br>max channel error {result.maxChannelError}<br>Pixie score {result.score:0.3f}%</p>
</div></div>
</div></div>""")
  if currentModel.len > 0:
    entries.add("</section>")
  let html = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Xray Report</title>
<style>body{font-family:monospace;margin:16px}.model-group{border:2px solid #aab4c2;margin:24px 0}.model-heading{position:sticky;top:0;z-index:1;background:#eef1f6;padding:12px 16px;border-bottom:1px solid #aab4c2}.model-heading h2{margin:0 0 6px;font-size:18px;overflow-wrap:anywhere}.model-heading p{margin:0}.tiles{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}.tile{width:256px}.tile-label{margin-bottom:6px}img{display:block;max-width:256px;background:repeating-conic-gradient(#eee 0% 25%,#fff 0% 50%) 0 0/16px 16px}.statistics{box-sizing:border-box;width:256px;height:256px;padding:12px;background:#ffffffb3;border:1px solid #ccc;font-size:13px;line-height:1.35}.statistics p{margin:0 0 12px}.statistics p:last-child{margin-bottom:0}.overview{margin:0 0 24px}.overview-image{position:relative;max-width:min(100%,calc(100vh - 160px))}.overview img{width:100%;height:auto;max-width:none;background:#181e28}.overview-tile{position:absolute;display:block;box-sizing:border-box}.overview-tile:hover,.overview-tile:focus-visible{box-shadow:inset 0 0 0 2px #ffb347;z-index:2}.overview figcaption{margin-top:10px;line-height:1.5}.capture{scroll-margin-top:100px}</style>
</head><body>
<h1>Xray Report</h1>
""" & "<p><b>Backend:</b> " & BackendName & " on " & hostOS &
    " / " & hostCPU & "</p>" & cardHtml & """
<p>Grouped by source file: missing, skipped and failed comparisons first, then each file's worst Pixie score. All frames, poses and views stay together in manifest order.</p>
<p>Same model, camera, scene, animation clip and absolute time. Images are compared without alignment or resizing.</p>
<p>Pixel counts use RGB bytes over the entire image, including the background. Within ±2 means every RGB channel differs by at most 2 on the 0–255 scale. Xray: green = generated darker; blue = generated brighter; red = alpha difference.</p>
<p>The ok label uses the existing 2% Pixie threshold; visible differences can still pass it. Skipped or failed captures are not comparisons.</p>
""" & (if iblDirectory.len > 0:
  "<p><b>Matched lighting:</b> shared Khronos neutral HDR environment, rotation and exposure; linear sRGB textures, GGX image-based lighting, HDR framebuffer and PBR Neutral tone mapping. Shared material extensions and authored punctual lights are included.</p>"
elif referenceSettings != nil:
  "<p><b>Lighting currently differs:</b> Khronos uses the neutral HDR studio and PBR Neutral tone mapping. Nim uses its current procedural environment and sun/rim/ambient lighting. These measurements include that difference.</p>"
else: "") & (if referenceRenderer != nil:
  "<p><b>Reference renderer:</b> " &
  xmltree.escape(referenceRenderer["repository"].getStr()) & " @ " &
  xmltree.escape(referenceRenderer["revision"].getStr()) & "</p>"
else: "") & entries.join("\n") & "\n</body></html>"
  writeFile(path, html)
  var metrics = newJArray()
  for result in orderedResults:
    metrics.add(%*{
      "id": result.caseId,
      "label": result.captureLabel,
      "status": result.status,
      "message": result.message,
      "timeSeconds": result.animationTime,
      "pixels": result.pixels,
      "differentPixels": result.differentPixels,
      "pixelsOverTolerance2": result.pixelsOverTolerance,
      "meanAbsoluteErrorRgb": result.meanAbsoluteError,
      "rootMeanSquareErrorRgb": result.rootMeanSquareError,
      "maxChannelErrorRgb": result.maxChannelError,
      "pixieScore": result.score
    })
  writeFile(path.parentDir() / "metrics.json", metrics.pretty() & "\n")

let rawParams = commandLineParams()

var
  updateBaselines = false
  positionalParams: seq[string]
  manifestPath: string
  caseFilter: string
for param in rawParams:
  if param == "--update":
    updateBaselines = true
  elif param.startsWith("--manifest="):
    manifestPath = resolvePath(param[11 .. ^1])
  elif param.startsWith("--case="):
    caseFilter = param[7 .. ^1]
  elif param.startsWith("--ibl="):
    iblDirectory = resolvePath(param[6 .. ^1])
  else:
    positionalParams.add(param)

var referenceCases: seq[JsonNode]
if manifestPath.len > 0:
  if updateBaselines:
    quit("--update cannot overwrite Khronos references. Regenerate them with tools/reference.", 1)
  let manifest = parseFile(manifestPath)
  doAssert manifest["version"].getInt() == 1, "Unsupported reference manifest"
  referenceSettings = manifest["settings"]
  referenceRenderer = manifest["sources"]["renderer"]
  var ids: seq[string]
  for item in manifest["cases"]:
    let id = item["id"].getStr()
    doAssert id.len > 0 and id == sanitizeFileName(id) and id notin ids,
      "Invalid or duplicate reference id"
    ids.add(id)
    if caseFilter.len == 0 or caseFilter.split(',').anyIt(it.len > 0 and it in id):
      referenceCases.add(item)
  if referenceCases.len == 0:
    quit("No reference cases match the selection.", 1)

let
  modelsPath =
    if positionalParams.len > 0:
      resolvePath(positionalParams[0])
    else:
      defaultModelsDir()
  tmpDir =
    if positionalParams.len > 1:
      resolvePath(positionalParams[1])
    elif manifestPath.len > 0:
      joinPath(defaultTmpDir(), "reference")
    else:
      defaultTmpDir()
  masterScreenshotsDir =
    if positionalParams.len > 2:
      resolvePath(positionalParams[2])
    elif manifestPath.len > 0:
      joinPath(manifestPath.parentDir(), "images")
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

var modelPaths: seq[string]
if manifestPath.len > 0:
  for item in referenceCases:
    let relative = item["model"].getStr().replace('\\', '/')
    doAssert relative.startsWith("Models/") and ".." notin relative.split('/'),
      "Reference model must be relative to the sample asset repository"
    modelPaths.add(joinPath(modelsPath, relative[7 .. ^1]))
else:
  modelPaths = discoverModels(modelsPath)
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
  if referenceSettings != nil:
    ivec2(referenceSettings["width"].getInt().int32,
      referenceSettings["height"].getInt().int32)
  else:
    ivec2(WindowSize, WindowSize),
  visible = manifestPath.len == 0,
  msaa = msaa8x
)
when not defined(useDirectX) and not defined(useVulkan) and not defined(useMetal4):
  makeContextCurrent(window)
  loadExtensions()
elif defined(useDirectX) or defined(useVulkan):
  loadExtensions()
renderer = newRenderer(window)
pbrContext = newPbrContext(renderer)
when SupportsIbl:
  if iblDirectory.len > 0:
    pbrContext.attachIblEnvironment(loadIblEnvironment(iblDirectory))
  else:
    when not defined(useMetal4):
      pbrContext.attachEnvironmentMap(loadDefaultEnvironmentMap())

var results: seq[AssetResult]
for i, modelPath in modelPaths:
  if manifestPath.len > 0:
    referenceCase = referenceCases[i]
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
let reportPath = joinPath(tmpDir, "xray_report.html")
writeReport(reportPath, results)
echo "Wrote report: ", reportPath
var hasFailure = false
for result in results:
  if result.status notin ["ok", "skip"]:
    hasFailure = true
if pbrContext != nil:
  pbrContext.destroy()
if renderer != nil:
  renderer.shutdown()
echo "done"
if hasFailure:
  quit(1)
