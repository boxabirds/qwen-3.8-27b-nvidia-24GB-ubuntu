// METEOR RUSH 3D - no external libraries, pure canvas 3D projection

const canvas = document.getElementById('canvas') || (() => {
  const c = document.createElement('canvas');
  c.id = 'canvas';
  document.body.insertBefore(c, document.body.firstChild);
  return c;
})();
const ctx = canvas.getContext('2d');

let W = 0, H = 0;
function resize() {
  W = canvas.width = window.innerWidth;
  H = canvas.height = window.innerHeight;
}
window.addEventListener('resize', resize);
resize();

// ---------- math helpers ----------
const TAU = Math.PI * 2;
const rand = (a, b) => a + Math.random() * (b - a);
const clamp = (v, a, b) => v < a ? a : v > b ? b : v;

// project world point (x, y, z) to screen. Camera at origin looking down +z.
function project(x, y, z) {
  const f = 420; // focal length
  const s = f / Math.max(z, 1);
  return { sx: W / 2 + x * s, sy: H / 2 - y * s, s };
}

// ---------- game state ----------
const STATE = { MENU: 0, PLAYING: 1, PAUSED: 2, GAMEOVER: 3 };
let state = STATE.MENU;

const ship = { x: 0, y: 0, z: 60, vx: 0, vy: 0 };
const WORLD_Z_MAX = 900;
let score = 0;
let combo = 0;
let comboTimer = 0;
let wave = 1;
let hull = 100;
let boostActive = false;
let firing = false;
let fireCooldown = 0;
let shake = 0;
let time = 0;

const meteors = [];
const lasers = [];
const particles = [];
const stars = [];
const powerups = [];

// ---------- stars background ----------
function initStars() {
  stars.length = 0;
  for (let i = 0; i < 260; i++) {
    stars.push({
      x: rand(-1, 1) * W * 0.7,
      y: rand(-1, 1) * H * 0.7,
      z: rand(50, WORLD_Z_MAX),
      tw: rand(0, TAU)
    });
  }
}
initStars();

// ---------- input ----------
const keys = {};
let mouseX = W / 2, mouseY = H / 2;

window.addEventListener('keydown', e => {
  keys[e.code] = true;
  if (e.code === 'Escape' && (state === STATE.PLAYING || state === STATE.PAUSED)) {
    togglePause();
  }
});
window.addEventListener('keyup', e => { keys[e.code] = false; });

window.addEventListener('mousemove', e => {
  mouseX = e.clientX;
  mouseY = e.clientY;
});
window.addEventListener('mousedown', () => { firing = true; });
window.addEventListener('mouseup', () => { firing = false; });

const overlay = document.getElementById('overlay');
const startBtn = document.getElementById('start-btn');
startBtn.addEventListener('click', startGame);

// ---------- HUD refs ----------
const scoreEl = document.getElementById('score');
const waveEl = document.getElementById('wave');
const comboEl = document.getElementById('combo-display');
const shieldEl = document.getElementById('shield-bar-inner');
const flashEl = document.getElementById('damage-flash');
const subtitleEl = document.getElementById('subtitle');
const finalScoreEl = document.getElementById('final-score');

// ---------- spawning ----------
function spawnMeteor() {
  const size = rand(10, 34) + Math.min(wave * 2, 30);
  const speed = rand(140, 220) + wave * 18;
  meteors.push({
    x: rand(-260, 260),
    y: rand(-160, 160),
    z: WORLD_Z_MAX,
    vx: rand(-30, 30),
    vy: rand(-30, 30),
    size,
    speed,
    rot: rand(0, TAU),
    rotSpeed: rand(-2, 2),
    hp: Math.ceil(size / 14),
    verts: makeMeteorVerts(size),
    hue: rand(15, 45)
  });
}

function makeMeteorVerts(size) {
  const verts = [];
  const n = 9;
  for (let i = 0; i < n; i++) {
    const a = (i / n) * TAU + rand(-0.3, 0.3);
    const r = size * rand(0.75, 1.15);
    verts.push({ x: Math.cos(a) * r, y: Math.sin(a) * r });
  }
  return verts;
}

