'use strict';
const $ = id => document.getElementById(id);
const SVG_NS = 'http://www.w3.org/2000/svg';
const MARKS = [0, 5, 10, 50, 100, 250, 500, 1000];
const SEGMENTS = MARKS.length - 1;
const SWEEP = 270;
const START = 135;
const RADIUS = 92;
const HUB = 98;
const NEEDLE_TIP = 61;
const BUSY = ['INSTALLING', 'CONNECTING', 'PING', 'DOWNLOAD', 'UPLOAD'];
const RUNNING = ['CONNECTING', 'PING', 'DOWNLOAD', 'UPLOAD'];
const METERED = ['DOWNLOAD', 'UPLOAD'];
const DIRS = new Set(['left', 'right', 'up', 'down']);
const BACKENDS = {
 global: { zh: '全球网测', en: 'CAICT', program: 'globalspeedtest-go',
  source: ['从 GitHub 下载最新版本并安装', 'Download the latest release from GitHub and install it'] },
 speedtest: { zh: 'speedtest.net', en: 'speedtest.net', program: 'speedtest-go',
  source: ['从 OpenWrt 软件源安装', 'Install it from the OpenWrt package feed'] }
};
const words = {
 title: ['测速', 'Speed test'],
 go: ['开始', 'GO'],
 download: ['下载', 'Download'],
 upload: ['上传', 'Upload'],
 ping: ['延迟', 'Ping'],
 jitter: ['抖动', 'Jitter'],
 installTitle: ['安装测速程序', 'Install the speed test'],
 install: ['下载安装', 'Install'],
 cancel: ['取消', 'Cancel'],
 close: ['关闭', 'Close'],
 backendTitle: ['切换后端', 'Switch backend'],
 backendGlobal: ['全球网测', 'CAICT'],
 check: ['正在获取最新版本…', 'Finding the latest version…'],
 installStep: ['正在安装…', 'Installing…'],
 update: ['正在更新软件源…', 'Updating the package feeds…'],
 add: ['正在下载安装…', 'Downloading and installing…'],
 installFailed: ['安装失败，请检查网络后重试', 'The install failed; check the network and retry'],
 testFailed: ['测速失败，请检查网络后重试', 'Speed test failed; check the network and retry'],
 startFailed: ['无法启动测速', 'Cannot start the speed test'],
 cancelled: ['已取消测速', 'Speed test cancelled']
};
const t = key => e5.t({ zh: words[key][0], en: words[key][1] });
const tr = (zh, en) => e5.t({ zh, en });

let status = { phase: 'IDLE', backend: 'global', installed: true, failed: null };
// The open dialog: 'backend', 'install' (asking), 'progress' (installing, or
// its failure until closed), or none.
let dialog = null;
let pending = false;
let pollTimer = null;
let themeKey = '';
let shown = 0;
let tween = 0;
const markViews = [];

const hostBody = (() => {
 try { return window.parent !== window ? window.parent.document.body : null; }
 catch (_) { return null; }
})();

function speedToNorm(mbps) {
 if (!(mbps > 0)) return 0;
 for (let i = 0; i < SEGMENTS; i++) {
  if (mbps < MARKS[i + 1])
   return (i + (mbps - MARKS[i]) / (MARKS[i + 1] - MARKS[i])) / SEGMENTS;
 }
 return 1;
}

function backendLabel(id) {
 return e5.t(BACKENDS[id]);
}

function polar(degrees, radius) {
 const a = degrees * Math.PI / 180;
 return { x: HUB + radius * Math.cos(a), y: HUB + radius * Math.sin(a) };
}

function arcPath(from, to, radius) {
 const sweep = to - from;
 if (!(sweep > .01)) return '';
 const a = polar(from, radius), b = polar(to, radius);
 const large = sweep > 180 ? 1 : 0;
 return `M${a.x.toFixed(2)} ${a.y.toFixed(2)}A${radius} ${radius} 0 ${large} 1 ${b.x.toFixed(2)} ${b.y.toFixed(2)}`;
}

function buildGauge() {
 $('gauge-arc-bg').setAttribute('d', arcPath(START, START + SWEEP, RADIUS));
 const box = $('gauge-marks');
 for (let i = 0; i <= SEGMENTS; i++) {
  const at = polar(START + SWEEP * i / SEGMENTS, 71);
  const mark = document.createElementNS(SVG_NS, 'text');
  mark.setAttribute('class', 'mark');
  mark.setAttribute('x', at.x.toFixed(2));
  mark.setAttribute('y', at.y.toFixed(2));
  mark.textContent = String(MARKS[i]);
  box.append(mark);
  markViews.push(mark);
 }
}

function paintNeedle(degrees) {
 const tip = polar(degrees, NEEDLE_TIP);
 const a = degrees * Math.PI / 180, dx = Math.cos(a), dy = Math.sin(a);
 $('gauge-needle').setAttribute('points',
  `${tip.x.toFixed(2)},${tip.y.toFixed(2)} ` +
  `${(HUB - dy * 4).toFixed(2)},${(HUB + dx * 4).toFixed(2)} ` +
  `${(HUB + dy * 4).toFixed(2)},${(HUB - dx * 4).toFixed(2)}`);
}

