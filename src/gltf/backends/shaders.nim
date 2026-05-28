## Unified glTF shader sources generated through Shady.

import
  std/math,
  shady, vmath

const ShaderPi = 3.1415926535897932384626433832795'f

var
  model*: Uniform[Mat4]
  view*: Uniform[Mat4]
  proj*: Uniform[Mat4]
  lightSpace*: Uniform[Mat4]
  useSkinning*: Uniform[bool]
  jointMatrices*: Uniform[array[128, Mat4]]

  invProj*: Uniform[Mat4]
  invView*: Uniform[Mat4]
  lod*: Uniform[float32]

  sampleTex*: Uniform[Sampler2d]
  baseColorTexture*: Uniform[Sampler2d]
  baseColorFactor*: Uniform[Vec4]
  baseColorTexCoord*: Uniform[int]
  baseColorUvOffset*: Uniform[Vec2]
  baseColorUvScale*: Uniform[Vec2]
  baseColorUvRotation*: Uniform[float32]

  metallicRoughnessTexture*: Uniform[Sampler2d]
  metallicFactor*: Uniform[float32]
  roughnessFactor*: Uniform[float32]
  transmissionFactor*: Uniform[float32]
  metallicRoughnessTexCoord*: Uniform[int]
  metallicRoughnessUvOffset*: Uniform[Vec2]
  metallicRoughnessUvScale*: Uniform[Vec2]
  metallicRoughnessUvRotation*: Uniform[float32]

  normalTexture*: Uniform[Sampler2d]
  normalScale*: Uniform[float32]
  normalTexCoord*: Uniform[int]
  normalUvOffset*: Uniform[Vec2]
  normalUvScale*: Uniform[Vec2]
  normalUvRotation*: Uniform[float32]

  occlusionTexture*: Uniform[Sampler2d]
  occlusionStrength*: Uniform[float32]
  occlusionTexCoord*: Uniform[int]
  occlusionUvOffset*: Uniform[Vec2]
  occlusionUvScale*: Uniform[Vec2]
  occlusionUvRotation*: Uniform[float32]

  emissiveTexture*: Uniform[Sampler2d]
  emissiveFactor*: Uniform[Vec3]
  emissiveTexCoord*: Uniform[int]
  emissiveUvOffset*: Uniform[Vec2]
  emissiveUvScale*: Uniform[Vec2]
  emissiveUvRotation*: Uniform[float32]

  environmentMap*: Uniform[SamplerCube]
  environmentMipCount*: Uniform[float32]
  shadowMap*: Uniform[Sampler2dShadow]
  shadowMapTexelSize*: Uniform[Vec2]
  tint*: Uniform[Vec4]

  useShadow*: Uniform[bool]
  useNormalTexture*: Uniform[bool]
  alphaCutoff*: Uniform[float32]

  ambientLightColor*: Uniform[Vec4]
  sunLightDirection*: Uniform[Vec3]
  sunLightColor*: Uniform[Vec4]
  rimLightDirection*: Uniform[Vec3]
  rimLightColor*: Uniform[Vec4]
  cameraPosition*: Uniform[Vec3]
  debugViewMode*: Uniform[int]
  shadowBias*: Uniform[float32]

