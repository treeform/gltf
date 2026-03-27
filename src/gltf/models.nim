import
  std/[strformat, math],
  vmath, chroma, pixie, opengl

type
  AlphaMode* = enum
    OpaqueAlphaMode, MaskAlphaMode, BlendAlphaMode

  AnimPath* = enum
    AnimTranslation, AnimRotation, AnimScale

  AnimationChannel* = object
    target*: Node
    path*: AnimPath
    times*: seq[float32]
    valuesVec3*: seq[Vec3]
    valuesQuat*: seq[Quat]

  AnimationClip* = object
    name*: string
    duration*: float32
    channels*: seq[AnimationChannel]

  Material* = ref object
    name*: string
    baseColor*: Image
    baseColorFactor*: Color
    metallicRoughness*: Image
    metallicFactor*: float32
    roughnessFactor*: float32
    normal*: Image
    normalScale*: float32
    occlusion*: Image
    occlusionStrength*: float32
    emissive*: Image
    emissiveFactor*: Color

    alphaMode*: AlphaMode
    alphaCutoff*: float32
    doubleSided*: bool
    clampToEdge*: bool

    # OpenGL Ids.
    baseColorId*: GLuint
    metallicRoughnessId*: GLuint
    normalId*: GLuint
    occlusionId*: GLuint
    emissiveId*: GLuint

  Node* = ref object
    name*: string
    visible*: bool = true
    pos*: Vec3
    rot*: Quat
    scale*: Vec3
    mat*: Mat4

    basePos*: Vec3
    baseRot*: Quat
    baseScale*: Vec3

    animations*: seq[AnimationClip]
    currentClip*: int
    animTime*: float32

    points*: seq[Vec3]
    uvs*: seq[Vec2]
    normals*: seq[Vec3]
    tangents*: seq[Vec4]
    colors*: seq[ColorRGBX]
    indices16*: seq[uint16] ## 16bit indices for small models.
    indices32*: seq[uint32] ## 32bit indices for large models.
    material*: Material

    nodes*: seq[Node]

    # OpenGL Ids.
    uploaded*: bool
    vertexArrayId*: GLuint
    pointsId*: GLuint
    uvsId*: GLuint
    normalsId*: GLuint
    tangentsId*: GLuint
    colorsId*: GLuint
    indicesId*: GLuint


proc shallowCopy*(node: Node): Node =
  ## Create a shallow copy of a node.
  ## Does not copy mesh, textures, etc.
  ## This is useful to create instances of a node.

  result = Node()
  result.name = node.name
  result.visible = node.visible
  result.pos = node.pos
  result.rot = node.rot
  result.scale = node.scale
  result.mat = node.mat

  result.basePos = node.basePos
  result.baseRot = node.baseRot
  result.baseScale = node.baseScale

  result.animations = node.animations
  result.currentClip = node.currentClip
  result.animTime = node.animTime

  result.points = node.points
  result.uvs = node.uvs
  result.normals = node.normals
  result.tangents = node.tangents
  result.colors = node.colors
  result.indices16 = node.indices16
  result.indices32 = node.indices32
  result.material = node.material

  result.nodes = node.nodes

  result.uploaded = node.uploaded
  result.vertexArrayId = node.vertexArrayId
  result.pointsId = node.pointsId
  result.uvsId = node.uvsId
  result.normalsId = node.normalsId
  result.tangentsId = node.tangentsId
  result.colorsId = node.colorsId
  result.indicesId = node.indicesId

proc resetToBase*(node: Node) =
  ## Reset the node (and its children) to the original transform.
  if node == nil:
    return
  node.pos = node.basePos
  node.rot = node.baseRot
  node.scale = node.baseScale
  for n in node.nodes:
    n.resetToBase()

proc sampleVec3(times: seq[float32], values: seq[Vec3], t: float32): Vec3 =
  if values.len == 0 or times.len == 0:
    return vec3(0, 0, 0)
  if t <= times[0]:
    return values[0]
  for i in 0 ..< times.len - 1:
    let t0 = times[i]
    let t1 = times[i + 1]
    if t <= t1:
      let u = (t - t0) / (t1 - t0)
      return values[i] * (1 - u) + values[i + 1] * u
  return values[^1]

