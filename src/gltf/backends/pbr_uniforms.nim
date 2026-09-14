## Shared material and frame values for the DirectX and Vulkan shader layouts.
import std/[algorithm, math, strutils], pixie, chroma, vmath,
  ../common, ../models, ./shader_layout

type
  PbrFrameUniforms* = object of RootObj
    size*: IVec2
    clearColor*, tint*: Color
    transform*, view*, proj*: Mat4
    useTrs*: bool
    ambientLightColor*, sunLightColor*, rimLightColor*: Color
    sunLightDirection*, rimLightDirection*, cameraPosition*: Vec3
    debugView*: DebugView
    fogColor*: Color
    fogStart*, fogEnd*, fogDensity*, fogStrength*: float32
    environmentMapStrength*, environmentRotation*, exposure*: float32
    environmentMipCount*: int
    useShadows*, drawSkybox*, vsync*, useIbl*, transmissionBackground*: bool
    skyboxLod*: float32
    lightCount*: int
    lightDirections*, lightColors*, lightPositions*: array[32, Vec3]
    lightParameters*: array[32, Vec4]
  MaterialTextureInput* = object
    name*: string
    image*: Image
    ktx2*: string
    sampler*: TextureSampler
    transform*: TextureTransform
    srgb*: bool
    present*: bool
  SceneDraw* = object
    owner*: Node
    primitive*: Primitive
    transform*: Mat4
    depth*: float32
    blended*: bool
  SceneDraws* = object
    opaque*, blended*, transmitted*: seq[SceneDraw]

proc transmissionMaterial*(material: Material): bool =
  material != nil and (material.hasTransmission or material.transmissionFactor > 0)

proc primitiveDepth*(primitive: Primitive, transform, view: Mat4): float32 =
  ## Use the indexed centroid and view-space depth, as in the reference.
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
  (view * transform * vec4(center, 1)).z

proc sceneDraws*(frame: PbrFrameUniforms, root: Node): SceneDraws =
  var draws: SceneDraws
  proc visit(node: Node) =
    if node == nil or not node.visible: return
    if node.mesh != nil:
      for primitive in node.mesh.primitives:
        if not primitive.hasGeometry(): continue
        let material = primitive.material
        let blend = frame.tint.a < 1 or (material != nil and
          (if frame.useIbl: material.alphaMode else: material.legacyAlphaMode) == BlendAlphaMode)
        let entry = SceneDraw(owner: node, primitive: primitive, transform: node.mat,
          depth: primitive.primitiveDepth(node.mat, frame.view), blended: blend)
        if frame.useIbl and material.transmissionMaterial(): draws.transmitted.add(entry)
        elif blend: draws.blended.add(entry)
        else: draws.opaque.add(entry)
    for child in node.nodes: visit(child)
  visit(root)
  for entries in [addr draws.blended, addr draws.transmitted]:
    entries[].sort(proc(a, b: SceneDraw): int = cmp(a.depth, b.depth))
  draws

proc textureInputs*(material: Material): seq[MaterialTextureInput] =
  template addTexture(slot: untyped, isSrgb: bool) =
    result.add(MaterialTextureInput(name: astToStr(slot), image: material.slot,
      ktx2: material.`slot Ktx2`, sampler: material.`slot Sampler`,
      transform: material.`slot Transform`, srgb: isSrgb,
      present: material.slot != nil or material.`slot Ktx2`.len > 0))
  addTexture(baseColor, true)
  addTexture(metallicRoughness, false)
  addTexture(normal, false)
  addTexture(occlusion, false)
  addTexture(emissive, true)
  addTexture(transmission, false)
  addTexture(thickness, false)
  addTexture(diffuseTransmission, false)
  addTexture(diffuseTransmissionColor, true)
  addTexture(anisotropy, false)
  addTexture(clearcoat, false)
  addTexture(clearcoatRoughness, false)
  addTexture(clearcoatNormal, false)
  addTexture(iridescence, false)
  addTexture(iridescenceThickness, false)
  addTexture(specular, false)
  addTexture(specularColor, true)
  addTexture(sheenColor, true)
  addTexture(sheenRoughness, false)
  addTexture(diffuse, true)
  addTexture(specularGlossiness, true)

