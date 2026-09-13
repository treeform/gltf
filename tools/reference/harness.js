import { GltfView, GltfState } from '/renderer/gltf-viewer.module.js';
import { mat4, vec3 } from '/math/index.js';

const canvas = document.querySelector('canvas');
const gl = canvas.getContext('webgl2', { alpha: false, antialias: true });
if (!gl) throw new Error('WebGL 2 is unavailable');
const view = new GltfView(gl);
const loader = view.createResourceLoader(undefined, undefined, '/renderer/libs/');
let state, currentModel, environment, timeSeconds = 0;
const failures = [];
canvas.addEventListener('webglcontextlost', event => {
  event.preventDefault();
  failures.push('WebGL context lost');
});
const urlPath = value => value.split('/').map(encodeURIComponent).join('/');

async function initialize(settings) {
  canvas.width = settings.width;
  canvas.height = settings.height;
  canvas.style.width = `${settings.width}px`;
  canvas.style.height = `${settings.height}px`;
  await loader.initDracoLib();
  environment = await loader.loadEnvironment('/environment/neutral.hdr', {
    lut_ggx_file: '/renderer/assets/lut_ggx.png',
    lut_charlie_file: '/renderer/assets/lut_charlie.png',
    lut_sheen_E_file: '/renderer/assets/lut_sheen_E.png'
  });
  if (!environment) throw new Error('Environment failed to load');
  const debug = gl.getExtension('WEBGL_debug_renderer_info');
  return {
    vendor: gl.getParameter(debug ? debug.UNMASKED_VENDOR_WEBGL : gl.VENDOR),
    renderer: gl.getParameter(debug ? debug.UNMASKED_RENDERER_WEBGL : gl.RENDERER),
    version: gl.getParameter(gl.VERSION),
    samples: gl.getParameter(gl.SAMPLES),
    contextAttributes: gl.getContextAttributes()
  };
}

async function load(model, settings) {
  if (currentModel === model) return;
  state = view.createState();
  state.environment = environment;
  // The pinned upstream timer treats fixedTime=0 as false. Supply an exact clock
  // for every timestamp, including zero, without changing the renderer source.
  state.animationTimer.elapsedSec = () => timeSeconds;
  state.gltf = await loader.loadGltf(`/models/${urlPath(model)}`);
  Object.assign(state.renderingParameters, settings.rendering);
  state.renderingParameters.toneMap = GltfState.ToneMaps[settings.toneMap];
  if (!state.renderingParameters.toneMap) throw new Error(`Unknown tone map: ${settings.toneMap}`);
  state.renderingParameters.enabledExtensions.KHR_interactivity = false;
  currentModel = model;
}

