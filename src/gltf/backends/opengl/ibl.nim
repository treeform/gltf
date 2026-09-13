## Prefiltered HDR lighting assets and a floating-point presentation pass.
import std/[json, os, math, strutils], opengl, vmath, chroma,
  ../../shaders, ../shaders as shaderSources

type
  IblEnvironment* = object
    diffuse*, specular*, lut*: GLuint
    mipCount*: int
    intensityScale*: float32
  HdrTarget* = object
    framebuffer, colorTexture, depthTexture, flagTexture: GLuint
    program, vao, vbo: GLuint
    width, height: int32
    previousFramebuffer: GLint
    active*: bool

proc maxIblAnisotropy*(): float32 =
  result = 1.0'f
  var count: GLint
  glGetIntegerv(GL_NUM_EXTENSIONS, count.addr)
  for index in 0 ..< count:
    let name = $cast[cstring](glGetStringi(GL_EXTENSIONS, index.GLuint))
    if name in ["GL_EXT_texture_filter_anisotropic", "GL_ARB_texture_filter_anisotropic"]:
      glGetFloatv(GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT, result.addr)
      return

proc destroy*(environment: var IblEnvironment) =
  for id in [environment.diffuse, environment.specular, environment.lut]:
    var texture = id
    if texture != 0: glDeleteTextures(1, texture.addr)
  environment = IblEnvironment()

