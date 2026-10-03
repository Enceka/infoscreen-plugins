// Build first. All analytics requests are intercepted: this test never changes production counters.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require(process.env.E5_PLAYWRIGHT || 'playwright');
const dist = path.resolve(__dirname, '../dist');
const catalog = JSON.parse(fs.readFileSync(path.join(dist, 'index.json'), 'utf8'));

(async () => {
  let enabled = false;
  let base;
  const server = http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    const file = path.resolve(dist, pathname.replace(/^\/infoscreen-plugins\//, '') || 'index.html');
    if (!file.startsWith(dist + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) return response.writeHead(404).end();
    let body = fs.readFileSync(file);
    const type = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.gz': 'application/gzip' }[path.extname(file)];
    if (enabled && file.endsWith('index.html')) body = Buffer.from(body.toString().replace(/(<meta name="store-url" content=")[^"]*(">)/, '$1' + base + '$2'));
    response.writeHead(200, { 'Content-Type': type || 'application/json' });
    response.end(body);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}/infoscreen-plugins/`;
  const downloadKey = (id) => base + '__stats__/downloads/' + id;
  const counts = new Map([[downloadKey('bigclock'), 7]]);
  const requests = [];
  let failure = false;
  let malformed = false;
  let holdRead = false;
  let pendingRead;
  let extraApp = false;
  let version;
  let browser;
  const errors = [];
  try {
    browser = await chromium.launch({ headless: true });
    async function newPage() {
      const context = await browser.newContext({ viewport: { width: 1440, height: 1080 } });
      const page = await context.newPage();
      page.on('pageerror', (error) => errors.push(error.message));
      await page.route('**/index.json', (route) => {
        const plugins = catalog.plugins.map((app) => ({ ...app, url: base + 'packages/' + app.id + '-' + app.version + '.tar.gz' }));
        if (version) plugins.find((app) => app.id === 'bigclock').version = version;
        if (extraApp) plugins.push({ ...plugins.find((app) => app.id === 'bigclock'), id: 'visits', name: { zh: '访问应用', en: 'Visits app' } });
        return route.fulfill({ json: { ...catalog, plugins } });
      });
      await page.route('https://busuanzi.9420.ltd/api', async (route) => {
        const request = route.request();
        const method = request.method();
        const key = request.headers()['x-bsz-referer'];
        requests.push({ method, key, cookie: request.headers().cookie });
        if (failure) return route.fulfill({ status: 503, body: 'Unavailable' });
        if (method === 'POST') counts.set(key, (counts.get(key) || 0) + 1);
        const result = { success: true, data: { page_pv: malformed ? -1 : counts.get(key) || 0, site_pv: 99999 } };
        if (holdRead && method === 'GET' && key === downloadKey('bigclock')) {
          pendingRead = () => route.fulfill({ json: result });
          return;
        }
        return route.fulfill({ json: result });
      });
      return page;
    }
    const preview = await newPage();
    await preview.goto(base);
    await preview.locator('.app-card').first().waitFor();
    assert.equal(requests.length, 0, 'Local preview sent production statistics');
    assert.equal(await preview.locator('#visit-count').textContent(), '—');
    await preview.context().close();

    enabled = true;
    const page = await newPage();
    await page.goto(base + '?private-search=do-not-send#apps');
    await page.waitForFunction(() => document.getElementById('visit-count').textContent === '1');
    await page.waitForFunction(() => document.querySelector('[data-stat-key="download:bigclock"]').textContent === '7');
    assert.equal(requests.filter((request) => request.method === 'POST').length, 1);
    assert(requests.every((request) => !request.key.includes('private-search') && request.cookie === undefined));
    const before = requests.length;
    await page.locator('#language').click();
    await page.locator('[data-filter="frontend"]').click();
    await page.locator('#search').fill('clock');
    await page.locator('#search').fill('');
    await page.locator('[data-filter="all"]').click();
    assert.equal(requests.length, before, 'Rendering sent extra analytics requests');
    async function download(link) {
      const [event] = await Promise.all([page.waitForEvent('download'), link.click()]);
      assert.equal(await event.failure(), null, 'Statistics interrupted the package download');
    }
    const clockLink = () => page.locator('.download-link[data-download-id="bigclock"]');
    await download(clockLink());
    await page.waitForFunction(() => document.querySelector('[data-stat-key="download:bigclock"]').textContent === '8');
    assert.equal(counts.get(base), 1, 'Download incremented page views');
    assert.equal(requests.filter((request) => request.method === 'POST' && request.key === downloadKey('bigclock')).length, 1);
    await page.locator('.app-card').filter({ has: clockLink() }).locator('.app-details').click();
    assert.equal(await page.locator('#detail-download-count').textContent(), '8');
    await download(page.locator('#detail-download'));
    await page.waitForFunction(() => document.getElementById('detail-download-count').textContent === '9');
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('.download-count[data-stat-key="download:bigclock"]').textContent(), '9');

    // New browser storage still sees the same remotely stored totals; a new visit is separate.
    const another = await newPage();
    await another.goto(base + 'index.html');
    await another.waitForFunction(() => document.getElementById('visit-count').textContent === '2');
    await another.waitForFunction(() => document.querySelector('[data-stat-key="download:bigclock"]').textContent === '9');
    await another.context().close();
    version = '99.0';
    await page.reload();
    await page.waitForFunction(() => document.getElementById('visit-count').textContent === '3');
    await page.waitForFunction(() => document.querySelector('[data-stat-key="download:bigclock"]').textContent === '9');
    assert(await page.getByText('v99.0', { exact: true }).isVisible(), 'Version fixture not loaded');
    version = undefined;

    // A delayed read arriving after a successful click must not move the counter backwards.
    holdRead = true;
    await page.reload();
    await page.waitForFunction(() => document.getElementById('visit-count').textContent === '4');
    assert(pendingRead);
    await download(clockLink());
    await page.waitForFunction(() => document.querySelector('[data-stat-key="download:bigclock"]').textContent === '10');
    await pendingRead();
    assert.equal(await page.locator('.download-count[data-stat-key="download:bigclock"]').textContent(), '10');
    holdRead = false;
    extraApp = true;
    await page.reload();
    await page.waitForFunction(() => document.querySelector('[data-stat-key="download:visits"]').textContent === '0');
    assert.equal(counts.get(base), 5);
    assert.equal(await page.locator('#visit-count').textContent(), '5', 'App named visits collided with view counter');
    extraApp = false;

    for (const width of [320, 390, 768, 1440]) {
      await page.setViewportSize({ width, height: 844 });
      const layout = await page.evaluate(() => ({ content: document.documentElement.scrollWidth, width: innerWidth }));
      assert(layout.content <= layout.width, JSON.stringify(layout));
    }
    if (process.env.E5_STORE_SCREENSHOTS) {
      await page.reload();
      await page.waitForFunction(() => document.querySelector('[data-stat-key="download:bigclock"]').textContent === '10');
      fs.mkdirSync(process.env.E5_STORE_SCREENSHOTS, { recursive: true });
      await page.locator('#language').click();
      await page.screenshot({ path: path.join(process.env.E5_STORE_SCREENSHOTS, 'statistics-desktop.png'), fullPage: true });
      await page.setViewportSize({ width: 390, height: 844 });
      await page.screenshot({ path: path.join(process.env.E5_STORE_SCREENSHOTS, 'statistics-mobile.png'), fullPage: true });
    }
    if (await page.locator('html').getAttribute('lang') !== 'zh-CN') await page.locator('#language').click();
    failure = true;
    await page.reload();
    await page.waitForFunction(() => document.getElementById('visit-count').title.includes('暂不可用'));
    assert.equal(await page.locator('#visit-count').textContent(), '—');
    assert.equal(await page.locator('.download-count[data-stat-key="download:bigclock"]').textContent(), '—');
    await download(clockLink());
    assert.equal(await page.locator('.download-count[data-stat-key="download:bigclock"]').textContent(), '—');
    failure = false;
    malformed = true;
    await page.reload();
    await page.waitForFunction(() => document.getElementById('visit-count').title.includes('暂不可用'));
    assert.equal(await page.locator('#visit-count').textContent(), '—', 'Invalid counts displayed');
    assert.deepEqual(errors, [], 'Browser errors');
    console.log('Statistics passed: preview isolation, persistent shared counts, visits separated from download clicks, card and dialog downloads, cross-version totals, stale responses, safe keys, responsive layout and failures without blocking downloads.');
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
