## This file handles rendering for PBR.

import
  std/[strutils, algorithm, math],
  opengl, windy, pixie, vmath,
  ../../common, ../../models, ../../shaders, ../../ktx2,
  ./common as openglCommon,
  ./ibl,
  ./transmission,
  ../shaders as shaderSources

export ibl.IblEnvironment, ibl.loadIblEnvironment

const
  VertexEntryPoint* = "main"
  FragmentEntryPoint* = "main"

  envMapSize* = 512 # Size of the environment map.
  StudioEnvSize = 8

  PbrVertexShader* = shaderSources.PbrVertSrc
  PbrFragmentShader* = shaderSources.PbrFragSrc
  SkyboxVertexShader* = shaderSources.SkyboxVertSrc
  SkyboxFragmentShader* = shaderSources.SkyboxFragSrc
  ShadowDepthVertexShader* = shaderSources.ShadowDepthVertSrc
  ShadowDepthFragmentShader* = shaderSources.ShadowDepthFragSrc

const
  ShadowMapSize = 2048

when defined(emscripten):
  const
    ShadowMapInternalFormat = GL_DEPTH_COMPONENT24.GLint
    ShadowMapPixelType = GL_UNSIGNED_INT
else:
  const
    ShadowMapInternalFormat = GL_DEPTH_COMPONENT.GLint
    ShadowMapPixelType = cGL_FLOAT

type
  EnvironmentMap* = object
    textureId*: GLuint
    mipCount*: float32

  TextureTransformUniforms = object
    texCoord: GLint
    offset: GLint
    scale: GLint
    rotation: GLint

  PbrUniforms = object
    model: GLint
    normalMatrix: GLint
    view: GLint
    proj: GLint
    lightSpace: GLint
    useSkinning: GLint
    jointMatrices: GLint
    environmentMap: GLint
    environmentMipCount: GLint
    environmentRotation: GLint
    hasVertexTangent: GLint
    sheenEnabled, sheenColorFactor, sheenRoughnessFactor: GLint
    specularFactor, specularColorFactor: GLint
    punctualLightCount, punctualLightDirections, punctualLightColors: GLint
    punctualLightPositions, punctualLightParameters: GLint
    baseColorTexture: GLint
    baseColorFactor: GLint
    baseColorTransform: TextureTransformUniforms
    metallicRoughnessTexture: GLint
    metallicFactor: GLint
    roughnessFactor: GLint
    transmissionFactor: GLint
    diffuseTransmissionFactor, diffuseTransmissionColorFactor: GLint
    hasDiffuseTransmissionTexture, hasDiffuseTransmissionColorTexture: GLint
    diffuseTransmissionTransform, diffuseTransmissionColorTransform: TextureTransformUniforms
    materialIor, thicknessFactor, attenuationColor, attenuationDistance: GLint
    volumeScale: GLint
    hasTransmissionTexture, hasThicknessTexture, transmissionBackground: GLint
    exposure: GLint
    transmissionTransform, thicknessTransform: TextureTransformUniforms
    metallicRoughnessTransform: TextureTransformUniforms
    normalTexture: GLint
    normalScale: GLint
    normalTransform: TextureTransformUniforms
    useNormalTexture: GLint
    occlusionTexture: GLint
    occlusionStrength: GLint
    occlusionTransform: TextureTransformUniforms
    emissiveTexture: GLint
    emissiveFactor: GLint
    emissiveTransform: TextureTransformUniforms
    shadowMap: GLint
    shadowBias: GLint
    shadowMapTexelSize: GLint
    alphaCutoff: GLint
    unlitMaterial: GLint
    opaqueMaterial: GLint
    ambientLightColor: GLint
    sunLightDirection: GLint
    sunLightColor: GLint
    rimLightDirection: GLint
    rimLightColor: GLint
    debugViewMode: GLint
    cameraPosition: GLint
    tint: GLint
    fogColor: GLint
    fogStart: GLint
    fogEnd: GLint
    fogDensity: GLint
    fogStrength: GLint
    environmentMapStrength: GLint
    useShadow: GLint

  SkyboxUniforms = object
    invProj: GLint
    invView: GLint
    environmentMap: GLint
    lod: GLint

  ShadowUniforms = object
    model: GLint
    view: GLint
    proj: GLint
    useSkinning: GLint
    jointMatrices: GLint
    tint: GLint

  Renderer* = ref object
    window*: Window

  BlendEntry = object
    node: Node
    primitive: Primitive
    transform: Mat4
    tint: Color
    root: Node
    useShadow: bool
    lightSpace: Mat4
    shadowTex: GLuint

  PbrPassValues = object
    ## Shadow copy of PBR uniform values already uploaded to pbrShader.
    ## Uniform values are per-program GL state, so this cache stays valid
    ## across foreign program binds and frames until the values change.
    valid: bool
    view: Mat4
    proj: Mat4
    lightSpace: Mat4
    tint: Color
    ambientLightColor: Color
    sunLightDirection: Vec3
    sunLightColor: Color
    rimLightDirection: Vec3
    rimLightColor: Color
    debugView: DebugView
    cameraPosition: Vec3
    fogColor: Color
    fogStart: float32
    fogEnd: float32
    fogDensity: float32
    fogStrength: float32
    environmentMapStrength: float32
    environmentMipCount: float32
    useShadow: bool
    useSkinning: bool
    useNormalTexture: bool
    alphaCutoff: float32

  PbrGlState = object
    ## Shadow copy of the global GL bindings and enables the PBR pass owns
    ## while a pass is active. Unknown values force a real GL call.
    programBound: bool
    activeUnit: int
    boundTexture: array[17, GLuint]
    textureEpoch: uint64
    blend: int8
    depthMask: int8
    cullFace: int8
    frontFaceCw: int8

  PbrContext* = ref object
    ## Reusable state for PBR rendering.
    size*: IVec2
    clearColor*: Color
    transform*: Mat4
    view*: Mat4
    proj*: Mat4
    tint*: Color
    useTrs*: bool
    ambientLightColor*: Color
    sunLightDirection*: Vec3
    sunLightColor*: Color
    rimLightDirection*: Vec3
    rimLightColor*: Color
    debugView*: DebugView
    cameraPosition*: Vec3
    fogColor*: Color
    fogStart*: float32
    fogEnd*: float32
    fogDensity*: float32
    fogStrength*: float32
    environmentMapStrength*: float32
    environmentMap*: EnvironmentMap
    iblEnvironment*: IblEnvironment
    punctualLightCount: int32
    punctualLightDirections, punctualLightColors, punctualLightPositions: array[32, Vec3]
    punctualLightParameters: array[32, Vec4]
    environmentRotation*: float32 ## IBL rotation about Y, in degrees.
    exposure*: float32 ## Linear exposure multiplier before PBR Neutral.
    hdrTarget: HdrTarget
    transmissionTarget: TransmissionTarget
    transmissionBackground: bool
    ownsIblEnvironment: bool
    maxIblAnisotropy: float32
    useShadows*: bool
    drawSkybox*: bool
    skyboxLod*: float32
    vsync*: bool
    pbrShader*: GLuint
    skyboxShader*: GLuint
    skyboxVao*: GLuint
    skyboxVbo*: GLuint
    shadowMapFbo*: GLuint
    shadowMapTex*: GLuint
    shadowDepthShader*: GLuint
    shadowMapSize*: int
    shadowBias*: float32
    pbrUniforms: PbrUniforms
    skyboxUniforms: SkyboxUniforms
    shadowUniforms: ShadowUniforms
    ownsEnvironmentMap: bool
    jointMatrices: seq[Mat4]
    blended: seq[BlendEntry]
    backgroundDraws, transmitted: seq[BlendEntry]
    deferred: seq[BlendEntry]
    passValues: PbrPassValues
    glState: PbrGlState
    passDepth: int
    lastMaterial: Material
    lastMaterialVersion: uint64

const TextureUnknown = high(GLuint)

var textureBindEpoch: uint64 = 1
  ## Bumped whenever GL texture ids are deleted anywhere, so per-unit bind
  ## caches never trust an id that may have been recycled by glGenTextures.

proc invalidateGlState*(ctx: PbrContext) =
  ## Marks GL program, texture-unit, and enable state unknown. Call after
  ## running your own GL commands (binding other programs or textures,
  ## toggling blend/depth/cull) between draws inside a pass. Uniform values
  ## are per-program state and stay cached.
  if ctx == nil:
    return
  ctx.glState.programBound = false
  ctx.glState.activeUnit = -1
  for unit in 0 ..< ctx.glState.boundTexture.len:
    ctx.glState.boundTexture[unit] = TextureUnknown
  ctx.glState.blend = -1
  ctx.glState.depthMask = -1
  ctx.glState.cullFace = -1
  ctx.glState.frontFaceCw = -1
  ctx.lastMaterial = nil

proc invalidateUniformCache*(ctx: PbrContext) =
  ## Escape hatch for consumers that upload uniforms to pbrShader directly.
  if ctx == nil:
    return
  ctx.passValues.valid = false
  ctx.lastMaterial = nil

proc uniformLocation(shader: GLuint, name: cstring): GLint =
  ## Returns one shader uniform location.
  glGetUniformLocation(shader, name)

proc loadTextureTransformUniforms(
  shader: GLuint,
  prefix: cstring
): TextureTransformUniforms =
  ## Caches one texture transform uniform group.
  let base = $prefix
  result.texCoord = uniformLocation(shader, (base & "TexCoord").cstring)
  result.offset = uniformLocation(shader, (base & "UvOffset").cstring)
  result.scale = uniformLocation(shader, (base & "UvScale").cstring)
  result.rotation = uniformLocation(shader, (base & "UvRotation").cstring)

