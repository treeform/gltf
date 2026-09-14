# Khronos reference captures

All reference images live in `tests/reference/images/`. There is one catalog:

- `tests/reference/manifest.json` selects 149 model files and 301 captures.
- `tests/reference/images/<case-id>.png` contains each reference image once.
- `tests/reference/run.json` records renderer provenance and image hashes.
- `tests/reference/index.html` displays the reference gallery.

The catalog includes rest poses, animation timestamps and selected scenes.
ABeautifulGame is excluded because it is slow and adds little coverage.
Use filters for focused work against the same manifest and images.

## Compare

From `tools/reference`:

```sh
# Compare all 301 captures against the saved references.
npm run compare -- --strict

# Select the graphics backend.
npm run compare -- --strict --backend=metal
npm run compare -- --strict --backend=directx
npm run compare -- --strict --backend=vulkan

# Compare one model, or several name fragments, using the same references.
npm run compare -- --strict --case=SimpleMorph
npm run compare -- --strict --case=MandarinOrange,DiffuseTransmissionTeacup

# Keep a focused report in its own temporary output directory.
npm run compare -- --case=Avocado --out=../../tests/tmp/reference-avocado

# Reuse the compiled harness when its source has not changed.
npm run compare -- --no-build --strict
```

`--backend` defaults to `opengl`. Other backends use separate executables,
build caches and report directories. Metal requires macOS. DirectX and the
current Vulkan backend require Windows. Every metrics record identifies the
actual backend, and `--no-build` rejects the wrong backend executable.

The OpenGL report is `tests/tmp/reference/xray_report.html`. Metal, DirectX
and Vulkan default to `reference-metal`, `reference-directx` and
`reference-vulkan` under `tests/tmp`. Each output includes `overview_card.png`,
`metrics.json`, `implementation.json`, `nim-run.log`, and generated/Xray images.
These are native comparison outputs; the shared references stay in
`tests/reference/images/`. Native windows are hidden in manifest mode.

Add `--commit=COMMIT_HASH` to link a report to a verified clean implementation
commit. `--legacy` compares the earlier lighting profile for diagnosis.

The package selects Shady's `gltf-backend-parity` branch and vk14's
`gltf-anisotropic-sampling` branch. Keep existing sibling checkouts on compatible
revisions. All material, HDR presentation and mip shaders are authored in Nim
and generated through Shady. Backend code manages resources and render passes.
Vulkan uses `glslangValidator`, or `SHADY_SPIRV_COMPILER`, to compile SPIR-V.
`-d:shadyBinaryShaders` uses the checked-in binaries; rebuild them from the
repository root with `nim r tools/build_backend_shaders.nim`.

## Capture

```sh
# Refresh the catalog, checking every image twice for repeatability.
npm run capture -- --verify

# Refresh one model or an exact case ID in the shared image folder.
npm run capture -- --models=SimpleMorph --verify
npm run capture -- --cases=Fox__a2_t0p428583 --verify

# Refit a model's shared camera across all its poses, then recapture it.
npm run capture -- --models=SimpleMorph --refit --verify

# Explicitly replace the complete manifest and fit all catalog cameras.
npm run manifest -- --force --verify
```

A focused capture replaces only selected images and retains the other capture
records, including their original browser/GPU provenance. It requires the
existing run to match the manifest and source revisions. If those changed
outside `--refit`, recapture the complete catalog. `--init` always creates the
complete catalog and refuses to overwrite an existing manifest without
`--force`. The native harness rejects baseline updates in manifest mode.

Capture writes directly from the pinned renderer's canvas. `--verify` captures
the same pose twice and compares hashes. `--report-only` rebuilds the gallery
from an existing capture record. `--out` can place diagnostic captures under
`tests/tmp` without changing the saved reference images.

## Setup and provenance

Requires Node.js, Git, Nim and the library's Nim dependencies. From
`tools/reference`, on POSIX shells:

```sh
PUPPETEER_CACHE_DIR="$PWD/.cache/puppeteer" npm ci
npm run setup
```

In PowerShell, set `$env:PUPPETEER_CACHE_DIR = "$PWD/.cache/puppeteer"` before
`npm ci`. Setup clones the source repositories beside `gltf` when absent,
builds the reference renderer, and downloads the studio HDR and Draco decoder.
Existing checkouts must be clean and match `sources.json`; setup never resets
them. Override their locations with `GLTF_REFERENCE_RENDERER` and
`GLTF_SAMPLE_ASSETS`.

Export the shared lighting before the first native comparison. This focused
capture can use a temporary output folder and leaves the saved masters intact:

```sh
npm run capture -- --models=OrientationTest --export-environment --verify --out=../../tests/tmp/environment-export
```

