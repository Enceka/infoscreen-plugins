'use strict';
const $ = (id) => document.getElementById(id);
const body = $('stk-body');
const tabs = $('sim-tabs');

const words = {
 appTitle: ['SIM 卡应用', 'SIM Toolkit'],
 disabled: ['SIM 卡应用 (STK) 已在设置中关闭', 'SIM Toolkit (STK) is disabled in Settings'],
 enable: ['启用', 'Enable'],
 loading: ['正在读取 SIM 卡菜单…', 'Reading the SIM menu…'],
 waiting: ['正在等待 SIM 卡…', 'Waiting for the SIM…'],
 loadingHint: ['首次加载可能需要数秒', 'This may take a few seconds'],
 ok: ['确定', 'OK'],
 back: ['返回', 'Back'],
 send: ['发送', 'Send'],
 yes: ['是', 'Yes'],
 no: ['否', 'No'],
 cancel: ['取消', 'Cancel'],
 call: ['呼叫', 'Call'],
 retry: ['重新读取', 'Retry'],
 clearCache: ['清除缓存', 'Clear cache'],
 clearCacheLabel: ['清除 STK 菜单缓存', 'Clear the STK menu cache'],
 noSim: ['未插入 SIM 卡', 'No SIM card'],
 restart: ['SIM 卡应用已开启，重启设备后才能使用。', 'The SIM toolkit is on; restart the device to use it.'],
 noMenu: ['SIM 卡没有提供应用菜单', 'The SIM offers no menu'],
 callPrompt: ['SIM 卡请求拨打电话', 'The SIM asks to make a call'],
 length: ['长度 {0}-{1}', 'Length {0}-{1}'],
 digitsOnly: [' · 仅数字', ' · digits only'],
 minLength: ['至少输入 {0} 个字符', 'Enter at least {0} characters'],
 maxLength: ['最多输入 {0} 个字符', 'Enter at most {0} characters'],
 digitsError: ['仅能输入数字、*、# 和 +', 'Digits, *, # and + only'],
 cacheCleared: ['STK 菜单缓存已清除', 'STK menu cache cleared'],
 requestFailed: ['请求失败：{0}', 'Request failed: {0}']
};

function tr(key, ...values) {
 const entry = words[key] || [key, key];
 let text = e5.t({ zh: entry[0], en: entry[1] });
 values.forEach((value, index) => {
  text = text.split('{' + index + '}').join(String(value));
 });
 return text;
}

const THEME_VARS = ['--bg', '--surface-rgb', '--button-rgb', '--active-rgb', '--text', '--dim', '--line', '--accent', '--ui-opacity'];

function syncTheme() {
 let host = null;
 try { host = window.parent.document.body; } catch (error) { host = null; }
 if (!host) return;
 const root = document.documentElement;
 const palette = window.parent.getComputedStyle(host);
 THEME_VARS.forEach((name) => {
  const value = palette.getPropertyValue(name).trim();
  if (value) root.style.setProperty(name, value);
 });
 root.dataset.theme = host.dataset.theme || 'dark';
 root.classList.toggle('desktop-wallpaper', host.classList.contains('desktop-wallpaper'));
 root.style.setProperty('--desktop-wallpaper', host.style.getPropertyValue('--desktop-wallpaper'));
}

function isObject(value) {
 return !!value && typeof value === 'object' && !Array.isArray(value);
}

function enabledOf(value) {
 return !isObject(value) || value.enabled !== false;
}

function dualOf(value) {
 return isObject(value) && value.dual_sim === true;
}

const LIVE_VIEWS = ['MENU', 'SELECT', 'TEXT', 'INPUT', 'YESNO', 'CALL'];

function viewOf(data, enabled) {
 if (!enabled)
  return 'DISABLED';
 if (status?.restart === true)
  return 'RESTART';
 let view = String(data.view ?? '').trim().toUpperCase();
 if (view === 'WAIT')
  view = 'WAITING';
 return view || 'EMPTY';
}

function itemsOf(data) {
 if (!Array.isArray(data.items))
  return [];
 return data.items.map((item, index) => ({
  id: item.id ?? index + 1,
  label: String(item.text ?? '')
 }));
}

function titleOf(data, view, enabled) {
 if (!enabled)
  return tr('appTitle');
 return LIVE_VIEWS.includes(view) && data.title ? String(data.title) : tr('appTitle');
}

