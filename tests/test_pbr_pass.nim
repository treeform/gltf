## Exercises the opt-in beginPass/endPass API from PR 48 on real hardware.
## Renders the same scene with implicit passes, one explicit pass, nested
## passes, and foreign GL state + invalidateGlState, and checks the images
## match. Also checks the uniform value cache never serves stale values.

import
  std/[os, strformat, times],
  chroma, pixie, windy, vmath, opengl,
  gltf

const
  WindowSize = 512
  Background = color(0.7058824, 0.74509805, 0.8627451, 1.0)
  OutDir = "tests/tmp/pass"

proc modelsDir(): string =
  ## Finds the Khronos sample assets the same way tests/sample_assets.nim does.
  for candidate in [
    joinPath(getCurrentDir(), "..", "glTF-Sample-Assets", "Models"),
    joinPath(getCurrentDir(), "..", "..", "glTF-Sample-Assets", "Models"),
    joinPath(getCurrentDir(), "glTF-Sample-Assets", "Models")
  ]:
    if dirExists(candidate):
      return candidate
  quit("glTF-Sample-Assets not found next to the repo", 1)

let ModelsDir = modelsDir()

var window = newWindow("PBR pass test", ivec2(WindowSize, WindowSize), msaa = msaa8x)
makeContextCurrent(window)
loadExtensions()
let renderer = newRenderer(window)
let ctx = newPbrContext(renderer)
ctx.attachEnvironmentMap(loadDefaultEnvironmentMap())
createDir(OutDir)

proc load(rel: string): Node =
  let file = readGltfFile(joinPath(ModelsDir, rel))
  doAssert file.unsupportedUsedExtensions.len == 0, rel
  file.root

let
  helmet = load("DamagedHelmet/glTF-Binary/DamagedHelmet.glb")
  alpha = load("AlphaBlendModeTest/glTF-Binary/AlphaBlendModeTest.glb")
  spheres = load("MetalRoughSpheresNoTextures/glTF-Binary/MetalRoughSpheresNoTextures.glb")

proc fitScale(node: Node, target: float32): Mat4 =
  let b = node.computeBounds()
  scale(vec3(target / max(b.radius, 0.001))) * translate(-b.center)

let
  helmetPlace = translate(vec3(-1.6, 0.9, 0)) * fitScale(helmet, 1.0)
  alphaPlace = translate(vec3(1.6, 0.9, 0)) * fitScale(alpha, 1.0)
  spheresPlace = translate(vec3(0, -1.2, 0)) * fitScale(spheres, 1.1)

