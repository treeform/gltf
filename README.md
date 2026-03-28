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

| Feature | Read | Render | Write | Notes |
| --- | --- | --- | --- | --- |
| `.gltf` JSON files | Yes | n/a | No | Reads external buffers and data URIs. |
| `.glb` binary files | Yes | n/a | Yes | `writeGLB` writes binary glTF 2.0. |
| Scenes and node hierarchies | Yes | Yes | Yes | Preserves names, children, and TRS transforms. |
| Primitive modes | Yes | Yes | Yes | Points, lines, strips, fans, and triangles are read and rendered. |
| Positions | Yes | Yes | Yes | `POSITION` is supported. |
| Normals | Yes | Yes | Yes | `NORMAL` is supported. |
| Tangents | Yes | Yes | No | Reads authored tangents and falls back to generated tangents when missing. |
| UV set 0 | Yes | Yes | Yes | `TEXCOORD_0` is supported. |
| UV set 1 | Yes | Yes | No | `TEXCOORD_1` is loaded and used by texture inputs with `texCoord: 1`. |
| Vertex colors | Yes | Yes | Yes | `COLOR_0` is supported. |
| Indices | Yes | Yes | Yes | Reads `uint8`, `uint16`, and `uint32`. Writes `uint8`, `uint16`, and `uint32`. |
| PBR base color | Yes | Yes | Yes | Reads texture and factor. Writes texture and factor. |
| Metallic and roughness factors | Yes | Yes | Yes | Scalar factors are read and written. |
| Metallic-roughness texture | Yes | Yes | No | Loaded and rendered, not exported yet. |
| Normal texture | Yes | Yes | No | Loaded and rendered, not exported yet. |
| Occlusion texture | Yes | Yes | No | Loaded and rendered, not exported yet. |
| Emissive texture and factor | Yes | Yes | No | Loaded and rendered, not exported yet. |
| Alpha modes | Yes | Yes | Yes | `OPAQUE`, `MASK`, and `BLEND` are supported. |
| Double-sided materials | Yes | Yes | Yes | Read and written. |
| PNG and JPEG images | Yes | Yes | Partial | Reader supports file URIs, data URIs, and buffer views. Writer embeds PNG data in GLB. |
| Sparse accessors | Partial | Partial | No | Scalar, `VEC2`, `VEC3`, `VEC4`, and quaternion paths are supported. Sparse `MAT4` is not handled yet. |
| Animations | Partial | Partial | No | Translation, rotation, scale, and morph weight channels support `STEP`, `LINEAR`, and `CUBICSPLINE`. |
| Skins | Yes | Yes | No | `JOINTS_0` and `WEIGHTS_0` are supported with GPU skinning. |
| Morph targets | Yes | Yes | No | Position, normal, and tangent targets are applied at runtime. |
| Cameras | Yes | Yes | No | Perspective and orthographic cameras are loaded from glTF. |
| `KHR_texture_transform` | Yes | Yes | No | Texture transforms and `texCoord` overrides are supported. |
| `KHR_materials_transmission` | Partial | Partial | No | Transmission factors are read and rendered, but broader extension coverage is incomplete. |
| `KHR_node_visibility` | Yes | Yes | No | Static visibility and visibility animation are supported. |
| `KHR_animation_pointer` | Partial | Partial | No | Only the visibility target path is supported. |
| `KHR_draco_mesh_compression` | No | No | No | Not supported yet. |
| `KHR_mesh_quantization` | No | No | No | Not supported yet. |
| `KHR_texture_basisu` | No | No | No | Not supported yet. |
| `KHR_lights_punctual` | No | No | No | Not supported yet. |
| `KHR_materials_unlit` | No | No | No | Not supported yet. |
| `EXT_texture_webp` | No | No | No | Not supported yet. |

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