function spawnPowerup(x, y, z) {
  if (Math.random() < 0.22) {
    powerups.push({ x, y, z, type: 'heal', rot: 0 });
  }
}

// ---------- particles ----------
function burst(x, y, z, color, count, speed) {
  for (let i = 0; i < count; i++) {
    const a = rand(0, TAU);
    const sp = rand(speed * 0.3, speed);
    particles.push({
      x, y, z,
      vx: Math.cos(a) * sp,
      vy: Math.sin(a) * sp,
      vz: rand(-60, 60),
      life: rand(0.4, 1.0),
      maxLife: 1,
      color,
      size: rand(2, 5)
    });
  }
}

// ---------- shooting ----------
function fireLaser() {
  const aimX = ((mouseX / W) * 2 - 1) * 300;
  const aimY = (1 - (mouseY / H) * 2) * 190;
  lasers.push({
    x: ship.x + (Math.random() < 0.5 ? -8 : 8),
    y: ship.y,
    z: ship.z + 20,
    vx: (aimX - ship.x) * 3.2,
    vy: (aimY - ship.y) * 3.2,
    vz: 1600
  });
}

// ---------- damage ----------
function damage(amount) {
  hull -= amount;
  shake = Math.min(shake + amount * 0.4, 18);
  flashEl.style.opacity = '1';
  setTimeout(() => { flashEl.style.opacity = '0'; }, 90);
  if (hull <= 0) {
    hull = 0;
    gameOver();
  }
}

// ---------- game flow ----------
function startGame() {
  state = STATE.PLAYING;
  score = 0; combo = 0; wave = 1; hull = 100;
  meteors.length = 0; lasers.length = 0; particles.length = 0; powerups.length = 0;
  ship.x = 0; ship.y = 0; ship.z = 60;
  overlay.classList.add('hidden');
  updateHUD();
}

function gameOver() {
  state = STATE.GAMEOVER;
  burst(ship.x, ship.y, ship.z, '#ff5030', 90, 420);
  subtitleEl.textContent = 'SHIP DESTROYED';
  finalScoreEl.style.display = 'block';
  finalScoreEl.textContent = 'SCORE: ' + score;
  startBtn.textContent = 'Relaunch';
  setTimeout(() => overlay.classList.remove('hidden'), 900);
}

function togglePause() {
  if (state === STATE.PLAYING) {
    state = STATE.PAUSED;
    subtitleEl.textContent = 'PAUSED — PRESS ESC TO RESUME';
    finalScoreEl.style.display = 'none';
    startBtn.textContent = 'Resume';
    overlay.classList.remove('hidden');
  } else if (state === STATE.PAUSED) {
    state = STATE.PLAYING;
    overlay.classList.add('hidden');
  }
}

function updateHUD() {
  scoreEl.textContent = score;
  waveEl.textContent = wave;
  comboEl.textContent = combo > 1 ? 'COMBO x' + combo : '';
  shieldEl.style.width = clamp(hull, 0, 100) + '%';
  shieldEl.style.background = hull < 30
    ? 'linear-gradient(90deg, #ff4030, #ff8040)'
    : 'linear-gradient(90deg, #3fa9ff, #7df0ff)';
}

// ---------- update ----------
let last = performance.now();
let spawnTimer = 0;

