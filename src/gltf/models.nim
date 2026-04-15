import
  std/[strformat, math],
  vmath, chroma, pixie, opengl,
  common

proc trs*(node: Node): Mat4

proc shallowCopy*(node: Node): Node =
  ## Creates a shallow copy of a node.
  result = Node()
  result.name = node.name
  result.visible = node.visible
  result.pos = node.pos
  result.rot = node.rot
  result.scale = node.scale
  result.mat = node.mat

  result.baseVisible = node.baseVisible
  result.basePos = node.basePos
  result.baseRot = node.baseRot
  result.baseScale = node.baseScale

  result.animations = node.animations
  result.activeClips = node.activeClips
  result.animTime = node.animTime

  result.mesh = node.mesh
  result.skin = node.skin
  result.camera = node.camera
  result.nodes = node.nodes

proc defaultTextureSampler*(): TextureSampler =
  TextureSampler(
    magFilter: GL_LINEAR,
    minFilter: GL_LINEAR_MIPMAP_LINEAR,
    wrapS: GL_REPEAT,
    wrapT: GL_REPEAT
  )

proc wrapModeName(mode: GLint): string =
  case mode
  of GL_REPEAT:
    "repeat"
  of GL_CLAMP_TO_EDGE:
    "clamp_to_edge"
  of GL_MIRRORED_REPEAT:
    "mirrored_repeat"
  else:
    $mode

proc filterName(mode: GLint): string =
  case mode
  of GL_NEAREST:
    "nearest"
  of GL_LINEAR:
    "linear"
  of GL_NEAREST_MIPMAP_NEAREST:
    "nearest_mipmap_nearest"
  of GL_LINEAR_MIPMAP_NEAREST:
    "linear_mipmap_nearest"
  of GL_NEAREST_MIPMAP_LINEAR:
    "nearest_mipmap_linear"
  of GL_LINEAR_MIPMAP_LINEAR:
    "linear_mipmap_linear"
  else:
    $mode

proc `$`*(sampler: TextureSampler): string =
  &"(magFilter: {filterName(sampler.magFilter)}, " &
  &"minFilter: {filterName(sampler.minFilter)}, " &
  &"wrapS: {wrapModeName(sampler.wrapS)}, " &
  &"wrapT: {wrapModeName(sampler.wrapT)})"

proc primitiveModeName*(mode: GLenum): string =
  ## Returns a readable primitive mode label.
  case mode
  of GL_POINTS:
    "POINTS"
  of GL_LINES:
    "LINES"
  of GL_LINE_LOOP:
    "LINE_LOOP"
  of GL_LINE_STRIP:
    "LINE_STRIP"
  of GL_TRIANGLES:
    "TRIANGLES"
  of GL_TRIANGLE_STRIP:
    "TRIANGLE_STRIP"
  of GL_TRIANGLE_FAN:
    "TRIANGLE_FAN"
  else:
    $mode.int

proc updateTransforms*(
  node: Node,
  transform = mat4(),
  applyTrs = true
) =
  ## Updates world transforms for a node tree.
  if node == nil:
    return
  node.mat =
    if applyTrs:
      transform * node.trs
    else:
      transform
  for child in node.nodes:
    child.updateTransforms(node.mat)

proc hasGeometry*(primitive: Primitive): bool =
  primitive != nil and primitive.points.len > 0

proc hasGeometry*(mesh: Mesh): bool =
  if mesh == nil:
    return false
  for primitive in mesh.primitives:
    if primitive.hasGeometry():
      return true
  false

proc hasGeometry*(node: Node): bool =
  if node == nil:
    return false
  if node.mesh.hasGeometry():
    return true
  for child in node.nodes:
    if child.hasGeometry():
      return true
  false

