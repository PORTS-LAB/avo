// Drifting haze with light shining through it, drawn with WebGL at a low
// resolution (smoke is soft, so a fraction of the pixels is enough). It draws
// one still frame when the visitor prefers reduced motion, pauses when off
// screen or in a background tab, and leaves the CSS gradient underneath in
// place when WebGL is not available. Given a `pointer` ({ x, y } from 0 to 1
// across the canvas, y up, and `active`), the light leans slowly toward it.

const VERTEX = `
attribute vec2 aPos;
varying vec2 vUv;
void main() {
  vUv = aPos * 0.5 + 0.5;
  gl_Position = vec4(aPos, 0.0, 1.0);
}`;

const FRAGMENT = `
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 vUv;
uniform vec2 uRes;
uniform float uTime;
uniform vec2 uSun;
uniform vec3 uBase0;
uniform vec3 uBase1;
uniform vec3 uLight;
uniform vec3 uSmoke;
uniform float uDensity;
uniform float uGlow;

float hash(vec2 p) {
  p = fract(p * vec2(234.34, 435.345));
  p += dot(p, p + 34.23);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
  for (int i = 0; i < 5; i++) {
    v += a * noise(p);
    p = m * p;
    a *= 0.5;
  }
  return v;
}

void main() {
  float aspect = uRes.x / uRes.y;
  vec2 uv = vUv;
  vec2 p = vec2(uv.x * aspect, uv.y);
  vec2 sun = vec2(uSun.x * aspect, uSun.y);
  float t = uTime;

  // Smoke: two slow layers, one bent by the other.
  vec2 q = vec2(
    fbm(p * 1.3 + vec2(t * 0.020, t * 0.004)),
    fbm(p * 1.3 + vec2(5.2, 1.3) - vec2(t * 0.013, 0.0)));
  float smoke = fbm(p * 1.9 + q * 1.7 + vec2(-t * 0.015, t * 0.005));
  float fog = smoothstep(0.28, 0.92, smoke) * uDensity;
  fog *= mix(1.2, 0.6, uv.y); // heavier near the ground

  // Light: a glow and a dimmed disc, a faint halo, and shafts where smoke scatters it.
  vec2 dir = p - sun;
  float d = length(dir);
  float glow = exp(-d * 2.5) * uGlow;
  float core = exp(-d * d * 52.0);
  float halo = exp(-pow((d - 0.34) / 0.045, 2.0)) * 0.09;
  vec2 nd = dir / max(d, 0.001);
  float shafts = fbm(nd * 2.6 + vec2(t * 0.018, -t * 0.012));
  shafts = smoothstep(0.45, 0.86, shafts) * exp(-d * 1.3);

  vec3 col = mix(uBase0, uBase1, clamp(uv.y * 0.7 + glow * 0.6, 0.0, 1.0));
  col += uSmoke * fog * 0.24;
  col += uLight * fog * glow * 1.05;
  col += uLight * glow * 0.28;
  col += uLight * core * 0.8 * (1.0 - fog * 0.5);
  col += uLight * halo * (0.4 + fog);
  col += uLight * shafts * (0.08 + fog * 0.22);

  float vig = smoothstep(1.3, 0.3, length((uv - 0.5) * vec2(aspect * 0.75, 1.0)));
  col *= mix(0.7, 1.0, vig);
  col += (hash(gl_FragCoord.xy + fract(t * 0.37)) - 0.5) / 150.0;
  gl_FragColor = vec4(col, 1.0);
}`;

// Colours: the page background (AvoDeep toward black), light mixed from
// AvoFlesh and a warmed AvoPit, smoke in grey-green.
export const PRESETS = {
  hero: {
    sun: [0.76, 0.56],
    sunPortrait: [0.62, 0.08],
    base0: [0.024, 0.042, 0.022],
    base1: [0.052, 0.086, 0.042],
    light: [0.93, 0.8, 0.58],
    smoke: [0.34, 0.4, 0.27],
    density: 0.9,
    glow: 0.82,
  },
};

function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    gl.deleteShader(shader);
    return null;
  }
  return shader;
}

/**
 * Starts the haze on a canvas. Returns a function that stops it, or null
 * when WebGL is not available (the CSS background then stays as it is).
 */
