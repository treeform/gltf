## Core metallic/roughness IBL and PBR Neutral, ported to Shady/Nim from
## Khronos glTF-Sample-Renderer (Apache-2.0). See khronos-LICENSE.txt.
## Included by shaders.nim to share the vertex interface and material uniforms.

var
  diffuseEnvironment*: Uniform[SamplerCube]
  ggxLut*: Uniform[Sampler2d]
  environmentRotation*: Uniform[Mat3]
  hdrInput*: Uniform[Sampler2d]
  toneFlags*: Uniform[USampler2d]
  exposure*: Uniform[float32]
  hasVertexTangent*: Uniform[bool]

func pbrNeutral*(input: Vec3): Vec3 =
  ## Khronos PBR Neutral, operating on exposed linear radiance.
  let x = min(input.r, min(input.g, input.b))
  let offset = if x < 0.08'f: x - 6.25'f * x * x else: 0.04'f
  var value: Vec3 = input - vec3(offset)
  let peak = max(value.r, max(value.g, value.b))
  if peak < 0.76'f:
    return value
  let newPeak = 1.0'f - 0.24'f * 0.24'f / (peak + 0.24'f - 0.76'f)
  value = value * (newPeak / peak)
  let desaturation = 1.0'f - 1.0'f / (0.15'f * (peak - newPeak) + 1.0'f)
  result = mix(value, vec3(newPeak), desaturation)