function paintReadout() {
 const phase = status.phase;
 let value = '···', unit;
 if (METERED.includes(phase)) {
  value = shown >= 100 ? shown.toFixed(0) : shown.toFixed(1);
  unit = phase === 'UPLOAD' ? '↑ Mbps' : '↓ Mbps';
 } else if (phase === 'PING' && status.ping_ms > 0) {
  value = String(Math.round(status.ping_ms));
  unit = tr('延迟 ms', 'Ping ms');
 } else if (phase === 'INSTALLING') {
  unit = tr('正在下载安装', 'Installing');
 } else {
  unit = tr('连接服务器', 'Connecting');
 }
 $('readout-value').textContent = value;
 $('readout-unit').textContent = unit;
}

function paintGauge() {
 const at = speedToNorm(shown);
 const degrees = START + SWEEP * at;
 $('gauge-arc').setAttribute('d', arcPath(START, degrees, RADIUS));
 markViews.forEach((mark, i) => mark.classList.toggle('on', i / SEGMENTS <= at));
 paintNeedle(degrees);
 paintReadout();
}

function showRate(target) {
 cancelAnimationFrame(tween);
 tween = 0;
 if (Math.abs(target - shown) < .05) {
  shown = target;
  paintGauge();
  return;
 }
 const from = shown;
 let start = 0;
 const step = now => {
  if (!start) start = now;
  const k = Math.min(1, (now - start) / 300);
  shown = from + (target - from) * (1 - Math.pow(1 - k, 3));
  paintGauge();
  if (k < 1) tween = requestAnimationFrame(step);
 };
 tween = requestAnimationFrame(step);
}

function syncTheme() {
 if (!hostBody) return;
 const palette = getComputedStyle(hostBody);
 const names = ['--bg', '--surface-rgb', '--button-rgb', '--active-rgb', '--text', '--dim', '--line', '--accent', '--ui-opacity'];
 const values = names.map(name => palette.getPropertyValue(name).trim());
 const themed = hostBody.dataset.theme || 'dark';
 const wallpaper = hostBody.classList.contains('desktop-wallpaper') ? hostBody.style.getPropertyValue('--desktop-wallpaper') : '';
 const key = `${themed}|${values.join('|')}|${wallpaper}`;
 if (key === themeKey) return;
 themeKey = key;
 const root = document.documentElement;
 names.forEach((name, i) => { if (values[i]) root.style.setProperty(name, values[i]); });
 document.body.dataset.theme = themed;
 document.body.classList.toggle('desktop-wallpaper', !!wallpaper);
 root.style.setProperty('--desktop-wallpaper', wallpaper);
}

function result(value, digits) {
 return value > 0 ? value.toFixed(digits) : '—';
}

function renderInfo() {
 $('download').textContent = result(status.download_mbps, 1);
 $('upload').textContent = result(status.upload_mbps, 1);
 $('ping').textContent = result(status.ping_ms, 0);
 $('jitter').textContent = result(status.jitter_ms, 0);
 $('isp').textContent = status.isp || tr('本机网络', 'This network');
 $('ip').textContent = status.ip || '—';
 $('sponsor').textContent = status.sponsor || t('backendTitle');
 $('server').textContent = status.server || backendLabel(status.backend);
 // The backend can be switched only until the first test after the page opens.
 $('backend-btn').disabled = status.phase !== 'IDLE' || pending;
}

function installStepText() {
 if (status.phase === 'FAILED') return t('installFailed');
 const step = status.install_step;
 if (step === 'download')
  return tr(`正在从 ${status.install_host || 'github.com'} 下载 v${status.install_version}…`,
   `Downloading v${status.install_version} from ${status.install_host || 'github.com'}…`);
 if (step === 'install') return t('installStep');
 return step ? t(step) : '';
}

function renderDialogs() {
 const b = BACKENDS[status.backend];
 $('backend-modal').hidden = dialog !== 'backend';
 $('install-modal').hidden = dialog !== 'install';
 $('progress-modal').hidden = dialog !== 'progress';
 $('backend-global').classList.toggle('current', status.backend === 'global');
 $('backend-speedtest').classList.toggle('current', status.backend === 'speedtest');
 $('install-body').textContent = tr(`${b.zh}需要 ${b.program}，是否${b.source[0]}？`,
  `${b.en} needs ${b.program}. ${b.source[1]}?`);
 $('progress-title').textContent = tr(`正在安装 ${b.program}`, `Installing ${b.program}`);
 $('progress-step').textContent = installStepText();
 $('progress-pct').textContent = `${status.install_pct}%`;
 $('progress-bar').style.width = `${status.install_pct}%`;
 $('progress-cancel').textContent = status.phase === 'FAILED' ? t('close') : t('cancel');
}