proc sampleQuat(times: seq[float32], values: seq[Quat], t: float32): Quat =
  if values.len == 0 or times.len == 0:
    return quat(0, 0, 0, 1)
  if t <= times[0]:
    return values[0]
  for i in 0 ..< times.len - 1:
    let t0 = times[i]
    let t1 = times[i + 1]
    if t <= t1:
      let u = (t - t0) / (t1 - t0)
      let q =
        values[i] * (1 - u) +
        values[i + 1] * u
      return q.normalize()
  return values[^1]

proc applyClipAt*(clip: AnimationClip, time: float32) =
  if clip.channels.len == 0:
    return
  let t =
    if clip.duration > 0: time mod clip.duration
    else: time
  for ch in clip.channels:
    case ch.path
    of AnimTranslation:
      if ch.valuesVec3.len > 0:
        ch.target.pos = sampleVec3(ch.times, ch.valuesVec3, t)
    of AnimScale:
      if ch.valuesVec3.len > 0:
        ch.target.scale = sampleVec3(ch.times, ch.valuesVec3, t)
    of AnimRotation:
      if ch.valuesQuat.len > 0:
        ch.target.rot = sampleQuat(ch.times, ch.valuesQuat, t)

proc updateAnimation*(node: Node, dt: float32) =
  ## Advance and apply the current animation clip.
  if node == nil:
    return
  node.resetToBase()
  if node.animations.len > 0 and node.currentClip < node.animations.len:
    node.animTime += dt
    applyClipAt(node.animations[node.currentClip], node.animTime)

proc uploadTextureToGpu(
  textureId: var GLuint,
  image: Image,
  wrapS = GL_REPEAT,
  wrapT = GL_REPEAT
) =
  ## Upload a texture to the GPU.
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
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapS.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrapT.GLint)
  glGenerateMipmap(GL_TEXTURE_2D)

proc uploadToGpu*(node: Node) =
  ## Upload the vertex data to the GPU.

  # Generate the vertex array.
  glGenVertexArrays(1, node.vertexArrayId.addr)
  glBindVertexArray(node.vertexArrayId)

  if node.indices32.len > 0:
    glGenBuffers(1, node.indicesId.addr)
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, node.indicesId)
    glBufferData(
      GL_ELEMENT_ARRAY_BUFFER,
      node.indices32.len * sizeof(uint32),
      node.indices32[0].addr,
      GL_STATIC_DRAW
    )
  elif node.indices16.len > 0:
    glGenBuffers(1, node.indicesId.addr)
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, node.indicesId)
    glBufferData(
      GL_ELEMENT_ARRAY_BUFFER,
      node.indices16.len * sizeof(uint16),
      node.indices16[0].addr,
      GL_STATIC_DRAW
    )

  if node.points.len > 0:
    glGenBuffers(1, node.pointsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, node.pointsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      node.points.len * sizeof(Vec3),
      node.points[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, 0, nil)

  if node.uvs.len > 0:
    glGenBuffers(1, node.uvsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, node.uvsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      node.uvs.len * sizeof(Vec2),
      node.uvs[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(3)
    glVertexAttribPointer(3, 2, cGL_FLOAT, GL_FALSE, 0, nil)

  if node.normals.len > 0:
    glGenBuffers(1, node.normalsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, node.normalsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      node.normals.len * sizeof(Vec3),
      node.normals[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(2)
    glVertexAttribPointer(2, 3, cGL_FLOAT, GL_FALSE, 0, nil)

  if node.tangents.len > 0:
    glGenBuffers(1, node.tangentsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, node.tangentsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      node.tangents.len * sizeof(Vec4),
      node.tangents[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(4)
    glVertexAttribPointer(4, 4, cGL_FLOAT, GL_FALSE, 0, nil)

  if node.colors.len > 0:
    glGenBuffers(1, node.colorsId.addr)
    glBindBuffer(GL_ARRAY_BUFFER, node.colorsId)
    glBufferData(
      GL_ARRAY_BUFFER,
      node.colors.len * sizeof(ColorRGBX),
      node.colors[0].addr,
      GL_STATIC_DRAW
    )
    glEnableVertexAttribArray(1)
    glVertexAttribPointer(1, 4, cGL_UNSIGNED_BYTE, GL_TRUE, 0, nil)
  else:
    glDisableVertexAttribArray(1)
    glVertexAttrib4f(1, 1.0, 1.0, 1.0, 1.0)

  if node.material != nil:

    var wrapS = GL_REPEAT
    var wrapT = GL_REPEAT
    if node.material.clampToEdge:
      wrapS = GL_CLAMP_TO_EDGE
      wrapT = GL_CLAMP_TO_EDGE

    if node.material.baseColor != nil:
      uploadTextureToGpu(
        node.material.baseColorId,
        node.material.baseColor,
        wrapS,
        wrapT
      )

    if node.material.metallicRoughness != nil:
      glGenTextures(1, node.material.metallicRoughnessId.addr)
      glBindTexture(GL_TEXTURE_2D, node.material.metallicRoughnessId)
      glTexImage2D(
        GL_TEXTURE_2D,
        0,
        GL_RGBA.GLint,
        node.material.metallicRoughness.width.GLint,
        node.material.metallicRoughness.height.GLint,
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        node.material.metallicRoughness.data[0].addr
      )
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapS)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrapT)
      glGenerateMipmap(GL_TEXTURE_2D)

    if node.material.normal != nil:
      glGenTextures(1, node.material.normalId.addr)
      glBindTexture(GL_TEXTURE_2D, node.material.normalId)
      glTexImage2D(
        GL_TEXTURE_2D,
        0,
        GL_RGBA.GLint,
        node.material.normal.width.GLint,
        node.material.normal.height.GLint,
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        node.material.normal.data[0].addr
      )
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapS)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrapT)
      glGenerateMipmap(GL_TEXTURE_2D)

    if node.material.occlusion != nil:
      glGenTextures(1, node.material.occlusionId.addr)
      glBindTexture(GL_TEXTURE_2D, node.material.occlusionId)
      glTexImage2D(
        GL_TEXTURE_2D,
        0,
        GL_RGBA.GLint,
        node.material.occlusion.width.GLint,
        node.material.occlusion.height.GLint,
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        node.material.occlusion.data[0].addr
      )
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapS)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrapT)
      glGenerateMipmap(GL_TEXTURE_2D)

    if node.material.emissive != nil:
      glGenTextures(1, node.material.emissiveId.addr)
      glBindTexture(GL_TEXTURE_2D, node.material.emissiveId)
      glTexImage2D(
        GL_TEXTURE_2D,
        0,
        GL_RGBA.GLint,
        node.material.emissive.width.GLint,
        node.material.emissive.height.GLint,
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        node.material.emissive.data[0].addr
      )
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapS)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrapT)
      glGenerateMipmap(GL_TEXTURE_2D)

  node.uploaded = true