proc computeSmoothNormals*(prim: Primitive) =
  ## Generates smooth normals by accumulating face normals per vertex.
  if prim.normals.len > 0 or prim.points.len == 0:
    return
  prim.normals = newSeq[Vec3](prim.points.len)
  template accumulateTri(ia, ib, ic: int) =
    let
      a = prim.points[ia]
      b = prim.points[ib]
      c = prim.points[ic]
      n = cross(b - a, c - a)
    prim.normals[ia] += n
    prim.normals[ib] += n
    prim.normals[ic] += n
  if prim.indices32.len > 0:
    for i in countup(0, prim.indices32.len - 3, 3):
      accumulateTri(
        prim.indices32[i + 0].int,
        prim.indices32[i + 1].int,
        prim.indices32[i + 2].int
      )
  elif prim.indices16.len > 0:
    for i in countup(0, prim.indices16.len - 3, 3):
      accumulateTri(
        prim.indices16[i + 0].int,
        prim.indices16[i + 1].int,
        prim.indices16[i + 2].int
      )
  else:
    for i in countup(0, prim.points.len - 3, 3):
      accumulateTri(i, i + 1, i + 2)
  for i in 0 ..< prim.normals.len:
    let len = length(prim.normals[i])
    prim.normals[i] =
      if len <= 0.000001'f:
        vec3(0, 1, 0)
      else:
        prim.normals[i] / len

proc ensureNormals*(node: Node) =
  ## Generates smooth normals for any primitive in the tree that lacks them.
  if node == nil:
    return
  if node.mesh != nil:
    for prim in node.mesh.primitives:
      prim.computeSmoothNormals()
  for child in node.nodes:
    child.ensureNormals()

proc uploadTextureToGpu(
  textureId: var GLuint,
  image: Image,
  sampler = defaultTextureSampler()
) =
  ## Uploads a texture to the GPU.
  glGenTextures(1, textureId.addr)
  glBindTexture(GL_TEXTURE_2D, textureId)
  if image.isOpaque():
    var data = newSeq[uint8](image.width * image.height * 3)
    for i, rgbx in image.data:
      data[i * 3 + 0] = rgbx.r
      data[i * 3 + 1] = rgbx.g
      data[i * 3 + 2] = rgbx.b
    glTexImage2D(
      GL_TEXTURE_2D,
      0,
      GL_RGB.GLint,
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
      GL_RGBA.GLint,
      image.width.GLint,
      image.height.GLint,
      0,
      GL_RGBA,
      GL_UNSIGNED_BYTE,
      image.data[0].addr
    )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, sampler.magFilter)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, sampler.minFilter)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, sampler.wrapS)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, sampler.wrapT)
  glGenerateMipmap(GL_TEXTURE_2D)

proc uploadMaterialToGpu(material: Material) =
  if material == nil:
    return
  if material.baseColor != nil and material.baseColorId == 0:
    uploadTextureToGpu(
      material.baseColorId,
      material.baseColor,
      material.baseColorSampler
    )
  if material.metallicRoughness != nil and material.metallicRoughnessId == 0:
    uploadTextureToGpu(
      material.metallicRoughnessId,
      material.metallicRoughness,
      material.metallicRoughnessSampler
    )
  if material.normal != nil and material.normalId == 0:
    uploadTextureToGpu(
      material.normalId,
      material.normal,
      material.normalSampler
    )
  if material.occlusion != nil and material.occlusionId == 0:
    uploadTextureToGpu(
      material.occlusionId,
      material.occlusion,
      material.occlusionSampler
    )
  if material.emissive != nil and material.emissiveId == 0:
    uploadTextureToGpu(
      material.emissiveId,
      material.emissive,
      material.emissiveSampler
    )

proc clearMaterialFromGpu(material: Material) =
  if material == nil:
    return
  if material.baseColorId != 0.GLuint:
    glDeleteTextures(1, material.baseColorId.addr)
    material.baseColorId = 0
  if material.metallicRoughnessId != 0.GLuint:
    glDeleteTextures(1, material.metallicRoughnessId.addr)
    material.metallicRoughnessId = 0
  if material.normalId != 0.GLuint:
    glDeleteTextures(1, material.normalId.addr)
    material.normalId = 0
  if material.occlusionId != 0.GLuint:
    glDeleteTextures(1, material.occlusionId.addr)
    material.occlusionId = 0
  if material.emissiveId != 0.GLuint:
    glDeleteTextures(1, material.emissiveId.addr)
    material.emissiveId = 0