function currentData() {
 if (!isObject(status) || !Array.isArray(status.slots))
  return { view: 'LOADING' };
 return isObject(status.slots[slot]) ? status.slots[slot] : {};
}

function signatureOf(data, view, enabled, dual) {
 return JSON.stringify({
  enabled,
  slot,
  dual,
  view,
  title: data.title ?? '',
  items: LIVE_VIEWS.includes(view) ? itemsOf(data) : [],
  text: data.text ?? '',
  default_item: data.default_item ?? 0,
  default_text: data.default_text ?? '',
  secret: data.secret === true,
  digits_only: data.digits_only === true,
  max: data.max ?? 0,
  min: data.min ?? 0,
  call_number: data.call_number ?? '',
  present: data.present === true
 });
}

function findFocus(key) {
 if (!key)
  return null;
 return Array.from(body.querySelectorAll('[data-focus]'))
  .find((element) => element.dataset.focus === key) || null;
}

function bodyFocusables() {
 return Array.from(body.querySelectorAll('button:not([disabled]), input:not([disabled])'))
  .filter((element) => !element.closest('[hidden]'));
}

function focusElement(element) {
 if (!element)
  return false;
 element.focus({ preventScroll: true });
 if (typeof element.scrollIntoView === 'function')
  element.scrollIntoView({ block: 'nearest' });
 return true;
}

function focusTab(index) {
 return focusElement($('sim-tab-' + index));
}

function messageCard(text) {
 const card = document.createElement('section');
 card.className = 'card message-card';
 const message = document.createElement('p');
 message.className = 'message';
 message.textContent = String(text ?? '');
 card.append(message);
 return card;
}

function actionRow(buttons) {
 const row = document.createElement('div');
 row.className = 'stk-actions';
 buttons.forEach((button) => row.append(button));
 return row;
}

function actionButton(label, kind, focus, handler) {
 const button = document.createElement('button');
 button.type = 'button';
 button.className = 'stk-button' + (kind ? ' ' + kind : '');
 button.dataset.focus = focus;
 button.textContent = label;
 button.addEventListener('click', handler);
 return button;
}

function stateView(view) {
 const box = document.createElement('div');
 box.className = 'state-card';
 const spinner = document.createElement('span');
 spinner.className = 'spinner';
 const title = document.createElement('strong');
 title.className = 'state-title';
 title.textContent = view === 'LOADING' ? tr('loading') : tr('waiting');
 const hint = document.createElement('p');
 hint.className = 'state-hint';
 hint.textContent = tr('loadingHint');
 box.append(spinner, title, hint);
 return box;
}

function headingNode(text) {
 const heading = document.createElement('h2');
 heading.className = 'stk-heading';
 heading.textContent = String(text ?? '');
 return heading;
}