proc clearFromGpu*(node: Node) =
  ## Clear the vertex data from the GPU.
  if node.uploaded:
    glDeleteVertexArrays(1, node.vertexArrayId.addr)
    if node.indices16.len > 0 or node.indices32.len > 0:
      glDeleteBuffers(1, node.indicesId.addr)
    if node.indices32.len > 0:
      glDeleteBuffers(1, node.indicesId.addr)
    if node.points.len > 0:
      glDeleteBuffers(1, node.pointsId.addr)
    if node.uvs.len > 0:
      glDeleteBuffers(1, node.uvsId.addr)
    if node.normals.len > 0:
      glDeleteBuffers(1, node.normalsId.addr)
    if node.tangents.len > 0:
      glDeleteBuffers(1, node.tangentsId.addr)
    if node.colors.len > 0:
      glDeleteBuffers(1, node.colorsId.addr)
    if node.material != nil:
      if node.material.baseColorId != 0.GLuint:
        glDeleteTextures(1, node.material.baseColorId.addr)
      if node.material.metallicRoughnessId != 0.GLuint:
        glDeleteTextures(1, node.material.metallicRoughnessId.addr)
  node.uploaded = false
  for n in node.nodes:
    n.clearFromGpu()

proc updateOnGpu*(node: Node) =
  ## Update the data on the GPU.

  if not node.uploaded:
    node.uploadToGpu()
  else:
    glBindVertexArray(node.vertexArrayId)

    if node.points.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, node.pointsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        node.points.len * sizeof(Vec3),
        node.points[0].addr,
        GL_STATIC_DRAW
      )

    if node.uvs.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, node.uvsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        node.uvs.len * sizeof(Vec2),
        node.uvs[0].addr,
        GL_STATIC_DRAW
      )

    if node.normals.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, node.normalsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        node.normals.len * sizeof(Vec3),
        node.normals[0].addr,
        GL_STATIC_DRAW
      )

    if node.tangents.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, node.tangentsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        node.tangents.len * sizeof(Vec4),
        node.tangents[0].addr,
        GL_STATIC_DRAW
      )

    if node.colors.len > 0:
      glBindBuffer(GL_ARRAY_BUFFER, node.colorsId)
      glBufferData(
        GL_ARRAY_BUFFER,
        node.colors.len * sizeof(ColorRGBX),
        node.colors[0].addr,
        GL_STATIC_DRAW
      )

    if node.indices32.len > 0:
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, node.indicesId)
      glBufferData(
        GL_ELEMENT_ARRAY_BUFFER,
        node.indices32.len * sizeof(uint32),
        node.indices32[0].addr,
        GL_STATIC_DRAW
      )
    elif node.indices16.len > 0:
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, node.indicesId)
      glBufferData(
        GL_ELEMENT_ARRAY_BUFFER,
        node.indices16.len * sizeof(uint16),
        node.indices16[0].addr,
        GL_STATIC_DRAW
      )

  for n in node.nodes:
    n.updateOnGpu()