function update(dt) {
  time += dt;

  // ship steering
  let ax = 0, ay = 0;
  if (keys['KeyA'] || keys['ArrowLeft']) ax -= 1;
  if (keys['KeyD'] || keys['ArrowRight']) ax += 1;
  if (keys['KeyW'] || keys['ArrowUp']) ay += 1;
  if (keys['KeyS'] || keys['ArrowDown']) ay -= 1;

  const speed = 340;
  ship.vx += ax * speed * dt * 6;
  ship.vy += ay * speed * dt * 6;
  ship.vx *= Math.pow(0.0025, dt); // damping
  ship.vy *= Math.pow(0.0025, dt);

  boostActive = keys['ShiftLeft'] || keys['ShiftRight'];
  if (boostActive && hull > 5) {
    ship.vx *= 1.04;
    ship.vy *= 1.04;
    hull -= 6 * dt;
  }

  ship.x += ship.vx * dt;
  ship.y += ship.vy * dt;
  ship.x = clamp(ship.x, -300, 300);
  ship.y = clamp(ship.y, -190, 190);

  // firing
  fireCooldown -= dt;
  if (firing && fireCooldown <= 0) {
    fireLaser();
    fireCooldown = 0.09;
  }

  // combo timer
  if (comboTimer > 0) {
    comboTimer -= dt;
    if (comboTimer <= 0) combo = 0;
  }

  // wave progression: based on score thresholds
  const targetWave = 1 + Math.floor(score / 600);
  if (targetWave !== wave) {
    wave = targetWave;
  }

  // spawn meteors
  spawnTimer -= dt;
  if (spawnTimer <= 0) {
    spawnMeteor();
    spawnTimer = clamp(1.4 - wave * 0.09, 0.35, 1.4);
  }

  // meteors
  for (let i = meteors.length - 1; i >= 0; i--) {
    const m = meteors[i];
    m.z -= m.speed * dt;
    m.x += m.vx * dt;
    m.y += m.vy * dt;
    m.rot += m.rotSpeed * dt;

    // collision with ship (z near ship.z)
    if (m.z < ship.z + 25 && m.z > ship.z - 10) {
      const dx = m.x - ship.x, dy = m.y - ship.y;
      const rr = m.size * 0.8 + 16;
      if (dx * dx + dy * dy < rr * rr) {
        damage(18 + m.size * 0.3);
        burst(m.x, m.y, m.z, '#ff7040', 26, 300);
        meteors.splice(i, 1);
        combo = 0;
        continue;
      }
    }

    if (m.z < -50) {
      meteors.splice(i, 1);
    }
  }

  // lasers
  for (let i = lasers.length - 1; i >= 0; i--) {
    const l = lasers[i];
    l.x += l.vx * dt;
    l.y += l.vy * dt;
    l.z += l.vz * dt;
    if (l.z > WORLD_Z_MAX + 50) { lasers.splice(i, 1); continue; }

    // hit test vs meteors
    for (let j = meteors.length - 1; j >= 0; j--) {
      const m = meteors[j];
      if (Math.abs(l.z - m.z) < 30) {
        const dx = l.x - m.x, dy = l.y - m.y;
        if (dx * dx + dy * dy < (m.size + 6) * (m.size + 6)) {
          lasers.splice(i, 1);
          m.hp--;
          burst(l.x, l.y, l.z, '#9fe8ff', 5, 120);
          if (m.hp <= 0) {
            const pts = Math.round(m.size * 3 + wave * 5);
            score += pts;
            combo++;
            comboTimer = 2.5;
            burst(m.x, m.y, m.z, `hsl(${m.hue}, 100%, 60%)`, 22, 260);
            spawnPowerup(m.x, m.y, m.z);
            meteors.splice(j, 1);
          }
          break;
        }
      }
    }
  }

  // powerups
  for (let i = powerups.length - 1; i >= 0; i--) {
    const p = powerups[i];
    p.z -= 120 * dt;
    p.rot += 3 * dt;
    if (p.z < ship.z + 20 && p.z > ship.z - 10) {
      const dx = p.x - ship.x, dy = p.y - ship.y;
      if (dx * dx + dy * dy < 45 * 45) {
        hull = clamp(hull + 30, 0, 100);
        burst(p.x, p.y, p.z, '#7dffb0', 20, 200);
        powerups.splice(i, 1);
        continue;
      }
    }
    if (p.z < -50) powerups.splice(i, 1);
  }

  // particles
  for (let i = particles.length - 1; i >= 0; i--) {
    const p = particles[i];
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    p.z += p.vz * dt;
    p.life -= dt;
    if (p.life <= 0) particles.splice(i, 1);
  }

  // stars drift toward camera
  for (const s of stars) {
    s.z -= 260 * dt;
    s.tw += dt * 5;
    if (s.z < 30) {
      s.z = WORLD_Z_MAX;
      s.x = rand(-1, 1) * W * 0.7;
      s.y = rand(-1, 1) * H * 0.7;
    }
  }

  shake *= Math.pow(0.02, dt);
  updateHUD();
}