proc materialBindingKey*(inputs: openArray[MaterialTextureInput], ibl: bool,
    environmentVersion, materialVersion: uint64): string =
  ## Factors, UV transforms and animation values live in per-draw uniforms.
  ## Materials referencing the same images and samplers share GPU bindings.
  result = $ibl & ":" & $environmentVersion & ":" & $materialVersion
  for input in inputs:
    let identity = if input.image != nil and input.image.width == 1 and input.image.height == 1:
      $input.image.data[0]
      else: $cast[uint](input.image)
    result.add ";" & input.name & ":" & identity & ":" & $input.sampler
    result.add ":" & $input.srgb
    if input.ktx2.len > 0: result.add ":" & input.ktx2

proc updateLights*(frame: var PbrFrameUniforms, root: Node) =
  var count = 0
  var directions, positions, colors: array[32, Vec3]
  var parameters: array[32, Vec4]
  proc visit(node: Node) =
    if node == nil or not node.visible: return
    if node.punctualLight != nil:
      if count >= 32: raise newException(ValueError, "IBL supports at most 32 authored punctual lights")
      let light = node.punctualLight
      var rotation = mat4()
      for axis in 0 ..< 3:
        let column = node.mat[axis].xyz
        if column.lengthSq > 0:
          let unit = normalize(column)
          for row in 0 ..< 3: rotation[axis, row] = unit[row]
      directions[count] = quatRotate(normalize(quat(rotation)), vec3(0, 0, -1))
      positions[count] = node.mat[3].xyz
      colors[count] = vec3(light.color.r, light.color.g, light.color.b) * light.intensity
      parameters[count] = vec4(light.kind.ord.float32, light.range,
        cos(light.innerConeAngle), cos(light.outerConeAngle))
      inc count
    for child in node.nodes: visit(child)
  visit(root)
  frame.lightCount = count
  frame.lightDirections = directions
  frame.lightPositions = positions
  frame.lightColors = colors
  frame.lightParameters = parameters

proc vertexUniforms*(layout: ShaderLayout, owner, root: Node,
    transform, view, proj: Mat4): seq[uint32] =
  var data = newUniformData(layout)
  let joints = root.skinMatrices(owner)
  data.put("useSkinning", joints.len > 0)
  for i in 0 ..< min(joints.len, 128): data.put("jointMatrices", joints[i], i)
  data.put("model", transform)
  data.put("normalMatrix", transform.normalMatrix)
  data.put("lightSpace", mat4())
  data.put("proj", proj)
  data.put("view", view)
  data.words

