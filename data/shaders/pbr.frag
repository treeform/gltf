#version 410 core

const float PI = 3.1415926535897932384626433832795;

in vec3 position;
in vec4 color;
in vec3 normal;
in vec2 uv;
in mat3 TBN;
in vec4 vPosLightSpace;

uniform mat4 model;

uniform sampler2D baseColorTexture;
uniform vec4 baseColorFactor;
uniform vec2 baseColorUvOffset;
uniform vec2 baseColorUvScale;
uniform float baseColorUvRotation;
uniform sampler2D metallicRoughnessTexture;
uniform float metallicFactor;
uniform float roughnessFactor;
uniform vec2 metallicRoughnessUvOffset;
uniform vec2 metallicRoughnessUvScale;
uniform float metallicRoughnessUvRotation;
uniform sampler2D normalTexture;
uniform float normalScale;
uniform vec2 normalUvOffset;
uniform vec2 normalUvScale;
uniform float normalUvRotation;
uniform sampler2D occlusionTexture;
uniform float occlusionStrength;
uniform vec2 occlusionUvOffset;
uniform vec2 occlusionUvScale;
uniform float occlusionUvRotation;
uniform sampler2D emissiveTexture;
uniform vec3 emissiveFactor;
uniform vec2 emissiveUvOffset;
uniform vec2 emissiveUvScale;
uniform float emissiveUvRotation;
uniform samplerCube environmentMap;
uniform sampler2DShadow shadowMap;

uniform mat4 lightSpace;
uniform bool useShadow = false;
uniform bool useNormalTexture = false;

uniform float alphaCutoff;

uniform vec4 ambientLightColor;
uniform vec3 sunLightDirection;
uniform vec4 sunLightColor;
uniform vec3 rimLightDirection;
uniform vec4 rimLightColor;
uniform vec3 cameraPosition;
uniform int debugViewMode = 0;
uniform float shadowBias = 0.0015;
uniform float shadowKernelRadius = 2.0; // in texels

out vec4 fragColor;

vec2 toSphericalUv(vec3 v) {
  // Convert cartesian coordinates to spherical coordinates in the range [0, 1]
  float phi = atan(v.z, v.x);
  float theta = acos(v.y);
  return vec2(phi / (2.0 * PI) + 0.5, theta / PI);
}

float sampleShadow(vec4 posLightSpace, vec3 normal, vec3 lightDir) {
  if (!useShadow) return 0.0;
  vec3 projCoords = posLightSpace.xyz / posLightSpace.w;
  projCoords = projCoords * 0.5 + 0.5;
  if (projCoords.z > 1.0 || projCoords.x < 0.0 || projCoords.x > 1.0 || projCoords.y < 0.0 || projCoords.y > 1.0) {
    return 0.0;
  }
  float bias = max(shadowBias, 0.002 * (1.0 - dot(normal, lightDir)));
  vec2 texelSize = 1.0 / textureSize(shadowMap, 0);
  float total = 0.0;
  float weightSum = 0.0;
  for (int x = -2; x <= 2; ++x) {
    for (int y = -2; y <= 2; ++y) {
      float wx = 1.0 - abs(float(x)) * 0.25;
      float wy = 1.0 - abs(float(y)) * 0.25;
      float w = wx * wy;
      vec2 offset = vec2(x, y) * texelSize;
      float lit = texture(shadowMap, vec3(projCoords.xy + offset, projCoords.z - bias));
      total += w * lit;
      weightSum += w;
    }
  }
  float litAvg = total / weightSum;
  return 1.0 - litAvg;
}

vec2 transformUv(vec2 uv, vec2 offset, vec2 scale, float rotation) {
  float c = cos(rotation);
  float s = sin(rotation);
  mat2 rot = mat2(c, -s, s, c);
  return rot * (uv * scale) + offset;
}