// Export the pinned renderer's actual convolution results, without quantizing
// HDR radiance to PNG. Native GL uses the same bottom-up rows and cube faces.
async function exportEnvironment() {
  const framebuffer = gl.createFramebuffer();
  const previous = gl.getParameter(gl.FRAMEBUFFER_BINDING);
  const textures = [];
  // The energy LUT is a PNG, uploaded by the renderer on first sheen draw.
  // Export its linear bytes with the same unflipped upload convention.
  const energyImage = environment.images[environment.textures[environment.sheenELUT.index].source[0]].image;
  const energyTexture = gl.createTexture();
  try {
    gl.bindTexture(gl.TEXTURE_2D, energyTexture);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, energyImage);
    gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
    for (const [name, info, size, levels, faces] of [
      ['diffuse', environment.diffuseEnvMap, 256, 1, 6],
      ['specular', environment.specularEnvMap, 256, environment.mipCount, 6],
      ['ggx-lut', environment.lut, 1024, 1, 1],
      ['charlie', environment.sheenEnvMap, 256, environment.mipCount, 6],
      ['charlie-lut', environment.sheenLUT, 1024, 1, 1],
      ['sheen-energy-lut', null, energyImage.width, 1, 1]
    ]) {
      const texture = info ? environment.images[environment.textures[info.index].source[0]].image : energyTexture;
      for (let level = 0; level < levels; level++) {
        const width = size >> level;
        for (let face = 0; face < faces; face++) {
          const target = faces === 6 ? gl.TEXTURE_CUBE_MAP_POSITIVE_X + face : gl.TEXTURE_2D;
          gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, target, texture, level);
          if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) throw new Error(`Cannot read ${name}/${level}/${face}`);
          const pixels = new Float32Array(width * width * 4);
          if (info) {
            gl.readPixels(0, 0, width, width, gl.RGBA, gl.FLOAT, pixels);
          } else {
            const rgba = new Uint8Array(pixels.length);
            gl.readPixels(0, 0, width, width, gl.RGBA, gl.UNSIGNED_BYTE, rgba);
            for (let i = 0; i < rgba.length; i++) pixels[i] = rgba[i] / 255;
          }
          const error = gl.getError();
          if (error) throw new Error(`Environment readback GL error ${error}`);
          const bytes = new Uint8Array(pixels.buffer);
          let binary = '';
          for (let i = 0; i < bytes.length; i += 32768) binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
          const file = `${name}-${level}-${face}.rgba32f`;
          await window.saveEnvironmentTexture(file, btoa(binary));
          textures.push({ name, level, face, width, file, bytes: bytes.length });
        }
      }
    }
    return { version: 1, format: 'rgba32f-le', rowOrder: 'bottom-up',
      cubeFaceOrder: ['+X', '-X', '+Y', '-Y', '+Z', '-Z'],
      mipCount: environment.mipCount, intensityScale: environment.iblIntensityScale, textures };
  } finally {
    gl.bindFramebuffer(gl.FRAMEBUFFER, previous);
    gl.deleteFramebuffer(framebuffer);
    gl.deleteTexture(energyTexture);
  }
}

function pose(item) {
  timeSeconds = item.timeSeconds;
  state.sceneIndex = item.scene;
  state.animationIndices = item.animationIndices;
  state.variant = item.materialVariant ?? undefined;
  if (!state.gltf.scenes[item.scene]) throw new Error(`Missing scene ${item.scene}`);
  if (item.animationIndices.some(i => !state.gltf.animations[i])) throw new Error('Missing animation');
  // Used only to resolve bounds without drawing or advancing real time.
  view._animate(state);
  state.gltf.scenes[item.scene].applyTransformHierarchy(state.gltf);
}