proc clearTreeFromGpu*(node: Node) =
  ## Clear the vertex data from the GPU for the whole tree.
  for n in node.nodes:
    n.clearTreeFromGpu()
  node.clearFromGpu()

proc trs*(node: Node): Mat4 =
  ## Get the transformation matrix of a node.
  translate(node.pos) * node.rot.mat4() * scale(node.scale)

proc draw*(
  node: Node,
  shader: GLuint,
  transform, view, proj: Mat4,
  tint: Color,
  useTrs = true,
  skipBlend = false
) =
  if not node.visible:
    return

  node.mat = transform * node.trs

  if skipBlend and node.material != nil and node.material.alphaMode == BlendAlphaMode:
    for n in node.nodes:
      n.draw(shader, node.mat, view, proj, tint, useTrs=true, skipBlend=skipBlend)
    return


  let
    modelUniform = glGetUniformLocation(shader, "model")
    viewUniform = glGetUniformLocation(shader, "view")
    projUniform = glGetUniformLocation(shader, "proj")

  var
    modelArray = node.mat
    viewArray = view
    projArray = proj
  glUniformMatrix4fv(modelUniform, 1, GL_FALSE, cast[ptr float32](modelArray.addr))
  glUniformMatrix4fv(viewUniform, 1, GL_FALSE, cast[ptr float32](viewArray.addr))
  glUniformMatrix4fv(projUniform, 1, GL_FALSE, cast[ptr float32](projArray.addr))

  if not node.uploaded:
    node.uploadToGpu()

  glBindVertexArray(node.vertexArrayId)

  if node.material != nil and not (skipBlend and node.material.alphaMode == BlendAlphaMode):
    # Bind the material texture (or 0 to ensure no previous texture is bound)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, node.material.baseColorId)

    let sampleTexUniform = glGetUniformLocation(shader, "sampleTex")
    if sampleTexUniform >= 0:
      glUniform1i(sampleTexUniform, 0)

    let baseColorFactorUniform = glGetUniformLocation(shader, "baseColorFactor")
    if baseColorFactorUniform >= 0:
      glUniform4f(
        baseColorFactorUniform,
        node.material.baseColorFactor.r,
        node.material.baseColorFactor.g,
        node.material.baseColorFactor.b,
        node.material.baseColorFactor.a
      )

    let alphaCutoffUniform = glGetUniformLocation(shader, "alphaCutoff")
    if alphaCutoffUniform >= 0:
      var cutoff = -1.0
      if node.material.alphaMode == MaskAlphaMode:
        cutoff = node.material.alphaCutoff
      glUniform1f(alphaCutoffUniform, cutoff)

  else:
    glBindTexture(GL_TEXTURE_2D, 0)
    let sampleTexUniform = glGetUniformLocation(shader, "sampleTex")
    if sampleTexUniform >= 0:
      glUniform1i(sampleTexUniform, 0)

  let colorTintUniform = glGetUniformLocation(shader, "tint")
  glUniform4f(colorTintUniform, tint.r, tint.g, tint.b, tint.a)

  if node.indices32.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, node.indicesId)
    glDrawElements(
      GL_TRIANGLES,
      node.indices32.len.GLint,
      GL_UNSIGNED_INT,
      nil
    )
  elif node.indices16.len > 0:
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, node.indicesId)
    glDrawElements(
      GL_TRIANGLES,
      node.indices16.len.GLint,
      GL_UNSIGNED_SHORT,
      nil
    )
  else:
    glDrawArrays(GL_TRIANGLES, 0, node.points.len.cint)

  for n in node.nodes:
    n.draw(shader, node.mat, view, proj, tint, useTrs=true, skipBlend=skipBlend)