proc loadPbrUniforms(shader: GLuint): PbrUniforms =
  ## Caches PBR shader uniform locations.
  result.model = uniformLocation(shader, "model")
  result.normalMatrix = uniformLocation(shader, "normalMatrix")
  result.view = uniformLocation(shader, "view")
  result.proj = uniformLocation(shader, "proj")
  result.lightSpace = uniformLocation(shader, "lightSpace")
  result.useSkinning = uniformLocation(shader, "useSkinning")
  result.jointMatrices = uniformLocation(shader, "jointMatrices")
  result.environmentMap = uniformLocation(shader, "environmentMap")
  result.environmentMipCount = uniformLocation(shader, "environmentMipCount")
  result.environmentRotation = uniformLocation(shader, "environmentRotation")
  result.hasVertexTangent = uniformLocation(shader, "hasVertexTangent")
  result.sheenEnabled = uniformLocation(shader, "sheenEnabled")
  result.sheenColorFactor = uniformLocation(shader, "sheenColorFactor")
  result.sheenRoughnessFactor = uniformLocation(shader, "sheenRoughnessFactor")
  result.specularFactor = uniformLocation(shader, "specularFactor")
  result.specularColorFactor = uniformLocation(shader, "specularColorFactor")
  result.punctualLightCount = uniformLocation(shader, "punctualLightCount")
  result.punctualLightDirections = uniformLocation(shader, "punctualLightDirections")
  result.punctualLightColors = uniformLocation(shader, "punctualLightColors")
  result.punctualLightPositions = uniformLocation(shader, "punctualLightPositions")
  result.punctualLightParameters = uniformLocation(shader, "punctualLightParameters")
  result.baseColorTexture = uniformLocation(shader, "baseColorTexture")
  result.baseColorFactor = uniformLocation(shader, "baseColorFactor")
  result.baseColorTransform =
    loadTextureTransformUniforms(shader, "baseColor")
  result.metallicRoughnessTexture =
    uniformLocation(shader, "metallicRoughnessTexture")
  result.metallicFactor = uniformLocation(shader, "metallicFactor")
  result.roughnessFactor = uniformLocation(shader, "roughnessFactor")
  result.transmissionFactor = uniformLocation(shader, "transmissionFactor")
  result.diffuseTransmissionFactor = uniformLocation(shader, "diffuseTransmissionFactor")
  result.diffuseTransmissionColorFactor = uniformLocation(shader, "diffuseTransmissionColorFactor")
  result.hasDiffuseTransmissionTexture = uniformLocation(shader, "hasDiffuseTransmissionTexture")
  result.hasDiffuseTransmissionColorTexture = uniformLocation(shader, "hasDiffuseTransmissionColorTexture")
  result.diffuseTransmissionTransform = loadTextureTransformUniforms(shader, "diffuseTransmission")
  result.diffuseTransmissionColorTransform = loadTextureTransformUniforms(shader, "diffuseTransmissionColor")
  result.materialIor = uniformLocation(shader, "materialIor")
  result.volumeScale = uniformLocation(shader, "volumeScale")
  result.thicknessFactor = uniformLocation(shader, "thicknessFactor")
  result.attenuationColor = uniformLocation(shader, "attenuationColor")
  result.attenuationDistance = uniformLocation(shader, "attenuationDistance")
  result.hasTransmissionTexture = uniformLocation(shader, "hasTransmissionTexture")
  result.hasThicknessTexture = uniformLocation(shader, "hasThicknessTexture")
  result.transmissionBackground = uniformLocation(shader, "transmissionBackground")
  result.exposure = uniformLocation(shader, "exposure")
  result.transmissionTransform = loadTextureTransformUniforms(shader, "transmission")
  result.thicknessTransform = loadTextureTransformUniforms(shader, "thickness")
  result.metallicRoughnessTransform =
    loadTextureTransformUniforms(shader, "metallicRoughness")
  result.normalTexture = uniformLocation(shader, "normalTexture")
  result.normalScale = uniformLocation(shader, "normalScale")
  result.normalTransform = loadTextureTransformUniforms(shader, "normal")
  result.useNormalTexture = uniformLocation(shader, "useNormalTexture")
  result.occlusionTexture = uniformLocation(shader, "occlusionTexture")
  result.occlusionStrength = uniformLocation(shader, "occlusionStrength")
  result.occlusionTransform = loadTextureTransformUniforms(shader, "occlusion")
  result.emissiveTexture = uniformLocation(shader, "emissiveTexture")
  result.emissiveFactor = uniformLocation(shader, "emissiveFactor")
  result.emissiveTransform = loadTextureTransformUniforms(shader, "emissive")
  result.shadowMap = uniformLocation(shader, "shadowMap")
  result.shadowBias = uniformLocation(shader, "shadowBias")
  result.shadowMapTexelSize = uniformLocation(shader, "shadowMapTexelSize")
  result.alphaCutoff = uniformLocation(shader, "alphaCutoff")
  result.unlitMaterial = uniformLocation(shader, "unlitMaterial")
  result.opaqueMaterial = uniformLocation(shader, "opaqueMaterial")
  result.ambientLightColor = uniformLocation(shader, "ambientLightColor")
  result.sunLightDirection = uniformLocation(shader, "sunLightDirection")
  result.sunLightColor = uniformLocation(shader, "sunLightColor")
  result.rimLightDirection = uniformLocation(shader, "rimLightDirection")
  result.rimLightColor = uniformLocation(shader, "rimLightColor")
  result.debugViewMode = uniformLocation(shader, "debugViewMode")
  result.cameraPosition = uniformLocation(shader, "cameraPosition")
  result.tint = uniformLocation(shader, "tint")
  result.fogColor = uniformLocation(shader, "fogColor")
  result.fogStart = uniformLocation(shader, "fogStart")
  result.fogEnd = uniformLocation(shader, "fogEnd")
  result.fogDensity = uniformLocation(shader, "fogDensity")
  result.fogStrength = uniformLocation(shader, "fogStrength")
  result.environmentMapStrength =
    uniformLocation(shader, "environmentMapStrength")
  result.useShadow = uniformLocation(shader, "useShadow")

proc loadSkyboxUniforms(shader: GLuint): SkyboxUniforms =
  ## Caches skybox shader uniform locations.
  result.invProj = uniformLocation(shader, "invProj")
  result.invView = uniformLocation(shader, "invView")
  result.environmentMap = uniformLocation(shader, "environmentMap")
  result.lod = uniformLocation(shader, "lod")

proc loadShadowUniforms(shader: GLuint): ShadowUniforms =
  ## Caches shadow-depth shader uniform locations.
  result.model = uniformLocation(shader, "model")
  result.view = uniformLocation(shader, "view")
  result.proj = uniformLocation(shader, "proj")
  result.useSkinning = uniformLocation(shader, "useSkinning")
  result.jointMatrices = uniformLocation(shader, "jointMatrices")
  result.tint = uniformLocation(shader, "tint")

proc mipCountForSize(size: int): float32 =
  ## Returns the highest mip level for one square texture size.
  if size <= 1:
    0.0'f32
  else:
    floor(log2(size.float32))

proc setupPbr(ctx: PbrContext) =
  ## Sets up the PBR rendering resources for one context.
  doAssert ctx != nil, "PBR context must not be nil."

  when not defined(emscripten):
    # Reduce visible seams when sampling blurred cubemap mip levels.
    glEnable(GL_TEXTURE_CUBE_MAP_SEAMLESS)

  ctx.pbrShader = compileShaderFiles(
    PbrVertexShader,
    PbrFragmentShader
  )
  ctx.pbrUniforms = loadPbrUniforms(ctx.pbrShader)
  # Sampler-unit assignments never change; set them once at link time.
  glUseProgram(ctx.pbrShader)
  glUniform1i(ctx.pbrUniforms.baseColorTexture, 0)
  glUniform1i(ctx.pbrUniforms.metallicRoughnessTexture, 1)
  glUniform1i(ctx.pbrUniforms.normalTexture, 2)
  glUniform1i(ctx.pbrUniforms.occlusionTexture, 3)
  glUniform1i(ctx.pbrUniforms.emissiveTexture, 4)
  glUniform1i(ctx.pbrUniforms.environmentMap, 5)
  glUniform1i(ctx.pbrUniforms.shadowMap, 6)
  ctx.passValues = PbrPassValues()
  ctx.invalidateGlState()
  ctx.skyboxShader = compileShaderFiles(
    SkyboxVertexShader,
    SkyboxFragmentShader
  )
  ctx.skyboxUniforms = loadSkyboxUniforms(ctx.skyboxShader)

  ctx.shadowDepthShader = compileShaderFiles(
    ShadowDepthVertexShader,
    ShadowDepthFragmentShader
  )
  ctx.shadowUniforms = loadShadowUniforms(ctx.shadowDepthShader)

  # Shadow map resources.
  glGenFramebuffers(1, addr ctx.shadowMapFbo)
  glGenTextures(1, addr ctx.shadowMapTex)
  glBindTexture(GL_TEXTURE_2D, ctx.shadowMapTex)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    ShadowMapInternalFormat,
    ctx.shadowMapSize.GLsizei,
    ctx.shadowMapSize.GLsizei,
    0,
    GL_DEPTH_COMPONENT,
    ShadowMapPixelType,
    nil
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  when defined(emscripten):
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
  else:
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE.cint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL.cint)
  when not defined(emscripten):
    var borderColor = [1.0.GLfloat, 1.0, 1.0, 1.0]
    glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, borderColor[0].addr)

  glBindFramebuffer(GL_FRAMEBUFFER, ctx.shadowMapFbo)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER,
    GL_DEPTH_ATTACHMENT,
    GL_TEXTURE_2D,
    ctx.shadowMapTex,
    0
  )
  when not defined(emscripten):
    glDrawBuffer(GL_NONE)
    glReadBuffer(GL_NONE)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

  # Bind shadow map to texture unit 6 so the sampler2DShadow uniform always
  # points to a valid depth texture, even when shadows are disabled.
  glUseProgram(ctx.pbrShader)
  glUniform1i(ctx.pbrUniforms.shadowMap, 6)
  glUniform1f(ctx.pbrUniforms.shadowBias, ctx.shadowBias)
  glUniform2f(
    ctx.pbrUniforms.shadowMapTexelSize,
    1.0'f32 / ctx.shadowMapSize.float32,
    1.0'f32 / ctx.shadowMapSize.float32
  )
  glUniform1f(ctx.pbrUniforms.environmentMipCount, 0)
  glActiveTexture(GL_TEXTURE6)
  glBindTexture(GL_TEXTURE_2D, ctx.shadowMapTex)
  glUseProgram(0)

  # Full-screen triangle data.
  var skyboxVertices = [
    -1.0f32, -1.0f32,
     3.0f32, -1.0f32,
    -1.0f32,  3.0f32
  ]

  glGenVertexArrays(1, addr ctx.skyboxVao)
  glGenBuffers(1, addr ctx.skyboxVbo)

  glBindVertexArray(ctx.skyboxVao)
  glBindBuffer(GL_ARRAY_BUFFER, ctx.skyboxVbo)
  glBufferData(GL_ARRAY_BUFFER, skyboxVertices.sizeof, addr skyboxVertices, GL_STATIC_DRAW)

  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 0, nil)

  glBindVertexArray(0)

proc newEnvironmentMap*(
  textureId: GLuint,
  mipCount: float32
): EnvironmentMap =
  ## Creates an environment-map handle from an existing texture.
  EnvironmentMap(textureId: textureId, mipCount: mipCount)

proc destroy*(environmentMap: var EnvironmentMap) =
  ## Deletes the OpenGL texture owned by an environment map.
  if environmentMap.textureId != 0:
    glDeleteTextures(1, environmentMap.textureId.addr)
    inc textureBindEpoch
  environmentMap = EnvironmentMap()

proc loadCubeTexture(path: string): EnvironmentMap =
  ## Creates a cube texture and returns its environment-map handle.

  var textureId: GLuint
  glGenTextures(1, addr(textureId))
  glBindTexture(GL_TEXTURE_CUBE_MAP, textureId)

  let directions = [
    "px", "nx", "py", "ny", "pz", "nz"
  ]
  var faceSize = 1
  for i, direction in directions:
    let facePath = path.replace("*", direction)
    let image = readImage(facePath)
    if i == 0:
      faceSize = max(image.width, image.height)
    glTexImage2D(
      (GL_TEXTURE_CUBE_MAP_POSITIVE_X.int + i).GLenum,
      0,
      GL_RGBA.GLint,
      image.width.GLsizei,
      image.height.GLsizei,
      0,
      GL_RGBA,
      GL_UNSIGNED_BYTE,
      image.data[0].addr
    )

  # Set texture parameters for the cube map.
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)

  # Generate mipmaps for the cube map.
  glGenerateMipmap(GL_TEXTURE_CUBE_MAP)
  newEnvironmentMap(textureId, mipCountForSize(faceSize))