function buildBody(data, view, enabled, dual) {
 const previousInput = $('stk-input');
 const previousInputKey = inputKey;
 const previousValue = previousInput ? previousInput.value : '';
 const active = document.activeElement;
 const wasInBody = !!(active && body.contains(active));
 const wasInTabs = !!(active && tabs.contains(active));
 const noFocus = !active || active === document.body || active === document.documentElement;
 const activeKey = active && active.dataset ? active.dataset.focus : '';
 const firstRender = !rendered;
 let preferredFocus = '';

 body.textContent = '';
 if (view !== 'INPUT')
  inputKey = '';

 if (LIVE_VIEWS.includes(view) && data.title)
  body.append(headingNode(data.title));

 if (view === 'DISABLED') {
  const enable = actionButton(tr('enable'), 'primary', 'enable', enableStk);
  enable.id = 'stk-enable';
  body.append(messageCard(tr('disabled')), actionRow([enable]));
 } else if (view === 'RESTART') {
  body.append(messageCard(tr('restart')));
 } else if (view === 'LOADING' || view === 'WAITING') {
  body.append(stateView(view));
 } else if (view === 'MENU' || view === 'SELECT') {
  const items = itemsOf(data);
  if (!items.length) {
   body.append(messageCard(tr('noMenu')));
  } else {
   const list = document.createElement('div');
   list.className = 'menu-list';
   items.forEach((item) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'menu-item';
    button.dataset.focus = 'item:' + item.id;
    button.dataset.itemId = String(item.id);
    const label = document.createElement('span');
    label.className = 'item-label';
    label.textContent = item.label;
    const chevron = document.createElement('span');
    chevron.className = 'chevron';
    chevron.textContent = '›';
    button.append(label, chevron);
    button.addEventListener('click', () => choose(item.id));
    list.append(button);
   });
   body.append(list);
   const defaultItem = data.default_item ? data.default_item : null;
   if (view === 'SELECT' && defaultItem !== null) {
    const target = items.find((item) => String(item.id) === String(defaultItem));
    if (target)
     preferredFocus = 'item:' + target.id;
   }
  }
 } else if (view === 'TEXT') {
  const ok = actionButton(tr('ok'), 'primary', 'ok', acknowledge);
  ok.id = 'stk-ok';
  body.append(messageCard(data.text), actionRow([ok]));
 } else if (view === 'INPUT') {
  if (data.text !== undefined && data.text !== null && String(data.text) !== '')
   body.append(messageCard(data.text));
  const input = document.createElement('input');
  input.id = 'stk-input';
  input.className = 'stk-field';
  input.type = data.secret === true ? 'password' : 'text';
  input.autocomplete = 'off';
  input.spellcheck = false;
  input.dataset.focus = 'input';
  const digitsOnly = data.digits_only === true;
  if (digitsOnly)
   input.inputMode = 'numeric';
  const maxLength = Number(data.max ?? 0);
  if (maxLength > 0)
   input.maxLength = maxLength;
  const defaultText = String(data.default_text ?? '');
  const key = JSON.stringify([slot, defaultText, maxLength, data.secret === true, digitsOnly]);
  input.value = previousInput && previousInputKey === key
   ? previousValue
   : defaultText;
  inputKey = key;
  body.append(input);
  const minLength = Number(data.min ?? 0);
  if (minLength > 0 || maxLength > 0) {
   const hint = document.createElement('p');
   hint.className = 'stk-hint';
   hint.textContent = tr('length', minLength, maxLength) +
    (digitsOnly ? tr('digitsOnly') : '');
   body.append(hint);
  } else if (digitsOnly) {
   const hint = document.createElement('p');
   hint.className = 'stk-hint';
   hint.textContent = tr('digitsOnly').replace(/^ · /, '');
   body.append(hint);
  }
  const back = actionButton(tr('back'), 'secondary', 'back', goBack);
  back.id = 'stk-input-back';
  const send = actionButton(tr('send'), 'primary', 'send', sendInput);
  send.id = 'stk-input-send';
  body.append(actionRow([back, send]));
 } else if (view === 'YESNO') {
  const no = actionButton(tr('no'), 'secondary', 'no', () => answerYesNo(false));
  no.id = 'stk-no';
  const yes = actionButton(tr('yes'), 'primary', 'yes', () => answerYesNo(true));
  yes.id = 'stk-yes';
  body.append(messageCard(data.text), actionRow([no, yes]));
 } else if (view === 'CALL') {
  const card = document.createElement('section');
  card.className = 'card call-card';
  const message = document.createElement('p');
  message.className = 'message';
  message.textContent = String(data.text ?? '') || tr('callPrompt');
  const number = document.createElement('div');
  number.className = 'call-number';
  number.textContent = String(data.call_number ?? '');
  card.append(message, number);
  body.append(card);
  const cancel = actionButton(tr('cancel'), 'secondary', 'cancel', () => callSetup(false));
  cancel.id = 'stk-cancel';
  const call = actionButton(tr('call'), 'primary', 'call', () => callSetup(true));
  call.id = 'stk-call';
  body.append(actionRow([cancel, call]));
 } else if (view === 'EMPTY' || view === 'IDLE') {
  if (data.present !== true) {
   body.append(messageCard(tr('noSim')));
  } else {
   const retry = actionButton(tr('retry'), 'primary', 'retry', retryMenu);
   retry.id = 'stk-retry';
   const clear = actionButton(tr('clearCache'), 'secondary', 'clear', clearCache);
   clear.id = 'stk-clear';
   body.append(messageCard(tr('noMenu')), actionRow([retry, clear]));
  }
 } else {
  body.append(messageCard(data.text));
 }

 rendered = true;
 const shouldFocus = !!preferredFocus ||
  (!wasInTabs && (wasInBody || noFocus || firstRender));
 if (!shouldFocus)
  return;
 const target = findFocus(preferredFocus) || findFocus(activeKey) || bodyFocusables()[0];
 focusElement(target);
}

