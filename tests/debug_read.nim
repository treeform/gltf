import
  std/times,
  gltf,
  "../../fluffy/src/fluffy/measure"

let start = epochTime()

startTrace()
discard readGltfFile("../glTF-Sample-Assets/Models/DamagedHelmet/glTF-Binary/DamagedHelmet.glb")
endTrace()
dumpMeasures("tests/tmp/debug_read_trace.json")

let finish = epochTime()

echo "Time: ", finish - start