function render() {
 syncTheme();
 const busy = BUSY.includes(status.phase);
 document.body.dataset.phase = status.phase;
 $('gauge-svg').toggleAttribute('hidden', !RUNNING.includes(status.phase));
 $('go-btn').hidden = busy;
 $('readout').hidden = !busy;
 $('needle-group').toggleAttribute('hidden', !METERED.includes(status.phase));
 renderInfo();
 renderDialogs();
 showRate(METERED.includes(status.phase) ? status.current_mbps : 0);
 e5.keepAwake(busy);
}

function openDialog(name, focus) {
 dialog = name;
 render();
 $(focus).focus();
}

function closeDialog() {
 dialog = null;
 render();
 $('go-btn').focus();
}

function applyStatus(next) {
 const failed = next.phase === 'FAILED' && status.phase !== 'FAILED';
 status = next;
 if (status.phase === 'INSTALLING' || (failed && status.failed === 'install'))
  dialog = 'progress';
 else if (dialog === 'progress' && status.phase !== 'FAILED')
  dialog = null;
 if (failed && status.failed !== 'install')
  e5.toast(t(status.failed === 'start' ? 'startFailed' : 'testFailed'));
 render();
 clearTimeout(pollTimer);
 if (BUSY.includes(status.phase))
  pollTimer = setTimeout(() => call('/status'), 250);
}

// A refused action (the test already running, say) leaves the page as the
// backend has it.
async function call(path, body) {
 try {
  applyStatus(await e5.api(path, body ? { body } : undefined));
 } catch (e) {
  if (path !== '/status') await call('/status');
 }
}

async function act(path, body) {
 pending = true;
 render();
 await call(path, body);
 pending = false;
 render();
}

function begin() {
 if (pending || BUSY.includes(status.phase)) return;
 if (status.installed) act('/start', {});
 else openDialog('install', 'install-confirm');
}

function chooseBackend(id) {
 dialog = null;
 if (id === status.backend) closeDialog();
 else act('/backend', { backend: id }).then(() => $('backend-btn').focus());
}

// Cancels the install or the test; a cancelled test leaves the backend free to switch.
function stopRun() {
 if (RUNNING.includes(status.phase)) e5.toast(t('cancelled'));
 dialog = null;
 act(status.phase === 'FAILED' ? '/reset' : '/stop', {});
 $('go-btn').focus();
}

function visibleIn(root) {
 return [...root.querySelectorAll('button:not([disabled])')].filter(el => el.getClientRects().length > 0);
}

function moveFocus(root, kind) {
 const items = visibleIn(root);
 if (!items.length) return;
 const forward = kind === 'right' || kind === 'down';
 const index = items.indexOf(document.activeElement);
 if (index < 0) {
  (forward ? items[0] : items[items.length - 1]).focus();
  return;
 }
 items[(index + (forward ? 1 : -1) + items.length) % items.length].focus();
}

function translate() {
 document.documentElement.lang = e5.lang === 'en' ? 'en' : 'zh';
 document.title = t('title');
 document.querySelectorAll('[data-text]').forEach(el => { el.textContent = t(el.dataset.text); });
 render();
}

$('go-btn').addEventListener('click', begin);
$('backend-btn').addEventListener('click', () => {
 if (!$('backend-btn').disabled) openDialog('backend', 'backend-' + status.backend);
});
$('backend-global').addEventListener('click', () => chooseBackend('global'));
$('backend-speedtest').addEventListener('click', () => chooseBackend('speedtest'));
$('backend-cancel').addEventListener('click', closeDialog);
$('install-confirm').addEventListener('click', () => {
 dialog = null;
 act('/start', { install: true });
});
$('install-cancel').addEventListener('click', closeDialog);
$('progress-cancel').addEventListener('click', stopRun);
for (const id of ['backend-modal', 'install-modal'])
 $(id).addEventListener('click', e => { if (e.target === $(id)) closeDialog(); });

e5.onKey(key => {
 if (key.kind === 'ok' && key.repeat) return true;
 const root = dialog ? $(dialog + '-modal') : document.body;
 if (DIRS.has(key.kind)) {
  moveFocus(root, key.kind);
  return true;
 }
 if (key.kind !== 'ok') return false;
 const el = document.activeElement;
 if (el && el.tagName === 'BUTTON' && root.contains(el)) e5.press(el);
 else if (dialog) visibleIn(root)[0]?.focus();
 else begin();
 return true;
});

e5.onBack(() => {
 if (dialog === 'progress' || BUSY.includes(status.phase)) stopRun();
 else if (dialog) closeDialog();
 else return false;
 return true;
});

e5.onLang(translate);
window.addEventListener('focus', syncTheme);
window.addEventListener('pagehide', () => {
 clearTimeout(pollTimer);
 if (BUSY.includes(status.phase)) e5.api('/stop', { body: {} }).catch(() => {});
});

buildGauge();
translate();
$('go-btn').focus();
call('/reset', {});
