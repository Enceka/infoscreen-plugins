// Build first: python3 tools/build.py. E5_PLAYWRIGHT can point to an existing Playwright installation.
// E5_STORE_SCREENSHOTS optionally saves desktop, mobile, English and dialog screenshots.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require(process.env.E5_PLAYWRIGHT || 'playwright');
const dist = path.resolve(__dirname, '../dist');
const catalog = JSON.parse(fs.readFileSync(path.join(dist, 'index.json'), 'utf8'));
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json', '.gz': 'application/gzip' };

(async () => {
  const server = http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    const relative = pathname.replace(/^\/infoscreen-plugins\//, '') || 'index.html';
    const file = path.resolve(dist, relative);
    if (!file.startsWith(dist + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      response.writeHead(404).end(); return;
    }
    response.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
    response.end(fs.readFileSync(file));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}/infoscreen-plugins/`;
  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1080 }, permissions: ['clipboard-read', 'clipboard-write'] });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    let mode = 'real';
    const fixture = { generated: catalog.generated, plugins: [
      { ...catalog.plugins.find((app) => !app.backend), id: 'bigclock', version: '1.0', backend: false },
      { id: 'sample', version: '2.0', api_version: 2, name: { zh: '测试后台', en: 'Sample backend' }, description: { zh: '一个测试应用', en: 'A sample app' }, size: 2048, backend: true, sha256: 'a'.repeat(64), url: `${base}packages/sample-2.0.tar.gz` },
    ] };
    await page.route('**/index.json', (route) => {
      if (mode === 'error') return route.fulfill({ status: 503, body: 'Unavailable' });
      if (mode === 'empty') return route.fulfill({ json: { generated: catalog.generated, plugins: [] } });
      if (mode === 'invalid') return route.fulfill({ json: { plugins: {} } });
      if (mode === 'unsafe') return route.fulfill({ json: { ...fixture, plugins: [{ ...fixture.plugins[0], url: 'javascript:alert(1)' }] } });
      if (mode === 'escaped') return route.fulfill({ json: { ...fixture, plugins: [{ ...fixture.plugins[0], name: { zh: '<img src=x onerror=alert(1)>', en: '<script>alert(1)</script>' } }] } });
      return route.fulfill({ json: mode === 'real' ? catalog : fixture });
    });
    async function ready() { await page.waitForFunction(() => document.getElementById('catalog-state').hidden); }
    async function layout() {
      const size = await page.evaluate(() => ({ width: innerWidth, content: document.documentElement.scrollWidth }));
      assert(size.content <= size.width, `Horizontal overflow: ${JSON.stringify(size)}`);
    }
    async function shot(name) {
      if (!process.env.E5_STORE_SCREENSHOTS) return;
      fs.mkdirSync(process.env.E5_STORE_SCREENSHOTS, { recursive: true });
      await page.screenshot({ path: path.join(process.env.E5_STORE_SCREENSHOTS, name + '.png'), fullPage: true });
    }
    await page.goto(base);
    await ready();
    assert.equal(await page.locator('.app-card').count(), catalog.plugins.length);
    assert.equal(await page.locator('#hero-count').textContent(), String(catalog.plugins.length));
    for (const app of catalog.plugins) {
      const response = await page.request.get(base + 'packages/' + app.id + '-' + app.version + '.tar.gz');
      assert.equal(response.status(), 200);
      assert.equal((await response.body()).length, app.size);
    }
    await layout(); await shot('desktop-zh');
    await page.locator('.app-details').first().click();
    assert(await page.locator('#details').isVisible());
    assert.equal(await page.locator('#detail-download').getAttribute('href'), catalog.plugins[0].url);
    assert.equal(await page.locator('#detail-sha').textContent(), catalog.plugins[0].sha256);
    await shot('app-details');
    await page.keyboard.press('Escape');
    assert(!(await page.locator('#details').isVisible()));
    await page.locator('.copy-button').click();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), '/usr/libexec/e5-infoscreen/plugin install /tmp/app.tar.gz');
    await page.locator('#language').click();
    assert.equal(await page.locator('html').getAttribute('lang'), 'en');
    assert.equal(await page.locator('#hero-title').innerText(), 'Small screen.\nMore possibilities.');
    await layout(); await shot('desktop-en');
    await page.reload(); await ready();
    assert.equal(await page.locator('html').getAttribute('lang'), 'en');
    for (const width of [320, 390, 768, 1024]) {
      await page.setViewportSize({ width, height: 844 });
      await layout();
      await page.locator('.app-details').first().click(); await layout();
      await page.keyboard.press('Escape');
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator('#language').click(); await shot('mobile-zh');
    mode = 'fixture';
    await page.reload(); await ready();
    await page.locator('[data-filter="backend"]').click();
    assert.equal(await page.locator('.app-card').count(), 1);
    assert.equal(await page.locator('.app-card h3').textContent(), '测试后台');
    assert.equal(await page.locator('[data-filter="backend"]').getAttribute('aria-pressed'), 'true');
    await page.locator('.app-details').click();
    assert(await page.locator('#backend-note').isVisible());
    await page.keyboard.press('Escape');
    await page.locator('[data-filter="frontend"]').click();
    assert.equal(await page.locator('.app-card h3').textContent(), '大字时钟');
    await page.locator('[data-filter="all"]').click();
    await page.locator('#search').fill('SAMPLE BACKEND');
    assert.equal(await page.locator('.app-card').count(), 1);
    await page.locator('#search').fill('不存在的应用');
    assert.equal(await page.locator('.app-card').count(), 0);
    assert(await page.getByText('没有找到匹配的应用', { exact: true }).isVisible());
    await page.getByRole('button', { name: '查看全部应用', exact: true }).click();
    assert.equal(await page.locator('.app-card').count(), 2);
    await page.locator('#search').blur(); await page.keyboard.press('/');
    assert(await page.locator('#search').evaluate((node) => node === document.activeElement));
    for (const badMode of ['error', 'invalid', 'unsafe']) {
      mode = badMode; await page.reload();
      await page.getByRole('button', { name: '重新加载', exact: true }).waitFor();
      assert.equal(await page.locator('.app-card').count(), 0);
      mode = 'fixture'; await page.getByRole('button', { name: '重新加载', exact: true }).click();
      await ready(); assert.equal(await page.locator('.app-card').count(), 2);
    }
    mode = 'empty'; await page.reload();
    await page.getByText('应用正在来的路上', { exact: true }).waitFor();
    assert.equal(await page.locator('#hero-count').textContent(), '0');
    assert.equal(await page.locator('.app-card').count(), 0);
    mode = 'escaped'; await page.reload(); await ready();
    assert.equal(await page.locator('.app-card h3').textContent(), '<img src=x onerror=alert(1)>');
    assert.equal(await page.locator('.app-card img').count(), 0);
    await page.locator('.app-details').click();
    assert.equal(await page.locator('#detail-name').textContent(), '<img src=x onerror=alert(1)>');
    assert.deepEqual(errors, [], 'Browser errors');
    console.log('Store UI passed: real build and packages, subpath hosting, search, filters, translations, clipboard, dialogs, responsive layouts, retry, empty catalog and safe rendering.');
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