proc uploadToGpu*(primitive: Primitive) =
  ## Upload the primitive data to the GPU.
  if primitive == nil or primitive.uploaded:
    return

  glGenVertexArrays(1, primitive.vertexArrayId.addr)
  glBindVertexArray(primitive.vertexArrayId)

  if primitive.indices32.len > 0:
    glGenBuffers(1, primitive.indicesId.addr)
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.indicesId)
    glBufferData(
      GL_ELEMENT_ARRAY_BUFFER,
      primitive.indices32.len * sizeof(uint32),
      primitive.indices32[0].addr,
      GL_STATIC_DRAW
    )
  elif primitive.indices16.len > 0:
    glGenBuffers(1, primitive.indicesId.addr)
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.indicesId)
    glBufferData(
      GL_ELEMENT_ARRAY_BUFFER,
      primitive.indices16.len * sizeof(uint16),
      primitive.indices16[0].addr,
      GL_STATIC_DRAW
    )

  if primitive.points.len > 0:
    glGenBuffers(1, primitive.pointsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, primitive.pointsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.points.len * sizeof(Vec3),
      primitive.points[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, 0, nil)

  if primitive.uvs.len > 0:
    glGenBuffers(1, primitive.uvsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, primitive.uvsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.uvs.len * sizeof(Vec2),
      primitive.uvs[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(3)
    glVertexAttribPointer(3, 2, cGL_FLOAT, GL_FALSE, 0, nil)

  if primitive.uvs1.len > 0:
    glGenBuffers(1, primitive.uvs1Id.addr)
    glBindBuffer(GL_ARRAY_BUFFER, primitive.uvs1Id)
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
    glGenBuffers(1, primitive.normalsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, primitive.normalsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.normals.len * sizeof(Vec3),
      primitive.normals[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(2)
    glVertexAttribPointer(2, 3, cGL_FLOAT, GL_FALSE, 0, nil)

  if primitive.tangents.len > 0:
    glGenBuffers(1, primitive.tangentsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, primitive.tangentsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      primitive.tangents.len * sizeof(Vec4),
      primitive.tangents[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(4)
    glVertexAttribPointer(4, 4, cGL_FLOAT, GL_FALSE, 0, nil)

  if primitive.colors.len > 0:
    glGenBuffers(1, primitive.colorsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, primitive.colorsId)
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
    glGenBuffers(1, primitive.jointIdsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, primitive.jointIdsId)
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
    glGenBuffers(1, primitive.jointWeightsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, primitive.jointWeightsId)
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
  primitive.uploaded = true

proc clearFromGpu*(primitive: Primitive) =
  ## Clear primitive data from the GPU.
  if primitive == nil:
    return
  if primitive.uploaded:
    glDeleteVertexArrays(1, primitive.vertexArrayId.addr)
    if primitive.indices16.len > 0 or primitive.indices32.len > 0:
      glDeleteBuffers(1, primitive.indicesId.addr)
    if primitive.points.len > 0:
      glDeleteBuffers(1, primitive.pointsId.addr)
    if primitive.uvs.len > 0:
      glDeleteBuffers(1, primitive.uvsId.addr)
    if primitive.uvs1.len > 0:
      glDeleteBuffers(1, primitive.uvs1Id.addr)
    if primitive.normals.len > 0:
      glDeleteBuffers(1, primitive.normalsId.addr)
    if primitive.tangents.len > 0:
      glDeleteBuffers(1, primitive.tangentsId.addr)
    if primitive.colors.len > 0:
      glDeleteBuffers(1, primitive.colorsId.addr)
    if primitive.jointIds.len > 0:
      glDeleteBuffers(1, primitive.jointIdsId.addr)
    if primitive.jointWeights.len > 0:
      glDeleteBuffers(1, primitive.jointWeightsId.addr)
    primitive.vertexArrayId = 0
    primitive.pointsId = 0
    primitive.uvsId = 0
    primitive.uvs1Id = 0
    primitive.normalsId = 0
    primitive.tangentsId = 0
    primitive.colorsId = 0
    primitive.jointIdsId = 0
    primitive.jointWeightsId = 0
    primitive.indicesId = 0
  clearMaterialFromGpu(primitive.material)
  primitive.uploaded = false

proc updateOnGpu*(primitive: Primitive) =
  ## Update primitive data on the GPU.
  if primitive == nil:
    return
  if not primitive.uploaded:
    primitive.uploadToGpu()
  else:
    glBindVertexArray(primitive.vertexArrayId)

    if primitive.points.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, primitive.pointsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        primitive.points.len * sizeof(Vec3),
        primitive.points[0].addr,
        GL_STATIC_DRAW
      )

    if primitive.uvs.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, primitive.uvsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        primitive.uvs.len * sizeof(Vec2),
        primitive.uvs[0].addr,
        GL_STATIC_DRAW
      )

    if primitive.uvs1.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, primitive.uvs1Id)
      glBufferData(
        GL_ARRAY_BUFFER,
        primitive.uvs1.len * sizeof(Vec2),
        primitive.uvs1[0].addr,
        GL_STATIC_DRAW
      )

    if primitive.normals.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, primitive.normalsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        primitive.normals.len * sizeof(Vec3),
        primitive.normals[0].addr,
        GL_STATIC_DRAW
      )

    if primitive.tangents.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, primitive.tangentsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        primitive.tangents.len * sizeof(Vec4),
        primitive.tangents[0].addr,
        GL_STATIC_DRAW
      )

    if primitive.colors.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, primitive.colorsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        primitive.colors.len * sizeof(ColorRGBX),
        primitive.colors[0].addr,
        GL_STATIC_DRAW
      )

    if primitive.jointIds.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, primitive.jointIdsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        primitive.jointIds.len * sizeof(JointIds),
        primitive.jointIds[0].addr,
        GL_STATIC_DRAW
      )

    if primitive.jointWeights.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, primitive.jointWeightsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        primitive.jointWeights.len * sizeof(Vec4),
        primitive.jointWeights[0].addr,
        GL_STATIC_DRAW
      )

    if primitive.indices32.len > 0:
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.indicesId)
      glBufferData(
        GL_ELEMENT_ARRAY_BUFFER,
        primitive.indices32.len * sizeof(uint32),
        primitive.indices32[0].addr,
        GL_STATIC_DRAW
      )
    elif primitive.indices16.len > 0:
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.indicesId)
      glBufferData(
        GL_ELEMENT_ARRAY_BUFFER,
        primitive.indices16.len * sizeof(uint16),
        primitive.indices16[0].addr,
        GL_STATIC_DRAW
      )

