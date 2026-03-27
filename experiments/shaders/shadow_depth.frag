#version 410

in vec2 vUv;

uniform sampler2D sampleTex;
uniform float alphaCutoff = -1.0;
uniform vec4 baseColorFactor = vec4(1.0);

void main() {
  if (alphaCutoff >= 0.0) {
    vec4 texColor = texture(sampleTex, vUv) * baseColorFactor;
    if (texColor.a < alphaCutoff) {
      discard;
    }
  }
  // Depth is written automatically to the depth attachment.
}