proc createSolidCubeTexture(color: ColorRGBX): EnvironmentMap =
  ## Creates a simple solid-color cube texture.
  var
    textureId: GLuint
    pixel = [color.r, color.g, color.b, color.a]

  glGenTextures(1, textureId.addr)
  glBindTexture(GL_TEXTURE_CUBE_MAP, textureId)

  for i in 0 ..< 6:
    glTexImage2D(
      (GL_TEXTURE_CUBE_MAP_POSITIVE_X.int + i).GLenum,
      0,
      GL_RGBA.GLint,
      1,
      1,
      0,
      GL_RGBA,
      GL_UNSIGNED_BYTE,
      pixel[0].addr
    )

  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)
  newEnvironmentMap(textureId, 0.0'f32)

proc studioFaceDirection(face, x, y, size: int): Vec3 =
  ## Returns a normalized direction for a cubemap texel.
  let
    u = ((x.float32 + 0.5'f) / size.float32) * 2.0'f - 1.0'f
    v = ((y.float32 + 0.5'f) / size.float32) * 2.0'f - 1.0'f
  case face
  of 0:
    normalize(vec3(1.0'f, -v, -u))
  of 1:
    normalize(vec3(-1.0'f, -v, u))
  of 2:
    normalize(vec3(u, 1.0'f, v))
  of 3:
    normalize(vec3(u, -1.0'f, -v))
  of 4:
    normalize(vec3(u, -v, 1.0'f))
  of 5:
    normalize(vec3(-u, -v, -1.0'f))
  else:
    vec3(0, 1, 0)

proc studioColor(dir: Vec3): ColorRGBX =
  ## Returns a tiny neutral studio-light sample color.
  let
    hemi = clamp(dir.y * 0.5'f + 0.5'f, 0.0'f, 1.0'f)
    keyDir = normalize(vec3(0.35'f, 0.85'f, 0.25'f))
    fillDir = normalize(vec3(-0.45'f, 0.65'f, -0.35'f))
    key = pow(max(dot(dir, keyDir), 0.0'f), 24.0'f)
    fill = pow(max(dot(dir, fillDir), 0.0'f), 8.0'f)
    cool = vec3(0.18'f, 0.19'f, 0.21'f)
    neutral = vec3(0.58'f, 0.6'f, 0.63'f)
    sky = vec3(0.92'f, 0.94'f, 0.97'f)
  var color = mix(cool, neutral, hemi)
  color = mix(color, sky, hemi * hemi)
  color += vec3(0.28'f, 0.27'f, 0.25'f) * key
  color += vec3(0.10'f, 0.11'f, 0.12'f) * fill
  rgbx(
    clamp((color.x * 255.0'f).int, 0, 255).uint8,
    clamp((color.y * 255.0'f).int, 0, 255).uint8,
    clamp((color.z * 255.0'f).int, 0, 255).uint8,
    255
  )

proc createStudioCubeTexture(): EnvironmentMap =
  ## Creates a tiny procedural cubemap for neutral studio lighting.
  var textureId: GLuint
  glGenTextures(1, textureId.addr)
  glBindTexture(GL_TEXTURE_CUBE_MAP, textureId)

  for face in 0 ..< 6:
    let image = newImage(StudioEnvSize, StudioEnvSize)
    for y in 0 ..< StudioEnvSize:
      for x in 0 ..< StudioEnvSize:
        image[x, y] = studioColor(
          studioFaceDirection(face, x, y, StudioEnvSize)
        )
    glTexImage2D(
      (GL_TEXTURE_CUBE_MAP_POSITIVE_X.int + face).GLenum,
      0,
      GL_RGBA.GLint,
      image.width.GLsizei,
      image.height.GLsizei,
      0,
      GL_RGBA,
      GL_UNSIGNED_BYTE,
      image.data[0].addr
    )

  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(
    GL_TEXTURE_CUBE_MAP,
    GL_TEXTURE_MIN_FILTER,
    GL_LINEAR_MIPMAP_LINEAR
  )
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)
  glGenerateMipmap(GL_TEXTURE_CUBE_MAP)
  newEnvironmentMap(textureId, mipCountForSize(StudioEnvSize))

proc loadEnvironmentMap*(cubeMapPath: string): EnvironmentMap =
  ## Loads an environment map from a cube texture path.
  loadCubeTexture(cubeMapPath)

proc loadSolidEnvironmentMap*(
  color = rgbx(180, 190, 220, 255)
): EnvironmentMap =
  ## Loads a solid-color cubemap.
  createSolidCubeTexture(color)

proc loadDefaultEnvironmentMap*(): EnvironmentMap =
  ## Loads a small procedural studio cubemap.
  createStudioCubeTexture()

proc drawSkybox*(
  ctx: PbrContext,
  view, proj: Mat4,
  environmentMap: EnvironmentMap,
  lod: float32 = 0.0
) =
  ## Draws the skybox using a full-screen quad.
  doAssert ctx != nil, "PBR context must not be nil."
  glUseProgram(ctx.skyboxShader)

  var
    invProj = proj.inverse
    invView = view.inverse

  glUniformMatrix4fv(
    ctx.skyboxUniforms.invProj,
    1,
    GL_FALSE,
    cast[ptr float32](invProj.addr)
  )
  glUniformMatrix4fv(
    ctx.skyboxUniforms.invView,
    1,
    GL_FALSE,
    cast[ptr float32](invView.addr)
  )

  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_CUBE_MAP, environmentMap.textureId)
  glUniform1i(ctx.skyboxUniforms.environmentMap, 0)
  glUniform1f(ctx.skyboxUniforms.lod, lod)

  # Draw a single triangle that covers the whole screen.
  glDisable(GL_CULL_FACE)
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)

  glBindVertexArray(ctx.skyboxVao)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)

  glDepthMask(GL_TRUE)
  glEnable(GL_DEPTH_TEST)

proc newPbrContext*(
  shadowMapSize = ShadowMapSize,
  shadowBias = 0.0015'f32
): PbrContext =
  ## Creates reusable state for PBR rendering.
  var ctx: PbrContext
  new(ctx)
  ctx.size = ivec2(0, 0)
  ctx.clearColor = color(0, 0, 0, 1)
  ctx.transform = mat4()
  ctx.view = mat4()
  ctx.proj = mat4()
  ctx.tint = color(1, 1, 1, 1)
  ctx.useTrs = true
  ctx.ambientLightColor = color(0.1, 0.1, 0.1, 1)
  ctx.sunLightDirection = vec3(1, 4, 2)
  ctx.sunLightColor = color(1, 1, 1, 1)
  ctx.rimLightDirection = vec3(-1, 1, -1)
  ctx.rimLightColor = color(0, 0, 0, 0)
  ctx.debugView = dvLit
  ctx.cameraPosition = vec3(0, 0, 10)
  ctx.fogColor = color(0, 0, 0, 1)
  ctx.fogStart = 0.0'f
  ctx.fogEnd = 1.0'f
  ctx.fogDensity = 0.0'f
  ctx.fogStrength = 0.0'f
  ctx.environmentMapStrength = 1.0'f
  ctx.environmentMap = EnvironmentMap()
  ctx.environmentRotation = 90.0'f
  ctx.exposure = 1.0'f
  ctx.ownsEnvironmentMap = false
  ctx.useShadows = false
  ctx.drawSkybox = false
  ctx.skyboxLod = 0
  ctx.vsync = false
  ctx.shadowMapSize = shadowMapSize
  ctx.shadowBias = shadowBias
  setupPbr(ctx)
  ctx

proc newPbrContext*(renderer: Renderer): PbrContext =
  ## Creates reusable state for PBR rendering.
  discard renderer
  newPbrContext()

proc attachEnvironmentMap*(
  ctx: PbrContext,
  environmentMap: EnvironmentMap,
  owned = true
) =
  ## Attaches an environment map to a PBR context.
  doAssert ctx != nil, "PBR context must not be nil."
  if ctx.ownsEnvironmentMap:
    ctx.environmentMap.destroy()
  ctx.environmentMap = environmentMap
  ctx.ownsEnvironmentMap = owned

proc attachIblEnvironment*(ctx: PbrContext, environment: IblEnvironment,
    owned = true) =
  ## Opt into linear core metallic/roughness shading with a prefiltered HDR
  ## environment. Wrap all scene draws in beginIblFrame/endIblFrame. Existing
  ## procedural-lighting contexts keep their original shader and texture data.
  doAssert not ctx.hdrTarget.active
  doAssert environment.specular != 0 and environment.diffuse != 0 and environment.lut != 0
  let shader = compileShaderFiles(PbrVertexShader, shaderSources.IblFragSrc)
  if ctx.ownsIblEnvironment:
    ctx.iblEnvironment.destroy()
  if ctx.ownsEnvironmentMap:
    ctx.environmentMap.destroy()
  glDeleteProgram(ctx.pbrShader)
  ctx.pbrShader = shader
  ctx.pbrUniforms = loadPbrUniforms(shader)
  ctx.iblEnvironment = environment
  ctx.ownsIblEnvironment = owned
  ctx.maxIblAnisotropy = maxIblAnisotropy()
  ctx.environmentMap = EnvironmentMap(textureId: environment.specular,
    mipCount: environment.mipCount.float32)
  ctx.ownsEnvironmentMap = false
  ctx.environmentMapStrength = environment.intensityScale
  glUseProgram(shader)
  for (name, unit) in [("baseColorTexture", 0), ("metallicRoughnessTexture", 1),
      ("normalTexture", 2), ("occlusionTexture", 3), ("emissiveTexture", 4),
      ("environmentMap", 5), ("diffuseEnvironment", 7), ("ggxLut", 8),
      ("charlieEnvironment", 9), ("charlieLut", 10), ("sheenEnergyLut", 11),
      ("transmissionBuffer", 12), ("transmissionTexture", 13), ("thicknessTexture", 14),
      ("diffuseTransmissionTexture", 15), ("diffuseTransmissionColorTexture", 16)]:
    glUniform1i(uniformLocation(shader, name.cstring), unit.GLint)
  glUniform1f(uniformLocation(shader, "transmissionBufferLod"), log2(TransmissionSize.float32))
  ctx.passValues = PbrPassValues()
  inc textureBindEpoch
  ctx.invalidateGlState()

proc beginIblFrame*(ctx: PbrContext) =
  ## Clear the HDR target using size/clearColor before drawing the whole scene.
  doAssert ctx.iblEnvironment.specular != 0, "Attach an IBL environment first"
  ctx.hdrTarget.beginHdr(ctx.size, ctx.clearColor)
  inc textureBindEpoch
  ctx.invalidateGlState()

proc endIblFrame*(ctx: PbrContext) =
  ## Present the scene with exposure, Khronos PBR Neutral and display transfer.
  doAssert ctx.passDepth == 0, "Finish batched draws before presenting HDR"
  ctx.hdrTarget.endHdr(ctx.exposure)
  inc textureBindEpoch
  ctx.invalidateGlState()

proc destroy*(ctx: PbrContext) =
  ## Deletes the OpenGL resources owned by a PBR context.
  if ctx == nil:
    return
  ctx.hdrTarget.destroy()
  ctx.transmissionTarget.destroy()
  if ctx.ownsIblEnvironment:
    ctx.iblEnvironment.destroy()
    inc textureBindEpoch
  if ctx.ownsEnvironmentMap:
    ctx.environmentMap.destroy()
  ctx.ownsEnvironmentMap = false
  if ctx.shadowMapTex != 0:
    glDeleteTextures(1, ctx.shadowMapTex.addr)
    inc textureBindEpoch
  if ctx.shadowMapFbo != 0:
    glDeleteFramebuffers(1, ctx.shadowMapFbo.addr)
  if ctx.skyboxVbo != 0:
    glDeleteBuffers(1, ctx.skyboxVbo.addr)
  if ctx.skyboxVao != 0:
    glDeleteVertexArrays(1, ctx.skyboxVao.addr)
  if ctx.pbrShader != 0:
    glDeleteProgram(ctx.pbrShader)
  if ctx.skyboxShader != 0:
    glDeleteProgram(ctx.skyboxShader)
  if ctx.shadowDepthShader != 0:
    glDeleteProgram(ctx.shadowDepthShader)
  ctx.shadowMapTex = 0
  ctx.shadowMapFbo = 0
  ctx.skyboxVbo = 0
  ctx.skyboxVao = 0
  ctx.pbrShader = 0
  ctx.skyboxShader = 0
  ctx.shadowDepthShader = 0

proc glValue(filter: TextureMagFilter): GLint =
  case filter
  of NearestMagFilter: GL_NEAREST.GLint
  of LinearMagFilter: GL_LINEAR.GLint

proc glValue(filter: TextureMinFilter): GLint =
  case filter
  of NearestMinFilter: GL_NEAREST.GLint
  of LinearMinFilter: GL_LINEAR.GLint
  of NearestMipmapNearestMinFilter: GL_NEAREST_MIPMAP_NEAREST.GLint
  of LinearMipmapNearestMinFilter: GL_LINEAR_MIPMAP_NEAREST.GLint
  of NearestMipmapLinearMinFilter: GL_NEAREST_MIPMAP_LINEAR.GLint
  of LinearMipmapLinearMinFilter: GL_LINEAR_MIPMAP_LINEAR.GLint

proc glValue(wrap: TextureWrap): GLint =
  case wrap
  of RepeatWrap: GL_REPEAT.GLint
  of ClampToEdgeWrap: GL_CLAMP_TO_EDGE.GLint
  of MirroredRepeatWrap: GL_MIRRORED_REPEAT.GLint

proc glValue(mode: PrimitiveMode): GLenum =
  case mode
  of PointsMode: GL_POINTS
  of LinesMode: GL_LINES
  of LineLoopMode: GL_LINE_LOOP
  of LineStripMode: GL_LINE_STRIP
  of TrianglesMode: GL_TRIANGLES
  of TriangleStripMode: GL_TRIANGLE_STRIP
  of TriangleFanMode: GL_TRIANGLE_FAN

proc setFrontFace(transform: Mat4, mode: PrimitiveMode) =
  if mode in {TrianglesMode, TriangleStripMode, TriangleFanMode} and
    transform.determinant < 0.0'f:
    glFrontFace(GL_CW)
  else:
    glFrontFace(GL_CCW)

proc ensureData(primitive: Primitive): PrimitiveData =
  if primitive.data == nil:
    primitive.data = PrimitiveData()
  primitive.data

proc beginPass*(ctx: PbrContext) =
  ## Starts a batched PBR pass. Until the matching endPass, the context
  ## assumes it owns the GL program binding, texture units 0-14, and the
  ## blend/depth/cull/front-face enables across draw calls, and defers
  ## blended primitives from all draws into one globally sorted flush at
  ## endPass. Nesting is allowed; only the outermost pair has effect.
  doAssert ctx != nil, "PBR context must not be nil."
  inc ctx.passDepth
  if ctx.passDepth == 1:
    ctx.invalidateGlState()
    ctx.blended.setLen(0)
    ctx.backgroundDraws.setLen(0)
    ctx.transmitted.setLen(0)

proc ensurePbrProgram(ctx: PbrContext) =
  if not ctx.glState.programBound:
    glUseProgram(ctx.pbrShader)
    ctx.glState.programBound = true

proc bindTextureCached(
  ctx: PbrContext,
  unit: int,
  target: GLenum,
  id: GLuint
) =
  if ctx.glState.textureEpoch != textureBindEpoch:
    for cachedUnit in 0 ..< ctx.glState.boundTexture.len:
      ctx.glState.boundTexture[cachedUnit] = TextureUnknown
    ctx.glState.textureEpoch = textureBindEpoch
  if ctx.glState.boundTexture[unit] == id:
    return
  if ctx.glState.activeUnit != unit:
    glActiveTexture(GLenum(GL_TEXTURE0.int + unit))
    ctx.glState.activeUnit = unit
  glBindTexture(target, id)
  ctx.glState.boundTexture[unit] = id

proc setBlendCached(ctx: PbrContext, on: bool) =
  let want = int8(ord(on))
  if ctx.glState.blend == want:
    return
  if on:
    glEnable(GL_BLEND)
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA,
      GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  else:
    glDisable(GL_BLEND)
  ctx.glState.blend = want

proc setDepthMaskCached(ctx: PbrContext, on: bool) =
  let want = int8(ord(on))
  if ctx.glState.depthMask == want:
    return
  glDepthMask(if on: GL_TRUE else: GL_FALSE)
  ctx.glState.depthMask = want

proc setCullFaceCached(ctx: PbrContext, on: bool) =
  let want = int8(ord(on))
  if ctx.glState.cullFace == want:
    return
  if on:
    glEnable(GL_CULL_FACE)
  else:
    glDisable(GL_CULL_FACE)
  ctx.glState.cullFace = want

proc setFrontFaceCached(
  ctx: PbrContext,
  transform: Mat4,
  mode: PrimitiveMode
) =
  let cw = int8(ord(
    mode in {TrianglesMode, TriangleStripMode, TriangleFanMode} and
    transform.determinant < 0.0'f
  ))
  if ctx.glState.frontFaceCw == cw:
    return
  glFrontFace(if cw == 1: GL_CW else: GL_CCW)
  ctx.glState.frontFaceCw = cw

proc ensureData(material: Material): MaterialData =
  if material.data == nil:
    material.data = MaterialData()
  material.data

proc uploadTextureToGpu(
  textureId: var GLuint,
  image: Image,
  ktx2Data: string,
  sampler: TextureSampler,
  srgb = false
) =
  ## Uploads a texture to OpenGL.
  if ktx2Data.len > 0:
    textureId = loadKtx2Texture(ktx2Data, sampler)
    inc textureBindEpoch
    return

  if image == nil:
    return

  glGenTextures(1, textureId.addr)
  glBindTexture(GL_TEXTURE_2D, textureId)
  # Binding on the active unit changes what the state cache believes is
  # bound there, so force every cached unit to rebind.
  inc textureBindEpoch
  # Opaque images upload as RGB, so NPOT widths can have non-4-byte rows.
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  if image.isOpaque():
    var data = newSeq[uint8](image.width * image.height * 3)
    for i, rgbx in image.data:
      data[i * 3 + 0] = rgbx.r
      data[i * 3 + 1] = rgbx.g
      data[i * 3 + 2] = rgbx.b
    glTexImage2D(
      GL_TEXTURE_2D,
      0,
      (if srgb: GL_SRGB8 else: GL_RGB).GLint,
      image.width.GLint,
      image.height.GLint,
      0,
      GL_RGB,
      GL_UNSIGNED_BYTE,
      data[0].addr
    )
  else:
    glTexImage2D(
      GL_TEXTURE_2D,
      0,
      (if srgb: GL_SRGB8_ALPHA8 else: GL_RGBA).GLint,
      image.width.GLint,
      image.height.GLint,
      0,
      GL_RGBA,
      GL_UNSIGNED_BYTE,
      image.data[0].addr
    )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, sampler.magFilter.glValue)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, sampler.minFilter.glValue)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, sampler.wrapS.glValue)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, sampler.wrapT.glValue)
  glGenerateMipmap(GL_TEXTURE_2D)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4)

proc uploadMaterialToGpu(material: Material) =
  if material == nil:
    return
  let data = material.ensureData()
  if (material.baseColor != nil or material.baseColorKtx2.len > 0) and data.baseColorId == 0:
    uploadTextureToGpu(
      data.baseColorId,
      material.baseColor,
      material.baseColorKtx2,
      material.baseColorSampler
    )
  if (material.metallicRoughness != nil or material.metallicRoughnessKtx2.len > 0) and
      data.metallicRoughnessId == 0:
    uploadTextureToGpu(
      data.metallicRoughnessId,
      material.metallicRoughness,
      material.metallicRoughnessKtx2,
      material.metallicRoughnessSampler
    )
  if (material.normal != nil or material.normalKtx2.len > 0) and data.normalId == 0:
    uploadTextureToGpu(
      data.normalId,
      material.normal,
      material.normalKtx2,
      material.normalSampler
    )
  if (material.occlusion != nil or material.occlusionKtx2.len > 0) and data.occlusionId == 0:
    uploadTextureToGpu(
      data.occlusionId,
      material.occlusion,
      material.occlusionKtx2,
      material.occlusionSampler
    )
  if (material.emissive != nil or material.emissiveKtx2.len > 0) and data.emissiveId == 0:
    uploadTextureToGpu(
      data.emissiveId,
      material.emissive,
      material.emissiveKtx2,
      material.emissiveSampler
    )
  data.materialVersion = material.materialVersion

  if data.transmissionId == 0:
    uploadTextureToGpu(data.transmissionId, material.transmission,
      material.transmissionKtx2, material.transmissionSampler)
  if data.thicknessId == 0:
    uploadTextureToGpu(data.thicknessId, material.thickness,
      material.thicknessKtx2, material.thicknessSampler)
  if data.diffuseTransmissionId == 0:
    uploadTextureToGpu(data.diffuseTransmissionId, material.diffuseTransmission,
      material.diffuseTransmissionKtx2, material.diffuseTransmissionSampler)
  if data.diffuseTransmissionColorId == 0:
    uploadTextureToGpu(data.diffuseTransmissionColorId, material.diffuseTransmissionColor,
      material.diffuseTransmissionColorKtx2, material.diffuseTransmissionColorSampler, srgb = true)

proc clearMaterialFromGpu(material: Material) =
  if material == nil or material.data == nil:
    return
  let data = material.data
  if data.transmissionId != 0: glDeleteTextures(1, data.transmissionId.addr)
  if data.thicknessId != 0: glDeleteTextures(1, data.thicknessId.addr)
  if data.diffuseTransmissionId != 0: glDeleteTextures(1, data.diffuseTransmissionId.addr)
  if data.diffuseTransmissionColorId != 0: glDeleteTextures(1, data.diffuseTransmissionColorId.addr)
  if data.baseColorSrgbId != 0:
    glDeleteTextures(1, data.baseColorSrgbId.addr)
  if data.emissiveSrgbId != 0:
    glDeleteTextures(1, data.emissiveSrgbId.addr)
  if data.baseColorId != 0.GLuint:
    glDeleteTextures(1, data.baseColorId.addr)
    data.baseColorId = 0
  if data.metallicRoughnessId != 0.GLuint:
    glDeleteTextures(1, data.metallicRoughnessId.addr)
    data.metallicRoughnessId = 0
  if data.normalId != 0.GLuint:
    glDeleteTextures(1, data.normalId.addr)
    data.normalId = 0
  if data.occlusionId != 0.GLuint:
    glDeleteTextures(1, data.occlusionId.addr)
    data.occlusionId = 0
  if data.emissiveId != 0.GLuint:
    glDeleteTextures(1, data.emissiveId.addr)
    data.emissiveId = 0
  material.data = nil
  inc textureBindEpoch

proc clearFromGpu*(primitive: Primitive)

proc uploadToGpu*(primitive: Primitive) =
  ## Uploads primitive data to OpenGL.
  if primitive == nil:
    return
  let data = primitive.ensureData()
  if data.uploaded and data.geometryVersion == primitive.geometryVersion:
    return
  if data.uploaded:
    primitive.clearFromGpu()
  discard primitive.ensureData()
  let gpu = primitive.data

  glGenVertexArrays(1, gpu.vertexArrayId.addr)
  glBindVertexArray(gpu.vertexArrayId)

  if primitive.indices32.len > 0:
    glGenBuffers(1, gpu.indicesId.addr)
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, gpu.indicesId)
    glBufferData(
      GL_ELEMENT_ARRAY_BUFFER,
      primitive.indices32.len * sizeof(uint32),
      primitive.indices32[0].addr,
      GL_STATIC_DRAW
    )
  elif primitive.indices16.len > 0:
    glGenBuffers(1, gpu.indicesId.addr)
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, gpu.indicesId)
    glBufferData(
      GL_ELEMENT_ARRAY_BUFFER,
      primitive.indices16.len * sizeof(uint16),
      primitive.indices16[0].addr,
      GL_STATIC_DRAW
    )

  if primitive.points.len > 0:
    glGenBuffers(1, gpu.pointsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, gpu.pointsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.points.len * sizeof(Vec3),
      primitive.points[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, 0, nil)

  if primitive.uvs.len > 0:
    glGenBuffers(1, gpu.uvsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, gpu.uvsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.uvs.len * sizeof(Vec2),
      primitive.uvs[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(3)
    glVertexAttribPointer(3, 2, cGL_FLOAT, GL_FALSE, 0, nil)

  if primitive.uvs1.len > 0:
    glGenBuffers(1, gpu.uvs1Id.addr)
    glBindBuffer(GL_ARRAY_BUFFER, gpu.uvs1Id)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.uvs1.len * sizeof(Vec2),
      primitive.uvs1[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(7)
    glVertexAttribPointer(7, 2, cGL_FLOAT, GL_FALSE, 0, nil)
  else:
    glDisableVertexAttribArray(7)
    glVertexAttrib2f(7, 0.0, 0.0)

  if primitive.normals.len > 0:
    glGenBuffers(1, gpu.normalsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, gpu.normalsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.normals.len * sizeof(Vec3),
      primitive.normals[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(2)
    glVertexAttribPointer(2, 3, cGL_FLOAT, GL_FALSE, 0, nil)

  if primitive.tangents.len > 0:
    glGenBuffers(1, gpu.tangentsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, gpu.tangentsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.tangents.len * sizeof(Vec4),
      primitive.tangents[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(4)
    glVertexAttribPointer(4, 4, cGL_FLOAT, GL_FALSE, 0, nil)
  else:
    glDisableVertexAttribArray(4)
    glVertexAttrib4f(4, 1.0, 0.0, 0.0, 1.0)

  if primitive.colors.len > 0:
    glGenBuffers(1, gpu.colorsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, gpu.colorsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.colors.len * sizeof(ColorRGBX),
      primitive.colors[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(1)
    glVertexAttribPointer(1, 4, cGL_UNSIGNED_BYTE, GL_TRUE, 0, nil)
  else:
    glDisableVertexAttribArray(1)
    glVertexAttrib4f(1, 1.0, 1.0, 1.0, 1.0)

  if primitive.jointIds.len > 0:
    glGenBuffers(1, gpu.jointIdsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, gpu.jointIdsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.jointIds.len * sizeof(JointIds),
      primitive.jointIds[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(5)
    glVertexAttribIPointer(5, 4, cGL_UNSIGNED_SHORT, 0, nil)
  else:
    glDisableVertexAttribArray(5)
    glVertexAttribI4ui(5, 0, 0, 0, 0)

  if primitive.jointWeights.len > 0:
    glGenBuffers(1, gpu.jointWeightsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, gpu.jointWeightsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.jointWeights.len * sizeof(Vec4),
      primitive.jointWeights[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(6)
    glVertexAttribPointer(6, 4, cGL_FLOAT, GL_FALSE, 0, nil)
  else:
    glDisableVertexAttribArray(6)
    glVertexAttrib4f(6, 0.0, 0.0, 0.0, 0.0)

  uploadMaterialToGpu(primitive.material)
  gpu.uploaded = true
  gpu.geometryVersion = primitive.geometryVersion

proc clearFromGpu*(primitive: Primitive) =
  ## Clears primitive data from OpenGL.
  if primitive == nil or primitive.data == nil:
    return
  let data = primitive.data
  if data.uploaded:
    glDeleteVertexArrays(1, data.vertexArrayId.addr)
    if primitive.indices16.len > 0 or primitive.indices32.len > 0:
      glDeleteBuffers(1, data.indicesId.addr)
    if primitive.points.len > 0:
      glDeleteBuffers(1, data.pointsId.addr)
    if primitive.uvs.len > 0:
      glDeleteBuffers(1, data.uvsId.addr)
    if primitive.uvs1.len > 0:
      glDeleteBuffers(1, data.uvs1Id.addr)
    if primitive.normals.len > 0:
      glDeleteBuffers(1, data.normalsId.addr)
    if primitive.tangents.len > 0:
      glDeleteBuffers(1, data.tangentsId.addr)
    if primitive.colors.len > 0:
      glDeleteBuffers(1, data.colorsId.addr)
    if primitive.jointIds.len > 0:
      glDeleteBuffers(1, data.jointIdsId.addr)
    if primitive.jointWeights.len > 0:
      glDeleteBuffers(1, data.jointWeightsId.addr)
  primitive.data = nil
  clearMaterialFromGpu(primitive.material)

proc clearFromGpu*(mesh: Mesh) =
  if mesh == nil:
    return
  for primitive in mesh.primitives:
    primitive.clearFromGpu()

proc clearFromGpu*(node: Node) =
  if node == nil:
    return
  node.mesh.clearFromGpu()
  for child in node.nodes:
    child.clearFromGpu()

proc setTextureTransformUniform(
  uniforms: TextureTransformUniforms,
  transform: TextureTransform
) =
  ## Sets UV transform uniforms for a texture input.
  glUniform1i(uniforms.texCoord, transform.texCoord.GLint)
  glUniform2f(
    uniforms.offset,
    transform.offset.x,
    transform.offset.y
  )
  glUniform2f(
    uniforms.scale,
    transform.scale.x,
    transform.scale.y
  )
  glUniform1f(uniforms.rotation, transform.rotation)

template syncPassValue(ctx: PbrContext, field, value, uploadStmt: untyped) =
  ## Uploads one shadowed pbrShader uniform only when its value changed.
  if not ctx.passValues.valid or ctx.passValues.field != value:
    ctx.passValues.field = value
    uploadStmt

proc applyPassUniforms(
  ctx: PbrContext,
  view, proj, lightSpace: Mat4,
  tint: Color,
  ambientLightColor: Color,
  sunLightDirection: Vec3,
  sunLightColor: Color,
  rimLightDirection: Vec3,
  rimLightColor: Color,
  debugView: DebugView,
  cameraPosition: Vec3,
  useShadow: bool
) =
  ## Uploads the frame-level uniform block through the value shadow, so a
  ## run of primitives sharing the same frame state costs zero GL calls.
  let u = ctx.pbrUniforms
  ctx.syncPassValue(view, view):
    var arr = view
    glUniformMatrix4fv(u.view, 1, GL_FALSE, cast[ptr float32](arr.addr))
  ctx.syncPassValue(proj, proj):
    var arr = proj
    glUniformMatrix4fv(u.proj, 1, GL_FALSE, cast[ptr float32](arr.addr))
  ctx.syncPassValue(lightSpace, lightSpace):
    var arr = lightSpace
    glUniformMatrix4fv(u.lightSpace, 1, GL_FALSE, cast[ptr float32](arr.addr))
  ctx.syncPassValue(tint, tint):
    glUniform4f(u.tint, tint.r, tint.g, tint.b, tint.a)
  ctx.syncPassValue(ambientLightColor, ambientLightColor):
    glUniform4f(
      u.ambientLightColor,
      ambientLightColor.r,
      ambientLightColor.g,
      ambientLightColor.b,
      ambientLightColor.a
    )
  ctx.syncPassValue(sunLightDirection, sunLightDirection):
    glUniform3f(
      u.sunLightDirection,
      sunLightDirection.x,
      sunLightDirection.y,
      sunLightDirection.z
    )
  ctx.syncPassValue(sunLightColor, sunLightColor):
    glUniform4f(
      u.sunLightColor,
      sunLightColor.r,
      sunLightColor.g,
      sunLightColor.b,
      sunLightColor.a
    )
  ctx.syncPassValue(rimLightDirection, rimLightDirection):
    glUniform3f(
      u.rimLightDirection,
      rimLightDirection.x,
      rimLightDirection.y,
      rimLightDirection.z
    )
  ctx.syncPassValue(rimLightColor, rimLightColor):
    glUniform4f(
      u.rimLightColor,
      rimLightColor.r,
      rimLightColor.g,
      rimLightColor.b,
      rimLightColor.a
    )
  ctx.syncPassValue(debugView, debugView):
    glUniform1i(u.debugViewMode, debugView.int.GLint)
  ctx.syncPassValue(cameraPosition, cameraPosition):
    glUniform3f(
      u.cameraPosition,
      cameraPosition.x,
      cameraPosition.y,
      cameraPosition.z
    )
  ctx.syncPassValue(fogColor, ctx.fogColor):
    glUniform4f(
      u.fogColor,
      ctx.fogColor.r,
      ctx.fogColor.g,
      ctx.fogColor.b,
      ctx.fogColor.a
    )
  ctx.syncPassValue(fogStart, ctx.fogStart):
    glUniform1f(u.fogStart, ctx.fogStart)
  ctx.syncPassValue(fogEnd, ctx.fogEnd):
    glUniform1f(u.fogEnd, ctx.fogEnd)
  ctx.syncPassValue(fogDensity, ctx.fogDensity):
    glUniform1f(u.fogDensity, ctx.fogDensity)
  ctx.syncPassValue(fogStrength, ctx.fogStrength):
    glUniform1f(u.fogStrength, ctx.fogStrength)
  ctx.syncPassValue(environmentMapStrength, ctx.environmentMapStrength):
    glUniform1f(u.environmentMapStrength, ctx.environmentMapStrength)
  ctx.syncPassValue(environmentMipCount, ctx.environmentMap.mipCount):
    glUniform1f(u.environmentMipCount, ctx.environmentMap.mipCount)
  if ctx.iblEnvironment.specular != 0:
    glUniform1i(u.transmissionBackground, ctx.transmissionBackground.GLint)
    glUniform1f(u.exposure, ctx.exposure)
    let
      angle = degToRad(ctx.environmentRotation)
      c = cos(angle)
      s = sin(angle)
      rotation = mat3(vec3(c, 0.0'f, -s), vec3(0.0'f, 1.0'f, 0.0'f), vec3(s, 0.0'f, c))
    glUniformMatrix3fv(u.environmentRotation, 1, GL_FALSE,
      cast[ptr float32](rotation.unsafeAddr))
    glUniform1i(u.punctualLightCount, ctx.punctualLightCount)
    if ctx.punctualLightCount > 0:
      glUniform3fv(u.punctualLightDirections, ctx.punctualLightCount,
        cast[ptr float32](ctx.punctualLightDirections[0].addr))
      glUniform3fv(u.punctualLightColors, ctx.punctualLightCount,
        cast[ptr float32](ctx.punctualLightColors[0].addr))
      glUniform3fv(u.punctualLightPositions, ctx.punctualLightCount,
        cast[ptr float32](ctx.punctualLightPositions[0].addr))
      glUniform4fv(u.punctualLightParameters, ctx.punctualLightCount,
        cast[ptr float32](ctx.punctualLightParameters[0].addr))
  ctx.syncPassValue(useShadow, useShadow):
    glUniform1i(u.useShadow, useShadow.GLint)
  ctx.passValues.valid = true

proc applyMaterial(
  ctx: PbrContext,
  primitive: Primitive,
  shadowTex: GLuint
) =
  ## Binds one primitive's material: texture binds are keyed on the actual
  ## GL ids (so late texture uploads are caught), material uniforms upload
  ## only when the material or its version changed, and blend/depth/cull
  ## enables go through the GL-state shadow.
  let material = primitive.material
  let u = ctx.pbrUniforms
  if material == nil:
    ctx.bindTextureCached(0, GL_TEXTURE_2D, 0)
    ctx.lastMaterial = nil
    return
  let materialData = material.ensureData()
  if ctx.iblEnvironment.specular != 0:
    glUniform1i(u.hasVertexTangent, (primitive.tangents.len > 0).GLint)
    if materialData.baseColorSrgbId == 0:
      uploadTextureToGpu(materialData.baseColorSrgbId, material.baseColor,
        material.baseColorKtx2, material.baseColorSampler, srgb = true)
    if materialData.emissiveSrgbId == 0:
      uploadTextureToGpu(materialData.emissiveSrgbId, material.emissive,
        material.emissiveKtx2, material.emissiveSampler, srgb = true)
    ctx.bindTextureCached(0, GL_TEXTURE_2D, materialData.baseColorSrgbId)
    ctx.bindTextureCached(4, GL_TEXTURE_2D, materialData.emissiveSrgbId)
    ctx.bindTextureCached(13, GL_TEXTURE_2D, materialData.transmissionId)
    ctx.bindTextureCached(14, GL_TEXTURE_2D, materialData.thicknessId)
    ctx.bindTextureCached(15, GL_TEXTURE_2D, materialData.diffuseTransmissionId)
    ctx.bindTextureCached(16, GL_TEXTURE_2D, materialData.diffuseTransmissionColorId)
  else:
    ctx.bindTextureCached(0, GL_TEXTURE_2D, materialData.baseColorId)
    ctx.bindTextureCached(4, GL_TEXTURE_2D, materialData.emissiveId)
  ctx.bindTextureCached(1, GL_TEXTURE_2D, materialData.metallicRoughnessId)
  ctx.bindTextureCached(2, GL_TEXTURE_2D, materialData.normalId)
  ctx.bindTextureCached(3, GL_TEXTURE_2D, materialData.occlusionId)
  if ctx.iblEnvironment.specular != 0 and ctx.maxIblAnisotropy > 1.0'f and
      (ctx.lastMaterial != material or ctx.lastMaterialVersion != material.materialVersion):
    # Match the reference's trilinear texture filtering with hardware AF.
    for (unit, sampler) in [(0, material.baseColorSampler),
        (1, material.metallicRoughnessSampler), (2, material.normalSampler),
        (3, material.occlusionSampler), (4, material.emissiveSampler),
        (13, material.transmissionSampler), (14, material.thicknessSampler),
        (15, material.diffuseTransmissionSampler), (16, material.diffuseTransmissionColorSampler)]:
      if ctx.glState.boundTexture[unit] == 0: continue
      if sampler.magFilter != NearestMagFilter and sampler.minFilter in
          {NearestMipmapLinearMinFilter, LinearMipmapLinearMinFilter}:
        glActiveTexture(GLenum(GL_TEXTURE0.int + unit))
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY_EXT, ctx.maxIblAnisotropy)
    ctx.glState.activeUnit = -1
  let activeShadowTex =
    if shadowTex != 0.GLuint:
      shadowTex
    else:
      ctx.shadowMapTex
  ctx.bindTextureCached(6, GL_TEXTURE_2D, activeShadowTex)

  # Depends on the primitive, not just the material.
  let useNormalTexture =
    material.hasNormalTexture and
    (ctx.iblEnvironment.specular != 0 or
      (primitive.normals.len > 0 and primitive.tangents.len > 0))
  ctx.syncPassValue(useNormalTexture, useNormalTexture):
    glUniform1i(u.useNormalTexture, useNormalTexture.ord.GLint)

  var cutoff = material.alphaCutoff
  let alphaMode = if ctx.iblEnvironment.specular != 0: material.alphaMode
    else: material.legacyAlphaMode
  case alphaMode
  of MaskAlphaMode:
    ctx.setBlendCached(false)
    ctx.setDepthMaskCached(true)
    cutoff = material.alphaCutoff
  of BlendAlphaMode:
    ctx.setBlendCached(true)
    ctx.setDepthMaskCached(false)
    cutoff = -1.0
  else:
    ctx.setBlendCached(false)
    ctx.setDepthMaskCached(true)
    cutoff = -1.0
  ctx.syncPassValue(alphaCutoff, cutoff):
    glUniform1f(u.alphaCutoff, cutoff)
  ctx.setCullFaceCached(not material.doubleSided)

  if ctx.lastMaterial == material and
      ctx.lastMaterialVersion == material.materialVersion:
    return

  glUniform1i(u.unlitMaterial, material.unlit.ord.GLint)
  glUniform1i(u.opaqueMaterial, (alphaMode == OpaqueAlphaMode).ord.GLint)
  glUniform4f(
    u.baseColorFactor,
    material.baseColorFactor.r,
    material.baseColorFactor.g,
    material.baseColorFactor.b,
    material.baseColorFactor.a
  )
  setTextureTransformUniform(u.baseColorTransform, material.baseColorTransform)
  glUniform1f(u.metallicFactor, material.metallicFactor)
  glUniform1f(u.roughnessFactor, material.roughnessFactor)
  glUniform1f(u.transmissionFactor, material.transmissionFactor)
  glUniform1f(u.diffuseTransmissionFactor, material.diffuseTransmissionFactor)
  glUniform3f(u.diffuseTransmissionColorFactor, material.diffuseTransmissionColorFactor.x,
    material.diffuseTransmissionColorFactor.y, material.diffuseTransmissionColorFactor.z)
  glUniform1i(u.hasDiffuseTransmissionTexture, (materialData.diffuseTransmissionId != 0).GLint)
  glUniform1i(u.hasDiffuseTransmissionColorTexture, (materialData.diffuseTransmissionColorId != 0).GLint)
  setTextureTransformUniform(u.diffuseTransmissionTransform, material.diffuseTransmissionTransform)
  setTextureTransformUniform(u.diffuseTransmissionColorTransform, material.diffuseTransmissionColorTransform)
  # The spec's explicit IOR=0 compatibility mode represents positive infinity.
  # At 1e8 the float32 Fresnel ratio rounds to exactly one without infinities.
  glUniform1f(u.materialIor, if material.hasIor and material.ior == 0: 1e8'f
    elif material.ior > 0: material.ior else: 1.5'f)
  glUniform1f(u.thicknessFactor, material.thicknessFactor)
  glUniform1f(u.attenuationDistance, material.attenuationDistance)
  glUniform3f(u.attenuationColor, material.attenuationColor.x,
    material.attenuationColor.y, material.attenuationColor.z)
  glUniform1i(u.hasTransmissionTexture, (materialData.transmissionId != 0).GLint)
  glUniform1i(u.hasThicknessTexture, (materialData.thicknessId != 0).GLint)
  setTextureTransformUniform(u.transmissionTransform, material.transmissionTransform)
  setTextureTransformUniform(u.thicknessTransform, material.thicknessTransform)
  let specularColor = if material.hasSpecular: material.specularColorFactor else: vec3(1)
  glUniform1f(u.specularFactor, if material.hasSpecular: material.specularFactor else: 1.0'f)
  glUniform3f(u.specularColorFactor, specularColor.x, specularColor.y, specularColor.z)
  glUniform1i(u.sheenEnabled, (ctx.iblEnvironment.charlie != 0 and
    material.sheenColorFactor != vec3(0)).GLint)
  glUniform3f(u.sheenColorFactor, material.sheenColorFactor.x,
    material.sheenColorFactor.y, material.sheenColorFactor.z)
  glUniform1f(u.sheenRoughnessFactor, material.sheenRoughnessFactor)
  setTextureTransformUniform(
    u.metallicRoughnessTransform,
    material.metallicRoughnessTransform
  )
  glUniform1f(u.normalScale, material.normalScale)
  setTextureTransformUniform(u.normalTransform, material.normalTransform)
  glUniform1f(u.occlusionStrength, material.occlusionStrength)
  setTextureTransformUniform(u.occlusionTransform, material.occlusionTransform)
  glUniform3f(
    u.emissiveFactor,
    material.emissiveFactor.r,
    material.emissiveFactor.g,
    material.emissiveFactor.b
  )
  setTextureTransformUniform(u.emissiveTransform, material.emissiveTransform)
  ctx.lastMaterial = material
  ctx.lastMaterialVersion = material.materialVersion

proc renderPbrPrimitive(
  primitive: Primitive,
  transform, view, proj: Mat4,
  tint: Color,
  ambientLightColor: Color,
  sunLightDirection: Vec3,
  sunLightColor: Color,
  rimLightDirection: Vec3,
  rimLightColor: Color,
  debugView: DebugView,
  cameraPosition: Vec3,
  useShadow: bool,
  lightSpace: Mat4,
  shadowTex: GLuint,
  deferBlend: bool,
  blended: var seq[BlendEntry],
  ctx: PbrContext,
  owner: Node,
  root: Node
) =
  if primitive == nil:
    return
  let pbrUniforms = ctx.pbrUniforms

  if deferBlend and ctx.iblEnvironment.specular != 0:
    let entry = BlendEntry(node: owner, primitive: primitive,
      transform: transform, tint: tint, root: root,
      useShadow: useShadow, lightSpace: lightSpace, shadowTex: shadowTex)
    if primitive.material != nil and (primitive.material.hasTransmission or
        primitive.material.transmissionFactor > 0):
      ctx.transmitted.add(entry)
      return
    ctx.backgroundDraws.add(entry)

  let isBlend =
    (primitive.material != nil and
      (primitive.material.alphaMode == BlendAlphaMode or
        (ctx.iblEnvironment.specular == 0 and primitive.material.legacyAlphaMode == BlendAlphaMode))) or
    tint.a < 1
  if deferBlend and isBlend:
    blended.add(BlendEntry(
      node: owner,
      primitive: primitive,
      transform: transform,
      tint: tint,
      root: root
    ))
    return

  ctx.ensurePbrProgram()
  ctx.applyPassUniforms(
    view,
    proj,
    lightSpace,
    tint,
    ambientLightColor,
    sunLightDirection,
    sunLightColor,
    rimLightDirection,
    rimLightColor,
    debugView,
    cameraPosition,
    useShadow
  )

  var
    modelArray = transform
    normalArray = transform.normalMatrix
  glUniform3f(pbrUniforms.volumeScale, transform[0].xyz.length,
    transform[1].xyz.length, transform[2].xyz.length)
  glUniformMatrix4fv(
    pbrUniforms.model,
    1,
    GL_FALSE,
    cast[ptr float32](modelArray.addr)
  )
  glUniformMatrix3fv(
    pbrUniforms.normalMatrix,
    1,
    GL_FALSE,
    cast[ptr float32](normalArray.addr)
  )

  root.skinMatricesInto(owner, ctx.jointMatrices)
  let useSkinning = ctx.jointMatrices.len > 0
  ctx.syncPassValue(useSkinning, useSkinning):
    glUniform1i(pbrUniforms.useSkinning, useSkinning.ord.GLint)
  if useSkinning:
    glUniformMatrix4fv(
      pbrUniforms.jointMatrices,
      ctx.jointMatrices.len.GLsizei,
      GL_FALSE,
      cast[ptr float32](ctx.jointMatrices[0].addr)
    )

  primitive.uploadToGpu()
  let primitiveData = primitive.data
  glBindVertexArray(primitiveData.vertexArrayId)

  # Lazy material uploads bind on the active texture unit. Bind pass textures
  # afterward so a first-use upload cannot replace the transmission snapshot.
  ctx.applyMaterial(primitive, shadowTex)

  ctx.bindTextureCached(
    5,
    GL_TEXTURE_CUBE_MAP,
    ctx.environmentMap.textureId
  )
  if ctx.iblEnvironment.specular != 0:
    ctx.bindTextureCached(7, GL_TEXTURE_CUBE_MAP, ctx.iblEnvironment.diffuse)
    ctx.bindTextureCached(8, GL_TEXTURE_2D, ctx.iblEnvironment.lut)
    ctx.bindTextureCached(9, GL_TEXTURE_CUBE_MAP, ctx.iblEnvironment.charlie)
    ctx.bindTextureCached(10, GL_TEXTURE_2D, ctx.iblEnvironment.charlieLut)
    ctx.bindTextureCached(11, GL_TEXTURE_2D, ctx.iblEnvironment.sheenEnergyLut)
    ctx.bindTextureCached(12, GL_TEXTURE_2D,
      if ctx.transmissionBackground: 0.GLuint else: ctx.transmissionTarget.texture)
  if tint.a < 1 and (
    primitive.material == nil or
    primitive.material.alphaMode != BlendAlphaMode
  ):
    # The tint uniform's alpha already multiplies the fragment alpha in the
    # shader; blending it here lets engines fade whole draws (for example
    # distance fades) without cloning materials. The depth write stays on so
    # mostly-solid objects keep occluding while they fade.
    ctx.setBlendCached(true)

  let glMode = primitive.mode.glValue
  ctx.setFrontFaceCached(transform, primitive.mode)
  when not defined(emscripten):
    if primitive.mode == PointsMode:
      glPointSize(1.0)

  if primitive.indices16.len == 0 and primitive.indices32.len == 0:
    glDrawArrays(glMode, 0, primitive.points.len.cint)
  else:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitiveData.indicesId)
    if primitive.indices16.len > 0:
      glDrawElements(
        glMode,
        primitive.indices16.len.GLint,
        GL_UNSIGNED_SHORT,
        nil
      )
    elif primitive.indices32.len > 0:
      glDrawElements(
        glMode,
        primitive.indices32.len.GLint,
        GL_UNSIGNED_INT,
        nil
      )
    else:
      raise newException(GltfError, "Invalid indices")

proc renderPbrNode(
  node: Node,
  transform, view, proj: Mat4,
  tint: Color,
  ambientLightColor: Color,
  sunLightDirection: Vec3,
  sunLightColor: Color,
  rimLightDirection: Vec3,
  rimLightColor: Color,
  debugView: DebugView,
  cameraPosition: Vec3,
  useShadow: bool,
  lightSpace: Mat4,
  shadowTex: GLuint,
  deferBlend: bool,
  blended: var seq[BlendEntry],
  ctx: PbrContext,
  drawChildren = true,
  applyTrs = true,
  root: Node = nil
) =
  ## Renders a node with the PBR shader.
  if not node.visible:
    return

  let rootNode =
    if root == nil:
      node
    else:
      root

  node.mat =
    if applyTrs:
      transform * node.trs
    else:
      transform

  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      renderPbrPrimitive(
        primitive,
        node.mat,
        view,
        proj,
        tint,
        ambientLightColor,
        sunLightDirection,
        sunLightColor,
        rimLightDirection,
        rimLightColor,
        debugView,
        cameraPosition,
        useShadow,
        lightSpace,
        shadowTex,
        deferBlend,
        blended,
        ctx,
        node,
        rootNode
      )

  if drawChildren:
    for n in node.nodes:
      n.renderPbrNode(
        node.mat,
        view,
        proj,
        tint,
        ambientLightColor,
        sunLightDirection,
        sunLightColor,
        rimLightDirection,
        rimLightColor,
        debugView,
        cameraPosition,
        useShadow,
        lightSpace,
        shadowTex,
        deferBlend,
        blended,
        ctx,
        drawChildren=true,
        applyTrs=true,
        root=rootNode
      )

proc updatePunctualLights(ctx: PbrContext, root: Node) =
  ## Authored lights use the same animated world transforms as the meshes.
  ctx.punctualLightCount = 0
  if ctx.iblEnvironment.specular == 0: return
  proc visit(node: Node) =
    if node == nil or not node.visible: return
    if node.punctualLight != nil:
      let i = ctx.punctualLightCount.int
      if i >= ctx.punctualLightDirections.len:
        raise newException(ValueError, "IBL supports at most 32 authored punctual lights")
      let light = node.punctualLight
      var rotation = mat4()
      for axis in 0 ..< 3:
        let column = node.mat[axis].xyz
        if column.lengthSq > 0:
          let unit = normalize(column)
          for row in 0 ..< 3: rotation[axis, row] = unit[row]
      ctx.punctualLightDirections[i] = quatRotate(normalize(quat(rotation)), vec3(0, 0, -1))
      ctx.punctualLightPositions[i] = node.mat[3].xyz
      ctx.punctualLightColors[i] = vec3(light.color.r, light.color.g, light.color.b) * light.intensity
      ctx.punctualLightParameters[i] = vec4(light.kind.ord.float32, light.range,
        cos(light.innerConeAngle), cos(light.outerConeAngle))
      inc ctx.punctualLightCount
    for child in node.nodes: visit(child)
  visit(root)

proc sortByDepth(ctx: PbrContext, entries: var seq[BlendEntry]) =
  ## Same indexed-vertex centroid and view-space depth as the reference.
  ## Compute once per primitive, rather than walking its vertices in the sort.
  var sorted: seq[tuple[depth: float32, entry: BlendEntry]]
  for entry in entries:
    let primitive = entry.primitive
    var center = vec3(0)
    var count = 0
    if primitive.indices16.len > 0:
      for index in primitive.indices16: center += primitive.points[index]
      count = primitive.indices16.len
    elif primitive.indices32.len > 0:
      for index in primitive.indices32: center += primitive.points[index]
      count = primitive.indices32.len
    else:
      for point in primitive.points: center += point
      count = primitive.points.len
    if count > 0: center /= count.float32
    sorted.add(((ctx.view * entry.transform * vec4(center, 1)).z, entry))
  sorted.sort(proc(a, b: tuple[depth: float32, entry: BlendEntry]): int = cmp(a.depth, b.depth))
  for i, item in sorted: entries[i] = item.entry

proc replay(ctx: PbrContext, entry: BlendEntry) =
  ctx.updatePunctualLights(entry.root)
  ctx.deferred.setLen(0)
  renderPbrPrimitive(entry.primitive, entry.transform, ctx.view, ctx.proj,
    entry.tint, ctx.ambientLightColor, ctx.sunLightDirection, ctx.sunLightColor,
    ctx.rimLightDirection, ctx.rimLightColor, ctx.debugView, ctx.cameraPosition,
    useShadow=entry.useShadow, lightSpace=entry.lightSpace, shadowTex=entry.shadowTex,
    deferBlend=false, blended=ctx.deferred, ctx=ctx, owner=entry.node, root=entry.root)

proc flushTransmission(ctx: PbrContext) =
  if ctx.transmitted.len == 0:
    ctx.backgroundDraws.setLen(0)
    return
  # Opaque geometry has already reached the final target. Replay everything
  # except transmission into a separate snapshot, including ordinary alpha.
  # Replay uses the same evaluated pose: no animation is advanced here.
  ctx.transmissionBackground = true
  try:
    ctx.transmissionTarget.beginBackground(ctx.clearColor)
    ctx.invalidateGlState()
    ctx.invalidateUniformCache()
    if ctx.drawSkybox:
      drawSkybox(ctx, ctx.view, ctx.proj, ctx.environmentMap, ctx.skyboxLod)
      ctx.invalidateGlState()
    for entry in ctx.backgroundDraws:
      if entry.tint.a >= 1 and (entry.primitive.material == nil or
          entry.primitive.material.alphaMode != BlendAlphaMode):
        ctx.replay(entry)
    ctx.sortByDepth(ctx.blended)
    for entry in ctx.blended: ctx.replay(entry)
    ctx.transmissionTarget.resolveBackground()
  finally:
    ctx.transmissionTarget.restore()
    ctx.transmissionBackground = false
    ctx.invalidateGlState()
    ctx.invalidateUniformCache()
  ctx.sortByDepth(ctx.transmitted)
  for entry in ctx.transmitted: ctx.replay(entry)
  ctx.backgroundDraws.setLen(0)
  ctx.transmitted.setLen(0)

proc flushBlended(ctx: PbrContext) =
  ## Renders deferred blended primitives back-to-front. Entries replay with
  ## the tint captured at defer time; shadows are not sampled in the blended
  ## pass, matching the pre-pass behavior.
  if ctx.blended.len == 0:
    return
  if ctx.iblEnvironment.specular != 0:
    ctx.sortByDepth(ctx.blended)
  else:
    ctx.blended.sort(proc(a, b: BlendEntry): int =
      let
        pa = (a.transform * vec4(0, 0, 0, 1)).xyz
        pb = (b.transform * vec4(0, 0, 0, 1)).xyz
        da = (ctx.cameraPosition - pa).lengthSq
        db = (ctx.cameraPosition - pb).lengthSq
      if da > db: -1 elif da < db: 1 else: 0
    )
  for entry in ctx.blended: ctx.replay(entry)
  ctx.blended.setLen(0)

proc abortPass(ctx: PbrContext) =
  ## Unwinds an implicit pass after an exception escaped a draw: drops the
  ## deferred blended entries, restores the canonical GL state and forgets
  ## every cached value so the next draw starts clean.
  ctx.blended.setLen(0)
  ctx.deferred.setLen(0)
  ctx.backgroundDraws.setLen(0)
  ctx.transmitted.setLen(0)
  ctx.transmissionTarget.restore()
  ctx.transmissionBackground = false
  ctx.passDepth = 0
  try:
    glDisable(GL_BLEND)
    glDepthMask(GL_TRUE)
    glFrontFace(GL_CCW)
    glEnable(GL_CULL_FACE)
  except CatchableError:
    discard
  ctx.invalidateGlState()
  ctx.invalidateUniformCache()

proc endPass*(ctx: PbrContext) =
  ## Ends a batched PBR pass: flushes deferred blended primitives, sorted
  ## back-to-front across every draw in the pass, and restores the canonical
  ## GL state (blend off, depth writes on, CCW front faces, culling on).
  doAssert ctx != nil, "PBR context must not be nil."
  doAssert ctx.passDepth > 0, "endPass without matching beginPass."
  try:
    if ctx.passDepth == 1:
      ctx.flushTransmission()
      ctx.flushBlended()
      glDisable(GL_BLEND)
      glDepthMask(GL_TRUE)
      glFrontFace(GL_CCW)
      glEnable(GL_CULL_FACE)
      ctx.glState.blend = 0
      ctx.glState.depthMask = 1
      ctx.glState.frontFaceCw = 0
      ctx.glState.cullFace = 1
    dec ctx.passDepth
  except:
    ctx.abortPass()
    raise

proc drawPbr(
  node: Node,
  ctx: PbrContext
) =
  ## Draws a node tree with PBR shading. Outside an explicit pass this runs
  ## as its own implicit pass (blended primitives flush at the end of this
  ## draw, exactly as before); inside beginPass/endPass the blended flush
  ## and state restore defer to endPass.
  doAssert ctx != nil, "PBR context must not be nil."
  if not node.visible:
    return

  let implicitPass = ctx.passDepth == 0
  if implicitPass:
    ctx.beginPass()

  var completed = false
  try:
    node.updateTransforms(ctx.transform, ctx.useTrs)
    ctx.updatePunctualLights(node)

    renderPbrNode(
      node,
      ctx.transform,
      ctx.view,
      ctx.proj,
      ctx.tint,
      ctx.ambientLightColor,
      ctx.sunLightDirection,
      ctx.sunLightColor,
      ctx.rimLightDirection,
      ctx.rimLightColor,
      ctx.debugView,
      ctx.cameraPosition,
      useShadow=false,
      lightSpace=mat4(),
      shadowTex=0,
      deferBlend=true,
      blended=ctx.blended,
      ctx=ctx,
      root=node
    )
    completed = true
  finally:
    if implicitPass:
      if completed:
        ctx.endPass()
      else:
        ctx.abortPass()

proc shadowLookAt(eye, center, up: Vec3): Mat4 =
  ## Standard OpenGL lookAt (z-backward) for shadow mapping.
  let
    f = normalize(center - eye)
    s = normalize(cross(f, up))
    u = cross(s, f)
  result[0, 0] = s.x
  result[1, 0] = s.y
  result[2, 0] = s.z
  result[3, 0] = -dot(s, eye)
  result[0, 1] = u.x
  result[1, 1] = u.y
  result[2, 1] = u.z
  result[3, 1] = -dot(u, eye)
  result[0, 2] = -f.x
  result[1, 2] = -f.y
  result[2, 2] = -f.z
  result[3, 2] = dot(f, eye)
  result[3, 3] = 1.0'f32

proc getShadowMatrices(
  node: Node,
  transform: Mat4,
  lightDir: Vec3
): (Mat4, Mat4, Mat4, Vec3) =
  ## Compute light view/projection for the node tree.
  let
    bounds = getAABounds(node, transform)
    center = bounds.center
    radius = bounds.radius().float32
    dir = normalize(lightDir)
    lightPos = center - dir * (radius * 2.0'f)
    nearPlane = max(0.1'f, radius * 0.1'f)
    farPlane = radius * 4.0'f
    orthoSize = radius * 1.5'f
    lightView = shadowLookAt(lightPos, center, vec3(0, 1, 0))
    lightProj = ortho(
      -orthoSize,
      orthoSize,
      -orthoSize,
      orthoSize,
      nearPlane,
      farPlane
    )
  return (lightView, lightProj, lightProj * lightView, lightPos)

proc renderShadowPrimitive(
  primitive: Primitive,
  owner,
  root: Node,
  transform, view, proj: Mat4,
  tint: Color,
  ctx: PbrContext
) =
  if primitive == nil or not primitive.hasGeometry():
    return
  if primitive.material != nil and
    primitive.material.alphaMode == BlendAlphaMode:
    return

  primitive.uploadToGpu()
  let primitiveData = primitive.data
  let shadowUniforms = ctx.shadowUniforms
  glBindVertexArray(primitiveData.vertexArrayId)

  var
    modelArray = transform
    viewArray = view
    projArray = proj
  glUniformMatrix4fv(
    shadowUniforms.model,
    1,
    GL_FALSE,
    cast[ptr float32](modelArray.addr)
  )
  glUniformMatrix4fv(
    shadowUniforms.view,
    1,
    GL_FALSE,
    cast[ptr float32](viewArray.addr)
  )
  glUniformMatrix4fv(
    shadowUniforms.proj,
    1,
    GL_FALSE,
    cast[ptr float32](projArray.addr)
  )

  root.skinMatricesInto(owner, ctx.jointMatrices)
  let useSkinning = ctx.jointMatrices.len > 0
  if shadowUniforms.useSkinning >= 0:
    glUniform1i(shadowUniforms.useSkinning, useSkinning.ord.GLint)
  if useSkinning:
    if shadowUniforms.jointMatrices >= 0:
      glUniformMatrix4fv(
        shadowUniforms.jointMatrices,
        ctx.jointMatrices.len.GLsizei,
        GL_FALSE,
        cast[ptr float32](ctx.jointMatrices[0].addr)
      )

  if shadowUniforms.tint >= 0:
    glUniform4f(shadowUniforms.tint, tint.r, tint.g, tint.b, tint.a)

  let glMode = primitive.mode.glValue
  setFrontFace(transform, primitive.mode)
  when not defined(emscripten):
    if primitive.mode == PointsMode:
      glPointSize(1.0)
  if primitive.indices16.len == 0 and primitive.indices32.len == 0:
    glDrawArrays(glMode, 0, primitive.points.len.cint)
  else:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitiveData.indicesId)
    if primitive.indices16.len > 0:
      glDrawElements(
        glMode,
        primitive.indices16.len.GLint,
        GL_UNSIGNED_SHORT,
        nil
      )
    elif primitive.indices32.len > 0:
      glDrawElements(
        glMode,
        primitive.indices32.len.GLint,
        GL_UNSIGNED_INT,
        nil
      )
  glFrontFace(GL_CCW)

proc renderShadowNode(
  node,
  root: Node,
  transform, view, proj: Mat4,
  tint: Color,
  ctx: PbrContext,
  applyTrs = true
) =
  if node == nil or not node.visible:
    return
  node.mat =
    if applyTrs:
      transform * node.trs
    else:
      transform
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      renderShadowPrimitive(
        primitive,
        node,
        root,
        node.mat,
        view,
        proj,
        tint,
        ctx
      )
  for child in node.nodes:
    renderShadowNode(
      child,
      root,
      node.mat,
      view,
      proj,
      tint,
      ctx,
      applyTrs=true
    )

proc drawPbrWithShadow(
  node: Node,
  ctx: PbrContext
) =
  ## Draws a node tree with PBR shading and shadows.
  doAssert ctx != nil, "PBR context must not be nil."
  if not node.visible:
    return

  let implicitPass = ctx.passDepth == 0
  if implicitPass:
    ctx.beginPass()
  var completed = false
  try:

    node.updateTransforms(ctx.transform, ctx.useTrs)

    let (lightView, lightProj, lightSpace, _) =
      getShadowMatrices(node, ctx.transform, ctx.sunLightDirection)
    ctx.updatePunctualLights(node)

    # Save viewport and framebuffer.
    var
      oldViewport: array[4, GLint]
      oldFramebuffer: GLint
    glGetIntegerv(GL_VIEWPORT, oldViewport[0].addr)
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, oldFramebuffer.addr)

    # Depth pass.
    glViewport(
      0,
      0,
      ctx.shadowMapSize.GLsizei,
      ctx.shadowMapSize.GLsizei
    )
    glBindFramebuffer(GL_FRAMEBUFFER, ctx.shadowMapFbo)
    glClear(GL_DEPTH_BUFFER_BIT)
    glUseProgram(ctx.shadowDepthShader)
    glEnable(GL_CULL_FACE)
    glCullFace(GL_BACK)
    glEnable(GL_DEPTH_TEST)
    glDepthMask(GL_TRUE)

    renderShadowNode(
      node,
      node,
      ctx.transform,
      lightView,
      lightProj,
      ctx.tint,
      ctx,
      applyTrs=true
    )

    glBindFramebuffer(GL_FRAMEBUFFER, oldFramebuffer.GLuint)

    # Restore viewport.
    glViewport(oldViewport[0], oldViewport[1], oldViewport[2], oldViewport[3])

    # The depth pass bound its own program and toggled enables.
    ctx.invalidateGlState()

    # Main pass with shadow sampling.
    renderPbrNode(
      node,
      ctx.transform,
      ctx.view,
      ctx.proj,
      ctx.tint,
      ctx.ambientLightColor,
      ctx.sunLightDirection,
      ctx.sunLightColor,
      ctx.rimLightDirection,
      ctx.rimLightColor,
      ctx.debugView,
      ctx.cameraPosition,
      useShadow=true,
      lightSpace=lightSpace,
      shadowTex=ctx.shadowMapTex,
      deferBlend=true,
      blended=ctx.blended,
      ctx=ctx,
      root=node
    )

    completed = true
  finally:
    if implicitPass:
      if completed:
        ctx.endPass()
      else:
        ctx.abortPass()

proc draw*(ctx: PbrContext, node: Node) =
  ## Draws a node tree using PBR context state.
  doAssert ctx != nil, "PBR context must not be nil."
  if node == nil:
    return
  if ctx.drawSkybox:
    drawSkybox(
      ctx,
      ctx.view,
      ctx.proj,
      ctx.environmentMap,
      ctx.skyboxLod
    )
    ctx.invalidateGlState()
  if ctx.useShadows and ctx.debugView == dvLit:
    drawPbrWithShadow(node, ctx)
  else:
    drawPbr(node, ctx)

proc draw*(ctx: PbrContext, file: GltfFile) =
  ## Draws a glTF file using PBR context state.
  if file != nil:
    ctx.draw(file.root)

proc newRenderer*(window: Window): Renderer =
  ## Creates an OpenGL renderer wrapper.
  result = Renderer(window: window)

proc beginFrame*(renderer: Renderer; window: Window; size: IVec2) =
  discard renderer
  discard window
  glViewport(0, 0, size.x, size.y)
  glCullFace(GL_BACK)
  glFrontFace(GL_CCW)
  glEnable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)

proc clearScreen*(renderer: Renderer; color: ColorRGBX) =
  discard renderer
  let c = color.color
  glClearColor(c.r, c.g, c.b, c.a)
  glClear(GL_DEPTH_BUFFER_BIT or GL_COLOR_BUFFER_BIT)

proc clearScreen*(renderer: Renderer; color: Color) =
  discard renderer
  glClearColor(color.r, color.g, color.b, color.a)
  glClear(GL_DEPTH_BUFFER_BIT or GL_COLOR_BUFFER_BIT)

proc endFrame*(renderer: Renderer) =
  discard renderer

proc captureScreenshot*(renderer: Renderer): Image =
  discard renderer
  var viewport: array[4, GLint]
  glGetIntegerv(GL_VIEWPORT, viewport[0].addr)
  let
    width = max(1, viewport[2].int)
    height = max(1, viewport[3].int)
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

proc release*(renderer: Renderer; node: Node) =
  discard renderer
  node.clearFromGpu()

proc shutdown*(renderer: Renderer) =
  discard renderer