The export reads the actual diffuse/specular/sheen cubemaps and lookup textures
from Khronos's GPU resources. Linear RGBA float data, source revisions, GPU
information and hashes are saved under `.cache/ibl`. Comparison verifies these
hashes and the manifest/PNG hashes before rendering. It rejects incomplete or
duplicate native capture lists. `npm test` also checks that the image directory
contains exactly the catalog's recorded masters.

References use the [Treeform glTF-Sample-Renderer fork](https://github.com/treeform/glTF-Sample-Renderer)
at `818318c0b09334998bea39766d88c2d58a76a2f6`, based on upstream `863b981`.
The fork fixes the duplicate mesh transform on skinned normals and tangents,
disables face culling in the final tone-map pass, and decodes specular/glossiness
RGB as sRGB while keeping alpha linear. All three fixes have WebGL regressions.
World-space skinning and zero-scaled mesh handling are retained.

Capture serves local resources over loopback HTTP and launches a dedicated
headless Chrome through Puppeteer. GPU/driver differences can produce small
pixel differences. `--software` explicitly selects SwiftShader when hardware
WebGL is unavailable. Sources and environment provenance are in the manifest.
The neutral HDR is copyright 2020 Amazon, LLC under CC-BY-4.0. Model attribution
is in each sample's `metadata.json`; the external Khronos renderer is Apache-2.0.

## Cameras and timing

Each manifest case records a model path, scene, animation indices, absolute
seconds and an explicit perspective camera. Its ID is the PNG filename.
Both renderers sample the same absolute time, including initialization frames;
physics, interactivity and frame-rate-dependent animation are disabled.

Camera fitting measures vertices after morphing, skinning and instancing over
all sampled poses. It keeps one camera per scene with an 8-pixel margin,
20-degree yaw/pitch and 45-degree FOV. `--refit` retains the viewing direction
and animation times. Samples include 0%, 37%, 73% and 137% of each animation's
end time, with the last exercising looping. Explicit camera overrides and
additional timestamps can be entered in the manifest.

## Reports and coverage

The overview shows one generated/Xray tile pair per source file, ordered by
its worst capture score. Clicking a tile opens that file's detailed comparisons.
All poses remain together in manifest order. Missing, skipped or failed
comparisons appear first. The detailed report includes every capture.

Metrics include differing RGB pixels, pixels within two values in every
channel, mean absolute error, RMSE, maximum channel error and the Pixie score.
Images are compared without alignment or resizing, including the background.
Xray green means native rendering is darker, blue means brighter, and red marks
alpha differences. Equal-brightness hue changes can cancel in the Xray image;
the numerical RGB metrics do not cancel.

The pass threshold remains 2%. `--strict` returns a failure for visual threshold
misses, while capture/compare errors always fail. Passing is image regression
coverage, not identical pixels or full glTF conformance.

The Windows catalog passes 301/301 on OpenGL, DirectX and Vulkan, with worst
Pixie scores of 0.8974%, 0.8953% and 0.9427%. macOS OpenGL and Metal each pass
301/301 with a worst score of 0.9096%. See `docs/macos-parity.md` for Mac details.

All four backends share neutral HDR lighting, 90-degree environment rotation,
exposure 1, linear material evaluation, GGX IBL and PBR Neutral tone mapping.
Color textures use sRGB formats; data maps remain linear. Compatible material
samplers use anisotropic filtering. DirectX/Vulkan color mipmaps are averaged
in linear light, with straight RGB and independently averaged alpha.

The shared material shader includes transmission, volume/IOR, diffuse
transmission, punctual lights, emissive strength, anisotropy, clearcoat,
iridescence, specular, sheen and legacy specular/glossiness. Unlit materials
retain their separate display-transfer behavior. Transmission samples a
same-frame 1024-square RGBA8 background with 4x MSAA and mipmaps. It cannot see
other glass in that snapshot or off-screen objects; chromatic dispersion is
not implemented by this pass. Selected scenes do not establish complete
extension coverage. The DirectX/Vulkan IBL path is not validated for KTX2
uploads, skybox presentation, fog or shadows.

`tests/ibl_pipeline.nim`, `tests/unlit_pipeline.nim` and
`tests/transmission_pipeline.nim` exercise real OpenGL tone mapping, alpha
modes, texture inputs and material behavior. Core tests cover parsing and GLB
round trips. Shady's Metal regression exercises the actual Apple compiler.

For tangent diagnosis, `node tangent-probe.mjs` compares isolated helmet
copies with Khronos-generated and reversed tangents. Add `--browser-jpegs`
to compare browser-decoded textures. Build the native harness first. Probe
outputs stay under `tests/tmp/tangent-probe`; saved references are not edited.
