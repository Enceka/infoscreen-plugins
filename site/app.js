'use strict';

const TEXT = {
  zh: {
    title: '信息屏应用商店 · Info screen apps', brand: '信息屏<span class="brand-secondary">应用商店</span>',
    skip: '跳转到应用列表', navApps: '发现应用', navInstall: '如何安装', heroFirst: '让小屏幕，', heroSecond: '有更多可能。',
    heroDescription: '给你的 E5 信息屏添一点新本领。<br>轻巧、开源的应用，让日常的小事更顺手。',
    browse: '探索应用', about: '了解信息屏', availableApps: '款应用，持续生长中', openSource: '开源 · 自由探索',
    clockCaption: '大字时钟', visualChip: '小应用，大用处。', collection: '发现你的下一个应用', updated: '目录更新于',
    all: '全部应用', frontend: '纯前端', backend: '含后台', searchLabel: '搜索应用', searchPlaceholder: '搜索应用名称、功能…',
    loading: '正在加载应用…', installTitle: '新本领，几步就到手。', installNote: '在你的 E5 上安装应用', onDevice: '在信息屏上安装',
    onDeviceDescription: '打开信息屏的应用商店，刷新列表，选择喜欢的应用并确认安装。', settings: '高级', manage: '应用管理', store: '应用商店',
    manual: '也可以手动安装', manualDescription: '下载应用包，上传到设备并命名为 /tmp/app.tar.gz，然后在设备终端运行：',
    footer: '为 E5 的小屏幕而造。', jsonIndex: '应用索引 JSON', docs: '开发文档', view: '查看应用', download: '下载',
    identifier: '应用 ID', packageSize: '应用包大小', requires: '接口要求', appType: '应用类型',
    backendNote: '此应用包含以 root 运行的后台服务。', detailInstall: '前往「高级 → 应用管理 → 应用商店」，刷新后选择此应用并确认安装。',
    checksum: '校验信息 · SHA-256', downloadPackage: '下载应用包', source: '查看源码',
    contributeTitle: '下一个应用，<br>由你来创造。', contributeDescription: '一个想法，一点代码。<br>让更多人的小屏幕，也多一份可能。', contributeLink: '提交你的应用',
    noMatches: '没有找到匹配的应用', noMatchesHint: '试试其他关键词，或查看全部应用。', clearSearch: '查看全部应用',
    empty: '应用正在来的路上', emptyHint: '商店暂时还没有应用，欢迎提交你的第一个作品。',
    loadError: '暂时无法加载应用列表', loadErrorHint: '请检查网络连接，然后再试一次。', retry: '重新加载',
    copied: '命令已复制', copyFailed: '无法自动复制，请选择命令并复制。', resultCount: (n) => `显示 ${n} 款应用`,
    close: '关闭', copy: '复制命令', languageLabel: 'Switch to English',
  },
  en: {
    title: 'Info screen app store', brand: 'Info screen<span class="brand-secondary">apps</span>',
    skip: 'Skip to apps', navApps: 'Explore apps', navInstall: 'How to install', heroFirst: 'Small screen.', heroSecond: 'More possibilities.',
    heroDescription: 'A little more power for your E5 info screen.<br>Small, open-source apps for the everyday.',
    browse: 'Explore apps', about: 'Meet the info screen', availableApps: 'apps, and growing', openSource: 'Open source · Yours to explore',
    clockCaption: 'Big clock', visualChip: 'Small apps. Big ideas.', collection: 'Find your next app', updated: 'Catalog updated',
    all: 'All apps', frontend: 'Frontend only', backend: 'With a backend', searchLabel: 'Search apps', searchPlaceholder: 'Search apps or features…',
    loading: 'Loading apps…', installTitle: 'A few steps to something new.', installNote: 'Install on your E5', onDevice: 'Install from the info screen',
    onDeviceDescription: 'Open the app store on your info screen, refresh the list, choose an app and confirm installation.', settings: 'Settings', manage: 'Apps', store: 'App store',
    manual: 'Or install a package yourself', manualDescription: 'Download a package, upload it to your device as /tmp/app.tar.gz, then run this in the device terminal:',
    footer: 'Made for the E5’s small screen.', jsonIndex: 'App index JSON', docs: 'Developer docs', view: 'View app', download: 'Download',
    identifier: 'App ID', packageSize: 'Package size', requires: 'API required', appType: 'App type',
    backendNote: 'This app includes a backend service that runs as root.', detailInstall: 'Go to Settings → Apps → App store, refresh the list, select this app and confirm installation.',
    checksum: 'Checksum · SHA-256', downloadPackage: 'Download package', source: 'View source',
    contributeTitle: 'The next app<br>could be yours.', contributeDescription: 'An idea and a little code.<br>Give everyone’s small screen a new possibility.', contributeLink: 'Contribute an app',
    noMatches: 'No matching apps', noMatchesHint: 'Try another keyword or browse all apps.', clearSearch: 'Show all apps',
    empty: 'Something new is on the way', emptyHint: 'There are no apps here yet. Share your first creation with the community.',
    loadError: 'Could not load the app list', loadErrorHint: 'Check your connection and try again.', retry: 'Try again',
    copied: 'Command copied', copyFailed: 'Please select the command and copy it manually.', resultCount: (n) => `${n} apps shown`,
    close: 'Close', copy: 'Copy command', languageLabel: '切换为中文',
  },
};