proc uploadToGpu*(mesh: Mesh) =
  if mesh == nil:
    return
  for primitive in mesh.primitives:
    primitive.uploadToGpu()

proc clearFromGpu*(mesh: Mesh) =
  if mesh == nil:
    return
  for primitive in mesh.primitives:
    primitive.clearFromGpu()

proc updateOnGpu*(mesh: Mesh) =
  if mesh == nil:
    return
  for primitive in mesh.primitives:
    primitive.updateOnGpu()

proc uploadToGpu*(node: Node) =
  ## Upload the node subtree to the GPU.
  if node == nil:
    return
  node.mesh.uploadToGpu()
  for child in node.nodes:
    child.uploadToGpu()

proc clearFromGpu*(node: Node) =
  ## Clear the node subtree from the GPU.
  if node == nil:
    return
  node.mesh.clearFromGpu()
  for child in node.nodes:
    child.clearFromGpu()

proc updateOnGpu*(node: Node) =
  ## Update the node subtree on the GPU.
  if node == nil:
    return
  node.mesh.updateOnGpu()
  for child in node.nodes:
    child.updateOnGpu()

proc clearTreeFromGpu*(node: Node) =
  ## Clear the vertex data from the GPU for the whole tree.
  node.clearFromGpu()

proc trs*(node: Node): Mat4 =
  ## Get the transformation matrix of a node.
  translate(node.pos) *
    node.rot.mat4() *
    scale(node.scale)

proc findTransform*(
  node, target: Node,
  transform = mat4(),
  world: var Mat4
): bool =
  ## Finds the world transform for a node in a tree.
  if node == nil or target == nil:
    return false
  let current = transform * node.trs
  if node == target:
    world = current
    return true
  for child in node.nodes:
    if findTransform(child, target, current, world):
      return true
  false

proc skinMatrices*(root, node: Node): seq[Mat4] =
  ## Computes joint matrices for a skinned node.
  if root == nil or node == nil or node.skin == nil:
    return
  let inverseNode = node.mat.inverse
  result.setLen(node.skin.joints.len)
  for i, joint in node.skin.joints:
    let inverseBind =
      if i < node.skin.inverseBindMatrices.len:
        node.skin.inverseBindMatrices[i]
      else:
        mat4()
    result[i] = inverseNode * joint.mat * inverseBind

proc toMat4(m: DMat4): Mat4 =
  ## Converts a double-precision matrix to float32.
  gmat4(
    m[0, 0].float32, m[0, 1].float32, m[0, 2].float32, m[0, 3].float32,
    m[1, 0].float32, m[1, 1].float32, m[1, 2].float32, m[1, 3].float32,
    m[2, 0].float32, m[2, 1].float32, m[2, 2].float32, m[2, 3].float32,
    m[3, 0].float32, m[3, 1].float32, m[3, 2].float32, m[3, 3].float32
  )