// ---------- render ----------
function drawStars() {
  for (const s of stars) {
    const p = project(s.x, s.y, s.z);
    if (p.s <= 0) continue;
    const a = clamp(1.2 - s.z / WORLD_Z_MAX, 0.15, 1) * (0.6 + 0.4 * Math.sin(s.tw));
    const r = clamp(p.s * 1.4, 0.5, 3);
    ctx.fillStyle = `rgba(200, 230, 255, ${a})`;
    ctx.beginPath();
    ctx.arc(p.sx, p.sy, r, 0, TAU);
    ctx.fill();
  }
}

function drawGridFloor() {
  // subtle perspective grid below ship for speed feel
  ctx.strokeStyle = 'rgba(60, 140, 220, 0.18)';
  ctx.lineWidth = 1;
  for (let z = 100; z < WORLD_Z_MAX; z += 60) {
    const p = project(-350, -200, z);
    const q = project(350, -200, z);
    ctx.beginPath();
    ctx.moveTo(p.sx, p.sy);
    ctx.lineTo(q.sx, q.sy);
    ctx.stroke();
  }
  for (let x = -350; x <= 350; x += 70) {
    const a = project(x, -200, 80);
    const b = project(x, -200, WORLD_Z_MAX);
    ctx.beginPath();
    ctx.moveTo(a.sx, a.sy);
    ctx.lineTo(b.sx, b.sy);
    ctx.stroke();
  }
}

function drawMeteor(m) {
  const p = project(m.x, m.y, m.z);
  if (p.s <= 0.02 || p.s > 40) return;
  const r = m.size * p.s;
  if (r < 1) return;

  ctx.save();
  ctx.translate(p.sx, p.sy);
  ctx.rotate(m.rot);

  // glow
  const glow = ctx.createRadialGradient(0, 0, r * 0.3, 0, 0, r * 1.9);
  glow.addColorStop(0, `hsla(${m.hue}, 100%, 65%, 0.5)`);
  glow.addColorStop(1, 'transparent');
  ctx.fillStyle = glow;
  ctx.beginPath();
  ctx.arc(0, 0, r * 1.9, 0, TAU);
  ctx.fill();

  // body (irregular polygon)
  const grad = ctx.createRadialGradient(-r * 0.3, -r * 0.3, r * 0.1, 0, 0, r);
  grad.addColorStop(0, `hsl(${m.hue}, 70%, 62%)`);
  grad.addColorStop(0.6, `hsl(${m.hue - 8}, 60%, 38%)`);
  grad.addColorStop(1, `hsl(${m.hue - 15}, 55%, 18%)`);
  ctx.fillStyle = grad;
  ctx.beginPath();
  const v = m.verts;
  for (let i = 0; i < v.length; i++) {
    const vx = v[i].x * p.s, vy = v[i].y * p.s;
    if (i === 0) ctx.moveTo(vx, vy); else ctx.lineTo(vx, vy);
  }
  ctx.closePath();
  ctx.fill();

  // craters
  ctx.fillStyle = `hsla(${m.hue - 15}, 60%, 12%, 0.7)`;
  for (let i = 0; i < 3; i++) {
    const ca = m.rot * 0.7 + i * 2.1;
    const cr = r * (0.12 + 0.05 * i);
    ctx.beginPath();
    ctx.arc(Math.cos(ca) * r * 0.4, Math.sin(ca) * r * 0.4, cr, 0, TAU);
    ctx.fill();
  }

  // fire trail behind (toward camera)
  const trail = ctx.createLinearGradient(0, 0, 0, r * 2.5);
  trail.addColorStop(0, `hsla(${m.hue + 10}, 100%, 60%, 0.55)`);
  trail.addColorStop(1, 'transparent');
  ctx.fillStyle = trail;
  ctx.beginPath();
  ctx.moveTo(-r * 0.5, r * 0.6);
  ctx.lineTo(r * 0.5, r * 0.6);
  ctx.lineTo(0, r * 2.5);
  ctx.closePath();
  ctx.fill();

  ctx.restore();
}