// Fit using actual positions after morphing, skinning and instancing. The
// viewer's own accessor-box fit omits these deformations in this revision.
function bounds(visit) {
  const gltf = state.gltf;
  const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
  const nodes = gltf.scenes[state.sceneIndex].gatherNodes(gltf, state.renderingParameters.enabledExtensions).nodes;
  const data = index => index === undefined ? null : gltf.accessors[index].getNormalizedDeinterlacedView(gltf);
  const p = vec3.create(), world = vec3.create(), skinned = vec3.create();
  for (const node of nodes) {
    if (node.mesh === undefined) continue;
    const skin = gltf.skins[node.skin];
    let joints;
    if (skin) {
      const inverseBind = data(skin.inverseBindMatrices);
      joints = skin.joints.map((index, i) => {
        const matrix = mat4.clone(gltf.nodes[index].getRenderedWorldTransform());
        if (inverseBind) mat4.multiply(matrix, matrix, inverseBind.subarray(i * 16, i * 16 + 16));
        return matrix;
      });
    }
    for (const primitive of gltf.meshes[node.mesh].primitives) {
      const positions = data(primitive.attributes.POSITION);
      if (!positions) continue;
      const morphs = (primitive.targets || []).map(t => data(t.POSITION));
      const morphWeights = node.getWeights(gltf) || [];
      const jointIds = [data(primitive.attributes.JOINTS_0), data(primitive.attributes.JOINTS_1)];
      const weights = [data(primitive.attributes.WEIGHTS_0), data(primitive.attributes.WEIGHTS_1)];
      const transforms = node.instanceWorldTransforms || [node.getRenderedWorldTransform()];
      for (let i = 0; i < positions.length / 3; i++) {
        vec3.set(p, positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]);
        for (let m = 0; m < morphs.length; m++) {
          if (!morphs[m] || !morphWeights[m]) continue;
          for (let axis = 0; axis < 3; axis++) p[axis] += morphs[m][i * 3 + axis] * morphWeights[m];
        }
        for (const transform of transforms) {
          if (joints && jointIds[0] && weights[0]) {
            vec3.zero(skinned);
            let total = 0;
            for (let set = 0; set < 2; set++) {
              if (!jointIds[set] || !weights[set]) continue;
              for (let j = 0; j < 4; j++) {
                const weight = weights[set][i * 4 + j];
                if (!weight) continue;
                vec3.transformMat4(world, p, joints[jointIds[set][i * 4 + j]]);
                vec3.scaleAndAdd(skinned, skinned, world, weight);
                total += weight;
              }
            }
            if (total > 0) vec3.scale(world, skinned, 1 / total);
            else vec3.transformMat4(world, p, transform);
          } else vec3.transformMat4(world, p, transform);
          if (visit) visit(world);
          for (let axis = 0; axis < 3; axis++) {
            min[axis] = Math.min(min[axis], world[axis]);
            max[axis] = Math.max(max[axis], world[axis]);
          }
        }
      }
    }
  }
  return { min, max };
}

async function fitCamera(cases, settings) {
  await load(cases[0].model, settings);
  const original = cases[0].camera;
  const back = vec3.normalize(vec3.create(), vec3.subtract(vec3.create(), original.position, original.target));
  const right = vec3.normalize(vec3.create(), vec3.cross(vec3.create(), original.up, back));
  const up = vec3.cross(vec3.create(), back, right);
  const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
  const coordinates = p => [vec3.dot(p, right), vec3.dot(p, up), vec3.dot(p, back)];
  // Center in camera coordinates, including all selected animation poses.
  for (const item of cases) {
    pose(item);
    bounds(p => {
      const q = coordinates(p);
      for (let axis = 0; axis < 3; axis++) {
        min[axis] = Math.min(min[axis], q[axis]);
        max[axis] = Math.max(max[axis], q[axis]);
      }
    });
  }
  if (![...min, ...max].every(Number.isFinite)) throw new Error('No finite renderable bounds');
  const center = min.map((v, i) => (v + max[i]) / 2);
  const target = vec3.create();
  for (const [i, axis] of [right, up, back].entries()) vec3.scaleAndAdd(target, target, axis, center[i]);
  const margin = settings.fit.marginPixels ?? 8;
  if (!(margin >= 0 && margin < Math.min(settings.width, settings.height) / 2)) throw new Error('Invalid camera margin');
  const tanY = Math.tan(original.verticalFovDegrees * Math.PI / 360);
  const tanX = tanY * settings.width / settings.height;
  const limitX = tanX * (1 - 2 * margin / settings.width);
  const limitY = tanY * (1 - 2 * margin / settings.height);
  let distance = 0;
  // Solve the perspective frustum inequalities for every deformed vertex.
  // A bounding sphere leaves large margins on thin or elongated models.
  for (const item of cases) {
    pose(item);
    bounds(p => {
      const q = coordinates(p).map((v, i) => v - center[i]);
      distance = Math.max(distance, q[2] + Math.abs(q[0]) / limitX, q[2] + Math.abs(q[1]) / limitY);
    });
  }
  const radius = Math.max(0.001, Math.hypot(...max.map((v, i) => (v - min[i]) / 2)));
  distance = Math.max(distance, radius * 0.001);
  return {
    ...original,
    position: Array.from(vec3.scaleAndAdd(vec3.create(), target, back, distance)),
    target: Array.from(target),
    near: Math.max(0.000001, Math.min(radius / 1000, (distance - (max[2] - center[2])) / 2)),
    far: distance + radius * 4
  };
}

