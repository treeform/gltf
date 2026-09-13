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
  charlieEnvironment*: Uniform[SamplerCube]
  charlieLut*: Uniform[Sampler2d]
  sheenEnergyLut*: Uniform[Sampler2d]
  sheenEnabled*: Uniform[bool]
  sheenColorTexture*, sheenRoughnessTexture*: Uniform[Sampler2d]
  hasSheenColorTexture*, hasSheenRoughnessTexture*: Uniform[bool]
  sheenColorTexCoord*, sheenRoughnessTexCoord*: Uniform[int]
  sheenColorUvOffset*, sheenColorUvScale*, sheenRoughnessUvOffset*, sheenRoughnessUvScale*: Uniform[Vec2]
  sheenColorUvRotation*, sheenRoughnessUvRotation*: Uniform[float32]
  sheenColorFactor*: Uniform[Vec3]
  sheenRoughnessFactor*: Uniform[float32]
  specularFactor*: Uniform[float32]
  specularColorFactor*: Uniform[Vec3]
  specularTexture*, specularColorTexture*: Uniform[Sampler2d]
  hasSpecularTexture*, hasSpecularColorTexture*: Uniform[bool]
  specularTexCoord*, specularColorTexCoord*: Uniform[int]
  specularUvOffset*, specularUvScale*, specularColorUvOffset*, specularColorUvScale*: Uniform[Vec2]
  specularUvRotation*, specularColorUvRotation*: Uniform[float32]
  anisotropyEnabled*, hasAnisotropyTexture*: Uniform[bool]
  anisotropyParameters*: Uniform[Vec3] # cos(rotation), sin(rotation), strength
  anisotropyTexture*: Uniform[Sampler2d]
  anisotropyTexCoord*: Uniform[int]
  anisotropyUvOffset*, anisotropyUvScale*: Uniform[Vec2]
  anisotropyUvRotation*: Uniform[float32]
  clearcoatFactor*, clearcoatRoughnessFactor*, clearcoatNormalScale*: Uniform[float32]
  clearcoatTexture*, clearcoatRoughnessTexture*, clearcoatNormalTexture*: Uniform[Sampler2d]
  hasClearcoatTexture*, hasClearcoatRoughnessTexture*, hasClearcoatNormalTexture*: Uniform[bool]
  clearcoatTexCoord*, clearcoatRoughnessTexCoord*, clearcoatNormalTexCoord*: Uniform[int]
  clearcoatUvOffset*, clearcoatUvScale*, clearcoatRoughnessUvOffset*, clearcoatRoughnessUvScale*: Uniform[Vec2]
  clearcoatNormalUvOffset*, clearcoatNormalUvScale*: Uniform[Vec2]
  clearcoatUvRotation*, clearcoatRoughnessUvRotation*, clearcoatNormalUvRotation*: Uniform[float32]
  iridescenceFactor*, iridescenceIor*: Uniform[float32]
  iridescenceThicknessRange*: Uniform[Vec2]
  iridescenceTexture*, iridescenceThicknessTexture*: Uniform[Sampler2d]
  hasIridescenceTexture*, hasIridescenceThicknessTexture*: Uniform[bool]
  iridescenceTexCoord*, iridescenceThicknessTexCoord*: Uniform[int]
  iridescenceUvOffset*, iridescenceUvScale*: Uniform[Vec2]
  iridescenceThicknessUvOffset*, iridescenceThicknessUvScale*: Uniform[Vec2]
  iridescenceUvRotation*, iridescenceThicknessUvRotation*: Uniform[float32]
  punctualLightCount*: Uniform[int32]
  punctualLightDirections*: Uniform[array[32, Vec3]]
  punctualLightColors*: Uniform[array[32, Vec3]]
  punctualLightPositions*: Uniform[array[32, Vec3]]
  punctualLightParameters*: Uniform[array[32, Vec4]] # kind, range, inner/outer cone cosine
  transmissionBuffer*: Uniform[Sampler2d]
  transmissionTexture*, thicknessTexture*: Uniform[Sampler2d]
  transmissionTexCoord*, thicknessTexCoord*: Uniform[int]
  transmissionUvOffset*, transmissionUvScale*: Uniform[Vec2]
  thicknessUvOffset*, thicknessUvScale*: Uniform[Vec2]
  transmissionUvRotation*, thicknessUvRotation*: Uniform[float32]
  hasTransmissionTexture*, hasThicknessTexture*: Uniform[bool]
  transmissionBackground*: Uniform[bool]
  transmissionBufferLod*: Uniform[float32]
  thicknessFactor*, materialIor*, attenuationDistance*: Uniform[float32]
  attenuationColor*: Uniform[Vec3]
  volumeScale*: Uniform[Vec3]
  diffuseTransmissionFactor*: Uniform[float32]
  diffuseTransmissionColorFactor*: Uniform[Vec3]
  diffuseTransmissionTexture*, diffuseTransmissionColorTexture*: Uniform[Sampler2d]
  hasDiffuseTransmissionTexture*, hasDiffuseTransmissionColorTexture*: Uniform[bool]
  diffuseTransmissionTexCoord*, diffuseTransmissionColorTexCoord*: Uniform[int]
  diffuseTransmissionUvOffset*, diffuseTransmissionUvScale*: Uniform[Vec2]
  diffuseTransmissionColorUvOffset*, diffuseTransmissionColorUvScale*: Uniform[Vec2]
  diffuseTransmissionUvRotation*, diffuseTransmissionColorUvRotation*: Uniform[float32]

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

