## This file handles rendering for PBR.

import
  std/[strutils, algorithm],
  opengl, windy, pixie, vmath,
  common, models, shaders

const
  envMapSize* = 512 # Size of the environment map.

  PbrVertSrc = staticRead("../../data/shaders/pbr.vert")
  PbrFragSrc = staticRead("../../data/shaders/pbr.frag")
  SkyboxVertSrc = staticRead("../../data/shaders/skybox.vert")
  SkyboxFragSrc = staticRead("../../data/shaders/skybox.frag")
  ShadowDepthVertSrc = staticRead("../../experiments/shaders/shadow_depth.vert")
  ShadowDepthFragSrc = staticRead("../../experiments/shaders/shadow_depth.frag")

var
  envMapFBO*: GLuint # Framebuffer object for environment map.
  environmentMapId*: GLuint # Texture ID for environment map.
  rboDepth*: GLuint # Renderbuffer object for depth buffer.

  pbrShader*: GLuint # Shader program for PBR rendering.
  skyboxShader*: GLuint # Shader program for skybox rendering.
  skyboxVao*: GLuint # VAO for skybox rendering.
  skyboxVbo*: GLuint # VBO for skybox rendering.

  shadowMapFbo*: GLuint
  shadowMapTex*: GLuint
  shadowDepthShader*: GLuint

const
  ShadowMapSize = 2048

proc setupPbr*() =
  ## Sets up the PBR rendering system.
  ## * Create Environment Map and Framebuffer.

  glGenTextures(1, addr environmentMapId)
  glBindTexture(GL_TEXTURE_CUBE_MAP, environmentMapId)

  for i in 0 ..< 6:
    glTexImage2D(
      (GL_TEXTURE_CUBE_MAP_POSITIVE_X.int + i).GLenum,
      0,
      GL_RGB.GLint,
      envMapSize,
      envMapSize,
      0,
      GL_RGB,
      GL_UNSIGNED_BYTE,
      nil
    )

  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)

  # Set up the offscreen framebuffer.
  glGenFramebuffers(1, addr envMapFBO)
  glBindFramebuffer(GL_FRAMEBUFFER, envMapFBO)

  # Create a depth renderbuffer.
  glGenRenderbuffers(1, addr rboDepth)
  glBindRenderbuffer(GL_RENDERBUFFER, rboDepth)
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, envMapSize, envMapSize)
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, rboDepth)

  if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
    echo "Framebuffer not complete!"

  glBindFramebuffer(GL_FRAMEBUFFER, 0)

  pbrShader = compileShaderFiles(
    PbrVertSrc,
    PbrFragSrc
  )

  skyboxShader = compileShaderFiles(
    SkyboxVertSrc,
    SkyboxFragSrc
  )

  shadowDepthShader = compileShaderFiles(
    ShadowDepthVertSrc,
    ShadowDepthFragSrc
  )

  # Shadow map resources.
  glGenFramebuffers(1, addr shadowMapFbo)
  glGenTextures(1, addr shadowMapTex)
  glBindTexture(GL_TEXTURE_2D, shadowMapTex)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_DEPTH_COMPONENT.GLint,
    ShadowMapSize,
    ShadowMapSize,
    0,
    GL_DEPTH_COMPONENT,
    cGL_FLOAT,
    nil
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE.cint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL.cint)
  var borderColor = [1.0.GLfloat, 1.0, 1.0, 1.0]
  glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, borderColor[0].addr)

  glBindFramebuffer(GL_FRAMEBUFFER, shadowMapFbo)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER,
    GL_DEPTH_ATTACHMENT,
    GL_TEXTURE_2D,
    shadowMapTex,
    0
  )
  glDrawBuffer(GL_NONE)
  glReadBuffer(GL_NONE)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

  # Full-screen triangle data.
  var skyboxVertices = [
    -1.0f32, -1.0f32,
     3.0f32, -1.0f32,
    -1.0f32,  3.0f32
  ]

  glGenVertexArrays(1, addr skyboxVao)
  glGenBuffers(1, addr skyboxVbo)

  glBindVertexArray(skyboxVao)
  glBindBuffer(GL_ARRAY_BUFFER, skyboxVbo)
  glBufferData(GL_ARRAY_BUFFER, skyboxVertices.sizeof, addr skyboxVertices, GL_STATIC_DRAW)

  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 0, nil)

  glBindVertexArray(0)