function drawLaser(l) {
  const p1 = project(l.x, l.y, l.z);
  const p2 = project(l.x - l.vx * 0.02, l.y - l.vy * 0.02, l.z - 40);
  if (p1.s <= 0 || p2.s <= 0) return;
  ctx.strokeStyle = 'rgba(140, 235, 255, 0.95)';
  ctx.lineWidth = clamp(p1.s * 4, 1, 6);
  ctx.lineCap = 'round';
  ctx.shadowColor = '#7de8ff';
  ctx.shadowBlur = 12;
  ctx.beginPath();
  ctx.moveTo(p1.sx, p1.sy);
  ctx.lineTo(p2.sx, p2.sy);
  ctx.stroke();
  ctx.shadowBlur = 0;
}

function drawPowerup(p) {
  const pr = project(p.x, p.y, p.z);
  if (pr.s <= 0.02) return;
  const r = 14 * pr.s;
  ctx.save();
  ctx.translate(pr.sx, pr.sy);
  ctx.rotate(p.rot);
  ctx.fillStyle = '#7dffb0';
  ctx.shadowColor = '#50ff90';
  ctx.shadowBlur = 16;
  ctx.fillRect(-r * 0.25, -r * 0.8, r * 0.5, r * 1.6);
  ctx.fillRect(-r * 0.8, -r * 0.25, r * 1.6, r * 0.5);
  ctx.restore();
  ctx.shadowBlur = 0;
}

function drawShip() {
  const p = project(ship.x, ship.y, ship.z);
  if (p.s <= 0) return;
  const s = p.s * 26;
  const tilt = clamp(ship.vx * 0.0015, -0.5, 0.5);

  ctx.save();
  ctx.translate(p.sx, p.sy);
  ctx.rotate(tilt);

  // engine flame
  const flame = 1 + Math.sin(time * 40) * 0.25 + (boostActive ? 0.8 : 0);
  const fg = ctx.createLinearGradient(0, s * 0.5, 0, s * (1.1 + flame * 0.5));
  fg.addColorStop(0, 'rgba(120, 220, 255, 0.9)');
  fg.addColorStop(0.5, 'rgba(80, 140, 255, 0.6)');
  fg.addColorStop(1, 'transparent');
  ctx.fillStyle = fg;
  ctx.beginPath();
  ctx.moveTo(-s * 0.3, s * 0.45);
  ctx.lineTo(s * 0.3, s * 0.45);
  ctx.lineTo(0, s * (1.1 + flame * 0.6));
  ctx.closePath();
  ctx.fill();

  // hull
  const hg = ctx.createLinearGradient(0, -s, 0, s * 0.5);
  hg.addColorStop(0, '#bfe9ff');
  hg.addColorStop(0.5, '#4d9fe0');
  hg.addColorStop(1, '#1c4a80');
  ctx.fillStyle = hg;
  ctx.beginPath();
  ctx.moveTo(0, -s);          // nose
  ctx.lineTo(s * 0.85, s * 0.5);   // right wing tip
  ctx.lineTo(s * 0.35, s * 0.3);
  ctx.lineTo(0, s * 0.45);
  ctx.lineTo(-s * 0.35, s * 0.3);
  ctx.lineTo(-s * 0.85, s * 0.5);  // left wing tip
  ctx.closePath();
  ctx.fill();

  // cockpit
  const cg = ctx.createRadialGradient(0, -s * 0.35, 1, 0, -s * 0.3, s * 0.45);
  cg.addColorStop(0, '#eaffff');
  cg.addColorStop(1, '#2a7ab8');
  ctx.fillStyle = cg;
  ctx.beginPath();
  ctx.ellipse(0, -s * 0.3, s * 0.22, s * 0.42, 0, 0, TAU);
  ctx.fill();

  // wing lights
  ctx.fillStyle = boostActive ? '#ffd76a' : '#ff5050';
  ctx.shadowColor = boostActive ? '#ffd76a' : '#ff5050';
  ctx.shadowBlur = 10;
  ctx.beginPath();
  ctx.arc(-s * 0.7, s * 0.42, s * 0.09, 0, TAU);
  ctx.fill();
  ctx.fillStyle = '#50ff90';
  ctx.shadowColor = '#50ff90';
  ctx.beginPath();
  ctx.arc(s * 0.7, s * 0.42, s * 0.09, 0, TAU);
  ctx.fill();

  ctx.restore();
  ctx.shadowBlur = 0;
}