proc loadIblEnvironment*(directory: string): IblEnvironment =
  ## Load the linear float textures exported by tools/reference. No GPU-side
  ## convolution or lossy PNG intermediate is involved. Caller owns the result.
  let manifest = parseFile(directory / "environment.json")
  if manifest["version"].getInt() != 1 or
      manifest["format"].getStr() != "rgba32f-le" or
      manifest["rowOrder"].getStr() != "bottom-up":
    raise newException(ValueError, "Unsupported IBL environment format")
  when cpuEndian != littleEndian:
    {.error: "IBL float asset loading currently requires little endian".}
  result.mipCount = manifest["mipCount"].getInt()
  result.intensityScale = manifest["intensityScale"].getFloat().float32
  if result.mipCount < 1 or result.mipCount > 13:
    raise newException(ValueError, "Invalid IBL mip count")
  glGenTextures(1, result.diffuse.addr)
  glGenTextures(1, result.specular.addr)
  glGenTextures(1, result.lut.addr)
  try:
    for (id, target, levels) in [(result.diffuse, GL_TEXTURE_CUBE_MAP, 1),
        (result.specular, GL_TEXTURE_CUBE_MAP, result.mipCount),
        (result.lut, GL_TEXTURE_2D, 1)]:
      glBindTexture(target, id)
      glTexParameteri(target, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
      glTexParameteri(target, GL_TEXTURE_MIN_FILTER,
        (if levels > 1: GL_LINEAR_MIPMAP_LINEAR else: GL_LINEAR).GLint)
      glTexParameteri(target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
      glTexParameteri(target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
      if target == GL_TEXTURE_CUBE_MAP:
        glTexParameteri(target, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE.GLint)
      glTexParameteri(target, GL_TEXTURE_MAX_LEVEL, (levels - 1).GLint)
    var seen: seq[string]
    for item in manifest["textures"]:
      let
        name = item["name"].getStr()
        level = item["level"].getInt()
        face = item["face"].getInt()
        width = item["width"].getInt()
        file = item["file"].getStr()
        key = name & ":" & $level & ":" & $face
        isCube = name != "ggx-lut"
        maxLevels = if name == "specular": result.mipCount else: 1
      if name notin ["diffuse", "specular", "ggx-lut"] or
          file != extractFilename(file) or ":" in file or file in [".", ".."] or
          width < 1 or width > 4096 or level < 0 or level >= maxLevels or
          face < 0 or face >= (if isCube: 6 else: 1) or key in seen:
        raise newException(ValueError, "Invalid IBL texture entry")
      seen.add(key)
      let bytes = readFile(directory / file)
      if bytes.len != width * width * 4 * sizeof(float32):
        raise newException(ValueError, "Incorrect IBL texture byte count: " & file)
      let target = if isCube: GL_TEXTURE_CUBE_MAP else: GL_TEXTURE_2D
      let id = if name == "diffuse": result.diffuse
        elif name == "specular": result.specular else: result.lut
      glBindTexture(target, id)
      glTexImage2D(if isCube: GLenum(GL_TEXTURE_CUBE_MAP_POSITIVE_X.int + face) else: target,
        level.GLint, GL_RGBA32F.GLint, width.GLsizei, width.GLsizei, 0,
        GL_RGBA, cGL_FLOAT, bytes[0].unsafeAddr)
    if seen.len != 6 + 6 * result.mipCount + 1:
      raise newException(ValueError, "Incomplete IBL environment")
    let error = glGetError()
    if error != GL_NO_ERROR:
      raise newException(ValueError, "IBL texture upload GL error " & $error.uint32)
  except:
    result.destroy()
    raise

proc destroyAttachments(target: var HdrTarget) =
  for id in [target.colorTexture, target.depthTexture, target.flagTexture]:
    var texture = id
    if texture != 0: glDeleteTextures(1, texture.addr)
  if target.framebuffer != 0: glDeleteFramebuffers(1, target.framebuffer.addr)
  target.framebuffer = 0
  target.colorTexture = 0
  target.depthTexture = 0
  target.flagTexture = 0

proc destroy*(target: var HdrTarget) =
  target.destroyAttachments()
  if target.program != 0: glDeleteProgram(target.program)
  if target.vao != 0: glDeleteVertexArrays(1, target.vao.addr)
  if target.vbo != 0: glDeleteBuffers(1, target.vbo.addr)
  target = HdrTarget()

proc beginHdr*(target: var HdrTarget, size: IVec2, background: Color) =
  ## The pinned Khronos main HDR target is single-sample RGBA16F + R8UI
  ## tone flags + depth24. Its internalMSAA setting affects transmission only.
  doAssert not target.active, "HDR frame already active"
  doAssert size.x > 0 and size.y > 0
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, target.previousFramebuffer.addr)
  if target.program == 0:
    target.program = compileShaderFiles(shaderSources.HdrPostVertSrc, shaderSources.HdrPostFragSrc)
    glGenVertexArrays(1, target.vao.addr)
    glBindVertexArray(target.vao)
    glGenBuffers(1, target.vbo.addr)
    glBindBuffer(GL_ARRAY_BUFFER, target.vbo)
    var vertices = [-1.0'f, -1.0'f, 3.0'f, -1.0'f, -1.0'f, 3.0'f]
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices[0].addr, GL_STATIC_DRAW)
    let location = glGetAttribLocation(target.program, "vertexPosition").GLuint
    glEnableVertexAttribArray(location)
    glVertexAttribPointer(location, 2, cGL_FLOAT, GL_FALSE, 0, nil)
  if target.framebuffer == 0 or target.width != size.x or target.height != size.y:
    target.destroyAttachments()
    target.width = size.x
    target.height = size.y
    glGenFramebuffers(1, target.framebuffer.addr)
    glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer)
    for (texture, attachment, internalFormat, format, pixelType) in [
        (target.colorTexture.addr, GL_COLOR_ATTACHMENT0, GL_RGBA16F, GL_RGBA, cGL_FLOAT),
        (target.depthTexture.addr, GL_DEPTH_ATTACHMENT, GL_DEPTH_COMPONENT24, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT),
        (target.flagTexture.addr, GL_COLOR_ATTACHMENT1, GL_R8UI, GL_RED_INTEGER, GL_UNSIGNED_BYTE)]:
      glGenTextures(1, texture)
      glBindTexture(GL_TEXTURE_2D, texture[])
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
      glTexImage2D(GL_TEXTURE_2D, 0, internalFormat.GLint, size.x, size.y,
        0, format, pixelType, nil)
      glFramebufferTexture2D(GL_FRAMEBUFFER, attachment, GL_TEXTURE_2D, texture[], 0)
    var attachments = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1]
    glDrawBuffers(2, attachments[0].addr)
    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
      raise newException(ValueError, "Incomplete HDR framebuffer")
  glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer)
  glViewport(0, 0, size.x, size.y)
  glDepthMask(GL_TRUE)
  glDisable(GL_FRAMEBUFFER_SRGB)
  var
    clear = [pow(background.r, 2.2'f), pow(background.g, 2.2'f), pow(background.b, 2.2'f), background.a]
    flags = [1'u32, 1'u32, 1'u32, 1'u32]
    depth = 1.0'f
  glClearBufferfv(GL_COLOR, 0, clear[0].addr)
  glClearBufferuiv(GL_COLOR, 1, flags[0].addr)
  glClearBufferfv(GL_DEPTH, 0, depth.addr)
  target.active = true

proc endHdr*(target: var HdrTarget, exposure: float32) =
  doAssert target.active, "HDR frame is not active"
  glBindFramebuffer(GL_FRAMEBUFFER, target.previousFramebuffer.GLuint)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glUseProgram(target.program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, target.colorTexture)
  glUniform1i(glGetUniformLocation(target.program, "hdrInput"), 0)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, target.flagTexture)
  glUniform1i(glGetUniformLocation(target.program, "toneFlags"), 1)
  glUniform1f(glGetUniformLocation(target.program, "exposure"), exposure)
  glBindVertexArray(target.vao)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glEnable(GL_DEPTH_TEST)
  glEnable(GL_CULL_FACE)
  glDepthMask(GL_TRUE)
  target.active = false