proc loadCubeTexture(path: string): GLuint =
  ## Creates a cube texture and returns its OpenGL ID.

  var textureId: GLuint
  glGenTextures(1, addr(textureId))
  glBindTexture(GL_TEXTURE_CUBE_MAP, textureId)

  let directions = [
    "px", "nx", "py", "ny", "pz", "nz"
  ]
  for i, direction in directions:
    let image = readImage(path.replace("*", direction))
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

  return textureId

proc createSolidCubeTexture(color: ColorRGBX): GLuint =
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
  textureId

proc loadEnvironmentMap*(cubeMapPath: string) =
  ## Loads an environment map from a cube texture path.
  environmentMapId = loadCubeTexture(cubeMapPath)

proc loadDefaultEnvironmentMap*(color = rgbx(180, 190, 220, 255)) =
  ## Loads a fallback environment map when no skybox images are available.
  if environmentMapId != 0:
    glDeleteTextures(1, environmentMapId.addr)
  environmentMapId = createSolidCubeTexture(color)

proc drawSkybox*(view, proj: Mat4, lod: float32 = 0.0) =
  ## Draws the skybox using a full-screen quad.
  glUseProgram(skyboxShader)

  var
    invProj = proj.inverse
    invView = view.inverse

  glUniformMatrix4fv(
    glGetUniformLocation(skyboxShader, "invProj"),
    1,
    GL_FALSE,
    cast[ptr float32](invProj.addr)
  )
  glUniformMatrix4fv(
    glGetUniformLocation(skyboxShader, "invView"),
    1,
    GL_FALSE,
    cast[ptr float32](invView.addr)
  )

  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_CUBE_MAP, environmentMapId)
  glUniform1i(glGetUniformLocation(skyboxShader, "environmentMap"), 0)
  glUniform1f(glGetUniformLocation(skyboxShader, "lod"), lod)

  # Draw a single triangle that covers the whole screen.
  glDisable(GL_CULL_FACE)
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)

  glBindVertexArray(skyboxVao)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)

  glDepthMask(GL_TRUE)
  glEnable(GL_DEPTH_TEST)