function renderChrome(data, view, enabled, dual) {
 syncTheme();
 const title = titleOf(data, view, enabled);
 document.title = title;
 tabs.hidden = !enabled || !dual || view === 'RESTART';
 for (let index = 0; index < 2; index++) {
  const tab = $('sim-tab-' + index);
  tab.setAttribute('aria-selected', String(index === slot));
  tab.setAttribute('aria-pressed', String(index === slot));
 }
 body.dataset.view = enabled ? view : 'DISABLED';
 body.dataset.slot = String(slot);
}

function render(force) {
 const enabled = enabledOf(status);
 const data = currentData();
 const view = viewOf(data, enabled);
 const dual = dualOf(status);
 const toast = String(data.toast ?? '');
 if (toast) {
  e5.toast(toast);
  data.toast = '';
 }
 renderChrome(data, view, enabled, dual);
 const signature = signatureOf(data, view, enabled, dual);
 if (force || signature !== lastSignature) {
  lastSignature = signature;
  buildBody(data, view, enabled, dual);
 }
}

function applyStatus(value, initial) {
 if (!isObject(value) || !Array.isArray(value.slots))
  return false;
 status = value;
 const target = value.slots[value.slot];
 if (initial || target?.pending || target?.view === 'text')
  slot = value.slot === 1 ? 1 : 0;
 render();
 return true;
}

async function refresh(initial) {
 if (refreshing || acting)
  return;
 refreshing = true;
 try {
  const result = await e5.api('/status');
  applyStatus(result, initial === true);
 } catch (error) {
  // A short outage leaves the last view in place; the next poll retries.
 } finally {
  refreshing = false;
 }
}

async function postAction(path, request, onSuccess) {
 acting = true;
 try {
  const result = await e5.api(path, { body: request ?? {} });
  if (isObject(result) && result.ok === false)
   throw new Error(result.error || 'HTTP');
  if (onSuccess)
   onSuccess(result);
  if (!applyStatus(result, false))
   await refresh(false);
 } catch (error) {
  e5.toast(tr('requestFailed', error && error.message ? error.message : String(error)));
 } finally {
  acting = false;
 }
}

function enableStk() {
 postAction('/enabled', { enabled: true });
}

function choose(itemId) {
 postAction('/choose', { slot, item_id: itemId });
}

function acknowledge() {
 postAction('/ack', { slot });
}

function answerYesNo(yes) {
 postAction('/yesno', { slot, yes });
}

function callSetup(accept) {
 postAction('/call', { slot, accept });
}

function retryMenu() {
 postAction('/retry', { slot });
}

function goBack() {
 inputKey = '';
 postAction('/back', { slot });
}

function clearCache() {
 postAction('/clear-cache', {}, () => e5.toast(tr('cacheCleared')));
}