proc drawPrimitive(
  primitive: Primitive,
  shader: GLuint,
  tint: Color,
  skipBlend = false
) =
  if primitive == nil or not primitive.hasGeometry():
    return

  if skipBlend and
     primitive.material != nil and
     primitive.material.alphaMode == BlendAlphaMode:
    return

  if not primitive.uploaded:
    primitive.uploadToGpu()

  glBindVertexArray(primitive.vertexArrayId)

  if primitive.material != nil and
     not (skipBlend and primitive.material.alphaMode == BlendAlphaMode):
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, primitive.material.baseColorId)

    let sampleTexUniform = glGetUniformLocation(shader, "sampleTex")
    if sampleTexUniform >= 0:
      glUniform1i(sampleTexUniform, 0)

    let baseColorFactorUniform = glGetUniformLocation(shader, "baseColorFactor")
    if baseColorFactorUniform >= 0:
      glUniform4f(
        baseColorFactorUniform,
        primitive.material.baseColorFactor.r,
        primitive.material.baseColorFactor.g,
        primitive.material.baseColorFactor.b,
        primitive.material.baseColorFactor.a
      )

    let alphaCutoffUniform = glGetUniformLocation(shader, "alphaCutoff")
    if alphaCutoffUniform >= 0:
      var cutoff = -1.0
      if primitive.material.alphaMode == MaskAlphaMode:
        cutoff = primitive.material.alphaCutoff
      glUniform1f(alphaCutoffUniform, cutoff)
  else:
    glBindTexture(GL_TEXTURE_2D, 0)
    let sampleTexUniform = glGetUniformLocation(shader, "sampleTex")
    if sampleTexUniform >= 0:
      glUniform1i(sampleTexUniform, 0)

  if primitive.material != nil and primitive.material.doubleSided:
    glDisable(GL_CULL_FACE)
  else:
    glEnable(GL_CULL_FACE)

  let colorTintUniform = glGetUniformLocation(shader, "tint")
  glUniform4f(colorTintUniform, tint.r, tint.g, tint.b, tint.a)

  if primitive.mode == GL_POINTS:
    glPointSize(1.0)

  if primitive.indices32.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.indicesId)
    glDrawElements(
      primitive.mode,
      primitive.indices32.len.GLint,
      GL_UNSIGNED_INT,
      nil
    )
  elif primitive.indices16.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.indicesId)
    glDrawElements(
      primitive.mode,
      primitive.indices16.len.GLint,
      GL_UNSIGNED_SHORT,
      nil
    )
  else:
    glDrawArrays(primitive.mode, 0, primitive.points.len.cint)

proc draw*(
  node: Node,
  shader: GLuint,
  transform, view, proj: Mat4,
  tint: Color,
  useTrs = true,
  skipBlend = false,
  root: Node = nil
) =
  ## Draws the node with a float32 transform.
  if not node.visible:
    return

  let rootNode =
    if root == nil:
      node
    else:
      root
  if root == nil:
    rootNode.updateTransforms(transform, useTrs)

  node.mat =
    if useTrs:
      transform * node.trs
    else:
      transform
  let
    modelUniform = glGetUniformLocation(shader, "model")
    viewUniform = glGetUniformLocation(shader, "view")
    projUniform = glGetUniformLocation(shader, "proj")

  var
    modelArray = node.mat
    viewArray = view
    projArray = proj
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

  let jointMatrices = rootNode.skinMatrices(node)
  let useSkinning =
    jointMatrices.len > 0 and
    node.mesh != nil
  let useSkinningUniform = glGetUniformLocation(shader, "useSkinning")
  if useSkinningUniform >= 0:
    glUniform1i(useSkinningUniform, useSkinning.ord.GLint)
  if useSkinning:
    let jointMatricesUniform = glGetUniformLocation(shader, "jointMatrices")
    if jointMatricesUniform >= 0:
      glUniformMatrix4fv(
        jointMatricesUniform,
        jointMatrices.len.GLsizei,
        GL_FALSE,
        cast[ptr float32](jointMatrices[0].addr)
      )

  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      primitive.drawPrimitive(shader, tint, skipBlend)

  for n in node.nodes:
    n.draw(
      shader,
      node.mat,
      view,
      proj,
      tint,
      useTrs=true,
      skipBlend=skipBlend,
      root=rootNode
    )