type
  DebugView* = enum
    dvLit,
    dvUnlit,
    dvNormals,
    dvAoBake,
    dvMetallic,
    dvSpecular

  BlendEntry = object
    node: Node
    transform: Mat4

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
  drawChildren = true,
  applyTrs = true
) =
  ## Renders a node with the PBR shader.
  if not node.visible:
    return

  glUseProgram(pbrShader)

  let currentTransform =
    if applyTrs:
      transform *
      translate(node.pos) *
      node.rot.mat4() *
      scale(node.scale)
    else:
      transform
  node.mat = currentTransform

  let
    modelUniform = glGetUniformLocation(pbrShader, "model")
    viewUniform = glGetUniformLocation(pbrShader, "view")
    projUniform = glGetUniformLocation(pbrShader, "proj")
    lightSpaceUniform = glGetUniformLocation(pbrShader, "lightSpace")

  var
    modelArray = node.mat
    viewArray = view
    projArray = proj
    lightSpaceArray = lightSpace
  glUniformMatrix4fv(
    modelUniform,
    1,
    GL_FALSE,
    cast[ptr float32](modelArray.addr)
  )
  glUniformMatrix4fv(
    viewUniform,
    1,
    GL_FALSE,
    cast[ptr float32](viewArray.addr)
  )
  glUniformMatrix4fv(
    projUniform,
    1,
    GL_FALSE,
    cast[ptr float32](projArray.addr)
  )
  glUniformMatrix4fv(
    lightSpaceUniform,
    1,
    GL_FALSE,
    cast[ptr float32](lightSpaceArray.addr)
  )

  if not node.uploaded:
    node.uploadToGpu()

  glBindVertexArray(node.vertexArrayId)

  let isBlend = node.material != nil and node.material.alphaMode == BlendAlphaMode

  if deferBlend and isBlend:
    if drawChildren:
      for n in node.nodes:
        n.renderPbrNode(
          transform,
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
          drawChildren=true,
          applyTrs=true
        )
    blended.add(BlendEntry(node: node, transform: node.mat))
    return

  if node.material != nil and (not (deferBlend and isBlend)):
    let useNormalTexture =
      node.material.hasNormalTexture and
      node.normals.len > 0 and
      node.tangents.len > 0

    glActiveTexture(GL_TEXTURE0)
    glUniform1i(glGetUniformLocation(pbrShader, "baseColorTexture"), 0)
    glBindTexture(GL_TEXTURE_2D, node.material.baseColorId)

    glUniform4f(
      glGetUniformLocation(pbrShader, "baseColorFactor"),
      node.material.baseColorFactor.r,
      node.material.baseColorFactor.g,
      node.material.baseColorFactor.b,
      node.material.baseColorFactor.a
    )

    glActiveTexture(GL_TEXTURE1)
    glUniform1i(glGetUniformLocation(pbrShader, "metallicRoughnessTexture"), 1)
    glBindTexture(GL_TEXTURE_2D, node.material.metallicRoughnessId)

    glUniform1f(
      glGetUniformLocation(pbrShader, "metallicFactor"),
      node.material.metallicFactor
    )
    glUniform1f(
      glGetUniformLocation(pbrShader, "roughnessFactor"),
      node.material.roughnessFactor
    )

    glActiveTexture(GL_TEXTURE2)
    glUniform1i(glGetUniformLocation(pbrShader, "normalTexture"), 2)
    glBindTexture(GL_TEXTURE_2D, node.material.normalId)

    glUniform1f(
      glGetUniformLocation(pbrShader, "normalScale"),
      node.material.normalScale
    )
    glUniform1i(
      glGetUniformLocation(pbrShader, "useNormalTexture"),
      useNormalTexture.ord.GLint
    )

    glActiveTexture(GL_TEXTURE3)
    glUniform1i(glGetUniformLocation(pbrShader, "occlusionTexture"), 3)
    glBindTexture(GL_TEXTURE_2D, node.material.occlusionId)

    glUniform1f(
      glGetUniformLocation(pbrShader, "occlusionStrength"),
      node.material.occlusionStrength
    )

    glActiveTexture(GL_TEXTURE4)
    glUniform1i(glGetUniformLocation(pbrShader, "emissiveTexture"), 4)
    glBindTexture(GL_TEXTURE_2D, node.material.emissiveId)

    glUniform3f(
      glGetUniformLocation(pbrShader, "emissiveFactor"),
      node.material.emissiveFactor.r,
      node.material.emissiveFactor.g,
      node.material.emissiveFactor.b,
    )

    glActiveTexture(GL_TEXTURE5)
    glUniform1i(glGetUniformLocation(pbrShader, "environmentMap"), 5)
    glBindTexture(GL_TEXTURE_CUBE_MAP, environmentMapId)

    if useShadow:
      glActiveTexture(GL_TEXTURE6)
      glUniform1i(glGetUniformLocation(pbrShader, "shadowMap"), 6)
      glBindTexture(GL_TEXTURE_2D, shadowTex)

    # Set up alpha mode.
    var cutoff = node.material.alphaCutoff
    case node.material.alphaMode
    of MaskAlphaMode:
      glDisable(GL_BLEND)
      glDepthMask(GL_TRUE)
      cutoff = node.material.alphaCutoff
    of BlendAlphaMode:
      glEnable(GL_BLEND)
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
      glDepthMask(GL_FALSE)
      cutoff = -1.0
    else:
      glDisable(GL_BLEND)
      glDepthMask(GL_TRUE)
      cutoff = -1.0
    glUniform1f(
      glGetUniformLocation(pbrShader, "alphaCutoff"),
      cutoff
    )

    # Set up double sided rendering.
    if node.material.doubleSided:
      glDisable(GL_CULL_FACE)
    else:
      glEnable(GL_CULL_FACE)

    # Add lights.
    glUniform4f(
      glGetUniformLocation(pbrShader, "ambientLightColor"),
      ambientLightColor.r,
      ambientLightColor.g,
      ambientLightColor.b,
      ambientLightColor.a
    )
    glUniform3f(
      glGetUniformLocation(pbrShader, "sunLightDirection"),
      sunLightDirection.x,
      sunLightDirection.y,
      sunLightDirection.z
    )
    glUniform4f(
      glGetUniformLocation(pbrShader, "sunLightColor"),
      sunLightColor.r,
      sunLightColor.g,
      sunLightColor.b,
      sunLightColor.a
    )
    glUniform3f(
      glGetUniformLocation(pbrShader, "rimLightDirection"),
      rimLightDirection.x,
      rimLightDirection.y,
      rimLightDirection.z
    )
    glUniform4f(
      glGetUniformLocation(pbrShader, "rimLightColor"),
      rimLightColor.r,
      rimLightColor.g,
      rimLightColor.b,
      rimLightColor.a
    )
    glUniform1i(
      glGetUniformLocation(pbrShader, "debugViewMode"),
      debugView.int.GLint
    )

    # Add the camera position.
    glUniform3f(
      glGetUniformLocation(pbrShader, "cameraPosition"),
      cameraPosition.x, cameraPosition.y, cameraPosition.z
    )

  else:
    glBindTexture(GL_TEXTURE_2D, 0)

  let colorTintUniform = glGetUniformLocation(pbrShader, "tint")
  glUniform4f(colorTintUniform, tint.r, tint.g, tint.b, tint.a)
  glUniform1i(glGetUniformLocation(pbrShader, "useShadow"), useShadow.Glint)

  if node.indices16.len == 0 and node.indices32.len == 0:
    glDrawArrays(GL_TRIANGLES, 0, node.points.len.cint)
  else:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, node.indicesId)
    if node.indices16.len > 0:
      glDrawElements(
        GL_TRIANGLES,
        node.indices16.len.GLint,
        GL_UNSIGNED_SHORT,
        nil
      )
    elif node.indices32.len > 0:
      glDrawElements(
        GL_TRIANGLES,
        node.indices32.len.GLint,
        GL_UNSIGNED_INT,
        nil
      )
    else:
      raise newException(GltfError, "Invalid indices")

  # Remove material settings.
  if node.material != nil and (not (deferBlend and isBlend)):
    glDisable(GL_BLEND)
    glDepthMask(GL_TRUE)
    glEnable(GL_CULL_FACE)

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
        drawChildren=true,
        applyTrs=true
      )

  if deferBlend and isBlend and drawChildren:
    blended.add(BlendEntry(node: node, transform: node.mat))