function sendInput() {
 const input = $('stk-input');
 if (!input)
  return false;
 const data = currentData();
 const text = input.value;
 const length = Array.from(text).length;
 const minLength = Number(data.min ?? 0);
 const maxLength = Number(data.max ?? 0);
 if (length < minLength) {
  e5.toast(tr('minLength', minLength));
  return false;
 }
 if (maxLength > 0 && length > maxLength) {
  e5.toast(tr('maxLength', maxLength));
  return false;
 }
 if (data.digits_only === true && !/^[0-9*#+]*$/.test(text)) {
  e5.toast(tr('digitsError'));
  return false;
 }
 postAction('/input', { slot, text });
 return true;
}

function insertInput(input, text) {
 const start = input.selectionStart ?? input.value.length;
 const end = input.selectionEnd ?? start;
 input.value = input.value.slice(0, start) + text + input.value.slice(end);
 input.setSelectionRange(start + text.length, start + text.length);
 input.dispatchEvent(new Event('input', { bubbles: true }));
}

function appendDigit(key) {
 if (!/^[0-9*#]$/.test(key))
  return false;
 const input = $('stk-input');
 if (!input)
  return false;
 const data = currentData();
 if (data.digits_only === true && !/[0-9*#+]/.test(key))
  return true;
 if (input.maxLength >= 0 && Array.from(input.value).length >= input.maxLength)
  return true;
 insertInput(input, key);
 return true;
}

function switchSlot(next) {
 if (next !== 0 && next !== 1)
  return;
 if (next === slot) {
  focusTab(next);
  return;
 }
 slot = next;
 inputKey = '';
 lastSignature = '';
 render();
 postAction('/open', { slot });
}

function moveFocus(direction) {
 const items = bodyFocusables();
 if (!items.length)
  return false;
 const active = document.activeElement;
 if (!items.includes(active)) {
  const target = direction === 'up' || direction === 'left' ? items[items.length - 1] : items[0];
  return focusElement(target);
 }
 const from = active.getBoundingClientRect();
 const horizontal = direction === 'left' || direction === 'right';
 const sign = direction === 'left' || direction === 'up' ? -1 : 1;
 const fromX = (from.left + from.right) / 2;
 const fromY = (from.top + from.bottom) / 2;
 let best = null;
 let bestScore = Infinity;
 for (const element of items) {
  if (element === active)
   continue;
  const rect = element.getBoundingClientRect();
  const dx = (rect.left + rect.right) / 2 - fromX;
  const dy = (rect.top + rect.bottom) / 2 - fromY;
  const forward = (horizontal ? dx : dy) * sign;
  if (forward <= 1)
   continue;
  const aligned = horizontal
   ? rect.top < from.bottom && rect.bottom > from.top
   : rect.left < from.right && rect.right > from.left;
  if (!aligned)
   continue;
  const score = (horizontal ? Math.abs(dx) : Math.abs(dy)) * 2 +
   (horizontal ? Math.abs(dy) : Math.abs(dx));
  if (score < bestScore) {
   best = element;
   bestScore = score;
  }
 }
 if (!best) {
  const at = items.indexOf(active);
  best = direction === 'down' || direction === 'right' ? items[at + 1] : items[at - 1];
 }
 if (!best)
  return false;
 return focusElement(best);
}

function handleKey(key) {
 if (!key)
  return false;
 const enabled = enabledOf(status);
 const data = currentData();
 const view = viewOf(data, enabled);
 if (enabled && view === 'INPUT' && key.kind === 'digit') {
  appendDigit(key.key);
  return true;
 }
 const active = document.activeElement;
 const onTab = !!(active && tabs.contains(active));
 if (!tabs.hidden) {
  if (onTab) {
   if (key.kind === 'left' || key.kind === 'right') {
    switchSlot(slot + (key.kind === 'right' ? 1 : -1));
    return true;
   }
   if (key.kind === 'down') {
    focusElement(bodyFocusables()[0]);
    return true;
   }
   if (key.kind === 'up') {
    const items = bodyFocusables();
    focusElement(items[items.length - 1]);
    return true;
   }
   if (key.kind === 'ok') {
    const target = Number(active.dataset.slot);
    if (target !== slot)
     switchSlot(target);
    return true;
   }
  } else if (key.kind === 'up') {
   const items = bodyFocusables();
   if (items.length && active === items[0]) {
    focusTab(slot);
    return true;
   }
  }
 }
 if (key.kind === 'ok') {
  if (active && body.contains(active)) {
   if (active.tagName === 'INPUT') {
    sendInput();
    return true;
   }
   if (active.tagName === 'BUTTON') {
    e5.press(active);
    return true;
   }
  }
  const first = bodyFocusables()[0];
  if (first) {
   focusElement(first);
   return true;
  }
  return false;
 }
 if (key.kind === 'up' || key.kind === 'down' || key.kind === 'left' || key.kind === 'right') {
  moveFocus(key.kind);
  return true;
 }
 return false;
}

let status = null;
let slot = 0;
let lastSignature = '';
let rendered = false;
let refreshing = false;
let acting = false;
let inputKey = '';
let pollTimer = null;

for (let index = 0; index < 2; index++) {
 const tab = $('sim-tab-' + index);
 tab.addEventListener('click', () => switchSlot(index));
}

e5.onKey(handleKey);
e5.onBack(() => {
 if (!isObject(status) || !enabledOf(status))
  return false;
 const view = viewOf(currentData(), true);
 if (!['SELECT', 'TEXT', 'INPUT', 'YESNO', 'CALL', 'WAITING'].includes(view))
  return false;
 goBack();
 return true;
});
e5.onLang(() => {
 document.documentElement.lang = e5.lang === 'en' ? 'en' : 'zh';
 lastSignature = '';
 render(true);
});

function start() {
 document.documentElement.lang = e5.lang === 'en' ? 'en' : 'zh';
 render();
 e5.api('/open', { body: {} }).then((result) => {
  if (!applyStatus(result, true))
   refresh(true);
 }).catch(() => refresh(true));
 pollTimer = setInterval(() => refresh(false), 600);
}

start();

window.addEventListener('pagehide', () => {
 if (pollTimer)
  clearInterval(pollTimer);
 e5.api('/close', { body: {} }).catch(() => {});
});
