'use strict';

// Busuanzi API: https://github.com/soxft/busuanzi/wiki/API
// Page counters keep visits separate from download-click events; never use site_pv here.
const storeStatistics = (() => {
  const endpoint = 'https://busuanzi.9420.ltd/api';
  const counts = new Map();
  const states = new Map();
  const requested = new Set();
  let root = null;
  let started = false;
  try {
    root = new URL(document.querySelector('meta[name="store-url"]').content);
    root.search = '';
    root.hash = '';
    if (root.origin !== location.origin || root.pathname !== new URL('./', location.href).pathname) root = null;
  } catch (_) { /* Source files and local previews do not send production events. */ }

  function counterUrl(key) {
    return key === 'visits' ? root.href : new URL(`__stats__/downloads/${encodeURIComponent(key.slice('download:'.length))}`, root).href;
  }

  function notify() { document.dispatchEvent(new Event('store-statistics')); }

  async function request(key, increment = false) {
    if (!root) return;
    states.set(key, 'loading');
    try {
      const response = await fetch(endpoint, {
        method: increment ? 'POST' : 'GET',
        headers: { 'x-bsz-referer': counterUrl(key) },
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
        cache: 'no-store',
        keepalive: increment,
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const result = await response.json();
      const value = result?.data?.page_pv;
      if (result.success !== true || !Number.isSafeInteger(value) || value < 0) throw new Error('Invalid statistics');
      // A slow read must not overwrite a newer click response with an older count.
      counts.set(key, Math.max(counts.get(key) ?? 0, value));
      states.set(key, 'ready');
    } catch (_) {
      // Existing counts remain visible; statistics never interrupt a download.
      if (!counts.has(key)) states.set(key, 'error');
    }
    notify();
  }

  function start() {
    if (started || !root) return;
    started = true;
    void request('visits', true);
  }

  async function loadDownloads(apps) {
    if (!root) return;
    const queue = apps.map((app) => `download:${app.id}`).filter((key) => !requested.has(key));
    queue.forEach((key) => requested.add(key));
    // Keep the public service's request load bounded as the catalog grows.
    const workers = Array.from({ length: Math.min(4, queue.length) }, async () => {
      while (queue.length) await request(queue.shift());
    });
    await Promise.all(workers);
  }

  function recordDownload(id) {
    const key = `download:${id}`;
    if (root && requested.has(key)) void request(key, true);
  }

  return {
    start, loadDownloads, recordDownload,
    count: (key) => counts.get(key),
    state: (key) => root ? (states.get(key) || 'loading') : 'disabled',
  };
})();
