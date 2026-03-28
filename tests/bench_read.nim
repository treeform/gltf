import
  benchy,
  gltf

proc benchmarkLoad(tag, path: string) =
  ## Benchmarks loading one glTF asset.
  timeIt tag:
    discard readGltfFile(path)

echo "Benchmarking GLB load times."

benchmarkLoad(
  "DamagedHelmet.glb",
  "../glTF-Sample-Assets/Models/DamagedHelmet/glTF-Binary/DamagedHelmet.glb"
)
benchmarkLoad(
  "CarConcept.glb",
  "../glTF-Sample-Assets/Models/CarConcept/glTF-Binary/CarConcept.glb"
)
benchmarkLoad(
  "BrainStem.glb",
  "../glTF-Sample-Assets/Models/BrainStem/glTF-Binary/BrainStem.glb"
)
benchmarkLoad(
  "Corset.glb",
  "../glTF-Sample-Assets/Models/Corset/glTF-Binary/Corset.glb"
)
benchmarkLoad(
  "WaterBottle.glb",
  "../glTF-Sample-Assets/Models/WaterBottle/glTF-Binary/WaterBottle.glb"
)