proc drawPbr*(
  node: Node,
  transform, view, proj: Mat4,
  tint: Color,
  useTrs = true,
  ambientLightColor = color(0.1, 0.1, 0.1, 1),
  sunLightDirection = vec3(1, 4, 2),
  sunLightColor = color(1, 1, 1, 1),
  rimLightDirection = vec3(-1, 1, -1),
  rimLightColor = color(0, 0, 0, 0),
  debugView = dvLit,
  cameraPosition = vec3(0, 0, 10)
) =
  ## Draws a node tree with PBR shading.
  if not node.visible:
    return

  var blended: seq[BlendEntry]

  renderPbrNode(
    node,
    transform,
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
    useShadow=false,
    lightSpace=mat4(),
    shadowTex=0,
    deferBlend=true,
    blended=blended
  )

  if blended.len > 0:
    glDepthMask(GL_FALSE)
    var sorted = blended
    sorted.sort(proc(a, b: BlendEntry): int =
      let
        pa = (a.transform * vec4(0, 0, 0, 1)).xyz
        pb = (b.transform * vec4(0, 0, 0, 1)).xyz
        da = (cameraPosition - pa).lengthSq
        db = (cameraPosition - pb).lengthSq
      if da > db: -1 elif da < db: 1 else: 0
    )
    for entry in sorted:
      var dummy: seq[BlendEntry]
      entry.node.renderPbrNode(
        entry.transform,
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
        useShadow=false,
        lightSpace=mat4(),
        shadowTex=0,
        deferBlend=false,
        blended=dummy,
        drawChildren=false,
        applyTrs=false
      )
    glDepthMask(GL_TRUE)