func identityMat4(): Mat4 =
  mat4(1.0'f)

proc skinMatrix(vertexJoints: UVec4, vertexWeights: Vec4): Mat4 =
  result =
    vertexWeights.x * jointMatrices[vertexJoints.x.int] +
    vertexWeights.y * jointMatrices[vertexJoints.y.int] +
    vertexWeights.z * jointMatrices[vertexJoints.z.int] +
    vertexWeights.w * jointMatrices[vertexJoints.w.int]

func transformUv(uv, offset, scale: Vec2, rotation: float32): Vec2 =
  let
    c = cos(rotation)
    s = sin(rotation)
    scaled = uv * scale
  result = vec2(
    c * scaled.x - s * scaled.y,
    s * scaled.x + c * scaled.y
  ) + offset

func selectUv(texCoord: int, uv, uv1: Vec2): Vec2 =
  if texCoord == 1:
    uv1
  else:
    uv

func safeNormalize(v: Vec3): Vec3 =
  if length(v) > 0.0'f:
    normalize(v)
  else:
    vec3(0.0'f, 0.0'f, 0.0'f)

proc gltfPbrVert*(
  vertexPosition: Vec3,
  vertexColor: Vec4,
  vertexNormal: Vec3,
  vertexUV: Vec2,
  vertexTangent: Vec4,
  vertexJoints: UVec4,
  vertexWeights: Vec4,
  vertexUV1: Vec2,
  gl_Position: var Vec4,
  worldPos: var Vec3,
  color: var Vec4,
  normal: var Vec3,
  uv: var Vec2,
  uv1: var Vec2,
  tangent: var Vec3,
  bitangent: var Vec3,
  vPosLightSpace: var Vec4
) =
  var skin = identityMat4()
  if useSkinning:
    skin =
      vertexWeights.x * jointMatrices[vertexJoints.x.int] +
      vertexWeights.y * jointMatrices[vertexJoints.y.int] +
      vertexWeights.z * jointMatrices[vertexJoints.z.int] +
      vertexWeights.w * jointMatrices[vertexJoints.w.int]
  let
    skinnedPosition = skin * vec4(vertexPosition, 1.0'f)
    skinnedNormal = (skin * vec4(vertexNormal, 0.0'f)).xyz
    skinnedTangent = (skin * vec4(vertexTangent.xyz, 0.0'f)).xyz
  worldPos = (model * skinnedPosition).xyz
  color = vertexColor
  uv = vertexUV
  uv1 = vertexUV1

  let n: Vec3 = safeNormalize((model * vec4(skinnedNormal, 0.0'f)).xyz)
  normal = n
  tangent = safeNormalize((model * vec4(skinnedTangent, 0.0'f)).xyz)
  bitangent = cross(n, tangent) * vertexTangent.w
  vPosLightSpace = lightSpace * vec4(worldPos, 1.0'f)
  gl_Position = proj * view * model * skinnedPosition

proc gltfPbrFrag*(
  worldPos: Vec3,
  color: Vec4,
  normal: Vec3,
  uv: Vec2,
  uv1: Vec2,
  tangent: Vec3,
  bitangent: Vec3,
  vPosLightSpace: Vec4,
  fragColor: var Vec4
) =
  let
    baseColorUv = transformUv(
      selectUv(baseColorTexCoord, uv, uv1),
      baseColorUvOffset,
      baseColorUvScale,
      baseColorUvRotation
    )
    metallicRoughnessUv = transformUv(
      selectUv(metallicRoughnessTexCoord, uv, uv1),
      metallicRoughnessUvOffset,
      metallicRoughnessUvScale,
      metallicRoughnessUvRotation
    )
    normalUv = transformUv(
      selectUv(normalTexCoord, uv, uv1),
      normalUvOffset,
      normalUvScale,
      normalUvRotation
    )
    occlusionUv = transformUv(
      selectUv(occlusionTexCoord, uv, uv1),
      occlusionUvOffset,
      occlusionUvScale,
      occlusionUvRotation
    )
    emissiveUv = transformUv(
      selectUv(emissiveTexCoord, uv, uv1),
      emissiveUvOffset,
      emissiveUvScale,
      emissiveUvRotation
    )

  fragColor = texture(baseColorTexture, baseColorUv)
  fragColor = fragColor * baseColorFactor
  fragColor = fragColor * color
  if fragColor.a < alphaCutoff:
    discardFragment()

  let
    albedo: Vec3 = fragColor.rgb
    roughness =
      texture(metallicRoughnessTexture, metallicRoughnessUv).g *
      roughnessFactor
    metallic =
      texture(metallicRoughnessTexture, metallicRoughnessUv).b *
      metallicFactor
    transmission = clamp(transmissionFactor, 0.0'f, 1.0'f)
    ambientOcclusion =
      texture(occlusionTexture, occlusionUv).g *
      occlusionStrength
    emissiveValue: Vec3 =
      texture(emissiveTexture, emissiveUv).rgb *
      emissiveFactor
    geometricNormal: Vec3 = normalize(cross(dFdx(worldPos), dFdy(worldPos)))
    meshNormal: Vec3 =
      if length(normal) > 0.0'f:
        normalize(normal)
      else:
        geometricNormal
    normalValue: Vec3 =
      normalize(texture(normalTexture, normalUv).rgb * 2.0'f -
        vec3(1.0'f, 1.0'f, 1.0'f)) *
      normalScale
    mappedNormal: Vec3 = normalize(
      tangent * normalValue.x +
      bitangent * normalValue.y +
      normal * normalValue.z
    )
  var computedNormal: Vec3 =
    if useNormalTexture:
      mappedNormal
    else:
      meshNormal
  if not gl_FrontFacing:
    computedNormal = -computedNormal
  let
    sunDir: Vec3 = normalize(-sunLightDirection)
    rimDir: Vec3 = normalize(-rimLightDirection)
    viewDir: Vec3 = normalize(cameraPosition - worldPos)
    reflectDir: Vec3 = reflect(-viewDir, computedNormal)
    halfVector: Vec3 = normalize(viewDir + sunDir)
    nDotH = max(dot(computedNormal, halfVector), 0.0'f)
    nDotL = max(dot(computedNormal, sunDir), 0.0'f)
    f0 = vec3(0.04'f, 0.04'f, 0.04'f)
    f0mix: Vec3 = mix(f0, albedo, metallic)
    cosTheta = max(dot(computedNormal, viewDir), 0.0'f)
    fresnel: Vec3 = f0mix +
      (vec3(1.0'f, 1.0'f, 1.0'f) - f0mix) *
      pow(1.0'f - cosTheta, 5.0'f)
    specComponent = nDotL * pow(nDotH, 2.0'f / (roughness + 0.0001'f))
    specular: Vec3 =
      sunLightColor.rgb *
      sunLightColor.a *
      fresnel *
      specComponent
    diffuse: Vec3 =
      sunLightColor.rgb *
      sunLightColor.a *
      (1.0'f - metallic) *
      albedo *
      nDotL
    rim =
      pow(1.0'f - max(dot(computedNormal, viewDir), 0.0'f), 2.5'f) *
      (1.0'f - metallic)
    rimFacing = max(dot(computedNormal, rimDir), 0.0'f)
    rimLight: Vec3 =
      rimLightColor.rgb *
      rimLightColor.a *
      rim *
      (0.15'f + 0.85'f * rimFacing) *
      (0.15'f + 0.35'f * ambientOcclusion)
    mipLevel = roughness * environmentMipCount
    envColor: Vec3 = textureLod(environmentMap, reflectDir, mipLevel).rgb
  var shadow = 0.0'f
  if useShadow:
    var projCoords = vPosLightSpace.xyz / vPosLightSpace.w
    projCoords = projCoords * 0.5'f + vec3(0.5'f, 0.5'f, 0.5'f)
    if projCoords.z <= 1.0'f and
        projCoords.x >= 0.0'f and projCoords.x <= 1.0'f and
        projCoords.y >= 0.0'f and projCoords.y <= 1.0'f:
      let bias =
        max(shadowBias, 0.002'f * (1.0'f - dot(computedNormal, sunDir)))
      var
        total = 0.0'f
        weightSum = 0.0'f
      for ix in 0 ..< 5:
        for iy in 0 ..< 5:
          let
            x = ix - 2
            y = iy - 2
            wx = 1.0'f - abs(x.float32) * 0.25'f
            wy = 1.0'f - abs(y.float32) * 0.25'f
            w = wx * wy
            offset = vec2(x.float32, y.float32) * shadowMapTexelSize
            lit = texture(
              shadowMap,
              vec3(projCoords.xy + offset, projCoords.z - bias)
            )
          total += w * lit
          weightSum += w
      shadow = 1.0'f - total / weightSum

  if debugViewMode == 1:
    fragColor = vec4(albedo * tint.rgb, fragColor.a * tint.a)
  elif debugViewMode == 2:
    fragColor = vec4(computedNormal * 0.5'f +
      vec3(0.5'f, 0.5'f, 0.5'f), fragColor.a)
  elif debugViewMode == 3:
    fragColor = vec4(
      ambientOcclusion,
      ambientOcclusion,
      ambientOcclusion,
      fragColor.a
    )
  elif debugViewMode == 4:
    fragColor = vec4(metallic, metallic, metallic, fragColor.a)
  elif debugViewMode == 5:
    let specularMap =
      clamp(
        dot(f0mix, vec3(0.3333333'f, 0.3333333'f, 0.3333333'f)) *
        (1.0'f - roughness * 0.5'f),
        0.0'f,
        1.0'f
      )
    fragColor = vec4(specularMap, specularMap, specularMap, fragColor.a)
  else:
    let
      direct: Vec3 = (specular + diffuse) * (1.0'f - shadow)
      lo: Vec3 =
        direct +
        ambientLightColor.rgb * ambientLightColor.a * ambientOcclusion +
        rimLight
    var litColor: Vec3 = mix(lo, envColor, fresnel * metallic)

    if transmission > 0.0'f:
      let glassMix =
        clamp(
          0.35'f + transmission * 0.55'f + roughness * 0.1'f,
          0.0'f,
          1.0'f
        )
      litColor = mix(litColor, envColor, glassMix)
      litColor = litColor * mix(1.0'f, 0.82'f, transmission)
      fragColor.a =
        fragColor.a * mix(1.0'f, 0.08'f + roughness * 0.2'f, transmission)

    litColor += emissiveValue
    fragColor = vec4(litColor, fragColor.a) * tint

proc gltfSkyboxVert*(
  vertexPosition: Vec2,
  gl_Position: var Vec4,
  rayDir: var Vec3
) =
  gl_Position = vec4(vertexPosition.x, vertexPosition.y, 1.0'f, 1.0'f)
  let far = invProj *
    vec4(vertexPosition.x, vertexPosition.y, 1.0'f, 1.0'f)
  rayDir = mat3(invView) * far.xyz

proc gltfSkyboxFrag*(rayDir: Vec3, fragColor: var Vec4) =
  let
    dir: Vec3 = normalize(rayDir)
    up =
      if abs(dir.z) < 0.999'f:
        vec3(0.0'f, 0.0'f, 1.0'f)
      else:
        vec3(1.0'f, 0.0'f, 0.0'f)
    tangent: Vec3 = normalize(cross(up, dir))
    bitangent: Vec3 = cross(dir, tangent)
    spread = lod * 0.015'f
  var colorValue = vec4(0.0'f, 0.0'f, 0.0'f, 0.0'f)
  for i in 0 ..< 16:
    let
      t = i.float32 / 16.0'f
      angle = t * 2.0'f * ShaderPi
      r = sqrt(t)
      offset = vec2(cos(angle), sin(angle)) * r * spread
      sampleDir: Vec3 =
        normalize(dir + tangent * offset.x + bitangent * offset.y)
    colorValue += textureLod(environmentMap, sampleDir, lod)
  fragColor = colorValue / 16.0'f

proc gltfShadowDepthVert*(
  vertexPosition: Vec3,
  vertexUV: Vec2,
  vertexJoints: UVec4,
  vertexWeights: Vec4,
  gl_Position: var Vec4,
  fragmentUv: var Vec2
) =
  fragmentUv = vertexUV
  let skin =
    if useSkinning:
      skinMatrix(vertexJoints, vertexWeights)
    else:
      identityMat4()
  gl_Position = proj * view * model * skin * vec4(vertexPosition, 1.0'f)

proc gltfShadowDepthFrag*(fragmentUv: Vec2) =
  if alphaCutoff >= 0.0'f:
    let texColor = texture(sampleTex, fragmentUv) * baseColorFactor
    if texColor.a < alphaCutoff:
      discardFragment()

const
  PbrVertSrc* = toShader(gltfPbrVert, glsl4Desktop, shaderVertex)
  PbrFragSrc* = toShader(gltfPbrFrag, glsl4Desktop, shaderFragment)
  SkyboxVertSrc* = toShader(gltfSkyboxVert, glsl4Desktop, shaderVertex)
  SkyboxFragSrc* = toShader(gltfSkyboxFrag, glsl4Desktop, shaderFragment)
  ShadowDepthVertSrc* =
    toShader(gltfShadowDepthVert, glsl4Desktop, shaderVertex)
  ShadowDepthFragSrc* =
    toShader(gltfShadowDepthFrag, glsl4Desktop, shaderFragment)

  PbrVertHlsl* = toShader(gltfPbrVert, hlslDX12, shaderVertex)
  PbrFragHlsl* = toShader(gltfPbrFrag, hlslDX12, shaderFragment)
  SkyboxVertHlsl* = toShader(gltfSkyboxVert, hlslDX12, shaderVertex)
  SkyboxFragHlsl* = toShader(gltfSkyboxFrag, hlslDX12, shaderFragment)
  ShadowDepthVertHlsl* =
    toShader(gltfShadowDepthVert, hlslDX12, shaderVertex)
  ShadowDepthFragHlsl* =
    toShader(gltfShadowDepthFrag, hlslDX12, shaderFragment)

  PbrVertVulkan* = toShader(gltfPbrVert, vulkanGlsl450, shaderVertex)
  PbrFragVulkan* = toShader(gltfPbrFrag, vulkanGlsl450, shaderFragment)
  SkyboxVertVulkan* = toShader(gltfSkyboxVert, vulkanGlsl450, shaderVertex)
  SkyboxFragVulkan* = toShader(gltfSkyboxFrag, vulkanGlsl450, shaderFragment)
  ShadowDepthVertVulkan* =
    toShader(gltfShadowDepthVert, vulkanGlsl450, shaderVertex)
  ShadowDepthFragVulkan* =
    toShader(gltfShadowDepthFrag, vulkanGlsl450, shaderFragment)

  PbrVertMsl* = toShader(gltfPbrVert, metalMSL, shaderVertex)
  PbrFragMsl* = toShader(gltfPbrFrag, metalMSL, shaderFragment)
  SkyboxVertMsl* = toShader(gltfSkyboxVert, metalMSL, shaderVertex)
  SkyboxFragMsl* = toShader(gltfSkyboxFrag, metalMSL, shaderFragment)
  ShadowDepthVertMsl* =
    toShader(gltfShadowDepthVert, metalMSL, shaderVertex)
  ShadowDepthFragMsl* =
    toShader(gltfShadowDepthFrag, metalMSL, shaderFragment)
