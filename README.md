# glTF Library and Viewer for Nim

This project provides a small glTF 2.0 toolkit for Nim.

It currently gives you three useful pieces:

- A loader that reads `.gltf` and `.glb` files into a `Node` tree.
- A small OpenGL PBR renderer that can draw that tree.
- A `writeGLB` exporter for writing a `Node` tree back to binary glTF.

The code is still a work in progress, but the current surface is already
useful for loading models, inspecting them, rendering them, and exporting
simple scenes.

## Project Layout

The project follows a simple layout:

- `src/` contains the library.
- `examples/` contains small runnable examples.
- `tools/` contains helper programs, including the viewer.
- `tests/` contains simple `doAssert` based tests.
- `experiments/` contains shader and rendering experiments.

The examples are meant to double as small docs and quick smoke tests.

## Support

The table below reflects what the code currently does today.

| Feature | Read | Write | Notes |
| --- | --- | --- | --- |
| `.gltf` JSON files | Yes | No | Reads external buffers and data URIs. |
| `.glb` binary files | Yes | Yes | `writeGLB` writes binary glTF 2.0. |
| Scenes and node hierarchies | Yes | Yes | Preserves names, children, and TRS transforms. |
| Triangle meshes | Yes | Yes | The renderer and writer assume triangle data. |
| Non-triangle primitive modes | No | No | Modes other than triangles are not handled correctly. |
| Positions | Yes | Yes | `POSITION` is supported. |
| Normals | Yes | Yes | `NORMAL` is supported. |
| UV set 0 | Yes | Yes | `TEXCOORD_0` is supported. |
| Vertex colors | Yes | Yes | `COLOR_0` is supported. |
| Indices | Yes | Partial | Reads `uint8`, `uint16`, and `uint32`. Writes `uint16` and `uint32`. |
| PBR base color | Yes | Yes | Reads texture and factor. Writes texture and factor. |
| Metallic and roughness factors | Yes | Yes | Scalar factors are read and written. |
| Metallic-roughness texture | Yes | No | Loaded and rendered, not exported yet. |
| Normal texture | Yes | No | Loaded and rendered, not exported yet. |
| Occlusion texture | Yes | No | Loaded and rendered, not exported yet. |
| Emissive texture and factor | Yes | No | Loaded and rendered, not exported yet. |
| Alpha modes | Yes | Yes | `OPAQUE`, `MASK`, and `BLEND` are supported. |
| Double-sided materials | Yes | Yes | Read and written. |
| PNG and JPEG images | Yes | Partial | Reader supports file URIs, data URIs, and buffer views. Writer embeds PNG data in GLB. |
| Animations | Partial | No | Translation, rotation, and scale clips are supported. |
| Tangents | Partial | No | Tangents are generated from normals and UVs when possible. |
| Required extensions | No | No | Unknown required extensions raise an error. |
| Skins | No | No | Not implemented yet. |
| Morph targets | No | No | Not implemented yet. |
| Cameras and lights from glTF | No | No | Not implemented yet. |

## Library Modules

The top level package exports these modules:

- `gltf/reader` for loading `.gltf` and `.glb`.
- `gltf/models` for the `Node` tree, animation helpers, bounds, and draw
  helpers.
- `gltf/pbr` for the OpenGL PBR renderer and skybox helpers.
- `gltf/writer` for `writeGLB`.
- `gltf/perf` and `gltf/shaders` for small renderer utilities.

If you only need the loader, you can import the specific modules you want
instead of pulling in everything.

## Examples

### Load A Model

The simplest example is `examples/load_model.nim`:

```sh
nim r examples/load_model.nim path/to/model.glb
```

It reads the file with `readGltfFile()` and prints a few basic facts about
the loaded scene:

- The file path.
- The root node name.
- The root child count.

This is a good first place to start if you only want to inspect loading.

### Run The Viewer

The interactive viewer lives in `tools/gltf_viewer.nim`:

```sh
nim r tools/gltf_viewer.nim path/to/model.glb
```

The viewer sets up the PBR renderer, loads the model, prints the scene
tree, computes bounds, and opens a window so you can inspect the result.

Current viewer controls:

- Middle mouse drag, or Command plus left drag, orbits the camera.
- Mouse wheel dollies in and out.
- `3` toggles whether the light follows the camera.
- `4` snaps the light position to the current camera.

This is the best way to check whether a model loads, renders, and animates
the way you expect.

## Using The Library

For simple loading, the API is small:

```nim
import gltf

let gltfFile = readGltfFile("model.glb")
let root = gltfFile.root

echo root.name
echo root.walkNodes().len
echo root.getBoundingSphere().radius
```

Useful helpers on `Node` include:

- `walkNodes()` to flatten the tree.
- `getAABounds()` and `getBoundingSphere()` for bounds.
- `updateAnimation()` to advance the active clip.
- `draw()` and `drawPbr()` style helpers for rendering.
- `dumpTree()` for quick debugging output.

To export a simple scene back to glTF binary:

```nim
import gltf

writeGLB(root, "out.glb")
```

## Tests

The project uses simple `doAssert` based tests.

Run them with:

```sh
nim r tests/tests.nim
```

Right now the tests are small. They mostly cover the basic `GltfFile`,
node walking, and bounds helpers.

## Notes

- The viewer uses `windy` and `silky`, but the loader can still be reused
  in your own engine code.
- The renderer is useful today, but it does not yet cover the full glTF
  spec.
- The writer is intentionally focused on a practical subset and currently
  targets `.glb` output only.