function drawParticles() {
  for (const p of particles) {
    const pr = project(p.x, p.y, p.z);
    if (pr.s <= 0.02) continue;
    const a = clamp(p.life / p.maxLife, 0, 1);
    ctx.globalAlpha = a;
    ctx.fillStyle = p.color;
    ctx.beginPath();
    ctx.arc(pr.sx, pr.sy, clamp(p.size * pr.s, 0.5, 8), 0, TAU);
    ctx.fill();
  }
  ctx.globalAlpha = 1;
}

function render() {
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  // background gradient
  const bg = ctx.createRadialGradient(W / 2, H * 0.45, 60, W / 2, H / 2, Math.max(W, H) * 0.8);
  bg.addColorStop(0, '#0a1630');
  bg.addColorStop(0.5, '#050b1c');
  bg.addColorStop(1, '#010208');
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, W, H);

  // camera shake
  if (shake > 0.3) {
    ctx.translate(rand(-shake, shake), rand(-shake, shake));
  }

  drawStars();
  drawGridFloor();

  // depth sort: far to near
  const drawables = [];
  for (const m of meteors) drawables.push({ z: m.z, type: 'meteor', obj: m });
  for (const l of lasers) drawables.push({ z: l.z, type: 'laser', obj: l });
  for (const p of powerups) drawables.push({ z: p.z, type: 'powerup', obj: p });
  if (state !== STATE.GAMEOVER) drawables.push({ z: ship.z, type: 'ship', obj: null });

  drawables.sort((a, b) => b.z - a.z);
  for (const d of drawables) {
    if (d.type === 'meteor') drawMeteor(d.obj);
    else if (d.type === 'laser') drawLaser(d.obj);
    else if (d.type === 'powerup') drawPowerup(d.obj);
    else if (d.type === 'ship') drawShip();
  }

  drawParticles();
}

// ---------- main loop ----------
function frame(now) {
  const dt = Math.min((now - last) / 1000, 0.05);
  last = now;

  if (state === STATE.PLAYING) {
    update(dt);
  } else if (state === STATE.GAMEOVER || state === STATE.MENU) {
    // keep particles/stars animating behind menus
    for (let i = particles.length - 1; i >= 0; i--) {
      const p = particles[i];
      p.x += p.vx * dt; p.y += p.vy * dt; p.z += p.vz * dt;
      p.life -= dt;
      if (p.life <= 0) particles.splice(i, 1);
    }
    for (const s of stars) {
      s.z -= 260 * dt;
      if (s.z < 30) { s.z = WORLD_Z_MAX; s.x = rand(-1, 1) * W * 0.7; s.y = rand(-1, 1) * H * 0.7; }
    }
    shake *= Math.pow(0.02, dt);
  }

  render();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
