import
  shady, vmath, pixie,
  ../common

const
  IblSamplerNames* = [
    "baseColorTexture",
    "metallicRoughnessTexture",
    "normalTexture",
    "occlusionTexture",
    "emissiveTexture",
    "environmentMap",
    "",
    "diffuseEnvironment",
    "ggxLut",
    "charlieEnvironment",
    "charlieLut",
    "sheenEnergyLut",
    "transmissionBuffer",
    "transmissionTexture",
    "thicknessTexture",
    "diffuseTransmissionTexture",
    "diffuseTransmissionColorTexture",
    "anisotropyTexture",
    "clearcoatTexture",
    "clearcoatRoughnessTexture",
    "clearcoatNormalTexture",
    "iridescenceTexture",
    "iridescenceThicknessTexture",
    "specularTexture",
    "specularColorTexture",
    "sheenColorTexture",
    "sheenRoughnessTexture",
    "diffuseTexture",
    "specularGlossinessTexture",
  ]

type IblTextureMask* = uint32

proc includes*(mask: IblTextureMask, unit: int): bool =
  ## Returns whether a logical texture slot is required by this material.
  (mask and (1'u32 shl unit)) != 0

proc neutralTexture(image: Image, compressed: string): bool =
  ## Folds only an actual white texel, including caller-replaced placeholders.
  image != nil and compressed.len == 0 and image.width == 1 and
    image.height == 1 and image.data[0] == rgbx(255, 255, 255, 255)

proc textureMask*(material: Material): IblTextureMask =
  ## Selects authored textures and the lighting resources used by a material.
  if material == nil:
    return 0
  template enable(unit: int, condition: bool) =
    ## Adds a logical slot only when its material input is active.
    if condition:
      result = result or (1'u32 shl unit)
  enable(0, (material.baseColor != nil or material.baseColorKtx2.len > 0) and
    not neutralTexture(material.baseColor, material.baseColorKtx2))
  enable(1, (material.metallicRoughness != nil or
      material.metallicRoughnessKtx2.len > 0) and
    not neutralTexture(
      material.metallicRoughness,
      material.metallicRoughnessKtx2
    ) and not material.unlit)
  enable(2, (material.normal != nil or material.normalKtx2.len > 0) and
    material.hasNormalTexture and not material.unlit)
  enable(3, (material.occlusion != nil or material.occlusionKtx2.len > 0) and
    not neutralTexture(material.occlusion, material.occlusionKtx2) and
        not material.unlit)
  enable(4, (material.emissive != nil or material.emissiveKtx2.len > 0) and
    not neutralTexture(material.emissive, material.emissiveKtx2) and
        not material.unlit)
  enable(5, not material.unlit)
  enable(7, not material.unlit)
  enable(8, not material.unlit)
  enable(9, not material.unlit and material.sheenColorFactor != vec3(0))
  enable(10, not material.unlit and material.sheenColorFactor != vec3(0))
  enable(11, not material.unlit and material.sheenColorFactor != vec3(0))
  enable(12, not material.unlit and (material.hasTransmission or
    material.transmissionFactor > 0))
  enable(13, (material.transmission != nil or material.transmissionKtx2.len >
      0) and not material.unlit)
  enable(14, (material.thickness != nil or material.thicknessKtx2.len > 0) and
      not material.unlit)
  enable(15, (material.diffuseTransmission != nil or
      material.diffuseTransmissionKtx2.len > 0) and not material.unlit)
  enable(16, (material.diffuseTransmissionColor != nil or
      material.diffuseTransmissionColorKtx2.len > 0) and not material.unlit)
  enable(17, (material.anisotropy != nil or material.anisotropyKtx2.len > 0) and
      not material.unlit)
  enable(18, (material.clearcoat != nil or material.clearcoatKtx2.len > 0) and
      not material.unlit)
  enable(19, (material.clearcoatRoughness != nil or
      material.clearcoatRoughnessKtx2.len > 0) and not material.unlit)
  enable(20, (material.clearcoatNormal != nil or
      material.clearcoatNormalKtx2.len > 0) and not material.unlit)
  enable(21, (material.iridescence != nil or material.iridescenceKtx2.len >
      0) and not material.unlit)
  enable(22, (material.iridescenceThickness != nil or
      material.iridescenceThicknessKtx2.len > 0) and not material.unlit)
  enable(23, (material.specular != nil or material.specularKtx2.len > 0) and
      not material.unlit)
  enable(24, (material.specularColor != nil or material.specularColorKtx2.len >
      0) and not material.unlit)
  enable(25, (material.sheenColor != nil or material.sheenColorKtx2.len > 0) and
      not material.unlit)
  enable(26, (material.sheenRoughness != nil or
      material.sheenRoughnessKtx2.len > 0) and not material.unlit)
  enable(27, (material.diffuse != nil or material.diffuseKtx2.len > 0) and
      not material.unlit)
  enable(28, (material.specularGlossiness != nil or
      material.specularGlossinessKtx2.len > 0) and not material.unlit)

proc specializeIbl*(source: string, mask: IblTextureMask): string =
  ## Removes absent texture reads so shaders fit the device sampler budget.
  var excluded: seq[string]
  for unit, name in IblSamplerNames:
    if name.len > 0 and not mask.includes(unit):
      excluded.add(name)
  replaceTextureReads(source, excluded)
