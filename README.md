<img src="docs/gltf.png">

# gltf - glTF library and viewer for Nim.

`nimby install gltf`

![Github Actions](https://github.com/treeform/gltf/workflows/Github%20Actions/badge.svg)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/treeform/gltf)
![GitHub Repo stars](https://img.shields.io/github/stars/treeform/gltf)
![GitHub](https://img.shields.io/github/license/treeform/gltf)
![GitHub issues](https://img.shields.io/github/issues/treeform/gltf)

[API reference](https://treeform.github.io/gltf)

## About

`gltf` is a small glTF 2.0 toolkit for Nim. It can load `.gltf` and
`.glb` files into a `Node` tree, render that tree with a small OpenGL PBR
pipeline, and write simple scenes back out as `.glb`.

The project is still growing, but it is already useful for:

- Loading glTF models in Nim code.
- Inspecting models with a local viewer.
- Rendering models with a simple PBR path.
- Exporting simple scenes back to binary glTF.

### Documentation

- API reference: [treeform.github.io/gltf](https://treeform.github.io/gltf)
- Source entry point: `src/gltf.nim`
- Example program: `examples/load_model.nim`
- Viewer tool: `tools/gltf_viewer.nim`

## Installation

Install the package with:

```sh
nimby install gltf
```

The package depends on:

- `vmath`
- `chroma`
- `pixie`
- `flatty`
- `opengl`
- `webby`
- `windy`
- `silky`

## Support

The table below reflects the current code, not the full glTF 2.0 spec.

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

## Usage

For simple loading:

```nim
import gltf

let gltfFile = readGltfFile("model.glb")
let root = gltfFile.root

echo root.name
echo root.walkNodes().len
echo root.getBoundingSphere().radius
```

Useful helpers on `Node` include:

- `walkNodes()`
- `getAABounds()`
- `getBoundingSphere()`
- `updateAnimation()`
- `dumpTree()`

To write a simple scene back to binary glTF:

```nim
import gltf

writeGLB(root, "out.glb")
```

## Examples

The repository includes a small example loader:

```sh
nim r examples/load_model.nim path/to/model.glb
```

It uses `readGltfFile()` and prints:

- The source file path.
- The root node name.
- The root child count.

This is the simplest way to verify that loading works.

## Viewer

The interactive viewer lives in `tools/gltf_viewer.nim`:

```sh
nim r tools/gltf_viewer.nim path/to/model.glb
```

It sets up the PBR renderer, loads the file, prints the node tree,
computes bounds, and opens a window for inspection.

Current controls:

- Middle mouse drag, or Command plus left drag, orbit the camera.
- Mouse wheel dollies in and out.
- `3` toggles light follow camera.
- `4` sets the light to the current camera position.

## Project Layout

- `src/` contains the library modules.
- `examples/` contains small runnable examples.
- `tools/` contains helper programs such as the viewer.
- `tests/` contains simple `doAssert` based tests.
- `experiments/` contains rendering experiments and shader work.

## Development

The project includes standard build and docs workflows:

- `.github/workflows/build.yml`
- `.github/workflows/docs.yml`

Run the checks locally with:

```sh
nim check src/gltf.nim
nim r tests/tests.nim
```

## License

This project uses the MIT license. See `LICENSE`.