func iblFresnel(nDotV, roughness: float32, f0: Vec3, brdf: Vec2): Vec3 =
  let
    fr: Vec3 = vec3(max(1.0'f - roughness, f0.r),
      max(1.0'f - roughness, f0.g), max(1.0'f - roughness, f0.b)) - f0
    ks: Vec3 = f0 + fr * pow(1.0'f - nDotV, 5.0'f)
    singleScatter: Vec3 = ks * brdf.x + vec3(brdf.y)
    missingEnergy = 1.0'f - brdf.x - brdf.y
    average: Vec3 = f0 + (vec3(1.0'f) - f0) / 21.0'f
    multipleScatter: Vec3 = missingEnergy * singleScatter * average /
      (vec3(1.0'f) - average * missingEnergy)
  result = singleScatter + multipleScatter

proc gltfIblFrag*(
  worldPos: Vec3, color: Vec4, normal: Vec3, uv: Vec2, uv1: Vec2,
  tangent: Vec3, bitangent: Vec3, vPosLightSpace: Vec4,
  fragColor: var Vec4, toneMapFlag: var uint32
) =
  if unlitMaterial != 0:
    let baseUv = transformUv(selectUv(baseColorTexCoord, uv, uv1),
      baseColorUvOffset, baseColorUvScale, baseColorUvRotation)
    var base = texture(baseColorTexture, baseUv) * baseColorFactor * color
    if opaqueMaterial != 0:
      base.a = 1.0'f
    elif alphaCutoff >= 0.0'f:
      if base.a < alphaCutoff:
        discardFragment()
      base.a = 1.0'f
    fragColor = base * tint
    # Khronos applies display transfer but no exposure or tone map to unlit.
    toneMapFlag = uint32(1)
    return
  let
    baseUv: Vec2 = transformUv(selectUv(baseColorTexCoord, uv, uv1),
      baseColorUvOffset, baseColorUvScale, baseColorUvRotation)
    mrUv: Vec2 = transformUv(selectUv(metallicRoughnessTexCoord, uv, uv1),
      metallicRoughnessUvOffset, metallicRoughnessUvScale,
      metallicRoughnessUvRotation)
    nUv: Vec2 = transformUv(selectUv(normalTexCoord, uv, uv1),
      normalUvOffset, normalUvScale, normalUvRotation)
    aoUv: Vec2 = transformUv(selectUv(occlusionTexCoord, uv, uv1),
      occlusionUvOffset, occlusionUvScale, occlusionUvRotation)
    eUv: Vec2 = transformUv(selectUv(emissiveTexCoord, uv, uv1),
      emissiveUvOffset, emissiveUvScale, emissiveUvRotation)
    base: Vec4 = texture(baseColorTexture, baseUv) * baseColorFactor * color
    mr: Vec4 = texture(metallicRoughnessTexture, mrUv)
    roughness = clamp(mr.g * roughnessFactor, 0.0'f, 1.0'f)
    metallic = clamp(mr.b * metallicFactor, 0.0'f, 1.0'f)
    ao = 1.0'f + occlusionStrength * (texture(occlusionTexture, aoUv).r - 1.0'f)
    emissive: Vec3 = texture(emissiveTexture, eUv).rgb * emissiveFactor
  var n: Vec3 = if length(normal) > 0.0'f: normalize(normal)
    else: normalize(cross(dFdx(worldPos), dFdy(worldPos)))
  if useNormalTexture:
    var t: Vec3 = tangent
    var b: Vec3 = bitangent
    if not hasVertexTangent:
      let
        dx: Vec3 = dFdx(worldPos)
        dy: Vec3 = dFdy(worldPos)
        uvDx: Vec2 = dFdx(nUv)
        uvDy: Vec2 = dFdy(nUv)
        determinant = uvDx.x * uvDy.y - uvDy.x * uvDx.y
      if abs(determinant) > 0.0000001'f:
        t = (uvDy.y * dx - uvDx.y * dy) / determinant
        t = normalize(t - n * dot(n, t))
        b = cross(n, t)
    let normalSample: Vec3 = texture(normalTexture, nUv).rgb * 2.0'f - vec3(1.0'f)
    n = normalize(normalize(t) * normalSample.x * normalScale +
      normalize(b) * normalSample.y * normalScale + n * normalSample.z)
  if not gl_FrontFacing:
    n = -n
  let
    v: Vec3 = normalize(cameraPosition - worldPos)
    nDotV = clamp(dot(n, v), 0.0'f, 1.0'f)
    brdf: Vec2 = texture(ggxLut, vec2(nDotV, roughness)).rg
    reflection: Vec3 = normalize(reflect(-v, n))
    diffuse: Vec3 = texture(diffuseEnvironment, environmentRotation * n).rgb *
      environmentMapStrength * base.rgb
    specular: Vec3 = textureLod(environmentMap, environmentRotation * reflection,
      roughness * (environmentMipCount - 1.0'f)).rgb * environmentMapStrength
    dielectric: Vec3 = mix(diffuse, specular,
      iblFresnel(nDotV, roughness, vec3(0.04'f), brdf))
    metal: Vec3 = specular * iblFresnel(nDotV, roughness, base.rgb, brdf)
  var radiance: Vec3 = mix(dielectric, metal, metallic) * ao
  # A directional key light uses the same GGX distribution/visibility as glTF.
  if sunLightColor.a > 0.0'f:
    let
      l: Vec3 = normalize(-sunLightDirection)
      h: Vec3 = normalize(v + l)
      nDotL = clamp(dot(n, l), 0.0'f, 1.0'f)
      nDotH = clamp(dot(n, h), 0.0'f, 1.0'f)
      vDotH = clamp(dot(v, h), 0.0'f, 1.0'f)
      a = max(roughness * roughness, 0.0001'f)
      a2 = a * a
      distributionDenom = nDotH * nDotH * (a2 - 1.0'f) + 1.0'f
      distribution = a2 / (ShaderPi * distributionDenom * distributionDenom)
      visibilityDenom = nDotL * sqrt(nDotV * nDotV * (1.0'f - a2) + a2) +
        nDotV * sqrt(nDotL * nDotL * (1.0'f - a2) + a2)
      visibility = if visibilityDenom > 0.0'f: 0.5'f / visibilityDenom else: 0.0'f
      f0: Vec3 = mix(vec3(0.04'f), base.rgb, metallic)
      fresnel: Vec3 = f0 + (vec3(1.0'f) - f0) * pow(1.0'f - vDotH, 5.0'f)
      direct: Vec3 = (vec3(1.0'f) - fresnel) * base.rgb * (1.0'f - metallic) / ShaderPi +
        fresnel * visibility * distribution
    radiance += direct * sunLightColor.rgb * sunLightColor.a * nDotL
  var alpha = base.a
  if opaqueMaterial != 0:
    alpha = 1.0'f
  elif alphaCutoff >= 0.0'f:
    if alpha < alphaCutoff:
      discardFragment()
    alpha = 1.0'f
  fragColor = vec4(radiance + emissive, alpha) * tint
  toneMapFlag = uint32(2)

proc hdrPostVert*(vertexPosition: Vec2, gl_Position: var Vec4, postUv: var Vec2) =
  gl_Position = vec4(vertexPosition.x, vertexPosition.y, 0.0'f, 1.0'f)
  postUv = vertexPosition * 0.5'f + vec2(0.5'f)

proc hdrPostFrag*(postUv: Vec2, fragColor: var Vec4) =
  let flag = texelFetch(toneFlags, ivec2(postUv * textureSize(hdrInput, 0)), 0).r
  let sampleValue: Vec4 = texture(hdrInput, postUv)
  var value: Vec3 = sampleValue.rgb
  if flag == uint32(2):
    value = pbrNeutral(value * exposure)
  if flag != uint32(0):
    # Match the pinned renderer's display transfer (gamma 2.2).
    value = vec3(pow(max(value.r, 0.0'f), 1.0'f / 2.2'f),
      pow(max(value.g, 0.0'f), 1.0'f / 2.2'f),
      pow(max(value.b, 0.0'f), 1.0'f / 2.2'f))
  fragColor = vec4(value, sampleValue.a)