proc dumpTree*(node: Node, indent: string = "") =
  echo &"{indent}{node.name}"

  # TRS
  echo &"{indent}  pos: {node.pos}"
  let euler = node.rot.toAngles().toDegrees()
  echo &"{indent}  rot: {node.rot} ({euler})"
  echo &"{indent}  scale: {node.scale}"

  # Material
  if node.material != nil:
    echo &"{indent}  material: {node.material.name}"
    if node.material.baseColor != nil:
      echo &"{indent}    baseColor: {node.material.baseColor}"
      echo &"{indent}    baseColorFactor: {node.material.baseColorFactor}"
    if node.material.metallicRoughness != nil:
      echo &"{indent}    metallicRoughness: {node.material.metallicRoughness}"
    echo &"{indent}    metallicFactor: {node.material.metallicFactor}"
    echo &"{indent}    roughnessFactor: {node.material.roughnessFactor}"
    if node.material.normal != nil:
      echo &"{indent}    normal: {node.material.normal}"
      echo &"{indent}    normalScale: {node.material.normalScale}"
    if node.material.occlusion != nil:
      echo &"{indent}    occlusion: {node.material.occlusion}"
      echo &"{indent}    occlusionStrength: {node.material.occlusionStrength}"
    if node.material.emissive != nil:
      echo &"{indent}    emissive: {node.material.emissive}"
      echo &"{indent}    emissiveFactor: {node.material.emissiveFactor}"
    # Alpha mode.
    if node.material.alphaMode == MaskAlphaMode:
      echo &"{indent}    alphaMode: Mask"
      echo &"{indent}    alphaCutoff: {node.material.alphaCutoff}"
    elif node.material.alphaMode == BlendAlphaMode:
      echo &"{indent}    alphaMode: Blend"
    else:
      echo &"{indent}    alphaMode: Opaque"
    echo &"{indent}    doubleSided: {node.material.doubleSided}"

  # Mesh
  if node.points.len > 0:
    echo &"{indent}  points: {node.points.len}"
  if node.uvs.len > 0:
    echo &"{indent}  uvs: {node.uvs.len}"
  if node.normals.len > 0:
    echo &"{indent}  normals: {node.normals.len}"
  if node.tangents.len > 0:
    echo &"{indent}  tangents: {node.tangents.len}"
  if node.colors.len > 0:
    echo &"{indent}  colors: {node.colors.len}"
  if node.indices16.len > 0:
    echo &"{indent}  indices (16bit): {node.indices16.len}"
  if node.indices32.len > 0:
    echo &"{indent}  indices (32bit): {node.indices32.len}"

  for n in node.nodes:
    n.dumpTree(indent & "  ")

proc walkNodes*(node: Node): seq[Node] =
  ## Walk the nodes tree and return a flat list of nodes.
  proc innerWalk(node: Node, arr: var seq[Node]) =
    arr.add(node)
    for n in node.nodes:
      innerWalk(n, arr)
  innerWalk(node, result)

type
  AABounds* = object
    min, max*: Vec3

  Bounds* = object
    center*: Vec3
    size*: Vec3
    radius*: float32

  BoundingSphere* = object
    center*: Vec3
    radius*: float

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
  for p in node.points:
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
  if node.points.len == 0:
    return BoundingSphere(center: vec3(0, 0, 0), radius: 0)
  var center = vec3(0, 0, 0)
  for p in node.points:
    center += trs * p
  center /= node.points.len.float32
  var radius = 0.float32
  for p in node.points:
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
  for i in 0 ..< node.indices16.len div 3:
    yield (
      node.points[node.indices16[i * 3 + 0]],
      node.points[node.indices16[i * 3 + 1]],
      node.points[node.indices16[i * 3 + 2]]
    )
  for i in 0 ..< node.indices32.len div 3:
    yield (
      node.points[node.indices32[i * 3 + 0]],
      node.points[node.indices32[i * 3 + 1]],
      node.points[node.indices32[i * 3 + 2]]
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
    transform.mat4,
    view.mat4,
    proj.mat4,
    tint,
    useTrs
  )