export function mountHaze(canvas, presetName, { reduceMotion, pointer } = {}) {
  const preset = PRESETS[presetName] || PRESETS.hero;
  let gl;
  try {
    gl = canvas.getContext('webgl', { alpha: false, antialias: false, depth: false, stencil: false, powerPreference: 'low-power' });
  } catch {
    gl = null;
  }
  if (!gl) return null;

  const vs = compile(gl, gl.VERTEX_SHADER, VERTEX);
  const fs = compile(gl, gl.FRAGMENT_SHADER, FRAGMENT);
  if (!vs || !fs) return null;
  const program = gl.createProgram();
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
  gl.useProgram(program);

  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const aPos = gl.getAttribLocation(program, 'aPos');
  gl.enableVertexAttribArray(aPos);
  gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

  const u = (name) => gl.getUniformLocation(program, name);
  const uRes = u('uRes');
  const uTime = u('uTime');
  const uSun = u('uSun');
  const uGlow = u('uGlow');
  gl.uniform3fv(u('uBase0'), preset.base0);
  gl.uniform3fv(u('uBase1'), preset.base1);
  gl.uniform3fv(u('uLight'), preset.light);
  gl.uniform3fv(u('uSmoke'), preset.smoke);
  gl.uniform1f(u('uDensity'), preset.density);

  // Where the light rests, and where it is now (it eases toward the pointer).
  let rest = preset.sun;
  const sun = [...preset.sun];
  const LEAN = 0.16;

  const small = window.matchMedia('(max-width: 760px)').matches;
  const scale = small ? 0.33 : 0.4;
  const maxPixels = 520_000;
  let width = 0;
  let height = 0;

  function resize() {
    const rect = canvas.getBoundingClientRect();
    let w = Math.max(32, Math.round(rect.width * scale));
    let h = Math.max(32, Math.round(rect.height * scale));
    if (w * h > maxPixels) {
      const k = Math.sqrt(maxPixels / (w * h));
      w = Math.round(w * k);
      h = Math.round(h * k);
    }
    if (w === width && h === height) return false;
    width = w;
    height = h;
    canvas.width = w;
    canvas.height = h;
    gl.viewport(0, 0, w, h);
    gl.uniform2f(uRes, w, h);
    // On a tall, narrow screen the text sits on top: keep the light lower and softer.
    const portrait = h > w * 1.1;
    rest = portrait && preset.sunPortrait ? preset.sunPortrait : preset.sun;
    sun[0] = rest[0];
    sun[1] = rest[1];
    gl.uniform2fv(uSun, sun);
    gl.uniform1f(uGlow, portrait ? preset.glow * 0.62 : preset.glow);
    return true;
  }

  // A fixed starting point, so the still frame looks the same every time.
  const start = performance.now() - 24_000;
  let frame = 0;
  let last = 0;
  let visible = true;
  let running = false;

  function draw(now) {
    if (pointer) {
      const lean = pointer.active ? LEAN : 0;
      sun[0] += (rest[0] + (pointer.x - rest[0]) * lean - sun[0]) * 0.05;
      sun[1] += (rest[1] + (pointer.y - rest[1]) * lean - sun[1]) * 0.05;
      gl.uniform2fv(uSun, sun);
    }
    gl.uniform1f(uTime, (now - start) / 1000);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    if (!canvas.classList.contains('is-ready')) canvas.classList.add('is-ready');
  }

  function tick(now) {
    frame = 0;
    if (!running) return;
    if (now - last >= (small ? 41 : 33)) {
      last = now;
      draw(now);
    }
    frame = requestAnimationFrame(tick);
  }

  function update() {
    const shouldRun = visible && !document.hidden && !reduceMotion?.matches;
    if (shouldRun && !running) {
      running = true;
      frame = requestAnimationFrame(tick);
    } else if (!shouldRun && running) {
      running = false;
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
    }
  }

  resize();
  draw(start + 24_000);

  const observer = new ResizeObserver(() => {
    if (resize() && !running) draw(performance.now());
  });
  observer.observe(canvas);

  const io = new IntersectionObserver((entries) => {
    visible = entries.some((e) => e.isIntersecting);
    update();
  });
  io.observe(canvas);

  const onVisibility = () => update();
  document.addEventListener('visibilitychange', onVisibility);
  reduceMotion?.addEventListener?.('change', update);

  canvas.addEventListener('webglcontextlost', (event) => {
    event.preventDefault();
    running = false;
    canvas.classList.remove('is-ready');
  });

  update();

  return () => {
    running = false;
    if (frame) cancelAnimationFrame(frame);
    observer.disconnect();
    io.disconnect();
    document.removeEventListener('visibilitychange', onVisibility);
  };
}
