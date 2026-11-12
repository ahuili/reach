// 手边 Reach 介绍视频：把 index.html 逐帧渲染成视频：本机 Chrome（无头）+ Chrome 调试协议截图 + ffmpeg 合成。不需要 npm 依赖。
// 用法：
//   node render.mjs                         → ../dist/Reach-介绍.mp4 + ../assets/demo.gif
//   node render.mjs --stills 12,20.5,33     → frames/still-*.png（检查画面用）
//   GITHUB_OWNER=xxx node render.mjs        → 片尾的 brew 命令和网址换成你的用户名
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const FPS = 30;
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const owner = process.env.GITHUB_OWNER
  || (readFileSync(path.join(root, 'scripts/repo.env'), 'utf8').match(/GITHUB_OWNER:-([^}"]+)/) || [])[1] || 'OWNER';
const args = process.argv.slice(2);
const stills = args[0] === '--stills' ? args[1].split(',').map(Number) : null;

const port = 9300 + Math.floor(Math.random() * 400);
const profile = path.join(os.tmpdir(), 'reach-promo-chrome-' + port);
const chrome = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--hide-scrollbars',
  '--allow-file-access-from-files', '--force-device-scale-factor=1', '--window-size=1920,1080', '--no-first-run', 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));

let ws, nextId = 1; const waiting = new Map(), events = [];
async function connect() {
  for (let i = 0; i < 50; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const pg = list.find(x => x.type === 'page');
      if (pg) { ws = new WebSocket(pg.webSocketDebuggerUrl); break; }
    } catch {}
    await sleep(200);
  }
  if (!ws) throw new Error('连不上 Chrome');
  await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
  ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); } else events.push(d); };
}
const send = (method, params = {}) => new Promise((ok, bad) => { const id = nextId++; waiting.set(id, d => d.error ? bad(new Error(method + ': ' + d.error.message)) : ok(d.result)); ws.send(JSON.stringify({ id, method, params })); });

try {
  await connect();
  await send('Page.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
  const url = 'file://' + path.join(here, 'index.html') + `?render=1&owner=${encodeURIComponent(owner)}`;
  await send('Page.navigate', { url });
  for (let i = 0; i < 100 && !events.some(e => e.method === 'Page.loadEventFired'); i++) await sleep(100);
  await send('Runtime.evaluate', { expression: 'document.fonts.ready', awaitPromise: true });
  const { result } = await send('Runtime.evaluate', { expression: 'window.DURATION' });
  const duration = result.value;

  const out = path.join(here, 'frames');
  rmSync(out, { recursive: true, force: true }); mkdirSync(out, { recursive: true });
  const shoot = async (t, file, fmt = 'jpeg') => {
    await send('Runtime.evaluate', { expression: `renderAt(${t})` });
    const { data } = await send('Page.captureScreenshot', { format: fmt, quality: fmt === 'jpeg' ? 92 : undefined, captureBeyondViewport: false });
    writeFileSync(file, Buffer.from(data, 'base64'));
  };

  if (stills) {
    for (const t of stills) await shoot(t, path.join(out, `still-${t}.png`), 'png');
    console.log('✓ 截图在', out);
  } else {
    const n = Math.round(duration * FPS);
    const t0 = Date.now();
    for (let i = 0; i < n; i++) {
      await shoot(i / FPS, path.join(out, String(i).padStart(5, '0') + '.jpg'));
      if (i % 150 === 0) process.stdout.write(`\r帧 ${i}/${n}（${Math.round((Date.now() - t0) / 1000)}s）`);
    }
    console.log(`\r✓ ${n} 帧`);
    const dist = path.join(root, 'dist'); mkdirSync(dist, { recursive: true });
    const mp4 = path.join(dist, 'Reach-介绍.mp4');
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(FPS), '-i', path.join(out, '%05d.jpg'),
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20', '-preset', 'slow', '-movflags', '+faststart', mp4], { stdio: 'inherit' });
    // README 用的 GIF：侧栏、粘贴、截图、篮子那一段（3.6~27.6 秒），960 宽、12 帧
    const gif = path.join(root, 'assets', 'demo.gif');
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-ss', '3.6', '-t', '24', '-i', mp4, '-vf',
      'fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle', gif], { stdio: 'inherit' });
    console.log('✓', mp4, '\n✓', gif);
  }
} finally {
  try { ws?.close(); } catch {}
  chrome.kill();
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
