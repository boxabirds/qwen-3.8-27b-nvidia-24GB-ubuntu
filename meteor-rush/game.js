(function () {
'use strict';

var canvas = document.getElementById('game');
var ctx = canvas.getContext('2d');
var W = 0, H = 0, CX = 0, CY = 0, DPR = 1;

var scoreEl = document.getElementById('score');
var speedEl = document.getElementById('speed');
var livesEl = document.getElementById('lives');
var menuEl = document.getElementById('menu');
var overEl = document.getElementById('over');
var pauseEl = document.getElementById('pause');
var hudEl = document.getElementById('hud');
var msgEl = document.getElementById('msg');
var flashEl = document.getElementById('flash');
var finalScoreEl = document.getElementById('finalScore');
var bestScoreEl = document.getElementById('bestScore');
var menuBestEl = document.getElementById('menuBest');
var startBtn = document.getElementById('startBtn');
var retryBtn = document.getElementById('retryBtn');

var play = { rangeX: 26, rangeY: 15 };

var CFG = {
  focal: 300,
  near: 8,
  playerZ: 18,
  shipSpeed: 70,
  fireRate: 0.14,
  bulletSpeed: 520,
  bulletLife: 1.7,
  spawnBase: 0.9,
  spawnMin: 0.26,
  rockMinR: 3.2,
  rockMaxR: 9,
  rockFar: 460,
  baseForward: 60,
  maxFwdMult: 3.2,
  maxRocks: 30,
  lives: 3,
  invuln: 2.0,
  starCount: 240
};

function resize() {
  DPR = Math.min(window.devicePixelRatio || 1, 2);
  W = window.innerWidth;
  H = window.innerHeight;
  canvas.width = Math.floor(W * DPR);
  canvas.height = Math.floor(H * DPR);
  canvas.style.width = W + 'px';
  canvas.style.height = H + 'px';
  ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  CX = W / 2;
  CY = H / 2;
  play.rangeX = Math.max(14, (CX * CFG.playerZ / CFG.focal) * 0.78);
  play.rangeY = Math.max(9, (CY * CFG.playerZ / CFG.focal) * 0.78);
}
window.addEventListener('resize', resize);
resize();

function norm3(x, y, z) {
  var l = Math.sqrt(x * x + y * y + z * z) || 1;
  return [x / l, y / l, z / l];
}

function rand3(s) {
  var x = Math.sin(s * 127.1 + 311.7) * 43758.5453123;
  return x - Math.floor(x);
}

function icosahedron() {
  var t = (1 + Math.sqrt(5)) / 2;
  var v = [
    [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
    [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
    [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]
  ];
  v = v.map(function (p) { return norm3(p[0], p[1], p[2]); });
  var f = [
    [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
    [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
    [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
    [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
  ];
  return { v: v, f: f };
}

function subdivide(m) {
  var cache = {};
  var nf = [];
  function mid(a, b) {
    var k = a < b ? a + '_' + b : b + '_' + a;
    if (cache[k] !== undefined) return cache[k];
    var pa = m.v[a], pb = m.v[b];
    var nv = norm3((pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2, (pa[2] + pb[2]) / 2);
    m.v.push(nv);
    var id = m.v.length - 1;
    cache[k] = id;
    return id;
  }
  for (var i = 0; i < m.f.length; i++) {
    var f = m.f[i];
    var ab = mid(f[0], f[1]);
    var bc = mid(f[1], f[2]);
    var ca = mid(f[2], f[0]);
    nf.push([f[0], ab, ca], [f[1], bc, ab], [f[2], ca, bc], [ab, bc, ca]);
  }
  m.f = nf;
}

function jitter(m, amt, seed) {
  for (var i = 0; i < m.v.length; i++) {
    var s = 1 + (rand3(seed * 57.31 + i * 17.17) - 0.5) * amt;
    m.v[i][0] *= s;
    m.v[i][1] *= s;
    m.v[i][2] *= s;
  }
}

function faceNormals(m) {
  m.n = [];
  for (var i = 0; i < m.f.length; i++) {
    var f = m.f[i];
    var a = m.v[f[0]], b = m.v[f[1]], c = m.v[f[2]];
    var u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
    var w = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
    var n = [
      u[1] * w[2] - u[2] * w[1],
      u[2] * w[0] - u[0] * w[2],
      u[0] * w[1] - u[1] * w[0]
    ];
    var cx = (a[0] + b[0] + c[0]) / 3;
    var cy = (a[1] + b[1] + c[1]) / 3;
    var cz = (a[2] + b[2] + c[2]) / 3;
    if (n[0] * cx + n[1] * cy + n[2] * cz < 0) n = [-n[0], -n[1], -n[2]];
    m.n.push(norm3(n[0], n[1], n[2]));
  }
}

var rockMeshes = [];
for (var gi = 0; gi < 4; gi++) {
  (function (gi) {
    var base = icosahedron();
    var m = { v: base.v, f: base.f };
    subdivide(m);
    jitter(m, 0.45, gi + 1);
    faceNormals(m);
    rockMeshes.push(m);
  })(gi);
}

var shipMesh = (function () {
  var m = {
    v: [
      [0, 0, 2.4],
      [-2.0, 0.25, -1.4],
      [2.0, 0.25, -1.4],
      [0, 1.2, -0.6],
      [0, -0.8, -0.6],
      [0, 0.1, -2.0]
    ],
    f: [
      [0, 1, 3], [0, 3, 2], [0, 2, 4], [0, 4, 1],
      [1, 3, 5], [3, 2, 5], [2, 4, 5], [4, 1, 5]
    ]
  };
  faceNormals(m);
  return m;
})();

var LIGHT = norm3(-0.57, 0.76, 0.62);

function rotM(rx, ry, rz) {
  var cx = Math.cos(rx), sx = Math.sin(rx);
  var cy = Math.cos(ry), sy = Math.sin(ry);
  var cz = Math.cos(rz), sz = Math.sin(rz);
  return [
    cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx,
    sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx,
    -sy, cy * sx, cy * cx
  ];
}

function applyM(M, x, y, z) {
  return [
    M[0] * x + M[1] * y + M[2] * z,
    M[3] * x + M[4] * y + M[5] * z,
    M[6] * x + M[7] * y + M[8] * z
  ];
}

function project(x, y, z) {
  if (z < CFG.near) return null;
  var s = CFG.focal / z;
  return { x: CX + x * s, y: CY - y * s, s: s, z: z };
}

var sfx = (function () {
  var ac = null, master = null, muted = false;
  function ensure() {
    if (!ac) {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      ac = new Ctx();
      master = ac.createGain();
      master.gain.value = 0.5;
      master.connect(ac.destination);
    }
    if (ac.state === 'suspended') ac.resume();
  }
  function tone(freq, dur, type, vol, slideTo) {
    if (muted || !ac) return;
    var t0 = ac.currentTime;
    var o = ac.createOscillator();
    var g = ac.createGain();
    o.type = type;
    o.frequency.setValueAtTime(freq, t0);
    if (slideTo) o.frequency.exponentialRampToValueAtTime(Math.max(1, slideTo), t0 + dur);
    g.gain.setValueAtTime(vol, t0);
    g.gain.exponentialRampToValueAtTime(0.001, t0 + dur);
    o.connect(g);
    g.connect(master);
    o.start(t0);
    o.stop(t0 + dur + 0.02);
  }
  function noise(dur, vol, cutoff) {
    if (muted || !ac) return;
    var n = Math.floor(ac.sampleRate * dur);
    var buf = ac.createBuffer(1, n, ac.sampleRate);
    var d = buf.getChannelData(0);
    for (var i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / n);
    var src = ac.createBufferSource();
    src.buffer = buf;
    var f = ac.createBiquadFilter();
    f.type = 'lowpass';
    f.frequency.value = cutoff;
    var g = ac.createGain();
    g.gain.value = vol;
    src.connect(f);
    f.connect(g);
    g.connect(master);
    src.start();
  }
  return {
    ensure: ensure,
    shoot: function () { ensure(); tone(920, 0.07, 'square', 0.08, 320); },
    explode: function (size) { ensure(); noise(0.3, 0.35, 700 + size * 80); tone(80, 0.28, 'sawtooth', 0.22, 32); },
    hit: function () { ensure(); noise(0.45, 0.5, 520); tone(150, 0.4, 'sawtooth', 0.35, 40); },
    over: function () {
      ensure();
      tone(392, 0.4, 'triangle', 0.4, 196);
      setTimeout(function () { tone(196, 0.7, 'triangle', 0.4, 98); }, 220);
    },
    toggle: function () { muted = !muted; return muted; }
  };
})();

var state = 'menu';
var time = 0, score = 0, kills = 0;
var lives = CFG.lives;
var invulnTimer = 0, shake = 0, flashTimer = 0;
var fwdMult = 1, spawnTimer = 0;
var ship = { x: 0, y: 0, vx: 0, vy: 0 };
var rocks = [], bullets = [], particles = [], stars = [];
var input = { l: 0, r: 0, u: 0, d: 0, shoot: 0 };
var lastShot = -1;
var lastScoreInt = -1;
var best = 0;
try { best = parseInt(localStorage.getItem('meteorRushBest') || '0', 10) || 0; } catch (e) {}

function newStar(z) {
  return {
    x: (Math.random() * 2 - 1) * 150,
    y: (Math.random() * 2 - 1) * 95,
    z: z !== undefined ? z : CFG.rockFar * (0.4 + Math.random() * 0.6),
    tw: Math.random() * 6.283
  };
}

function initStars() {
  stars = [];
  for (var i = 0; i < CFG.starCount; i++) stars.push(newStar());
}
initStars();

function rockTint() {
  var b = 85 + Math.random() * 55;
  return [b, b * (0.88 + Math.random() * 0.16), b * (0.78 + Math.random() * 0.14)];
}

function spawnRock() {
  if (rocks.length >= CFG.maxRocks) return;
  var r = CFG.rockMinR + Math.pow(Math.random(), 1.7) * (CFG.rockMaxR - CFG.rockMinR);
  rocks.push({
    x: (Math.random() * 2 - 1) * (play.rangeX + r * 0.9),
    y: (Math.random() * 2 - 1) * (play.rangeY + r * 0.9),
    z: CFG.rockFar * (0.8 + Math.random() * 0.5),
    r: r,
    vx: (Math.random() * 2 - 1) * 4,
    vy: (Math.random() * 2 - 1) * 4,
    drift: 20 + Math.random() * 60,
    rx: Math.random() * 6.283,
    ry: Math.random() * 6.283,
    rz: Math.random() * 6.283,
    rvx: (Math.random() * 2 - 1) * 1.3,
    rvy: (Math.random() * 2 - 1) * 1.3,
    rvz: (Math.random() * 2 - 1) * 1.3,
    mesh: rockMeshes[(Math.random() * rockMeshes.length) | 0],
    tint: rockTint(),
    hp: Math.max(1, Math.round(r / 2.6))
  });
}

function spawnBurst(x, y, z, col, n) {
  for (var i = 0; i < n; i++) {
    var a = Math.random() * 6.283;
    var b = Math.acos(Math.random() * 2 - 1);
    var sp = 18 + Math.random() * 55;
    particles.push({
      x: x, y: y, z: z,
      vx: Math.sin(a) * Math.sin(b) * sp,
      vy: Math.cos(b) * sp,
      vz: Math.cos(a) * Math.sin(b) * sp,
      life: 0.3 + Math.random() * 0.45,
      col: col,
      s: 0.7 + Math.random() * 1.6
    });
  }
}

function explodeRock(r) {
  shake = Math.min(1, shake + r.r * 0.045 + 0.12);
  flashTimer = Math.min(1, flashTimer + 0.1 * (r.r / CFG.rockMaxR) + 0.1);
  sfx.explode(r.r);
  var n = Math.floor(r.r * 2.6) + 10;
  spawnBurst(r.x, r.y, r.z, [255, 130 + Math.random() * 90 | 0, 40 + Math.random() * 70 | 0], n);
  if (r.r > 5.2) {
    var fr = r.r * 0.45;
    for (var k = 0; k < 2; k++) {
      rocks.push({
        x: r.x + (Math.random() * 2 - 1) * fr,
        y: r.y + (Math.random() * 2 - 1) * fr,
        z: r.z,
        r: fr,
        vx: r.vx + (Math.random() * 2 - 1) * 12,
        vy: r.vy + (Math.random() * 2 - 1) * 12,
        drift: r.drift + 25,
        rx: Math.random() * 6.283,
        ry: Math.random() * 6.283,
        rz: Math.random() * 6.283,
        rvx: r.rvx * 1.6,
        rvy: r.rvy * 1.6,
        rvz: r.rvz * 1.6,
        mesh: r.mesh,
        tint: r.tint,
        hp: Math.max(1, Math.round(fr / 2.6))
      });
    }
  }
}

function hitShip() {
  if (invulnTimer > 0 || state !== 'playing') return;
  lives--;
  invulnTimer = CFG.invuln;
  shake = 1;
  flashTimer = 0.9;
  sfx.hit();
  spawnBurst(ship.x, ship.y, CFG.playerZ, [130, 210, 255], 24);
  if (lives <= 0) {
    endGame();
  }
}

function endGame() {
  state = 'gameover';
  var sc = Math.floor(score);
  if (sc > best) {
    best = sc;
    try { localStorage.setItem('meteorRushBest', String(best)); } catch (e) {}
  }
  finalScoreEl.textContent = 'SCORE ' + sc.toLocaleString();
  bestScoreEl.textContent = 'BEST ' + best.toLocaleString();
  show(overEl);
  hide(hudEl);
  hide(msgEl);
  sfx.over();
}

function startGame() {
  sfx.ensure();
  time = 0;
  score = 0;
  kills = 0;
  lives = CFG.lives;
  invulnTimer = 1.5;
  shake = 0;
  flashTimer = 0;
  fwdMult = 1;
  spawnTimer = 0.6;
  lastShot = -1;
  ship = { x: 0, y: 0, vx: 0, vy: 0 };
  rocks = [];
  bullets = [];
  particles = [];
  lastScoreInt = -1;
  state = 'playing';
  hide(menuEl);
  hide(overEl);
  hide(pauseEl);
  show(hudEl);
  show(msgEl);
}

function show(el) { el.classList.remove('hidden'); }
function hide(el) { el.classList.add('hidden'); }

function update(dt) {
  time += dt;
  var level = 1 + Math.floor(time / 25);
  fwdMult = Math.min(1 + (level - 1) * 0.18, CFG.maxFwdMult);
  var fwd = CFG.baseForward * fwdMult;

  score += fwd * dt * 0.06;

  var ax = 0, ay = 0;
  if (input.l) ax -= 1;
  if (input.r) ax += 1;
  if (input.u) ay += 1;
  if (input.d) ay -= 1;
  ship.vx += (ax - ship.vx) * Math.min(1, dt * 10);
  ship.vy += (ay - ship.vy) * Math.min(1, dt * 10);
  ship.x = Math.max(-play.rangeX, Math.min(play.rangeX, ship.x + ship.vx * CFG.shipSpeed * dt));
  ship.y = Math.max(-play.rangeY, Math.min(play.rangeY, ship.y + ship.vy * CFG.shipSpeed * dt));

  if (input.shoot && time - lastShot >= CFG.fireRate) {
    lastShot = time;
    bullets.push({ x: ship.x - 1.5, y: ship.y + 0.3, z: CFG.playerZ + 2, vz: CFG.bulletSpeed, life: CFG.bulletLife });
    bullets.push({ x: ship.x + 1.5, y: ship.y + 0.3, z: CFG.playerZ + 2, vz: CFG.bulletSpeed, life: CFG.bulletLife });
    sfx.shoot();
  }

  spawnTimer -= dt;
  if (spawnTimer <= 0) {
    spawnTimer = Math.max(CFG.spawnMin, CFG.spawnBase - level * 0.05) * (0.7 + Math.random() * 0.6);
    spawnRock();
    if (level >= 4 && Math.random() < 0.35) spawnRock();
  }

  for (var i = rocks.length - 1; i >= 0; i--) {
    var r = rocks[i];
    r.z -= (fwd + r.drift) * dt;
    r.x += r.vx * dt;
    r.y += r.vy * dt;
    r.rx += r.rvx * dt;
    r.ry += r.rvy * dt;
    r.rz += r.rvz * dt;
    if (invulnTimer <= 0 && Math.abs(r.z - CFG.playerZ) < r.r * 0.7 + 1.6) {
      var dx = r.x - ship.x, dy = r.y - ship.y;
      var rr = r.r * 0.75 + 2.1;
      if (dx * dx + dy * dy < rr * rr) {
        explodeRock(r);
        rocks.splice(i, 1);
        hitShip();
        continue;
      }
    }
    if (r.z < 10) rocks.splice(i, 1);
  }

  for (var bi = bullets.length - 1; bi >= 0; bi--) {
    var b = bullets[bi];
    b.z += b.vz * dt;
    b.life -= dt;
    var removed = false;
    for (var j = rocks.length - 1; j >= 0; j--) {
      var ro = rocks[j];
      var dz = b.z - ro.z, ddx = b.x - ro.x, ddy = b.y - ro.y;
      var rad = ro.r * 0.95;
      if (dz * dz + ddx * ddx + ddy * ddy < rad * rad) {
        ro.hp--;
        spawnBurst(b.x, b.y, ro.z, [120, 230, 255], 5);
        if (ro.hp <= 0) {
          kills++;
          score += Math.round(ro.r * 10);
          explodeRock(ro);
          rocks.splice(j, 1);
        }
        removed = true;
        break;
      }
    }
    if (removed || b.life <= 0 || b.z > CFG.rockFar + 80) bullets.splice(bi, 1);
  }

  for (var pi = particles.length - 1; pi >= 0; pi--) {
    var p = particles[pi];
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    p.z += p.vz * dt;
    p.vx *= 0.985;
    p.vy *= 0.985;
    p.vz *= 0.985;
    p.life -= dt;
    if (p.life <= 0) particles.splice(pi, 1);
  }

  for (var si = 0; si < stars.length; si++) {
    var s = stars[si];
    s.z -= fwd * dt;
    if (s.z < CFG.near) stars[si] = newStar(CFG.rockFar * (0.7 + Math.random() * 0.5));
  }

  invulnTimer = Math.max(0, invulnTimer - dt);
  shake = Math.max(0, shake - dt * 2.6);
  flashTimer = Math.max(0, flashTimer - dt * 3);

  var sc = Math.floor(score);
  if (sc !== lastScoreInt) {
    lastScoreInt = sc;
    scoreEl.textContent = sc.toLocaleString();
  }
  speedEl.textContent = fwdMult.toFixed(1) + 'x';
  livesEl.innerHTML = lives > 0 ? '&#9829;'.repeat(lives) + '&#9826;'.repeat(CFG.lives - lives) : '—';
}

function updateAmbient(dt, fwd) {
  time += dt;
  for (var i = 0; i < stars.length; i++) {
    var s = stars[i];
    s.z -= fwd * dt;
    if (s.z < CFG.near) stars[i] = newStar(CFG.rockFar * (0.6 + Math.random() * 0.5));
  }
  if (fwd > 40 && rocks.length < 7 && Math.random() < 0.03) spawnRock();
  for (var ri = rocks.length - 1; ri >= 0; ri--) {
    var r = rocks[ri];
    r.z -= fwd * dt;
    r.x += r.vx * dt;
    r.y += r.vy * dt;
    r.rx += r.rvx * dt;
    r.ry += r.rvy * dt;
    r.rz += r.rvz * dt;
    if (r.z < 10) rocks.splice(ri, 1);
  }
  for (var pi = particles.length - 1; pi >= 0; pi--) {
    var p = particles[pi];
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    p.z += p.vz * dt;
    p.life -= dt;
    if (p.life <= 0) particles.splice(pi, 1);
  }
  flashTimer = Math.max(0, flashTimer - dt * 3);
}

function drawBackground() {
  var g = ctx.createLinearGradient(0, 0, 0, H);
  g.addColorStop(0, '#04051a');
  g.addColorStop(0.5, '#02030a');
  g.addColorStop(1, '#05060f');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, W, H);
  var r = ctx.createRadialGradient(CX, CY, 0, CX, CY, Math.max(W, H) * 0.75);
  r.addColorStop(0, 'rgba(45,80,160,0.16)');
  r.addColorStop(0.45, 'rgba(30,50,110,0.06)');
  r.addColorStop(1, 'rgba(0,0,0,0)');
  ctx.fillStyle = r;
  ctx.fillRect(0, 0, W, H);
}

function drawStars() {
  ctx.fillStyle = '#dfe9ff';
  for (var i = 0; i < stars.length; i++) {
    var s = stars[i];
    var p = project(s.x, s.y, s.z);
    if (!p) continue;
    var size = Math.max(0.5, p.s * 1.1);
    var a = (0.3 + 0.7 * (0.5 + 0.5 * Math.sin(time * 2.5 + s.tw))) * Math.min(1, (s.z - 6) / 46);
    if (a <= 0.02) continue;
    ctx.globalAlpha = a;
    ctx.fillRect(p.x - size / 2, p.y - size / 2, size, size);
  }
  ctx.globalAlpha = 1;
}

function drawMesh(mesh, M, ox, oy, oz, scale, col) {
  var pts = new Array(mesh.v.length);
  for (var i = 0; i < mesh.v.length; i++) {
    var v = mesh.v[i];
    var w = applyM(M, v[0] * scale, v[1] * scale, v[2] * scale);
    pts[i] = project(ox + w[0], oy + w[1], oz + w[2]);
  }
  var items = [];
  for (var fi = 0; fi < mesh.f.length; fi++) {
    var f = mesh.f[fi];
    var a = pts[f[0]], b = pts[f[1]], c = pts[f[2]];
    if (!a || !b || !c) continue;
    var n = applyM(M, mesh.n[fi][0], mesh.n[fi][1], mesh.n[fi][2]);
    var d = n[0] * LIGHT[0] + n[1] * LIGHT[1] + n[2] * LIGHT[2];
    items.push({ fi: fi, d: d, depth: (a.z + b.z + c.z) / 3 });
  }
  items.sort(function (p, q) { return q.depth - p.depth; });
  for (var k = 0; k < items.length; k++) {
    var it = items[k];
    var f2 = mesh.f[it.fi];
    var pa = pts[f2[0]], pb = pts[f2[1]], pc = pts[f2[2]];
    var L = 0.32 + 0.85 * Math.max(0, it.d);
    var rr = Math.min(255, col[0] * L) | 0;
    var gg = Math.min(255, col[1] * L) | 0;
    var bb = Math.min(255, col[2] * L) | 0;
    ctx.fillStyle = 'rgb(' + rr + ',' + gg + ',' + bb + ')';
    ctx.beginPath();
    ctx.moveTo(pa.x, pa.y);
    ctx.lineTo(pb.x, pb.y);
    ctx.lineTo(pc.x, pc.y);
    ctx.closePath();
    ctx.fill();
  }
}

function drawRock(r) {
  drawMesh(r.mesh, rotM(r.rx, r.ry, r.rz), r.x, r.y, r.z, r.r, r.tint);
}

function drawShip() {
  var inv = invulnTimer > 0 && Math.floor(time * 18) % 2 === 0;
  if (!inv) {
    var gp = project(ship.x, ship.y - 0.2, CFG.playerZ - 2.5);
    if (gp) {
      var fl = 0.6 + 0.4 * Math.sin(time * 42);
      var rad = Math.max(4, gp.s * 5.5);
      var g = ctx.createRadialGradient(gp.x, gp.y, 0, gp.x, gp.y, rad);
      g.addColorStop(0, 'rgba(140,225,255,' + (0.9 * fl) + ')');
      g.addColorStop(0.4, 'rgba(50,140,255,' + (0.35 * fl) + ')');
      g.addColorStop(1, 'rgba(20,60,180,0)');
      ctx.fillStyle = g;
      ctx.fillRect(gp.x - rad, gp.y - rad, rad * 2, rad * 2);
    }
  }
  if (inv) return;
  var roll = -ship.vx * 0.35;
  var yaw = ship.vx * 0.18;
  drawMesh(shipMesh, rotM(0, yaw, roll), ship.x, ship.y, CFG.playerZ, 1.15, [178, 205, 240]);
}

function drawBullet(b) {
  var p = project(b.x, b.y, b.z);
  if (!p) return;
  var rad = Math.max(5, p.s * 3.2);
  var g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, rad);
  g.addColorStop(0, 'rgba(230,255,255,0.95)');
  g.addColorStop(0.25, 'rgba(90,225,255,0.8)');
  g.addColorStop(1, 'rgba(20,80,220,0)');
  ctx.fillStyle = g;
  ctx.fillRect(p.x - rad, p.y - rad, rad * 2, rad * 2);
}

function drawParticles() {
  ctx.globalCompositeOperation = 'lighter';
  for (var i = 0; i < particles.length; i++) {
    var p = particles[i];
    var pr = project(p.x, p.y, p.z);
    if (!pr) continue;
    var a = Math.max(0, Math.min(1, p.life / 0.55));
    var sz = Math.max(0.6, pr.s * p.s * 0.55);
    ctx.fillStyle = 'rgba(' + (p.col[0] | 0) + ',' + (p.col[1] | 0) + ',' + (p.col[2] | 0) + ',' + a + ')';
    ctx.fillRect(pr.x - sz, pr.y - sz, sz * 2, sz * 2);
  }
  ctx.globalCompositeOperation = 'source-over';
}

function render() {
  var shx = (Math.random() * 2 - 1) * shake * 16;
  var shy = (Math.random() * 2 - 1) * shake * 16;
  ctx.save();
  ctx.translate(shx, shy);
  drawBackground();
  drawStars();

  var list = [];
  for (var i = 0; i < rocks.length; i++) {
    (function (r) { list.push({ z: r.z, fn: function () { drawRock(r); } }); })(rocks[i]);
  }
  for (var bi = 0; bi < bullets.length; bi++) {
    (function (b) { list.push({ z: b.z, fn: function () { drawBullet(b); } }); })(bullets[bi]);
  }
  if (state === 'playing') list.push({ z: CFG.playerZ, fn: drawShip });
  list.sort(function (a, b) { return b.z - a.z; });
  for (var k = 0; k < list.length; k++) list[k].fn();

  drawParticles();
  ctx.restore();

  flashEl.style.opacity = Math.min(0.75, flashTimer * 0.8).toFixed(3);
}

startBtn.addEventListener('click', startGame);
retryBtn.addEventListener('click', startGame);

window.addEventListener('keydown', function (e) {
  var k = e.key.toLowerCase();
  if (k === ' ' || k === 'arrowup' || k === 'arrowdown' || k === 'arrowleft' || k === 'arrowright') e.preventDefault();
  if (k === 'arrowleft' || k === 'a') input.l = 1;
  if (k === 'arrowright' || k === 'd') input.r = 1;
  if (k === 'arrowup' || k === 'w') input.u = 1;
  if (k === 'arrowdown' || k === 's') input.d = 1;
  if (k === ' ') input.shoot = 1;
  if (k === 'enter' && (state === 'menu' || state === 'gameover')) startGame();
  if (k === 'p') {
    if (state === 'playing') { state = 'paused'; show(pauseEl); }
    else if (state === 'paused') { state = 'playing'; hide(pauseEl); lastT = performance.now(); }
  }
  if (k === 'm') { sfx.ensure(); sfx.toggle(); }
});

window.addEventListener('keyup', function (e) {
  var k = e.key.toLowerCase();
  if (k === 'arrowleft' || k === 'a') input.l = 0;
  if (k === 'arrowright' || k === 'd') input.r = 0;
  if (k === 'arrowup' || k === 'w') input.u = 0;
  if (k === 'arrowdown' || k === 's') input.d = 0;
  if (k === ' ') input.shoot = 0;
});

window.addEventListener('blur', function () {
  input.l = input.r = input.u = input.d = input.shoot = 0;
  if (state === 'playing') { state = 'paused'; show(pauseEl); }
});

if (best > 0) {
  menuBestEl.textContent = 'BEST ' + best.toLocaleString();
  show(menuBestEl);
}

var lastT = performance.now();
function frame(now) {
  var dt = (now - lastT) / 1000;
  lastT = now;
  if (dt > 0.05) dt = 0.05;
  if (dt < 0) dt = 0;
  if (state === 'playing') update(dt);
  else if (state !== 'paused') updateAmbient(dt, state === 'menu' ? CFG.baseForward * 0.55 : 14);
  render();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

})();