proc pixelUniforms*(layout: ShaderLayout, primitive: Primitive,
    frame: PbrFrameUniforms, transform: Mat4): seq[uint32] =
  var data = newUniformData(layout)
  let material = primitive.material
  let inputs = material.textureInputs()
  let alphaMode = if frame.useIbl: material.alphaMode else: material.legacyAlphaMode
  let angle = degToRad(frame.environmentRotation)
  let rotation = mat3(vec3(cos(angle), 0'f, -sin(angle)), vec3(0, 1, 0), vec3(sin(angle), 0'f, cos(angle)))
  for field in layout.fields:
    let name = field.name
    var textureField = false
    for input in inputs:
      if name == input.name & "TexCoord":
        data.put(name, input.transform.texCoord); textureField = true
      elif name == input.name & "UvOffset":
        data.put(name, input.transform.offset); textureField = true
      elif name == input.name & "UvScale":
        data.put(name, input.transform.scale); textureField = true
      elif name == input.name & "UvRotation":
        data.put(name, input.transform.rotation); textureField = true
      elif name == "has" & input.name.capitalizeAscii & "Texture":
        data.put(name, input.present); textureField = true
      if textureField: break
    if textureField: continue
    case name
    of "unlitMaterial": data.put(name, material.unlit.ord)
    of "opaqueMaterial": data.put(name, (alphaMode == OpaqueAlphaMode).ord)
    of "alphaCutoff": data.put(name, if alphaMode == MaskAlphaMode: material.alphaCutoff else: -1'f)
    of "baseColorFactor": data.put(name, material.baseColorFactor)
    of "metallicFactor": data.put(name, material.metallicFactor)
    of "roughnessFactor": data.put(name, material.roughnessFactor)
    of "occlusionStrength": data.put(name, material.occlusionStrength)
    of "emissiveFactor":
      let c = material.emissiveRadiance
      data.put(name, vec3(c.r, c.g, c.b))
    of "normalScale": data.put(name, material.normalScale)
    of "useNormalTexture": data.put(name, material.hasNormalTexture and
      (frame.useIbl or (primitive.normals.len > 0 and primitive.tangents.len > 0)))
    of "hasVertexTangent": data.put(name, primitive.tangents.len > 0)
    of "transmissionFactor": data.put(name, material.transmissionFactor)
    of "diffuseTransmissionFactor": data.put(name, material.diffuseTransmissionFactor)
    of "diffuseTransmissionColorFactor": data.put(name, material.diffuseTransmissionColorFactor)
    of "thicknessFactor": data.put(name, material.thicknessFactor)
    of "attenuationColor": data.put(name, material.attenuationColor)
    of "attenuationDistance": data.put(name, material.attenuationDistance)
    of "materialIor": data.put(name, if material.hasIor and material.ior == 0: 1e8'f
      elif material.ior > 0: material.ior else: 1.5'f)
    of "volumeScale": data.put(name, vec3(transform[0].xyz.length, transform[1].xyz.length, transform[2].xyz.length))
    of "specularFactor": data.put(name, if material.hasSpecular: material.specularFactor else: 1'f)
    of "specularColorFactor": data.put(name, if material.hasSpecular: material.specularColorFactor else: vec3(1))
    of "specularGlossinessMaterial": data.put(name, material.hasSpecularGlossiness)
    of "diffuseFactor": data.put(name, material.diffuseFactor)
    of "specularGlossinessFactor": data.put(name, material.specularGlossinessFactor)
    of "glossinessFactor": data.put(name, material.glossinessFactor)
    of "sheenEnabled": data.put(name, material.sheenColorFactor != vec3(0))
    of "sheenColorFactor": data.put(name, material.sheenColorFactor)
    of "sheenRoughnessFactor": data.put(name, material.sheenRoughnessFactor)
    of "anisotropyEnabled": data.put(name, material.hasAnisotropy or material.anisotropyStrength > 0)
    of "anisotropyParameters": data.put(name, vec3(cos(material.anisotropyRotation), sin(material.anisotropyRotation), material.anisotropyStrength))
    of "clearcoatFactor": data.put(name, material.clearcoatFactor)
    of "clearcoatRoughnessFactor": data.put(name, material.clearcoatRoughnessFactor)
    of "clearcoatNormalScale": data.put(name, material.clearcoatNormalScale)
    of "iridescenceFactor": data.put(name, material.iridescenceFactor)
    of "iridescenceIor": data.put(name, material.iridescenceIor)
    of "iridescenceThicknessRange": data.put(name, vec2(material.iridescenceThicknessMinimum, material.iridescenceThicknessMaximum))
    of "tint": data.put(name, frame.tint)
    of "proj": data.put(name, frame.proj)
    of "view": data.put(name, frame.view)
    of "cameraPosition": data.put(name, frame.cameraPosition)
    of "environmentRotation": data.put(name, rotation)
    of "environmentMapStrength": data.put(name, frame.environmentMapStrength)
    of "environmentMipCount": data.put(name, frame.environmentMipCount.float32)
    of "exposure": data.put(name, frame.exposure)
    of "framebufferYDown": data.put(name, true)
    of "transmissionBackground": data.put(name, frame.transmissionBackground)
    of "transmissionBufferLod": data.put(name, 10'f)
    of "sunLightDirection": data.put(name, frame.sunLightDirection)
    of "sunLightColor": data.put(name, frame.sunLightColor)
    of "rimLightDirection": data.put(name, frame.rimLightDirection)
    of "rimLightColor": data.put(name, frame.rimLightColor)
    of "ambientLightColor": data.put(name, frame.ambientLightColor)
    of "fogColor": data.put(name, frame.fogColor)
    of "fogStart": data.put(name, frame.fogStart)
    of "fogEnd": data.put(name, frame.fogEnd)
    of "fogDensity": data.put(name, frame.fogDensity)
    of "fogStrength": data.put(name, frame.fogStrength)
    of "debugViewMode": data.put(name, frame.debugView.ord)
    of "useShadow": data.put(name, false)
    of "shadowBias": data.put(name, 0.0005'f)
    of "shadowMapTexelSize": data.put(name, vec2(1'f / 2048'f))
    of "punctualLightCount": data.put(name, frame.lightCount)
    of "punctualLightDirections", "punctualLightColors", "punctualLightPositions", "punctualLightParameters":
      for i in 0 ..< 32:
        case name
        of "punctualLightDirections": data.put(name, frame.lightDirections[i], i)
        of "punctualLightColors": data.put(name, frame.lightColors[i], i)
        of "punctualLightPositions": data.put(name, frame.lightPositions[i], i)
        else: data.put(name, frame.lightParameters[i], i)
    else: raise newException(ValueError, "No value supplied for shader uniform: " & name)
  data.words