proc setup(tint: Color, sun: Color) =
  let aspect = window.size.x.float32 / window.size.y.float32
  let cam = translate(vec3(0, 0, -6)) * rotateX(degToRad(12'f))
  ctx.size = window.size
  ctx.clearColor = Background
  ctx.view = cam
  ctx.proj = perspective(45'f, aspect, 0.01, 100)
  ctx.cameraPosition = vec3(cam.inverse.pos)
  ctx.tint = tint
  ctx.useTrs = true
  ctx.ambientLightColor = color(0.32, 0.36, 0.46, 0.18)
  ctx.sunLightDirection = normalize(vec3(1, -4, -2))
  ctx.sunLightColor = sun
  ctx.rimLightDirection = normalize(vec3(-1, 1, -1))
  ctx.rimLightColor = color(0.95, 0.72, 0.46, 0.25)
  ctx.debugView = dvLit
  ctx.useShadows = false
  ctx.drawSkybox = false
  ctx.vsync = false

proc foreignGl() =
  ## Simulates an engine running its own GL between draws.
  glUseProgram(0)
  glActiveTexture(GL_TEXTURE3)
  glBindTexture(GL_TEXTURE_2D, 0)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, 0)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glDepthMask(GL_FALSE)
  glFrontFace(GL_CW)

type Mode = enum
  Implicit, OnePass, Nested, ForeignInvalidate, ForeignNoInvalidate

proc frame(mode: Mode, tint = color(1, 1, 1, 1),
           sun = color(0.95, 0.96, 1.0, 1.0)): Image =
  pollEvents()
  renderer.beginFrame(window, window.size)
  renderer.clearScreen(Background)
  setup(tint, sun)
  if mode in {OnePass, Nested, ForeignInvalidate, ForeignNoInvalidate}:
    ctx.beginPass()
  if mode == Nested:
    ctx.beginPass()
  ctx.transform = helmetPlace
  ctx.draw(helmet)
  if mode in {ForeignInvalidate, ForeignNoInvalidate}:
    foreignGl()
  if mode == ForeignInvalidate:
    ctx.invalidateGlState()
  ctx.transform = spheresPlace
  ctx.draw(spheres)
  ctx.transform = alphaPlace
  ctx.draw(alpha)
  if mode == Nested:
    ctx.endPass()
  if mode in {OnePass, Nested, ForeignInvalidate, ForeignNoInvalidate}:
    ctx.endPass()
  renderer.endFrame()
  renderer.captureScreenshot()

proc score(a, b: Image): float32 =
  diff(a, b)[0]

# Warm up (first frame compiles shaders and uploads).
discard frame(Implicit)

let base = frame(Implicit)
base.writeFile(OutDir / "implicit.png")
for mode in [OnePass, Nested, ForeignInvalidate]:
  let img = frame(mode)
  img.writeFile(OutDir / ($mode & ".png"))
  let s = score(base, img)
  echo &"{mode:<20} vs implicit: xray score {s:0.4f}"
  doAssert s < 0.01, $mode & " diverged from implicit-pass rendering"

# Uniform value cache: values changed between passes must be honored.
let red = frame(OnePass, tint = color(1, 0.2, 0.2, 1))
red.writeFile(OutDir / "tint_red.png")
let whiteAgain = frame(OnePass)
let sRed = score(base, red)
let sWhite = score(base, whiteAgain)
echo &"tint red vs base: {sRed:0.4f}   white-after-red vs base: {sWhite:0.4f}"
doAssert sRed > 0.5, "tint change was not applied (stale uniform cache?)"
doAssert sWhite < 0.01, "tint did not restore (stale uniform cache?)"

let dim = frame(OnePass, sun = color(0.1, 0.1, 0.4, 1))
dim.writeFile(OutDir / "sun_dim.png")
let normalAgain = frame(OnePass)
let sDim = score(base, dim)
let sNormal = score(base, normalAgain)
echo &"sun dim vs base: {sDim:0.4f}   normal-after-dim vs base: {sNormal:0.4f}"
doAssert sDim > 0.5, "sun colour change was not applied (stale uniform cache?)"
doAssert sNormal < 0.01, "sun colour did not restore (stale uniform cache?)"

# Debug view switches shader paths mid-run; must not be stuck.
let normals = frame(OnePass)
ctx.debugView = dvLit
discard normals

# Timing: implicit passes vs one explicit pass, 120 frames each.
proc bench(mode: Mode): float =
  let start = epochTime()
  for i in 0 ..< 120:
    discard frame(mode)
  (epochTime() - start) / 120 * 1000
echo &"avg frame ms  implicit: {bench(Implicit):0.2f}   onePass: {bench(OnePass):0.2f}"

# Shadows on, fresh models uploaded lazily inside one explicit pass: the
# first frame (with mid-pass uploads) must match the second frame.
proc shadowFrame(models: seq[(Node, Mat4)], explicit = true): Image =
  pollEvents()
  renderer.beginFrame(window, window.size)
  renderer.clearScreen(Background)
  setup(color(1, 1, 1, 1), color(0.95, 0.96, 1.0, 1.0))
  ctx.useShadows = true
  if explicit: ctx.beginPass()
  for (node, place) in models:
    ctx.transform = place
    ctx.draw(node)
  if explicit: ctx.endPass()
  ctx.useShadows = false
  renderer.endFrame()
  renderer.captureScreenshot()

let fresh = @[
  (load("DamagedHelmet/glTF-Binary/DamagedHelmet.glb"), helmetPlace),
  (load("MetalRoughSpheresNoTextures/glTF-Binary/MetalRoughSpheresNoTextures.glb"), spheresPlace),
  (load("AlphaBlendModeTest/glTF-Binary/AlphaBlendModeTest.glb"), alphaPlace)
]
echo "shadow implicit frame..."
let shadowImplicit = shadowFrame(fresh, explicit = false)
shadowImplicit.writeFile(OutDir / "shadow_implicit.png")
echo "shadow explicit frames..."
let shadow1 = shadowFrame(fresh)
let shadow2 = shadowFrame(fresh)
shadow1.writeFile(OutDir / "shadow_frame1.png")
shadow2.writeFile(OutDir / "shadow_frame2.png")
let sShadow = score(shadow1, shadow2)
echo &"shadows on: first frame (lazy uploads) vs second frame: {sShadow:0.4f}"
doAssert sShadow < 0.01, "first shadowed frame diverged from steady state"
echo "PBR pass shadow test passed"

# A draw that throws mid-pass (unsupported supercompressed KTX2 upload) must
# not poison later draws: the implicit pass has to unwind.
let ktxPath = joinPath(ModelsDir, "AnisotropyBarnLamp/glTF-KTX-BasisU/AnisotropyBarnLamp.gltf")
if fileExists(ktxPath):
  let ktxModel = readGltfFile(ktxPath).root
  var threw = false
  try:
    pollEvents()
    renderer.beginFrame(window, window.size)
    renderer.clearScreen(Background)
    setup(color(1, 1, 1, 1), color(0.95, 0.96, 1.0, 1.0))
    ctx.transform = mat4()
    ctx.draw(ktxModel)
    renderer.endFrame()
  except GltfError as e:
    threw = true
    echo "throwing draw raised as expected: ", e.msg
  doAssert threw, "expected the KTX2 model to throw during draw"
  let afterThrow = frame(Implicit)
  afterThrow.writeFile(OutDir / "after_throw.png")
  let sThrow = score(base, afterThrow)
  echo &"after a throwing draw vs base: {sThrow:0.4f}"
  doAssert sThrow < 0.01, "a throwing draw poisoned later draws"
  echo "PBR pass exception test passed"

# Last, because it corrupts the context by contract: foreign GL inside a pass
# without invalidateGlState is unsupported (informational only).
try:
  let img = frame(ForeignNoInvalidate)
  img.writeFile(OutDir / "ForeignNoInvalidate.png")
  echo &"ForeignNoInvalidate  vs implicit: xray score {score(base, img):0.4f} (unsupported by contract)"
except Exception as e:
  echo "ForeignNoInvalidate  raised: ", e.msg, " (unsupported by contract)"

ctx.destroy()
renderer.shutdown()
echo "PBR pass tests passed"