void main() {
  vec2 baseColorUv = transformUv(
    uv,
    baseColorUvOffset,
    baseColorUvScale,
    baseColorUvRotation
  );
  vec2 metallicRoughnessUv = transformUv(
    uv,
    metallicRoughnessUvOffset,
    metallicRoughnessUvScale,
    metallicRoughnessUvRotation
  );
  vec2 normalUv = transformUv(
    uv,
    normalUvOffset,
    normalUvScale,
    normalUvRotation
  );
  vec2 occlusionUv = transformUv(
    uv,
    occlusionUvOffset,
    occlusionUvScale,
    occlusionUvRotation
  );
  vec2 emissiveUv = transformUv(
    uv,
    emissiveUvOffset,
    emissiveUvScale,
    emissiveUvRotation
  );

  fragColor.rgba = texture(baseColorTexture, baseColorUv).rgba;
  fragColor *= baseColorFactor;
  fragColor *= color;
  if (fragColor.a < alphaCutoff) {
    discard; // Discard pixel if alpha is below cutoff
  }

  // PBR parameters
  vec3 albedo = fragColor.rgb;
  float roughness =
    texture(metallicRoughnessTexture, metallicRoughnessUv).g *
    roughnessFactor;
  float metallic =
    texture(metallicRoughnessTexture, metallicRoughnessUv).b *
    metallicFactor;
  float ambientOcclusion =
    texture(occlusionTexture, occlusionUv).g *
    occlusionStrength;
  vec3 emissiveValue = texture(emissiveTexture, emissiveUv).rgb * emissiveFactor;

  // Triangle normal fallback for missing normal maps and debug views.
  vec3 triangleNormal = normalize(cross(dFdx(position), dFdy(position)));
  if (!gl_FrontFacing) {
    triangleNormal = -triangleNormal;
  }

  // Normal mapping
  vec3 normalValue = texture(normalTexture, normalUv).rgb;
  normalValue = normalize(normalValue * 2.0 - 1.0) * normalScale;
  vec3 mappedNormal = normalize(TBN * normalValue);
  vec3 computedNormal = useNormalTexture ? mappedNormal : triangleNormal;

  // Calculate lighting
  vec3 sunDir = normalize(-sunLightDirection);
  vec3 rimDir = normalize(-rimLightDirection);
  vec3 viewDir = normalize(cameraPosition - position);
  vec3 reflectDir = reflect(-viewDir, computedNormal);
  vec3 halfVector = normalize(viewDir + sunDir);
  float NdotH = max(dot(computedNormal, halfVector), 0.0);
  float NdotL = max(dot(computedNormal, sunDir), 0.0);

  // Fresnel-Schlick approximation
  const vec3 F0 = vec3(0.04); // Base Reflectance at Normal Incidence
  vec3 F0mix = mix(F0, albedo, metallic);
  float cosTheta = max(dot(computedNormal, viewDir), 0.0);
  vec3 fresnel = F0mix + (1.0 - F0mix) * pow(1.0 - cosTheta, 5.0);
  float specComponent = NdotL * pow(NdotH, 2.0 / (roughness + 0.0001));
  vec3 specular =
    sunLightColor.rgb *
    sunLightColor.a *
    fresnel *
    specComponent;

  // Diffuse lighting
  vec3 diffuse =
    sunLightColor.rgb *
    sunLightColor.a *
    (1.0 - metallic) *
    albedo *
    NdotL;

  // Shadow
  float shadow = sampleShadow(vPosLightSpace, computedNormal, sunDir);

  float rim =
    pow(1.0 - max(dot(computedNormal, viewDir), 0.0), 2.5) *
    (1.0 - metallic);
  float rimFacing = max(dot(computedNormal, rimDir), 0.0);
  vec3 rimLight =
    rimLightColor.rgb *
    rimLightColor.a *
    rim *
    (0.15 + 0.85 * rimFacing) *
    (0.15 + 0.35 * ambientOcclusion);

  // Environment mapping
  // Calculate mipmap level based on roughness to simulate blurry reflections.
  // Calculate mipmap level from roughness (textureQueryLevels not in GLSL 410).
  float envMapSize = float(textureSize(environmentMap, 0).x);
  float maxMipLevel = floor(log2(envMapSize));
  float mipLevel = roughness * maxMipLevel;
  // Sample the environment map with the calculated mipmap level
  vec3 envColor = textureLod(environmentMap, reflectDir, mipLevel).rgb;

  if (debugViewMode == 1) {
    fragColor.rgb = albedo;
    return;
  }

  if (debugViewMode == 2) {
    fragColor.rgb = computedNormal * 0.5 + 0.5;
    return;
  }

  if (debugViewMode == 3) {
    fragColor.rgb = vec3(ambientOcclusion);
    return;
  }

  if (debugViewMode == 4) {
    fragColor.rgb = vec3(metallic);
    return;
  }

  if (debugViewMode == 5) {
    float specularMap =
      clamp(
        dot(F0mix, vec3(0.3333333)) *
        (1.0 - roughness * 0.5),
        0.0,
        1.0
      );
    fragColor.rgb = vec3(specularMap);
    return;
  }

  // Combine light output
  vec3 direct = (specular + diffuse) * (1.0 - shadow);
  vec3 Lo =
    direct +
    ambientLightColor.rgb * ambientLightColor.a * ambientOcclusion +
    rimLight;

  // Reflective color blended with direct lighting
  fragColor.rgb = mix(Lo, envColor, fresnel * metallic);

  // Emissive
  fragColor.rgb += emissiveValue;

}