proc getShadowMatrices(node: Node, transform: Mat4, lightDir: Vec3): (Mat4, Mat4, Mat4, Vec3) =
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
    lightView = lookAt(lightPos, center, vec3(0, 1, 0))
    lightProj = ortho(
    -orthoSize,
    orthoSize,
    -orthoSize,
    orthoSize,
    nearPlane,
    farPlane
    )
  return (lightView, lightProj, lightProj * lightView, lightPos)

proc drawPbrWithShadow*(
  node: Node,
  transform, view, proj: Mat4,
  tint: Color,
  sunLightDirection = vec3(1, 4, 2),
  useTrs = true,
  ambientLightColor = color(0.1, 0.1, 0.1, 1),
  sunLightColor = color(1, 1, 1, 1),
  rimLightDirection = vec3(-1, 1, -1),
  rimLightColor = color(0, 0, 0, 0),
  debugView = dvLit,
  cameraPosition = vec3(0, 0, 10)
) =
  ## Draws a node tree with PBR shading and shadows.
  if not node.visible:
    return

  let (lightView, lightProj, lightSpace, _) =
    getShadowMatrices(node, transform, sunLightDirection)

  # Save viewport and framebuffer.
  var
    oldViewport: array[4, GLint]
    oldFramebuffer: GLint
  glGetIntegerv(GL_VIEWPORT, oldViewport[0].addr)
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, oldFramebuffer.addr)

  # Depth pass.
  glViewport(0, 0, ShadowMapSize, ShadowMapSize)
  glBindFramebuffer(GL_FRAMEBUFFER, shadowMapFbo)
  glClear(GL_DEPTH_BUFFER_BIT)
  glUseProgram(shadowDepthShader)
  glEnable(GL_CULL_FACE)
  glCullFace(GL_BACK)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)

  node.draw(
    shadowDepthShader,
    transform,
    lightView,
    lightProj,
    tint,
    useTrs=true,
    skipBlend=true
  )

  glBindFramebuffer(GL_FRAMEBUFFER, oldFramebuffer.GLuint)

  # Restore viewport.
  glViewport(oldViewport[0], oldViewport[1], oldViewport[2], oldViewport[3])

  # Main pass with shadow sampling.
  var blended: seq[BlendEntry]

  renderPbrNode(
    node,
    transform,
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
    useShadow=true,
    lightSpace=lightSpace,
    shadowTex=shadowMapTex,
    deferBlend=true,
    blended=blended
  )

  if blended.len > 0:
    glDepthMask(GL_FALSE)
    var sorted = blended
    sorted.sort(proc(a, b: BlendEntry): int =
      let pa = (a.transform * vec4(0, 0, 0, 1)).xyz
      let pb = (b.transform * vec4(0, 0, 0, 1)).xyz
      let da = (cameraPosition - pa).lengthSq
      let db = (cameraPosition - pb).lengthSq
      if da > db: -1 elif da < db: 1 else: 0
    )
    for entry in sorted:
      var dummy: seq[BlendEntry]
      entry.node.renderPbrNode(
        entry.transform,
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
        useShadow=false,
        lightSpace=mat4(),
        shadowTex=0,
        deferBlend=false,
        blended=dummy,
        drawChildren=false,
        applyTrs=false
      )
    glDepthMask(GL_TRUE)