async function describe(model, settings) {
  await load(model, settings);
  const scene = state.gltf.scene ?? 0;
  const samples = [{ label: 'rest', scene, animationIndices: [], timeSeconds: 0 }];
  for (const [index, animation] of state.gltf.animations.entries()) {
    animation.computeMinMaxTime(state.gltf);
    if (!Number.isFinite(animation.maxTime)) throw new Error(`Invalid animation ${index}`);
    const end = animation.maxTime;
    // Non-round fractions avoid accidentally sampling identical cycle poses.
    for (const fraction of [0, 0.37, 0.73, 1.37]) {
      const t = Number((end * fraction).toFixed(6));
      samples.push({ label: `a${index}_t${String(t).replace('.', 'p')}`, scene,
        animationIndices: [index], animationName: animation.name || `Animation ${index}`,
        timeSeconds: t, animationEndSeconds: end });
    }
  }
  const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
  for (const sample of samples) {
    pose(sample);
    const b = bounds();
    for (let axis = 0; axis < 3; axis++) {
      min[axis] = Math.min(min[axis], b.min[axis]);
      max[axis] = Math.max(max[axis], b.max[axis]);
    }
  }
  if (![...min, ...max].every(Number.isFinite)) throw new Error('No finite renderable bounds');
  const target = min.map((v, i) => (v + max[i]) / 2);
  const radius = Math.max(0.001, Math.hypot(...max.map((v, i) => v - target[i])));
  const yaw = settings.fit.yawDegrees * Math.PI / 180;
  const pitch = settings.fit.pitchDegrees * Math.PI / 180;
  const fov = settings.fit.verticalFovDegrees;
  const halfFov = Math.min(fov * Math.PI / 360, Math.atan(Math.tan(fov * Math.PI / 360) * settings.width / settings.height));
  const distance = radius / Math.sin(halfFov) * settings.fit.padding;
  const direction = [-Math.sin(yaw) * Math.cos(pitch), Math.sin(pitch), Math.cos(yaw) * Math.cos(pitch)];
  const camera = {
    position: target.map((v, i) => v + distance * direction[i]), target, up: [0, 1, 0],
    verticalFovDegrees: fov, near: Math.max(0.00001, radius / 1000), far: distance + radius * 4
  };
  return { samples, camera, bounds: { min, max }, extensionsRequired: state.gltf.extensionsRequired || [] };
}

async function capture(item, settings) {
  await load(item.model, settings);
  pose(item);
  const c = item.camera;
  state.cameraNodeIndex = undefined;
  state.userCamera.transform = mat4.targetTo(mat4.create(), c.position, c.target, c.up);
  state.userCamera.perspective.yfov = c.verticalFovDegrees * Math.PI / 180;
  state.userCamera.perspective.aspectRatio = settings.width / settings.height;
  state.userCamera.perspective.znear = c.near;
  state.userCamera.perspective.zfar = c.far;
  // Resource loading is awaited. Redraw and export in one JS task so WebGL's
  // default drawing buffer cannot be discarded between the two operations.
  // The first draw allocates the HDR framebuffers; the next clears them with
  // the requested background. Both draws sample exactly the same pose.
  for (let frame = 0; frame < settings.renderFrames; frame++) {
    view.renderFrame(state, canvas.width, canvas.height);
  }
  gl.finish();
  if (failures.length || gl.isContextLost()) throw new Error(failures.join('; ') || 'Context lost');
  const error = gl.getError();
  if (error !== gl.NO_ERROR) throw new Error(`WebGL error 0x${error.toString(16)}`);
  return canvas.toDataURL('image/png').split(',')[1];
}

window.reference = { initialize, describe, fitCamera, capture, exportEnvironment };
