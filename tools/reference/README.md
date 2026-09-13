# Khronos reference captures

The default loop is **five images**, one each from AnimatedCube, DamagedHelmet,
Fox, OrientationTest and SimpleMorph. Three sample animations after time zero.
The optional `tests/reference/manifest-25.json` adds rest poses and multiple
timestamps for every animation of those same five models. ABeautifulGame is
excluded because it is slow and adds little coverage. Full-catalog generation
requires the explicit `--all-models` flag; it is not part of normal iteration.

## Quick iteration

From `tools/reference`:

```sh
# Build the Nim harness, render the five cases, and write the comparison report.
npm run compare

# Reuse the compiled harness when only the manifest or models changed.
npm run compare -- --no-build

# Capture only one model's cases while working on it.
npm run compare -- --case=SimpleMorph

# Recreate the five official references, checking each twice for repeatability.
npm run capture -- --verify

# Export the shared, filtered HDR lighting once (and when sources change).
npm run capture -- --export-environment --verify

# Compare the earlier lighting for diagnosis.
npm run compare -- --legacy --out=../../tests/tmp/reference-legacy

# Tighten the shared cameras to an 8-pixel border, then recapture the five masters.
npm run capture -- --refit --verify
```

The native comparison writes `tests/tmp/reference/xray_report.html`,
`metrics.json`, `nim-run.log`, `generated/` and `xray/`. It does not regenerate
the official images. The five native captures take about 2.3 seconds on the
development machine, excluding compilation. Native windows are hidden in
manifest mode.

The report measures exact differing RGB pixels, pixels within two values in
every RGB channel, RGB mean absolute error, RMSE, maximum channel error and the
existing Pixie score. The images are neither aligned nor resized for comparison.
Percentages include background pixels. Xray green means Nim is darker, blue
means Nim is brighter, and red indicates an alpha difference. Pixie's Xray sums
signed RGB differences, so equal-brightness hue changes may cancel in that
visualization; the numerical RGB metrics do not cancel.

The `ok` / `diff_error` labels use the existing Pixie score threshold (2%).
They are regression thresholds, not assertions of physically correct rendering.
`npm run compare` succeeds when every case was rendered and compared; add
`--strict` to make visual threshold failures return a nonzero exit code.

## Fresh setup

Requires Node.js, Git, Nim, and the library's usual Nim dependencies.

```sh
# Keep the dedicated Chrome download within this tool directory (PowerShell).
$env:PUPPETEER_CACHE_DIR = "$PWD/.cache/puppeteer"
npm ci
npm run setup
```

On POSIX shells use `PUPPETEER_CACHE_DIR="$PWD/.cache/puppeteer" npm ci`.
Setup clones the pinned Khronos Sample Renderer and Sample Assets repositories
beside `gltf` when absent, builds the renderer, and downloads the pinned studio
HDR and Draco decoder. Existing repositories must be clean and at the exact
revisions in `sources.json`; setup never resets an existing checkout. Override
their locations with `GLTF_REFERENCE_RENDERER` and `GLTF_SAMPLE_ASSETS`.
After setup, run `npm run capture -- --export-environment --verify` before the
first native comparison. The environment export reads the actual diffuse cube,
five GGX specular mip levels and GGX reflectance lookup texture from Khronos's
GPU convolution. Linear RGBA float data is saved under `.cache/ibl`, together
with source revisions, environment provenance, GPU details and SHA-256 hashes.
Comparison verifies those hashes and the master images' manifest/PNG hashes
before rendering, so stale cameras or captures cannot silently pass.

Capture serves all resources on loopback HTTP and launches a dedicated headless
Chrome using Puppeteer. No upload service or browser UI interaction is needed.
The renderer's canvas is exported immediately after rendering. `run.json`
records Chrome/GPU information and PNG hashes; different GPUs or drivers can
produce small pixel differences. `--software` explicitly selects SwiftShader
when hardware WebGL is unavailable and changes the rendering backend.

## Manifest

`tests/reference/manifest.json` is the shared source of camera and timing data.
Each case contains the model path relative to the asset repository, scene,
animation indices, time in seconds, and an explicit camera with position,
target, up vector, vertical FOV in degrees, and near/far planes. Paths use `/`.
The case ID is also the PNG filename.

Edit these values and run capture and compare. Both renderers sample the same
absolute time; they never derive the animation time from frame rate or wall
clock. Physics and interactivity are disabled in the reference harness.
The two initialization renders sample the exact same timestamp. The wrapper
also handles the upstream fixed-time-zero timer edge case.

To build a new manifest with fitted cameras, `npm run manifest -- --force`
replaces the five-case manifest deliberately. Camera fitting measures positions
after morphing, skinning and instancing, across the selected animation
poses, then keeps one camera per model. A perspective fit to the actual vertices
uses `settings.fit.marginPixels` (8 by default) to fill the frame for debugging.
The longest projected extent approaches the border; shorter dimensions retain
space so the model's proportions and pose are preserved. `--refit` updates
existing cameras while keeping their viewing direction and animation times.
The default orbit follows the Nim
suite's 20-degree yaw/pitch and 45-degree FOV. `--expanded` emits all 25 poses.
The animation samples are 0, 37%, 73%, and 137% of each clip's end time; the last
exercises looping. Additional times and camera overrides can be entered in JSON.

