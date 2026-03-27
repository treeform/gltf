#version 410
in vec3 rayDir;
uniform samplerCube environmentMap;
uniform float lod;
out vec4 fragColor;

const float PI = 3.14159265359;

void main() {
    vec3 dir = normalize(rayDir);
    
    // Create an orthonormal basis for the sampling disk
    vec3 up = abs(dir.z) < 0.999 ? vec3(0, 0, 1) : vec3(1, 0, 0);
    vec3 tangent = normalize(cross(up, dir));
    vec3 bitangent = cross(dir, tangent);

    vec4 color = vec4(0.0);
    const int numSamples = 16;
    
    // The spread factor determines how far from the center we sample.
    float spread = lod * 0.015; 

    for (int i = 0; i < numSamples; i++) {
        float t = float(i) / float(numSamples);
        float angle = t * 2.0 * PI;
        float r = sqrt(t); 
        vec2 offset = vec2(cos(angle), sin(angle)) * r * spread;
        
        vec3 sampleDir = normalize(dir + tangent * offset.x + bitangent * offset.y);
        color += textureLod(environmentMap, sampleDir, lod);
    }
    
    fragColor = color / float(numSamples);
}