const $ = (id) => document.getElementById(id);
let lang = 'zh';
try { lang = localStorage.getItem('infoscreen-store-language') === 'en' ? 'en' : 'zh'; } catch (_) { /* Storage can be unavailable in private browsing. */ }
let catalog = null;
let loadState = 'loading';
let filter = 'all';
let selectedApp = null;
let toastTimer;

function translate(root = document) {
  root.querySelectorAll('[data-i18n]').forEach((node) => {
    const key = node.dataset.i18n;
    // Only these fixed translations contain markup; catalog text always uses textContent.
    if (['brand', 'heroDescription', 'contributeTitle', 'contributeDescription'].includes(key)) node.innerHTML = TEXT[lang][key];
    else node.textContent = TEXT[lang][key];
  });
  root.querySelectorAll('[data-placeholder]').forEach((node) => { node.placeholder = TEXT[lang][node.dataset.placeholder]; });
}

function applyLanguage() {
  document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
  document.title = TEXT[lang].title;
  translate();
  $('language').replaceChildren(document.createTextNode(lang === 'zh' ? 'EN ↗' : '中文 ↗'));
  $('language').setAttribute('aria-label', TEXT[lang].languageLabel);
  $('close-details').setAttribute('aria-label', TEXT[lang].close);
  document.querySelectorAll('.copy-button').forEach((node) => node.setAttribute('aria-label', TEXT[lang].copy));
  renderCatalog();
  if (selectedApp) fillDetails(selectedApp);
  updateClock();
}

function localized(value) {
  if (typeof value === 'string') return value;
  return value?.[lang] || value?.zh || value?.en || '';
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  return `${(bytes / 1024).toLocaleString(lang === 'zh' ? 'zh-CN' : 'en', { maximumFractionDigits: 1 })} KB`;
}

function iconFor(app) { return app.id === 'bigclock' ? '#icon-clock' : app.id === 'phone' ? '#icon-phone' : '#icon-app'; }

function setAppIcon(node, app) {
  node.classList.toggle('phone', app.id === 'phone');
  node.querySelector('use').setAttribute('href', iconFor(app));
}

function showState(title, hint, action, onClick) {
  const state = $('catalog-state');
  state.replaceChildren();
  const heading = document.createElement('p');
  heading.textContent = title;
  state.append(heading);
  if (hint) {
    const note = document.createElement('p');
    note.textContent = hint;
    state.append(note);
  }
  if (action) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'button app-details';
    button.textContent = action;
    button.addEventListener('click', onClick);
    state.append(button);
  }
  state.hidden = false;
}