To compare the 25-case set explicitly:

```sh
# Separate masters preserve the five-image loop's tighter cameras.
npm run capture -- --manifest=../../tests/reference/manifest-25.json --out=../../tests/tmp/reference-25-masters --verify
npm run compare -- --manifest=../../tests/reference/manifest-25.json --baselines=../../tests/tmp/reference-25-masters/images --out=../../tests/tmp/reference-25
```

For a single-case edit, `npm run capture -- --cases=Fox__a2_t0p428583` limits
rendering. Use `--out=...` for an isolated report, because a report describes
the current invocation. Capture refuses to replace an existing manifest unless
`--init --force` is explicit. The native `--update` switch is forbidden in
manifest mode so it cannot overwrite Khronos references.

## Lighting and tone mapping

The default native comparison now uses matching lighting on desktop OpenGL:
the shared neutral HDR studio, environment rotation 90 degrees, exposure 1,
GGX image-based reflections with multiple scattering compensation, linear
material evaluation and Khronos PBR Neutral tone mapping. Color/emissive
textures use sRGB GPU formats; normal, occlusion and metallic/roughness maps
remain linear. Anisotropic filtering matches the reference where supported.
Artificial sun/rim/ambient lights are absent from this environment-only
comparison. The `--legacy` option retains the previous view.

Nim renders to RGBA16F, then applies exposure, PBR Neutral and the pinned
renderer’s gamma-2.2 display transfer in a fullscreen pass. Integer flags keep
the background out of tone mapping. The pinned Khronos main HDR framebuffer
is single-sample; `internalMSAA` affects its transmission framebuffer.
Matching that behavior also aligns silhouettes.

The implementation is Nim/Shady code in the library. Initialize the profile
once and wrap the entire scene per frame:

```nim
pbr.attachIblEnvironment(loadIblEnvironment("path/to/exported/ibl"))
pbr.environmentRotation = 90
pbr.exposure = 1
pbr.sunLightColor = color(0, 0, 0, 0) # Environment-only lighting.

# Each frame: set size, clearColor, view, proj and cameraPosition as usual.
pbr.beginIblFrame()
pbr.draw(model)
pbr.endIblFrame()
```

The context owns the attached environment by default and frees it on destroy.
The HDR target is reused and resized on demand. Other contexts retain their
existing procedural-lighting shader. Studio filtering is performed once by
the capture tool; Nim does not need Chrome during native rendering.

## Current comparison limits

The five-case pilot covers core metallic/roughness materials and later
animation poses. Four cases have average RGB error below 0.03/255.
DamagedHelmet now averages about 0.24/255 after replacing the importer’s
averaged tangents and fixed handedness with canonical MikkTSpace. All 46,356
triangle-corner tangents match the pinned Khronos WASM output exactly. Vertex
splits preserve UVs, colors, skin weights and morph targets, and generated
tangents are saved in the morph bind pose. JPEG decoding differences account
for part of the remaining pixel error. Passing the 2% Pixie threshold does not
mean bit-identical output or full glTF conformance.

This new profile is implemented for desktop OpenGL. Advanced material
extensions, model punctual lights, skybox presentation, fog and shadows still
need integration with it; other native backends keep their existing path.
The five selected models do not use these extensions. Do not infer full-catalog
coverage from this pilot. glTF standardizes materials, but environment,
exposure and tone mapping must also agree for engines to look alike.

Validation: `tests/ibl_pipeline.nim` exercises real GPU tone mapping with known
HDR colors, three exposures and contrasting per-pixel flags. The five official
images are repeat-verified, and comparison runs the actual native pipeline.

### Tangent diagnosis

`node tangent-probe.mjs` creates isolated helmet copies with Khronos-generated
tangents and deliberately reversed handedness, then compares the native output
to the unchanged master. Build the native harness with `npm run compare` first.
Add `--browser-jpegs` to test Chrome-decoded normal/all JPEG textures through PNG
intermediates. These are diagnostic copies under `tests/tmp/tangent-probe`;
neither official assets nor masters are edited.

For the current helmet, RGB MAE falls from 1.114 with the old importer to 0.240
with matching tangents. Reversing handedness produces 1.432. Matching Chrome's
normal-map JPEG decode reduces it to 0.174, and matching all five JPEG decodes
reduces it to 0.111. This separates the tangent defect from remaining texture
and rendering differences; the normal native pipeline still reads the original
JPEG assets itself.

`tests/test_tangents.nim` covers mirrored vertex splits, attribute/morph
remapping, bind-pose persistence, unindexed geometry, strips/fans, degenerate
UVs and authored tangents. It also accepts the helmet path and the probe's
`khronos-tangents.json` to check every corner against the official algorithm.

Source repositories and environment provenance are recorded in the manifest.
The neutral HDR is copyright 2020 Amazon, LLC, distributed by Khronos Group,
under CC-BY-4.0. Model attribution is in each pinned sample asset's
`metadata.json`. Khronos renderer code is Apache-2.0 and is built externally.