func iblFresnel(nDotV, roughness: float32, f0: Vec3, brdf: Vec2,
    weight: float32): Vec3 =
  let
    fr: Vec3 = vec3(max(1.0'f - roughness, f0.r),
      max(1.0'f - roughness, f0.g), max(1.0'f - roughness, f0.b)) - f0
    ks: Vec3 = f0 + fr * pow(1.0'f - nDotV, 5.0'f)
    singleScatter: Vec3 = weight * (ks * brdf.x + vec3(brdf.y))
    missingEnergy = 1.0'f - brdf.x - brdf.y
    average: Vec3 = weight * (f0 + (vec3(1.0'f) - f0) / 21.0'f)
    multipleScatter: Vec3 = missingEnergy * singleScatter * average /
      (vec3(1.0'f) - average * missingEnergy)
  result = singleScatter + multipleScatter

func sheenLambdaHelper(x, alpha: float32): float32 =
  let
    s = (1.0'f - alpha) * (1.0'f - alpha)
    a = mix(21.5473'f, 25.3245'f, s)
    b = mix(3.82987'f, 3.32435'f, s)
    c = mix(0.19823'f, 0.16801'f, s)
    d = mix(-1.97760'f, -1.27393'f, s)
    e = mix(-4.32054'f, -4.85967'f, s)
  result = a / (1.0'f + b * pow(x, c)) + d * x + e

func sheenLambda(cosTheta, alpha: float32): float32 =
  if abs(cosTheta) < 0.5'f:
    return exp(sheenLambdaHelper(cosTheta, alpha))
  result = exp(2.0'f * sheenLambdaHelper(0.5'f, alpha) -
    sheenLambdaHelper(1.0'f - cosTheta, alpha))

func sheenBrdf(nDotL, nDotV, nDotH, roughness: float32): float32 =
  # Estevez/Kulla Charlie distribution and the reference's fitted visibility.
  let
    r = max(roughness, 0.000001'f)
    alpha = r * r
    invR = 1.0'f / alpha
    distribution = (2.0'f + invR) * pow(1.0'f - nDotH * nDotH, invR * 0.5'f) /
      (2.0'f * ShaderPi)
    visibility = clamp(1.0'f / ((1.0'f + sheenLambda(nDotV, alpha) +
      sheenLambda(nDotL, alpha)) * (4.0'f * nDotV * nDotL)), 0.0'f, 1.0'f)
  result = distribution * visibility

proc sheenScaling(nDot: float32, sheenColor: Vec3, roughness: float32): float32 =
  result = 1.0'f - max(sheenColor.r, max(sheenColor.g, sheenColor.b)) *
    texture(sheenEnergyLut, vec2(nDot, roughness)).r

proc textureLod(buffer: Uniform[Sampler2d], pos: Vec2, lod: float32): Vec4 =
  ## Shady recognizes the GLSL builtin; its current CPU API only declares Cube.
  ## These IBL shaders execute on the GPU, not the CPU sampler fallback.
  vec4(0.0'f)

func iorRoughness(roughness, ior: float32): float32 =
  roughness * clamp(ior * 2.0'f - 2.0'f, 0.0'f, 1.0'f)

proc volumeRay(n, v: Vec3, thickness: float32): Vec3 =
  # GLSL refract(-v, n, 1/ior), expressed here for Shady's CPU and GPU paths.
  let eta = 1.0'f / materialIor
  let d = dot(n, -v)
  let k = 1.0'f - eta * eta * (1.0'f - d * d)
  var direction = vec3(0.0'f)
  if k >= 0.0'f:
    direction = eta * -v - (eta * d + sqrt(k)) * n
  result = safeNormalize(direction) * thickness * volumeScale

proc volumeAttenuation(radiance: Vec3, distance: float32): Vec3 =
  result = radiance
  if attenuationDistance > 0.0'f:
    let power = distance / attenuationDistance
    result = result * vec3(pow(attenuationColor.r, power), pow(attenuationColor.g, power),
      pow(attenuationColor.b, power))

proc transmittedBackground(worldPos, ray: Vec3, roughness: float32): Vec3 =
  let clip = proj * view * vec4(worldPos + ray, 1.0'f)
  let sampleUv = (clip.xy / clip.w) * 0.5'f + vec2(0.5'f)
  let level = transmissionBufferLod * iorRoughness(roughness, materialIor)
  result = volumeAttenuation(textureLod(transmissionBuffer, sampleUv, level).rgb, length(ray))

proc punctualTransmission(n, v, l: Vec3, alphaRoughness: float32): float32 =
  let mirrored: Vec3 = normalize(l + 2.0'f * n * dot(-l, n))
  let h: Vec3 = safeNormalize(mirrored + v)
  let nl = clamp(dot(n, mirrored), 0.0'f, 1.0'f)
  let nv = clamp(dot(n, v), 0.0'f, 1.0'f)
  let nh = clamp(dot(n, h), 0.0'f, 1.0'f)
  let a = iorRoughness(alphaRoughness, materialIor)
  let a2 = a * a
  let denom = nh * nh * (a2 - 1.0'f) + 1.0'f
  let visibilityDenom = nl * sqrt(nv * nv * (1.0'f - a2) + a2) +
    nv * sqrt(nl * nl * (1.0'f - a2) + a2)
  result = 0.0'f
  if denom > 0.0'f and visibilityDenom > 0.0'f:
    result = a2 / (ShaderPi * denom * denom) * 0.5'f / visibilityDenom

proc inverseNeutralForTransmission(input: Vec3): Vec3 =
  # Match the reference's approximate inverse for unlit objects in the snapshot.
  var value: Vec3 = input
  let peak = max(value.r, max(value.g, value.b))
  if peak >= 0.76'f:
    value = value * ((peak / (1.0'f - peak + 0.76'f)) / peak)
  let x = min(value.r, min(value.g, value.b))
  value = value + vec3(if x < 0.08'f: x - 6.25'f * x * x else: 0.04'f)
  if exposure > 0.0'f: value = value / exposure
  result = value

func punctualAttenuation(pointToLight, direction: Vec3, parameters: Vec4): float32 =
  result = 1.0'f
  if parameters.x > 0.0'f:
    let distance = length(pointToLight)
    result = 1.0'f / max(distance * distance, 0.000000000001'f)
    if parameters.y > 0.0'f:
      result *= clamp(1.0'f - pow(distance / parameters.y, 4.0'f), 0.0'f, 1.0'f)
  if parameters.x > 1.0'f:
    let cosine = dot(direction, -safeNormalize(pointToLight))
    var angular = 0.0'f
    if cosine > parameters.w:
      angular = 1.0'f
      if cosine < parameters.z:
        angular = (cosine - parameters.w) / (parameters.z - parameters.w)
    result *= angular * angular

func anisotropicBrdf(n, v, l, h, t, b: Vec3, alphaRoughness, strength: float32): float32 =
  let
    at = mix(alphaRoughness, 1.0'f, strength * strength)
    ab = clamp(alphaRoughness, 0.001'f, 1.0'f)
    nl = clamp(dot(n, l), 0.0'f, 1.0'f)
    nh = clamp(dot(n, h), 0.001'f, 1.0'f)
    nv = dot(n, v)
    vv = nl * length(vec3(at * dot(t, v), ab * dot(b, v), nv))
    vl = nv * length(vec3(at * dot(t, l), ab * dot(b, l), nl))
    visibility = if vv + vl > 0.0'f: clamp(0.5'f / (vv + vl), 0.0'f, 1.0'f) else: 1.0'f
    a2 = at * ab
    f: Vec3 = vec3(ab * dot(t, h), at * dot(b, h), a2 * nh)
    denominator = dot(f, f)
  result = 0.0'f
  if denominator > 0.0'f:
    let w2 = a2 / denominator
    result = visibility * a2 * w2 * w2 / ShaderPi

func clearcoatBrdf(n, v, l, h: Vec3, roughness: float32): float32 =
  let
    nl = clamp(dot(n, l), 0.0'f, 1.0'f)
    nv = clamp(dot(n, v), 0.0'f, 1.0'f)
    nh = clamp(dot(n, h), 0.0'f, 1.0'f)
    a2 = roughness * roughness * roughness * roughness
    f = nh * nh * (a2 - 1.0'f) + 1.0'f
    ggx = nl * sqrt(nv * nv * (1.0'f - a2) + a2) +
      nv * sqrt(nl * nl * (1.0'f - a2) + a2)
  result = 0.0'f
  if f > 0.0'f and ggx > 0.0'f:
    result = nl * 0.5'f / ggx * a2 / (ShaderPi * f * f)

func filmSensitivity(pathDifference: float32, shift: Vec3): Vec3 =
  # Belcour/Barla Fourier fit of XYZ sensitivity, as used by Khronos.
  let
    phase = 2.0'f * ShaderPi * pathDifference * 1.0e-9'f
    amplitude = vec3(5.4856e-13'f, 4.4201e-13'f, 5.2481e-13'f)
    position = vec3(1.6810e6'f, 1.7953e6'f, 2.2084e6'f)
    variance = vec3(4.3278e9'f, 9.3046e9'f, 6.6121e9'f)
  var xyz: Vec3 = amplitude * sqrt(2.0'f * ShaderPi * variance) *
    cos(position * phase + shift) * exp(-phase * phase * variance)
  xyz.x += 9.7470e-14'f * sqrt(2.0'f * ShaderPi * 4.5282e9'f) *
    cos(2.2399e6'f * phase + shift.x) * exp(-4.5282e9'f * phase * phase)
  xyz /= 1.0685e-7'f
  # XYZ to linear Rec.709. These are rows of the transform.
  result = vec3(dot(vec3(3.2404542'f, -1.5371385'f, -0.4985314'f), xyz),
    dot(vec3(-0.9692660'f, 1.8760108'f, 0.0415560'f), xyz),
    dot(vec3(0.0556434'f, -0.2040259'f, 1.0572252'f), xyz))

func filmFresnel(ior, cosine, thickness: float32, baseF0: Vec3): Vec3 =
  # Air / thin dielectric film / base material. Fade the first interface out
  # as film thickness approaches zero; clamp F0 before converting it to IOR.
  let
    eta = mix(1.0'f, ior, smoothstep(0.0'f, 0.03'f, thickness))
    cosine2Squared = 1.0'f - (1.0'f - cosine * cosine) / (eta * eta)
  if cosine2Squared < 0.0'f: return vec3(1.0'f)
  let
    cosine2 = sqrt(cosine2Squared)
    r0 = (eta - 1.0'f) / (eta + 1.0'f)
    r12 = r0 * r0 + (1.0'f - r0 * r0) * pow(1.0'f - cosine, 5.0'f)
    t121 = 1.0'f - r12
    sqrtF0: Vec3 = sqrt(clamp(baseF0, vec3(0.0'f), vec3(0.9999'f)))
    baseIor: Vec3 = (vec3(1.0'f) + sqrtF0) / (vec3(1.0'f) - sqrtF0)
    ratio: Vec3 = (baseIor - vec3(eta)) / (baseIor + vec3(eta))
    r1: Vec3 = ratio * ratio
    r23: Vec3 = r1 + (vec3(1.0'f) - r1) * pow(1.0'f - cosine2, 5.0'f)
    pathDifference = 2.0'f * eta * thickness * cosine2
    phi21 = if eta < 1.0'f: 0.0'f else: ShaderPi
  var phaseShift = vec3(phi21)
  if baseIor.x < eta: phaseShift.x += ShaderPi
  if baseIor.y < eta: phaseShift.y += ShaderPi
  if baseIor.z < eta: phaseShift.z += ShaderPi
  let
    r123: Vec3 = clamp(r12 * r23, vec3(0.00001'f), vec3(0.9999'f))
    amplitude: Vec3 = sqrt(r123)
    rs: Vec3 = t121 * t121 * r23 / (vec3(1.0'f) - r123)
  result = vec3(r12) + rs
  var coefficient: Vec3 = rs - vec3(t121)
  for order in 1 .. 2:
    coefficient *= amplitude
    result += coefficient * 2.0'f * filmSensitivity(order.float32 * pathDifference,
      order.float32 * phaseShift)
  result = max(result, vec3(0.0'f))

func filmMix(diffuse, specular, fresnel: Vec3): Vec3 =
  # Use the largest reflected component to avoid inverse colors in the base.
  (1.0'f - max(fresnel.r, max(fresnel.g, fresnel.b))) * diffuse + fresnel * specular

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
    if transmissionBackground:
      fragColor = vec4(inverseNeutralForTransmission(fragColor.rgb), fragColor.a)
      toneMapFlag = uint32(2)
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
  var ng: Vec3 = n
  var t: Vec3 = tangent
  var b: Vec3 = bitangent
  if useNormalTexture or anisotropyEnabled or hasClearcoatNormalTexture:
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
  if useNormalTexture:
    let normalSample: Vec3 = texture(normalTexture, nUv).rgb * 2.0'f - vec3(1.0'f)
    n = normalize(normalize(t) * normalSample.x * normalScale +
      normalize(b) * normalSample.y * normalScale + n * normalSample.z)
  if not gl_FrontFacing:
    n = -n
    ng = -ng
    t = -t
    b = -b
  var coatNormal: Vec3 = ng
  if hasClearcoatNormalTexture:
    let coatUv: Vec2 = transformUv(selectUv(clearcoatNormalTexCoord, uv, uv1),
      clearcoatNormalUvOffset, clearcoatNormalUvScale, clearcoatNormalUvRotation)
    let coatSample: Vec3 = normalize((texture(clearcoatNormalTexture, coatUv).rgb *
      2.0'f - vec3(1.0'f)) * vec3(clearcoatNormalScale, clearcoatNormalScale, 1.0'f))
    # Clearcoat uses the geometric tangent frame, independent of base normal mapping.
    coatNormal = normalize(t) * coatSample.x + normalize(b) * coatSample.y + ng * coatSample.z
  var coat = clearcoatFactor
  var coatRoughness = clearcoatRoughnessFactor
  if hasClearcoatTexture:
    let coatUv: Vec2 = transformUv(selectUv(clearcoatTexCoord, uv, uv1),
      clearcoatUvOffset, clearcoatUvScale, clearcoatUvRotation)
    coat *= texture(clearcoatTexture, coatUv).r
  if hasClearcoatRoughnessTexture:
    let coatUv: Vec2 = transformUv(selectUv(clearcoatRoughnessTexCoord, uv, uv1),
      clearcoatRoughnessUvOffset, clearcoatRoughnessUvScale, clearcoatRoughnessUvRotation)
    coatRoughness *= texture(clearcoatRoughnessTexture, coatUv).g
  coatRoughness = clamp(coatRoughness, 0.0'f, 1.0'f)
  var anisotropy = 0.0'f
  var anisotropicT: Vec3 = vec3(1.0'f, 0.0'f, 0.0'f)
  var anisotropicB: Vec3 = vec3(0.0'f, 1.0'f, 0.0'f)
  if anisotropyEnabled:
    var direction: Vec2 = vec2(1.0'f, 0.0'f)
    anisotropy = anisotropyParameters.z
    if hasAnisotropyTexture:
      let aUv: Vec2 = transformUv(selectUv(anisotropyTexCoord, uv, uv1),
        anisotropyUvOffset, anisotropyUvScale, anisotropyUvRotation)
      let sampleValue: Vec3 = texture(anisotropyTexture, aUv).rgb
      direction = sampleValue.rg * 2.0'f - vec2(1.0'f)
      anisotropy *= sampleValue.b
    direction = normalize(vec2(anisotropyParameters.x * direction.x - anisotropyParameters.y * direction.y,
      anisotropyParameters.y * direction.x + anisotropyParameters.x * direction.y))
    anisotropicT = normalize(t) * direction.x + normalize(b) * direction.y
    anisotropicB = cross(ng, anisotropicT)
    anisotropy = clamp(anisotropy, 0.0'f, 1.0'f)
  var sheenColor: Vec3 = sheenColorFactor
  var sheenRoughness = sheenRoughnessFactor
  if hasSheenColorTexture:
    let sheenUv: Vec2 = transformUv(selectUv(sheenColorTexCoord, uv, uv1),
      sheenColorUvOffset, sheenColorUvScale, sheenColorUvRotation)
    sheenColor *= texture(sheenColorTexture, sheenUv).rgb
  if hasSheenRoughnessTexture:
    let sheenUv: Vec2 = transformUv(selectUv(sheenRoughnessTexCoord, uv, uv1),
      sheenRoughnessUvOffset, sheenRoughnessUvScale, sheenRoughnessUvRotation)
    sheenRoughness *= texture(sheenRoughnessTexture, sheenUv).a
  var specularWeight = specularFactor
  var specularTint: Vec3 = specularColorFactor
  if hasSpecularTexture:
    let specularUv: Vec2 = transformUv(selectUv(specularTexCoord, uv, uv1),
      specularUvOffset, specularUvScale, specularUvRotation)
    specularWeight *= texture(specularTexture, specularUv).a
  if hasSpecularColorTexture:
    let specularUv: Vec2 = transformUv(selectUv(specularColorTexCoord, uv, uv1),
      specularColorUvOffset, specularColorUvScale, specularColorUvRotation)
    specularTint *= texture(specularColorTexture, specularUv).rgb
  let
    v: Vec3 = normalize(cameraPosition - worldPos)
    nDotV = clamp(dot(n, v), 0.0'f, 1.0'f)
    brdf: Vec2 = texture(ggxLut, vec2(nDotV, roughness)).rg
    reflection: Vec3 = normalize(reflect(-v, n))
    reflectedDiffuse: Vec3 = texture(diffuseEnvironment, environmentRotation * n).rgb *
      environmentMapStrength * base.rgb
    f0 = (materialIor - 1.0'f) / (materialIor + 1.0'f)
    dielectricF0: Vec3 = min(vec3(f0 * f0) * specularTint, vec3(1.0'f))
    coatWeight = coat * (f0 * f0 + (1.0'f - f0 * f0) *
      pow(1.0'f - clamp(dot(coatNormal, v), 0.0'f, 1.0'f), 5.0'f))
  var specularReflection: Vec3 = reflection
  if anisotropy > 0.0'f:
    # The reference's single-sample approximation keeps base roughness as LOD
    # and bends the reflection normal toward the anisotropic bitangent plane.
    let anisotropicNormal: Vec3 = cross(cross(anisotropicB, v), anisotropicB)
    let bend = 1.0'f - anisotropy * (1.0'f - roughness)
    let bentNormal: Vec3 = normalize(mix(anisotropicNormal, n, bend * bend * bend * bend))
    specularReflection = normalize(reflect(-v, bentNormal))
  let specular: Vec3 = textureLod(environmentMap, environmentRotation * specularReflection,
    roughness * (environmentMipCount - 1.0'f)).rgb * environmentMapStrength
  var transmission = transmissionFactor
  if hasTransmissionTexture:
    let transUv = transformUv(selectUv(transmissionTexCoord, uv, uv1),
      transmissionUvOffset, transmissionUvScale, transmissionUvRotation)
    transmission *= texture(transmissionTexture, transUv).r
  var thickness = thicknessFactor
  if hasThicknessTexture:
    let thickUv = transformUv(selectUv(thicknessTexCoord, uv, uv1),
      thicknessUvOffset, thicknessUvScale, thicknessUvRotation)
    thickness *= texture(thicknessTexture, thickUv).g
  var ray = vec3(0.0'f)
  var diffuse = reflectedDiffuse
  var diffuseTransmission = diffuseTransmissionFactor
  var diffuseTransmissionColor: Vec3 = diffuseTransmissionColorFactor
  if hasDiffuseTransmissionTexture:
    let dtUv = transformUv(selectUv(diffuseTransmissionTexCoord, uv, uv1),
      diffuseTransmissionUvOffset, diffuseTransmissionUvScale, diffuseTransmissionUvRotation)
    diffuseTransmission *= texture(diffuseTransmissionTexture, dtUv).a
  if hasDiffuseTransmissionColorTexture:
    let dtColorUv = transformUv(selectUv(diffuseTransmissionColorTexCoord, uv, uv1),
      diffuseTransmissionColorUvOffset, diffuseTransmissionColorUvScale, diffuseTransmissionColorUvRotation)
    diffuseTransmissionColor *= texture(diffuseTransmissionColorTexture, dtColorUv).rgb
  # The thin-surface BTDF receives diffuse light from the opposite hemisphere.
  # Volume thickness uses the mean world-axis scale, as in the reference.
  let diffuseThickness = thickness * (volumeScale.x + volumeScale.y + volumeScale.z) / 3.0'f
  if diffuseTransmission > 0.0'f:
    let backDiffuse: Vec3 = texture(diffuseEnvironment, environmentRotation * -n).rgb *
      environmentMapStrength * diffuseTransmissionColor
    diffuse = mix(diffuse, volumeAttenuation(backDiffuse, diffuseThickness), diffuseTransmission)
  if transmission > 0.0'f:
    ray = volumeRay(n, v, thickness)
    diffuse = mix(diffuse, transmittedBackground(worldPos, ray, roughness) * base.rgb, transmission)
  var iridescence = iridescenceFactor
  var filmThickness = iridescenceThicknessRange.y
  if hasIridescenceTexture:
    let filmUv: Vec2 = transformUv(selectUv(iridescenceTexCoord, uv, uv1),
      iridescenceUvOffset, iridescenceUvScale, iridescenceUvRotation)
    iridescence *= texture(iridescenceTexture, filmUv).r
  if hasIridescenceThicknessTexture:
    let filmUv: Vec2 = transformUv(selectUv(iridescenceThicknessTexCoord, uv, uv1),
      iridescenceThicknessUvOffset, iridescenceThicknessUvScale, iridescenceThicknessUvRotation)
    filmThickness = mix(iridescenceThicknessRange.x, iridescenceThicknessRange.y,
      texture(iridescenceThicknessTexture, filmUv).g)
  if filmThickness == 0.0'f: iridescence = 0.0'f
  var filmDielectric: Vec3 = vec3(0.0'f)
  var filmMetal: Vec3 = vec3(0.0'f)
  var
    dielectric: Vec3 = mix(diffuse, specular,
      iblFresnel(nDotV, roughness, dielectricF0, brdf, specularWeight))
    metal: Vec3 = specular * iblFresnel(nDotV, roughness, base.rgb, brdf, 1.0'f)
  if iridescence > 0.0'f:
    filmDielectric = filmFresnel(iridescenceIor, nDotV, filmThickness, dielectricF0)
    filmMetal = filmFresnel(iridescenceIor, nDotV, filmThickness, base.rgb)
    dielectric = mix(dielectric, filmMix(diffuse, specular, filmDielectric), iridescence)
    metal = mix(metal, specular * filmMetal, iridescence)
  var radiance: Vec3 = mix(dielectric, metal, metallic)
  if sheenEnabled:
    let sheen: Vec3 = textureLod(charlieEnvironment, environmentRotation * reflection,
      sheenRoughness * (environmentMipCount - 1.0'f)).rgb * environmentMapStrength *
      sheenColor * texture(charlieLut, vec2(nDotV, sheenRoughness)).b
    radiance = sheen + radiance * sheenScaling(nDotV, sheenColor, sheenRoughness)
  if coat > 0.0'f:
    let coatReflection: Vec3 = normalize(reflect(-v, coatNormal))
    let coatRadiance: Vec3 = textureLod(environmentMap, environmentRotation * coatReflection,
      coatRoughness * (environmentMipCount - 1.0'f)).rgb * environmentMapStrength
    radiance = mix(radiance, coatRadiance, coatWeight)
  radiance *= ao
  # Authored lights and the optional key light share the same BRDF/BTDF.
  for lightIndex in 0 ..< 33:
    var lightDirection: Vec3 = sunLightDirection
    var lightColor: Vec3 = sunLightColor.rgb * sunLightColor.a
    var pointToLight: Vec3 = -lightDirection
    var lightParameters: Vec4 = vec4(0.0'f)
    if lightIndex > 0:
      if lightIndex > punctualLightCount: break
      lightDirection = punctualLightDirections[lightIndex - 1]
      lightColor = punctualLightColors[lightIndex - 1]
      lightParameters = punctualLightParameters[lightIndex - 1]
      pointToLight = -lightDirection
      if lightParameters.x > 0.0'f:
        pointToLight = punctualLightPositions[lightIndex - 1] - worldPos
    if max(lightColor.r, max(lightColor.g, lightColor.b)) > 0.0'f:
      let
        lightAttenuation = punctualAttenuation(pointToLight, lightDirection, lightParameters)
        l: Vec3 = safeNormalize(pointToLight)
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
        schlick = pow(1.0'f - vDotH, 5.0'f)
        metalFresnel: Vec3 = base.rgb + (vec3(1.0'f) - base.rgb) * schlick
        # In the reference, refraction shifts the point used for the analytic
        # specular light intensity; the diffuse/BTDF intensity is from entry.
        exitAttenuation = punctualAttenuation(pointToLight - ray, lightDirection, lightParameters)
      var specularBrdf: Vec3 = vec3(visibility * distribution * exitAttenuation)
      if anisotropyEnabled:
        specularBrdf = vec3(anisotropicBrdf(n, v, l, h, anisotropicT, anisotropicB,
          roughness * roughness, anisotropy) * exitAttenuation)
      var dielectricFresnel: Vec3 = specularWeight * (dielectricF0 +
        (vec3(1.0'f) - dielectricF0) * schlick)
      var backDiffuse: Vec3 = vec3(0.0'f)
      if diffuseTransmission > 0.0'f and dot(n, l) < 0.0'f:
        let mirrored: Vec3 = normalize(l + 2.0'f * n * dot(-l, n))
        let diffuseVdotH = clamp(dot(v, normalize(mirrored + v)), 0.0'f, 1.0'f)
        dielectricFresnel = specularWeight * (dielectricF0 +
          (vec3(1.0'f) - dielectricF0) * pow(1.0'f - diffuseVdotH, 5.0'f))
        backDiffuse = volumeAttenuation(diffuseTransmissionColor *
          clamp(dot(-n, l), 0.0'f, 1.0'f) / ShaderPi, diffuseThickness)
      var direct: Vec3 = mix(mix(base.rgb / ShaderPi * (1.0'f - diffuseTransmission) * lightAttenuation,
        specularBrdf, dielectricFresnel),
        metalFresnel * specularBrdf, metallic)
      var throughLight = backDiffuse * diffuseTransmission * (1.0'f - transmission) *
        (vec3(1.0'f) - dielectricFresnel) * (1.0'f - metallic) * lightAttenuation
      if transmission > 0.0'f:
        let transmissionLight = volumeAttenuation(base.rgb *
          punctualTransmission(n, v, safeNormalize(pointToLight - ray), a), length(ray))
        throughLight += (transmissionLight - base.rgb / ShaderPi * nDotL *
          (1.0'f - diffuseTransmission)) * transmission *
          (vec3(1.0'f) - dielectricFresnel) * (1.0'f - metallic) * lightAttenuation
      if iridescence > 0.0'f:
        var incidentDiffuse: Vec3 = (base.rgb / ShaderPi * nDotL * (1.0'f - diffuseTransmission) +
          backDiffuse * diffuseTransmission) * lightAttenuation
        if transmission > 0.0'f:
          let transmitted: Vec3 = volumeAttenuation(base.rgb *
            punctualTransmission(n, v, safeNormalize(pointToLight - ray), a), length(ray))
          incidentDiffuse = mix(incidentDiffuse, transmitted * lightAttenuation, transmission)
        let filmDirect: Vec3 = mix(filmMix(incidentDiffuse, specularBrdf * nDotL, filmDielectric),
          specularBrdf * nDotL * filmMetal, metallic)
        direct *= 1.0'f - iridescence
        throughLight = throughLight * (1.0'f - iridescence) + filmDirect * iridescence
      if sheenEnabled:
        direct = sheenColor * sheenBrdf(nDotL, nDotV, nDotH, sheenRoughness) * exitAttenuation +
          direct * min(sheenScaling(nDotV, sheenColor, sheenRoughness), sheenScaling(nDotL, sheenColor, sheenRoughness))
        throughLight *= min(sheenScaling(nDotV, sheenColor, sheenRoughness), sheenScaling(nDotL, sheenColor, sheenRoughness))
      if coat > 0.0'f:
        let coatDirect = clearcoatBrdf(coatNormal, v, safeNormalize(pointToLight - ray), h,
          coatRoughness) * exitAttenuation
        radiance += mix(direct * nDotL + throughLight, vec3(coatDirect), coatWeight) * lightColor
      else:
        radiance += direct * lightColor * nDotL
        radiance += throughLight * lightColor
  var alpha = base.a
  if opaqueMaterial != 0:
    alpha = 1.0'f
  elif alphaCutoff >= 0.0'f:
    if alpha < alphaCutoff:
      discardFragment()
    alpha = 1.0'f
  fragColor = vec4(radiance + emissive * (1.0'f - coatWeight), alpha) * tint
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
