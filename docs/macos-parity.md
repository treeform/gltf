# macOS Khronos parity

The macOS fixes are integrated with PR #53 on `khronos-parity`.
The matching Shady changes are on `gltf-backend-parity`, at
`703f21052849dc0e9e0e713c8c86d17c24d34528`.
Both repositories are required. All shader source generation and texture
specialization run through Shady. glTF contains shared Nim shader procedures
and backend resource and draw submission code.

Validated on macOS 15.1.1, Apple M4 Pro, Nim 2.2.6, on September 13, 2026.

| Backend | Passing captures | Skips or errors | Worst Pixie score |
| --- | ---: | ---: | ---: |
| OpenGL | 301 / 301 | 0 | 0.9096% |
| Metal | 301 / 301 | 0 | 0.9096% |

The threshold remains 2%. No reference masters or manifests were changed.
The 301 captures cover 149 source files with the manifest's selected scenes,
cameras, poses and animation times. ABeautifulGame remains excluded by the
original manifest. This is image regression coverage, not full conformance.

The reference is the Treeform glTF-Sample-Renderer fork at
`818318c0b09334998bea39766d88c2d58a76a2f6`, including its skinned-normal,
final-pass culling and specular/glossiness color-space fixes. Sample assets
remain pinned at `90d7ede14c7e280af263824604b427a1ca02cb66`. The lighting was
exported locally from this pinned renderer without replacing the masters.

## Reproduce

From the repository root, with the sibling Nim dependencies installed:

```sh
export GLTF_SAMPLE_ASSETS="$PWD/tests/tmp/reference-assets"
npm --prefix tools/reference run compare:all -- --strict --backend=opengl --out=../../tests/tmp/reference-opengl-mac
npm --prefix tools/reference run compare:all -- --strict --backend=metal --out=../../tests/tmp/reference-metal-mac
```

The assets path above is the detached worktree created for this run. For a
fresh checkout, follow the existing reference-tool setup, using the pinned
asset revision. Metal runtime comparison requires macOS.

Each output directory contains `xray_report.html`, `overview_card.png`,
per-capture generated and Xray images, `metrics.json`, `nim-run.log`, and
`implementation.json`. The comparator verifies master and lighting hashes
and rejects incomplete or duplicate capture lists.

## Other validation

Core Nim, Draco, KTX2, backend shader generation, and reference-tool tests
pass. The real OpenGL HDR, unlit, transmission and material extension GPU
assertions pass, as do PBR implicit, explicit, nested, shadow and exception
recovery passes. GPU tests use explicit offscreen presentation targets so
hidden macOS windows do not depend on an allocated window framebuffer.
Shady's Metal compiler test covers nested uniform and texture dependencies,
shared samplers, multiple outputs, early returns and texture dimensions.

Local dependency revisions and individual check logs are recorded in
`tests/tmp/dependencies-macos.json` and `tests/tmp/validation-macos.json`.
