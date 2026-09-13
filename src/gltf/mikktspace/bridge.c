/* Nim's packed float streams adapted to the unmodified MikkTSpace API. */
#include <stdint.h>
#include <string.h>
#include "mikktspace.h"

typedef struct {
    const float *positions, *normals, *uvs;
    const uint32_t *indices;
    int corners;
    float *tangents;
} GltfMikkMesh;

static int faceCount(const SMikkTSpaceContext *ctx) {
    return ((GltfMikkMesh *)ctx->m_pUserData)->corners / 3;
}
static int verticesPerFace(const SMikkTSpaceContext *ctx, int face) {
    (void)ctx; (void)face;
    return 3;
}
static void position(const SMikkTSpaceContext *ctx, float out[], int face, int vertex) {
    const GltfMikkMesh *mesh = (const GltfMikkMesh *)ctx->m_pUserData;
    memcpy(out, mesh->positions + 3 * mesh->indices[face * 3 + vertex], 3 * sizeof(float));
}
static void normal(const SMikkTSpaceContext *ctx, float out[], int face, int vertex) {
    const GltfMikkMesh *mesh = (const GltfMikkMesh *)ctx->m_pUserData;
    memcpy(out, mesh->normals + 3 * mesh->indices[face * 3 + vertex], 3 * sizeof(float));
}
static void texcoord(const SMikkTSpaceContext *ctx, float out[], int face, int vertex) {
    const GltfMikkMesh *mesh = (const GltfMikkMesh *)ctx->m_pUserData;
    memcpy(out, mesh->uvs + 2 * mesh->indices[face * 3 + vertex], 2 * sizeof(float));
}
static void tangent(const SMikkTSpaceContext *ctx, const float value[], float sign, int face, int vertex) {
    GltfMikkMesh *mesh = (GltfMikkMesh *)ctx->m_pUserData;
    float *out = mesh->tangents + 4 * (face * 3 + vertex);
    memcpy(out, value, 3 * sizeof(float));
    /* Match Khronos's MikkTSpace -> glTF texture-coordinate convention. */
    out[3] = -sign;
}

int gltfGenerateMikkTangents(const float *positions, const float *normals,
    const float *uvs, const uint32_t *indices, int corners, float *tangents) {
    GltfMikkMesh mesh = { positions, normals, uvs, indices, corners, tangents };
    SMikkTSpaceInterface interface = { faceCount, verticesPerFace, position,
        normal, texcoord, tangent, 0 };
    SMikkTSpaceContext context = { &interface, &mesh };
    return genTangSpaceDefault(&context);
}