function renderCatalog() {
  const grid = $('app-grid');
  grid.replaceChildren();
  grid.classList.remove('compact');
  $('catalog-state').hidden = true;
  if (loadState === 'loading') {
    showState(TEXT[lang].loading);
    return;
  }
  if (loadState === 'error') {
    showState(TEXT[lang].loadError, TEXT[lang].loadErrorHint, TEXT[lang].retry, loadCatalog);
    return;
  }
  const apps = catalog.plugins;
  $('hero-count').textContent = apps.length;
  const generated = new Date(catalog.generated);
  if (!Number.isNaN(generated.getTime())) {
    $('updated').dateTime = generated.toISOString();
    $('updated').textContent = generated.toLocaleDateString(lang === 'zh' ? 'zh-CN' : 'en', { year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC' });
  } else $('updated').textContent = '—';
  const query = $('search').value.trim().toLocaleLowerCase();
  const matches = apps.filter((app) => {
    const typeMatches = filter === 'all' || (filter === 'backend' ? app.backend : !app.backend);
    const searchText = [app.id, ...Object.values(app.name || {}), ...Object.values(app.description || {})].join(' ').toLocaleLowerCase();
    return typeMatches && searchText.includes(query);
  });
  grid.classList.toggle('compact', apps.length === 1 && !query && filter === 'all');
  $('app-count').textContent = matches.length;
  $('results-status').textContent = TEXT[lang].resultCount(matches.length);
  if (!apps.length) showState(TEXT[lang].empty, TEXT[lang].emptyHint);
  else if (!matches.length) showState(TEXT[lang].noMatches, TEXT[lang].noMatchesHint, TEXT[lang].clearSearch, resetSearch);
  matches.forEach((app) => {
    const card = $('app-template').content.firstElementChild.cloneNode(true);
    setAppIcon(card.querySelector('.app-icon'), app);
    card.querySelector('h3').textContent = localized(app.name) || app.id;
    card.querySelector('.app-version').textContent = `v${app.version}`;
    card.querySelector('.app-description').textContent = localized(app.description);
    card.querySelector('.app-kind').textContent = TEXT[lang][app.backend ? 'backend' : 'frontend'];
    card.querySelector('.app-kind').classList.toggle('with-backend', Boolean(app.backend));
    card.querySelector('.app-id').textContent = app.id;
    card.querySelector('.app-size').textContent = formatSize(app.size);
    card.querySelector('.app-api').textContent = `API ${app.api_version}`;
    card.querySelector('.app-details').addEventListener('click', () => {
      selectedApp = app;
      fillDetails(app);
      $('details').showModal();
    });
    const download = card.querySelector('.download-link');
    download.href = app.url;
    download.download = `${app.id}-${app.version}.tar.gz`;
    download.setAttribute('aria-label', `${TEXT[lang].download} ${localized(app.name) || app.id}`);
    translate(card);
    grid.append(card);
  });
  if (!query && filter === 'all') {
    const card = document.createElement('article');
    card.className = 'contribute-card';
    card.innerHTML = '<span class="contribute-icon"><svg class="icon"><use href="#icon-plus"/></svg></span><h3 data-i18n="contributeTitle"></h3><p data-i18n="contributeDescription"></p><a href="https://github.com/Enceka/infoscreen-plugins#readme" target="_blank" rel="noopener noreferrer"><span data-i18n="contributeLink"></span><svg class="icon"><use href="#icon-arrow"/></svg></a>';
    translate(card);
    grid.append(card);
  }
}

function fillDetails(app) {
  setAppIcon($('detail-icon'), app);
  $('detail-name').textContent = localized(app.name) || app.id;
  $('detail-version').textContent = `v${app.version}`;
  $('detail-description').textContent = localized(app.description);
  $('detail-id').textContent = app.id;
  $('detail-size').textContent = formatSize(app.size);
  $('detail-api').textContent = `API ${app.api_version}`;
  $('detail-kind').textContent = TEXT[lang][app.backend ? 'backend' : 'frontend'];
  $('backend-note').hidden = !app.backend;
  $('detail-sha').textContent = app.sha256 || '—';
  $('detail-download').href = app.url;
  $('detail-download').download = `${app.id}-${app.version}.tar.gz`;
  $('detail-source').href = `https://github.com/Enceka/infoscreen-plugins/tree/main/plugins/${encodeURIComponent(app.id)}`;
}

function resetSearch() {
  $('search').value = '';
  setFilter('all');
}

function setFilter(nextFilter) {
  filter = nextFilter;
  document.querySelectorAll('[data-filter]').forEach((button) => {
    const active = button.dataset.filter === filter;
    button.classList.toggle('active', active);
    button.setAttribute('aria-pressed', String(active));
  });
  renderCatalog();
}

async function loadCatalog() {
  loadState = 'loading';
  $('search').disabled = true;
  document.querySelectorAll('[data-filter]').forEach((button) => { button.disabled = true; });
  renderCatalog();
  try {
    const response = await fetch('index.json', { cache: 'no-cache', signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (!data || !Array.isArray(data.plugins)) throw new Error('Invalid catalog');
    data.plugins.forEach((app) => {
      if (!app || !/^[a-z0-9][a-z0-9_-]{0,31}$/.test(app.id) || !/^\d+(\.\d+){0,3}$/.test(app.version)
          || !Number.isInteger(app.api_version) || app.api_version < 1 || !Number.isFinite(app.size) || app.size < 0 || typeof app.url !== 'string'
          || !app.name || typeof app.name !== 'object' || !Object.values(app.name).every((name) => typeof name === 'string')
          || (app.description && (typeof app.description !== 'object' || !Object.values(app.description).every((description) => typeof description === 'string')))) {
        throw new Error('Invalid app');
      }
      const url = new URL(app.url, location.href);
      if (!['https:', 'http:'].includes(url.protocol)) throw new Error('Invalid package URL');
      app.url = url.href;
    });
    catalog = data;
    loadState = 'ready';
  } catch (_) {
    loadState = 'error';
  } finally {
    $('search').disabled = false;
    document.querySelectorAll('[data-filter]').forEach((button) => { button.disabled = false; });
    renderCatalog();
  }
}

function updateClock() {
  const now = new Date();
  $('clock-time').textContent = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
  $('clock-seconds').textContent = String(now.getSeconds()).padStart(2, '0');
  $('clock-date').textContent = now.toLocaleDateString(lang === 'zh' ? 'zh-CN' : 'en', { month: 'long', day: 'numeric', weekday: 'short' });
}

function toast(message) {
  clearTimeout(toastTimer);
  $('toast').textContent = message;
  $('toast').hidden = false;
  toastTimer = setTimeout(() => { $('toast').hidden = true; }, 3000);
}

$('language').addEventListener('click', () => {
  lang = lang === 'zh' ? 'en' : 'zh';
  try { localStorage.setItem('infoscreen-store-language', lang); } catch (_) { /* Keep switching usable without storage. */ }
  applyLanguage();
});
$('search').addEventListener('input', renderCatalog);
document.querySelectorAll('[data-filter]').forEach((button) => button.addEventListener('click', () => setFilter(button.dataset.filter)));
$('close-details').addEventListener('click', () => $('details').close());
$('details').addEventListener('close', () => { selectedApp = null; });
$('details').addEventListener('click', (event) => {
  if (event.target !== $('details')) return;
  const rect = $('details').getBoundingClientRect();
  if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) $('details').close();
});
document.addEventListener('keydown', (event) => {
  if (event.key === '/' && !event.ctrlKey && !event.metaKey && !event.altKey && !$('details').open
      && !['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement.tagName) && !document.activeElement.isContentEditable) {
    event.preventDefault();
    $('search').focus();
  }
});
document.querySelectorAll('[data-copy]').forEach((button) => button.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(button.dataset.copy);
    toast(TEXT[lang].copied);
  } catch (_) { toast(TEXT[lang].copyFailed); }
}));

applyLanguage();
loadCatalog();
setInterval(updateClock, 1000);