proc dumpTree*(node: Node, indent: string = "") =
  ## Prints the node tree for debugging.
  echo &"{indent}{node.name}"

  # Print the transform values.
  echo &"{indent}  pos: {node.pos}"
  let euler =
    node.rot
      .mat4()
      .toAngles()
      .toDegrees()
  echo &"{indent}  rot: {node.rot} ({euler})"
  echo &"{indent}  scale: {node.scale}"
  if node.camera != nil:
    echo &"{indent}  camera: {node.camera.name}"

  if node.mesh != nil:
    echo &"{indent}  mesh: {node.mesh.name}"
    echo &"{indent}  primitives: {node.mesh.primitives.len}"
    for i, primitive in node.mesh.primitives:
      let prefix = indent & &"    primitive[{i}]"
      if primitive.material != nil:
        echo &"{prefix} material: {primitive.material.name}"
        if primitive.material.baseColor != nil:
          echo &"{prefix} baseColor: {primitive.material.baseColor}"
          echo &"{prefix} baseColorFactor: {primitive.material.baseColorFactor}"
          echo &"{prefix} baseColorSampler: {primitive.material.baseColorSampler}"
        if primitive.material.metallicRoughness != nil:
          echo &"{prefix} metallicRoughness: {primitive.material.metallicRoughness}"
          echo &"{prefix} metallicRoughnessSampler: {primitive.material.metallicRoughnessSampler}"
        echo &"{prefix} metallicFactor: {primitive.material.metallicFactor}"
        echo &"{prefix} roughnessFactor: {primitive.material.roughnessFactor}"
        if primitive.material.normal != nil:
          echo &"{prefix} normal: {primitive.material.normal}"
          echo &"{prefix} normalSampler: {primitive.material.normalSampler}"
          echo &"{prefix} normalScale: {primitive.material.normalScale}"
        if primitive.material.occlusion != nil:
          echo &"{prefix} occlusion: {primitive.material.occlusion}"
          echo &"{prefix} occlusionSampler: {primitive.material.occlusionSampler}"
          echo &"{prefix} occlusionStrength: {primitive.material.occlusionStrength}"
        if primitive.material.emissive != nil:
          echo &"{prefix} emissive: {primitive.material.emissive}"
          echo &"{prefix} emissiveSampler: {primitive.material.emissiveSampler}"
          echo &"{prefix} emissiveFactor: {primitive.material.emissiveFactor}"
        if primitive.material.alphaMode == MaskAlphaMode:
          echo &"{prefix} alphaMode: Mask"
          echo &"{prefix} alphaCutoff: {primitive.material.alphaCutoff}"
        elif primitive.material.alphaMode == BlendAlphaMode:
          echo &"{prefix} alphaMode: Blend"
        else:
          echo &"{prefix} alphaMode: Opaque"
        echo &"{prefix} transmissionFactor: {primitive.material.transmissionFactor}"
        echo &"{prefix} doubleSided: {primitive.material.doubleSided}"

      if primitive.points.len > 0:
        echo &"{prefix} points: {primitive.points.len}"
      if primitive.uvs.len > 0:
        echo &"{prefix} uvs: {primitive.uvs.len}"
      if primitive.uvs1.len > 0:
        echo &"{prefix} uvs1: {primitive.uvs1.len}"
      if primitive.normals.len > 0:
        echo &"{prefix} normals: {primitive.normals.len}"
      if primitive.tangents.len > 0:
        echo &"{prefix} tangents: {primitive.tangents.len}"
      if primitive.colors.len > 0:
        echo &"{prefix} colors: {primitive.colors.len}"
      if primitive.indices16.len > 0:
        echo &"{prefix} indices (16bit): {primitive.indices16.len}"
      if primitive.indices32.len > 0:
        echo &"{prefix} indices (32bit): {primitive.indices32.len}"
      echo &"{prefix} mode: {primitiveModeName(primitive.mode)}"

  for n in node.nodes:
    n.dumpTree(indent & "  ")

proc walkNodes*(node: Node): seq[Node] =
  ## Walk the nodes tree and return a flat list of nodes.
  proc innerWalk(node: Node, arr: var seq[Node]) =
    arr.add(node)
    for n in node.nodes:
      innerWalk(n, arr)
  innerWalk(node, result)

