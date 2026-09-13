## Actual GPU regressions for the multi-pass renderer, independent of masters.
import std/json, flatty/binny, opengl, windy, vmath, chroma, pixie, gltf

proc constantTexture(target: GLenum, value: array[4, float32]): GLuint =
  glGenTextures(1, result.addr)
  glBindTexture(target, result)
  if target == GL_TEXTURE_CUBE_MAP:
    for face in 0 ..< 6:
      glTexImage2D((GL_TEXTURE_CUBE_MAP_POSITIVE_X.int + face).GLenum, 0,
        GL_RGBA16F.GLint, 1, 1, 0, GL_RGBA, cGL_FLOAT, value[0].unsafeAddr)
  else:
    glTexImage2D(target, 0, GL_RGBA16F.GLint, 1, 1, 0,
      GL_RGBA, cGL_FLOAT, value[0].unsafeAddr)
  glTexParameteri(target, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(target, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)

let window = newWindow("Transmission pipeline test", ivec2(64, 48), visible = false)
makeContextCurrent(window)
loadExtensions()
let renderer = newRenderer(window)
let ctx = newPbrContext(renderer)
ctx.attachIblEnvironment(IblEnvironment(
  diffuse: constantTexture(GL_TEXTURE_CUBE_MAP, [0'f, 0, 0, 1]),
  specular: constantTexture(GL_TEXTURE_CUBE_MAP, [0'f, 0, 0, 1]),
  lut: constantTexture(GL_TEXTURE_2D, [1'f, 0, 0, 1]), mipCount: 1, intensityScale: 1))
ctx.size = ivec2(64, 48) # Windows may enlarge very small native windows.
ctx.proj = ortho(-1'f, 1'f, -1'f, 1'f, 0.1'f, 10'f)
ctx.view = mat4()
ctx.cameraPosition = vec3(0, 0, 1000)
ctx.sunLightColor = color(0, 0, 0, 0)
ctx.clearColor = color(0, 0, 0, 1)
ctx.drawSkybox = false

var positions = newString(72)
for i, value in [-0.9'f, -0.9, 0, 0.9, -0.9, 0, 0.9, 0.9, 0,
    -0.9'f, -0.9, 0, 0.9, 0.9, 0, -0.9, 0.9, 0]:
  positions.writeFloat32(i * 4, value)
let root = loadModelJson(%*{
  "asset": {"version": "2.0"},
  "buffers": [{"byteLength": 72}],
  "bufferViews": [{"buffer": 0, "byteLength": 72}],
  "accessors": [{"bufferView": 0, "componentType": 5126, "count": 6, "type": "VEC3"}],
  "materials": [
    {"extensions": {"KHR_materials_unlit": {}}},
    {"pbrMetallicRoughness": {"metallicFactor": 0, "roughnessFactor": 0}, "extensions": {
      "KHR_materials_transmission": {"transmissionFactor": 1}, "KHR_materials_ior": {"ior": 1}}}
  ],
  "meshes": [
    {"primitives": [{"attributes": {"POSITION": 0}, "material": 0}]},
    {"primitives": [{"attributes": {"POSITION": 0}, "material": 1}]}
  ],
  "nodes": [{"mesh": 0, "translation": [0, 0, -2]},
    {"mesh": 1, "translation": [0, 0, -1], "scale": [0.8, 0.8, 1]}],
  "scenes": [{"nodes": [0, 1]}], "scene": 0
}, ".", @[positions])
let background = root.nodes[0]
let glass = root.nodes[1]
let bgMaterial = background.mesh.primitives[0].material
let glassPrimitive = glass.mesh.primitives[0]
let material = glassPrimitive.material
let uvs = @[vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1)]
for node in root.nodes:
  let primitive = node.mesh.primitives[0]
  primitive.uvs = uvs
  for uv in uvs:
    primitive.uvs1.add(vec2(1 - uv.x, uv.y))
    primitive.normals.add(vec3(0, 0, 1))
bgMaterial.baseColor = newImage(2, 2)
bgMaterial.baseColor[0, 0] = rgbx(110, 145, 180, 255)
bgMaterial.baseColor[1, 0] = rgbx(180, 110, 145, 255)
bgMaterial.baseColor[0, 1] = rgbx(145, 180, 110, 255)
bgMaterial.baseColor[1, 1] = rgbx(110, 180, 145, 255)
bgMaterial.baseColorSampler.magFilter = NearestMagFilter
bgMaterial.baseColorSampler.minFilter = NearestMinFilter

proc capture(separateDraws = false, reverse = false): seq[ColorRGBA] =
  inc material.materialVersion
  inc bgMaterial.materialVersion
  renderer.beginFrame(window, ctx.size)
  ctx.beginIblFrame()
  if separateDraws:
    # All submissions in one pass share a single transmission snapshot.
    ctx.beginPass()
    ctx.beginPass()
    if reverse:
      ctx.draw(glass)
      ctx.draw(background)
    else:
      ctx.draw(background)
      ctx.draw(glass)
    ctx.endPass()
    ctx.endPass()
  else:
    ctx.draw(root)
  var viewport: array[4, GLint]
  glGetIntegerv(GL_VIEWPORT, viewport[0].addr)
  doAssert viewport == [0.GLint, 0, ctx.size.x, ctx.size.y], "Transmission must restore viewport"
  ctx.endIblFrame()
  renderer.endFrame()
  result.setLen(ctx.size.x * ctx.size.y)
  glReadBuffer(GL_BACK)
  glReadPixels(0, 0, ctx.size.x, ctx.size.y, GL_RGBA, GL_UNSIGNED_BYTE, result[0].addr)
  doAssert glGetError() == GL_NO_ERROR
  for pixel in result: doAssert pixel.a == 255, "Transmission is not reduced coverage"

proc pixel(image: seq[ColorRGBA], x, y: int): ColorRGBA = image[y * ctx.size.x + x]
proc difference(a, b: ColorRGBA): int =
  max(abs(a.r.int - b.r.int), max(abs(a.g.int - b.g.int), abs(a.b.int - b.b.int)))

glass.visible = false
let withoutGlass = capture()
glass.visible = true
let clear = capture()
for (x, y) in [(20, 16), (44, 16), (20, 32), (44, 32)]:
  doAssert difference(clear.pixel(x, y), withoutGlass.pixel(x, y)) <= 2,
    "Clear IOR=1 must preserve the background at " & $x & "," & $y &
      ": got " & $clear.pixel(x, y) & " expected " & $withoutGlass.pixel(x, y)
doAssert capture(separateDraws = true) == clear
doAssert capture(separateDraws = true, reverse = true) == clear
doAssert capture() == clear, "The second frame must not sample stale or self-referential data"

# Conventional BLEND materials must also be present in the background snapshot.
bgMaterial.alphaMode = BlendAlphaMode
bgMaterial.baseColorFactor.a = 0.5
let blendedBackground = capture()
doAssert blendedBackground.pixel(20, 16).r > 30
doAssert blendedBackground.pixel(20, 16).r < clear.pixel(20, 16).r - 20
doAssert capture(separateDraws = true, reverse = true) == blendedBackground
bgMaterial.alphaMode = OpaqueAlphaMode
bgMaterial.baseColorFactor.a = 1

# A red-channel data map with deliberately opposite green values. UV1 mirrors it.
renderer.release(root)
material.transmission = newImage(2, 1)
material.transmission[0, 0] = rgbx(0, 255, 0, 255)
material.transmission[1, 0] = rgbx(255, 0, 0, 255)
material.transmissionSampler.magFilter = NearestMagFilter
material.transmissionSampler.minFilter = NearestMinFilter
material.transmissionTransform.texCoord = 1
let masked = capture()
doAssert difference(masked.pixel(20, 16), clear.pixel(20, 16)) <= 2
doAssert masked.pixel(44, 16).r < 3 and masked.pixel(44, 16).g < 3,
  "Transmission R/UV1 mask: left=" & $masked.pixel(20, 16) & " right=" & $masked.pixel(44, 16) &
    " texture=" & $material.data.transmissionId
# KHR_texture_transform offset swaps the two halves back using REPEAT.
material.transmissionTransform.offset.x = 0.5
let shifted = capture()
doAssert shifted.pixel(20, 16).r < 3
doAssert difference(shifted.pixel(44, 16), clear.pixel(44, 16)) <= 2

# Volume absorption uses green, linear data, and the node's scale.
renderer.release(root)
material.transmission = nil
material.hasVolume = true
material.thicknessFactor = 2
material.thickness = newImage(1, 1)
material.thickness.fill(rgbx(0, 128, 255, 255))
material.attenuationColor = vec3(0.5, 1, 1)
material.attenuationDistance = 1
let absorbed = capture()
doAssert absorbed.pixel(20, 16).r < clear.pixel(20, 16).r - 25
doAssert abs(absorbed.pixel(20, 16).g.int - clear.pixel(20, 16).g.int) <= 2
glass.scale.z = 2
let thicker = capture()
doAssert thicker.pixel(20, 16).r < absorbed.pixel(20, 16).r - 20
material.attenuationDistance = 0
let infiniteDistance = capture()
doAssert difference(infiniteDistance.pixel(20, 16), clear.pixel(20, 16)) <= 2

# A tilted thick interface displaces the sample; a thin interface does not.
renderer.release(root)
material.thickness = nil
material.thicknessFactor = 1
material.ior = 1.5
glass.scale.z = 1
let flatInterface = capture()
renderer.release(root)
for i in 0 ..< glassPrimitive.normals.len: glassPrimitive.normals[i] = vec3(0.6, 0, 0.8)
let refracted = capture()
doAssert difference(refracted.pixel(34, 16), flatInterface.pixel(34, 16)) > 25
material.thicknessFactor = 0
let thinInterface = capture()
doAssert difference(thinInterface.pixel(34, 16), flatInterface.pixel(34, 16)) < 3
for i in 0 ..< glassPrimitive.normals.len: glassPrimitive.normals[i] = vec3(0, 0, 1)

# Roughness must blur a high-frequency background, without losing it entirely.
renderer.release(root)
material.thickness = nil
material.thicknessFactor = 0
material.ior = 1.5
bgMaterial.baseColor = newImage(32, 32)
for y in 0 ..< 32:
  for x in 0 ..< 32:
    bgMaterial.baseColor[x, y] = if (x + y) mod 2 == 0: rgbx(110, 110, 110, 255)
      else: rgbx(210, 210, 210, 255)
let sharp = capture()
material.roughnessFactor = 1
let rough = capture()
var sharpMin = 255
var sharpMax = 0
var roughMin = 255
var roughMax = 0
for x in 17 .. 46:
  sharpMin = min(sharpMin, sharp.pixel(x, 24).r.int)
  sharpMax = max(sharpMax, sharp.pixel(x, 24).r.int)
  roughMin = min(roughMin, rough.pixel(x, 24).r.int)
  roughMax = max(roughMax, rough.pixel(x, 24).r.int)
doAssert sharpMax - sharpMin > 60
doAssert roughMax - roughMin < 3 and roughMin > 80

# Disabling transmission after using it must clear the deferred queue.
material.transmissionFactor = 0
material.hasTransmission = false
let opaque = capture()
doAssert opaque.pixel(32, 24).r < 3
material.hasTransmission = true
material.transmissionFactor = 1
material.ior = 0
doAssert capture().pixel(32, 24).r < 3, "Explicit IOR=0 must have unit Fresnel"
material.ior = 1.5

# Light behind the surface can transmit even when its front-facing NdotL is zero.
background.visible = false
material.roughnessFactor = 0.5
ctx.sunLightColor = color(1, 1, 1, 1)
ctx.sunLightDirection = normalize(vec3(0.5, 0, 1))
let backlit = capture()
doAssert backlit.pixel(32, 24).r > 20
material.transmissionFactor = 0
doAssert capture().pixel(32, 24).r < 3
ctx.useShadows = true
material.transmissionFactor = 1
discard capture()

# Diffuse transmission is back-side diffuse lighting, independent of base color.
ctx.useShadows = false
renderer.release(root)
material.transmissionFactor = 0
material.ior = 1
material.thicknessFactor = 0
material.diffuseTransmissionFactor = 1
material.diffuseTransmissionColorFactor = vec3(1, 0.5, 0.25)
material.baseColorFactor = color(0, 0, 1, 1)
ctx.sunLightDirection = vec3(0, 0, 1)
let diffuseBacklit = capture()
let dtPixel = diffuseBacklit.pixel(32, 24)
doAssert dtPixel.r > dtPixel.g and dtPixel.g > dtPixel.b and dtPixel.b > 20
ctx.sunLightDirection = vec3(0, 0, -1)
doAssert capture().pixel(32, 24).r < 3, "Full diffuse transmission removes front-side diffuse"
ctx.sunLightDirection = vec3(0, 0, 1)

# The mask is alpha, never red; UV1 and its transform apply independently.
renderer.release(root)
material.diffuseTransmission = newImage(2, 1)
material.diffuseTransmission[0, 0] = rgbx(255, 0, 0, 0)
material.diffuseTransmission[1, 0] = rgbx(0, 0, 0, 255)
material.diffuseTransmissionSampler.magFilter = NearestMagFilter
material.diffuseTransmissionSampler.minFilter = NearestMinFilter
material.diffuseTransmissionTransform.texCoord = 1
let diffuseMasked = capture()
doAssert difference(diffuseMasked.pixel(20, 16), dtPixel) <= 2
doAssert diffuseMasked.pixel(44, 16).r < 3
material.diffuseTransmissionTransform.offset.x = 0.5
let diffuseShifted = capture()
doAssert diffuseShifted.pixel(20, 16).r < 3
doAssert difference(diffuseShifted.pixel(44, 16), dtPixel) <= 2

# sRGB RGB values must be decoded without multiplying by texture alpha.
renderer.release(root)
material.diffuseTransmission = nil
material.diffuseTransmissionColorFactor = vec3(1)
material.diffuseTransmissionColor = newImage(1, 1)
material.diffuseTransmissionColor.fill(rgbx(128, 64, 192, 0))
let coloredDiffuse = capture()
let cdt = coloredDiffuse.pixel(32, 24)
doAssert cdt.b > cdt.r and cdt.r > cdt.g and cdt.g > 3
renderer.release(root)
material.diffuseTransmissionColor = nil
material.diffuseTransmissionColorFactor = vec3(0.215861, 0.051269, 0.527115)
doAssert difference(capture().pixel(32, 24), cdt) <= 1, "Diffuse color map must use sRGB transfer"
material.thicknessFactor = 1
material.attenuationColor = vec3(0.25, 1, 1)
material.attenuationDistance = 1
let diffuseAbsorbed = capture().pixel(32, 24)
doAssert diffuseAbsorbed.r < cdt.r - 15 and abs(diffuseAbsorbed.g.int - cdt.g.int) <= 2
material.attenuationDistance = 0
doAssert difference(capture().pixel(32, 24), cdt) <= 1
doAssert capture() == capture(), "Diffuse transmission must be repeatable"
echo "Diffuse transmission GPU: backlighting, energy balance, alpha mask, UV1/transform, sRGB color and absorption passed"

# Punctual lights: inverse-square distance, finite range and spot cones.
ctx.sunLightColor = color(0, 0, 0, 0)
material.diffuseTransmissionFactor = 0
material.baseColorFactor = color(1, 1, 1, 1)
material.thicknessFactor = 0
let lamp = Node(name: "Test light", visible: true, scale: vec3(1), rot: quat(),
  pos: vec3(0, 0, 1), punctualLight: PunctualLight(kind: PointLightKind,
    color: color(1, 1, 1, 1), intensity: 1, outerConeAngle: 0.7853982))
root.nodes.add(lamp)
let pointNear = capture().pixel(32, 24)
lamp.pos.z = 3
lamp.punctualLight.intensity = 4
doAssert difference(capture().pixel(32, 24), pointNear) <= 1,
  "Doubling distance and quadrupling intensity must preserve irradiance"
lamp.punctualLight.range = 3.5
doAssert capture().pixel(32, 24).r < 3, "Outside range must be unlit"
lamp.punctualLight.range = 0
lamp.punctualLight.kind = SpotLightKind
lamp.punctualLight.innerConeAngle = 0.1
lamp.punctualLight.outerConeAngle = 0.2
doAssert difference(capture().pixel(32, 24), pointNear) <= 1
lamp.rot = quatRotateY(0.4'f)
doAssert capture().pixel(32, 24).r < 3, "Outside the spot cone must be unlit"
lamp.rot = quatRotateY(0.15'f)
let coneEdge = capture().pixel(32, 24)
doAssert coneEdge.r > 3 and coneEdge.r < pointNear.r - 5
lamp.rot = quat()
let lightParent = Node(visible: true, scale: vec3(2, 3, 4), rot: quat(), nodes: @[lamp])
root.nodes[^1] = lightParent
lamp.pos.z = 0.75
doAssert difference(capture().pixel(32, 24), pointNear) <= 1,
  "Inherited scale moves a light but must not scale its intensity or cone"
lightParent.visible = false
doAssert capture().pixel(32, 24).r < 3, "Hidden ancestors must hide lights"
lightParent.visible = true
lamp.visible = false
doAssert capture().pixel(32, 24).r < 3
echo "Punctual light GPU: inverse square, range, cones, rotation, hierarchy, scale and visibility passed"

# Emission is multiplied in linear HDR before the PBR Neutral/display passes.
material.hasEmissiveStrength = true
material.emissiveFactor = color(1, 0.05, 0.0125, 1)
material.emissiveStrength = 4
doAssert difference(capture().pixel(32, 24), rgba(253, 155, 149, 255)) <= 1
material.emissiveStrength = 0
doAssert capture().pixel(32, 24).r < 3
material.emissiveStrength = 1
material.emissiveFactor = color(0.04, 0.04, 0.04, 1)
doAssert difference(capture().pixel(32, 24), rgba(31, 31, 31, 255)) <= 1
echo "Emissive strength GPU: HDR multiplier, neutral tone map, display transfer and zero strength passed"

# The anisotropic lobe follows tangent-space rotation and linear RGB data.
renderer.release(root)
material.emissiveFactor = color(0, 0, 0, 1)
material.metallicFactor = 1
material.roughnessFactor = 0.4
for i in 0 ..< glassPrimitive.points.len: glassPrimitive.tangents.add(vec4(1, 0, 0, 1))
ctx.sunLightColor = color(1, 1, 1, 1)
ctx.sunLightDirection = normalize(vec3(-0.5, 0, -1))
let isotropic = capture()
material.hasAnisotropy = true
doAssert difference(capture().pixel(32, 24), isotropic.pixel(32, 24)) <= 1
material.anisotropyStrength = 0.9
let anisotropic = capture()
material.anisotropyRotation = 1.57079632679'f
let rotatedAnisotropy = capture()
doAssert difference(anisotropic.pixel(32, 24), rotatedAnisotropy.pixel(32, 24)) > 15
renderer.release(root)
material.anisotropyRotation = 0
material.anisotropy = newImage(2, 1)
material.anisotropy[0, 0] = rgbx(255, 128, 0, 0)
material.anisotropy[1, 0] = rgbx(255, 128, 255, 0)
material.anisotropySampler.magFilter = NearestMagFilter
material.anisotropySampler.minFilter = NearestMinFilter
material.anisotropyTransform.texCoord = 1
let anisotropyMasked = capture()
doAssert difference(anisotropyMasked.pixel(20, 16), anisotropic.pixel(20, 16)) <= 2
doAssert difference(anisotropyMasked.pixel(44, 16), isotropic.pixel(44, 16)) <= 2
material.anisotropyTransform.offset.x = 0.5
let anisotropyShifted = capture()
doAssert difference(anisotropyShifted.pixel(20, 16), isotropic.pixel(20, 16)) <= 2
renderer.release(root)
material.anisotropy = newImage(1, 1)
material.anisotropy.fill(rgbx(128, 255, 255, 0))
doAssert difference(capture().pixel(32, 24), rotatedAnisotropy.pixel(32, 24)) <= 2
echo "Anisotropy GPU: zero strength, rotated lobe, RG direction/B strength, linear data, UV1 and transforms passed"

# Isolate a clearcoat highlight from a black nonreflective base layer.
renderer.release(root)
material.hasAnisotropy = false
material.anisotropyStrength = 0
material.anisotropy = nil
material.metallicFactor = 0
material.baseColorFactor = color(0, 0, 0, 1)
material.hasSpecular = true
material.specularFactor = 0
material.ior = 1.5
material.clearcoatFactor = 1
material.clearcoatRoughnessFactor = 0.3
ctx.sunLightDirection = vec3(0, 0, -1)
let coating = capture()
doAssert coating.pixel(32, 24).r > 100
renderer.release(root)
material.normal = newImage(1, 1)
material.normal.fill(rgbx(230, 128, 204, 255))
material.hasNormalTexture = true
material.normalScale = 1
doAssert difference(capture().pixel(32, 24), coating.pixel(32, 24)) <= 1,
  "The base normal map must not change the clearcoat normal"
renderer.release(root)
material.clearcoatNormal = material.normal
material.clearcoatNormalScale = 1
doAssert capture().pixel(32, 24).r < coating.pixel(32, 24).r - 80
material.clearcoatNormalScale = 0
doAssert difference(capture().pixel(32, 24), coating.pixel(32, 24)) <= 1
renderer.release(root)
material.clearcoatNormal = nil
material.clearcoat = newImage(2, 1)
material.clearcoat[0, 0] = rgbx(0, 255, 255, 255)
material.clearcoat[1, 0] = rgbx(255, 0, 0, 0)
material.clearcoatSampler.magFilter = NearestMagFilter
material.clearcoatSampler.minFilter = NearestMinFilter
material.clearcoatTransform.texCoord = 1
let coatMasked = capture()
doAssert difference(coatMasked.pixel(20, 16), coating.pixel(20, 16)) <= 1
doAssert coatMasked.pixel(44, 16).r < 3
material.clearcoatTransform.offset.x = 0.5
doAssert capture().pixel(20, 16).r < 3
renderer.release(root)
material.clearcoat = nil
material.clearcoatRoughness = newImage(1, 1)
material.clearcoatRoughness.fill(rgbx(255, 128, 0, 0))
material.clearcoatRoughnessFactor = 0.6
let roughMap = capture().pixel(32, 24)
renderer.release(root)
material.clearcoatRoughness = nil
material.clearcoatRoughnessFactor = 0.6'f * 128.0'f / 255.0'f
doAssert difference(capture().pixel(32, 24), roughMap) <= 1, "Clearcoat roughness uses linear green"
ctx.sunLightColor = color(0, 0, 0, 0)
material.emissiveFactor = color(0.5, 0.5, 0.5, 1)
let coatedEmission = capture().pixel(32, 24)
material.clearcoatFactor = 0
let uncoatedEmission = capture().pixel(32, 24)
doAssert coatedEmission.r < uncoatedEmission.r - 1, "Clearcoat must attenuate emission"
echo "Clearcoat GPU: independent normals, normal scale, R/G maps, UV1, transforms and emission layering passed"

# Thin-film interference must affect reflection without changing coverage.
renderer.release(root)
material.normal = nil
material.hasNormalTexture = false
material.emissiveFactor = color(0, 0, 0, 1)
material.baseColorFactor = color(1, 1, 1, 1)
material.specularFactor = 1
material.iridescenceIor = 1.3
material.iridescenceThicknessMinimum = 100
material.iridescenceThicknessMaximum = 400
material.roughnessFactor = 0.4
material.baseColorFactor = color(0, 0, 0, 1) # Isolate the colored specular reflection.
ctx.sunLightDirection = vec3(0, 0, -1)
ctx.sunLightColor = color(1, 1, 1, 1)
let noFilm = capture()
material.hasIridescence = true
doAssert capture() == noFilm, "Zero film strength must be neutral"
material.iridescenceFactor = 1
material.iridescenceThicknessMaximum = 0
doAssert capture() == noFilm, "Zero thickness must be neutral"
material.iridescenceThicknessMaximum = 400
let film400 = capture()
let filmPixel = film400.pixel(32, 24)
doAssert difference(filmPixel, noFilm.pixel(32, 24)) > 8
doAssert max(filmPixel.r, max(filmPixel.g, filmPixel.b)).int -
  min(filmPixel.r, min(filmPixel.g, filmPixel.b)).int > 8, "White light must acquire interference colors"
material.iridescenceThicknessMaximum = 200
let film200 = capture()
doAssert difference(film200.pixel(32, 24), filmPixel) > 8, "Film thickness must change hue"
renderer.release(root)
material.iridescenceThicknessMaximum = 400
material.iridescence = newImage(2, 1)
material.iridescence[0, 0] = rgbx(0, 255, 255, 255)
material.iridescence[1, 0] = rgbx(255, 0, 0, 0)
material.iridescenceSampler.magFilter = NearestMagFilter
material.iridescenceSampler.minFilter = NearestMinFilter
material.iridescenceTransform.texCoord = 1
let filmMask = capture()
doAssert difference(filmMask.pixel(20, 16), film400.pixel(20, 16)) <= 1
doAssert difference(filmMask.pixel(44, 16), noFilm.pixel(44, 16)) <= 1
material.iridescenceTransform.offset.x = 0.5
doAssert difference(capture().pixel(20, 16), noFilm.pixel(20, 16)) <= 1
renderer.release(root)
material.iridescence = nil
material.iridescenceThickness = newImage(1, 1)
material.iridescenceThickness.fill(rgbx(255, 128, 0, 0))
material.iridescenceThicknessMinimum = 600
material.iridescenceThicknessMaximum = 200
let filmMap = capture().pixel(32, 24)
renderer.release(root)
material.iridescenceThickness = nil
material.iridescenceThicknessMaximum = 600'f + (200'f - 600'f) * 128'f / 255'f
doAssert difference(capture().pixel(32, 24), filmMap) <= 1,
  "Thickness must use linear G, support reversed ranges, and ignore alpha"
doAssert capture() == capture(), "Film must be repeatable"
echo "Iridescence GPU: zero strength/thickness, interference hue, R/G maps, UV1 and reversed thickness range passed"

# Specular alpha controls dielectric reflection; RGB tint is sampled as sRGB.
renderer.release(root)
material.iridescenceFactor = 0
material.specularFactor = 1
material.specularColorFactor = vec3(1)
let fullSpecular = capture()
material.specularFactor = 0
let noSpecular = capture()
doAssert noSpecular.pixel(32, 24).r < 3 and fullSpecular.pixel(32, 24).r > 50
renderer.release(root)
material.specularFactor = 1
material.specular = newImage(2, 1)
material.specular[0, 0] = rgbx(255, 255, 255, 0)
material.specular[1, 0] = rgbx(0, 0, 0, 255)
material.specularSampler.magFilter = NearestMagFilter
material.specularSampler.minFilter = NearestMinFilter
material.specularTransform.texCoord = 1
let specularMask = capture()
doAssert difference(specularMask.pixel(20, 16), fullSpecular.pixel(20, 16)) <= 1
doAssert difference(specularMask.pixel(44, 16), noSpecular.pixel(44, 16)) <= 1
material.specularTransform.offset.x = 0.5
doAssert difference(capture().pixel(20, 16), noSpecular.pixel(20, 16)) <= 1
renderer.release(root)
material.specular = nil
material.specularColor = newImage(1, 1)
material.specularColor.fill(rgbx(128, 64, 192, 0))
let specularTint = capture().pixel(32, 24)
doAssert specularTint.b > specularTint.r and specularTint.r > specularTint.g and specularTint.g > 3
renderer.release(root)
material.specularColor = nil
material.specularColorFactor = vec3(0.215861, 0.051269, 0.527115)
doAssert difference(capture().pixel(32, 24), specularTint) <= 1,
  "Specular color must use sRGB transfer and preserve color under zero alpha"
material.metallicFactor = 1
material.baseColorFactor = color(0.2, 0.3, 0.4, 1)
let metalWithSpecular = capture()
material.specularFactor = 0
doAssert capture() == metalWithSpecular, "Specular extension must not attenuate metals"
echo "Specular GPU: reflection strength/alpha, sRGB color, UV1/offset and metallic independence passed"
ctx.destroy()
renderer.release(root)
renderer.shutdown()
echo "Transmission GPU pipeline: coverage, ordering, repeated frames, UV/data maps, absorption/scale, refraction, roughness, IOR, direct lighting and shadow coexistence passed"