proc center*(a: AABounds): Vec3 =
  ## Get the center of the axis-aligned bounding box.
  result = (a.min + a.max) / 2

proc radius*(a: AABounds): float =
  ## Get the radius of the axis-aligned bounding box.
  result = length(a.max - a.min) / 2

proc merge*(a, b: AABounds): AABounds =
  ## Merge two axis-aligned bounding boxes.
  result.min = min(a.min, b.min)
  result.max = max(a.max, b.max)

proc merge*(a, b: BoundingSphere): BoundingSphere =
  ## Merge two bounding spheres.
  var d = length(a.center - b.center)
  if d + b.radius <= a.radius:
    return a
  if d + a.radius <= b.radius:
    return b
  var r = (a.radius + d + b.radius) / 2
  return BoundingSphere(center: (a.center + b.center) / 2, radius: r)

proc getAABoundsNode*(node: Node, trs = mat4()): AABounds =
  ## Get the axis-aligned bounding box of the node.
  var bounds = AABounds()
  bounds.min = vec3(float32.high, float32.high, float32.high)
  bounds.max = vec3(float32.low, float32.low, float32.low)
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      for p in primitive.points:
        bounds.min = min(bounds.min, trs * p)
        bounds.max = max(bounds.max, trs * p)
  return bounds

proc getAABounds*(node: Node, trs = mat4()): AABounds =
  ## Get the axis-aligned bounding box of the node and its children.
  var bounds = getAABoundsNode(node, trs * node.trs)
  for n in node.nodes:
    bounds = bounds.merge(getAABounds(n, trs * node.trs))
  return bounds

proc computeBounds*(node: Node, trs = mat4()): Bounds =
  ## Computes a stable center, size, and radius for a node tree.
  let aabb = node.getAABounds(trs)
  if aabb.min.x > aabb.max.x or
     aabb.min.y > aabb.max.y or
     aabb.min.z > aabb.max.z:
    return Bounds(
      center: vec3(0, 0, 0),
      size: vec3(0, 0, 0),
      radius: 0
    )

  let size = aabb.max - aabb.min
  Bounds(
    center: aabb.center,
    size: size,
    radius: length(size) / 2
  )

proc getBoundingSphereNode*(node: Node, trs = mat4()): BoundingSphere =
  ## Get the bounding sphere of the node.
  if node.mesh == nil or not node.mesh.hasGeometry():
    return BoundingSphere(center: vec3(0, 0, 0), radius: 0)
  var center = vec3(0, 0, 0)
  var pointCount = 0
  for primitive in node.mesh.primitives:
    for p in primitive.points:
      center += trs * p
      inc pointCount
  if pointCount == 0:
    return BoundingSphere(center: vec3(0, 0, 0), radius: 0)
  center /= pointCount.float32
  var radius = 0.float32
  for primitive in node.mesh.primitives:
    for p in primitive.points:
      radius = max(radius, length(trs * p - center))
  return BoundingSphere(center: center, radius: radius)

proc getBoundingSphere*(node: Node, trs = mat4()): BoundingSphere =
  ## Get the bounding sphere of the node and its children.
  var bounds = getBoundingSphereNode(node, trs * node.trs)
  for n in node.nodes:
    bounds = bounds.merge(getBoundingSphere(n, trs * node.trs))
  return bounds

iterator triangles*(node: Node): (Vec3, Vec3, Vec3) =
  ## Triangles iterator for a node.
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      for i in 0 ..< primitive.indices16.len div 3:
        yield (
          primitive.points[primitive.indices16[i * 3 + 0]],
          primitive.points[primitive.indices16[i * 3 + 1]],
          primitive.points[primitive.indices16[i * 3 + 2]]
        )
      for i in 0 ..< primitive.indices32.len div 3:
        yield (
          primitive.points[primitive.indices32[i * 3 + 0]],
          primitive.points[primitive.indices32[i * 3 + 1]],
          primitive.points[primitive.indices32[i * 3 + 2]]
        )

proc `[]`*(node: Node, name: string): Node =
  ## Get a child node by name.
  for n in node.nodes:
    if n.name == name:
      return n

proc draw*(
  node: Node,
  shader: GLuint,
  transform, view, proj: DMat4,
  tint: Color,
  useTrs = true
) =
  ## Draw the node using a double precision transformation matrix.
  node.draw(
    shader,
    transform.toMat4(),
    view.toMat4(),
    proj.toMat4(),
    tint,
    useTrs
  )
