import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';

function extension() {
  const context = vm.createContext({ sendMessage() {} });
  vm.runInContext(fs.readFileSync(new URL('../assets/js/runtime.js', import.meta.url), 'utf8'), context);
  vm.runInContext(fs.readFileSync(new URL('../assets/extensions/linovelib.js', import.meta.url), 'utf8')
    .replace('export default class', 'globalThis.Linovelib = class'), context);
  const source = vm.runInContext('new Linovelib()', context);
  source.webSite = 'https://www.bilinovel.net';
  source.sleep = async () => {};
  return source;
}

// Stub only the DOM/network bridge. Exercise the real chapter pagination logic.
function pages(source, fixtures) {
  const requests = [];
  source.get = async (url, referer, browser) => {
    requests.push({ url, referer, browser });
    assert.ok(fixtures[url], `Unexpected page: ${url}`);
    return fixtures[url].html;
  };
  source.querySelector = async () => ({ text: Promise.resolve('测试章') });
  source.extractBlocks = async (_, content, url) => content.push(...fixtures[url].content);
  return requests;
}

const origin = 'https://www.bilinovel.net';

test('uses a mobile UA and the canonical mobile domain for browser chapter requests', async () => {
  const source = extension();
  let request;
  source.request = async (url, options) => { request = { url, options }; return ''; };
  await source.get('https://www.linovelib.com/novel/1/2.html',
    'https://m.bilinovel.com/novel/1/catalog', true);
  assert.equal(request.url, `${origin}/novel/1/2.html`);
  assert.equal(request.options.headers.Referer, `${origin}/novel/1/catalog`);
  assert.match(request.options.headers['User-Agent'], /Android.*Mobile/);
  assert.equal(request.options.browser, true);
  assert.equal(request.options.browserSelector, '#acontent');
});

test('joins all pages in order and stops before the following chapter', async () => {
  const source = extension();
  const requests = pages(source, {
    [`${origin}/novel/1/2.html`]: { html: `url_next : "/novel/1/2_2.html"`, content: ['第一段'] },
    [`${origin}/novel/1/2_2.html`]: { html: `url_next:'/novel/1/3.html'`, content: ['最后一段'] },
  });
  const result = await source.watch('/novel/1/2.html');
  assert.deepEqual(Array.from(result.content), ['第一段', '最后一段']);
  assert.equal(requests.length, 2);
  assert.ok(requests.every(r => r.browser));
  assert.equal(requests[1].referer, requests[0].url);
});

test('does not follow the same chapter number into another novel', async () => {
  const source = extension();
  const requests = pages(source, {
    [`${origin}/novel/1/2.html`]: { html: `url_next:'/novel/9/2_2.html'`, content: ['完整正文'] },
  });
  await source.watch('/novel/1/2.html');
  assert.equal(requests.length, 1);
});

test('rejects a truncated response instead of returning a cacheable preview', async () => {
  const source = extension();
  pages(source, {
    [`${origin}/novel/1/2.html`]: { html: '', content: ['内容加载失败，请更换浏览器'] },
  });
  await assert.rejects(source.watch('/novel/1/2.html'), /完整正文/);
});

test('rejects an empty response', async () => {
  const source = extension();
  pages(source, { [`${origin}/novel/1/2.html`]: { html: '', content: [] } });
  await assert.rejects(source.watch('/novel/1/2.html'), /完整正文/);
});

test('rejects a pagination loop', async () => {
  const source = extension();
  pages(source, {
    [`${origin}/novel/1/2.html`]: { html: `url_next:'/novel/1/2.html'`, content: ['正文'] },
  });
  await assert.rejects(source.watch('/novel/1/2.html'), /循环/);
});

test('reports the page limit instead of silently truncating a long chapter', async () => {
  const source = extension();
  const fixtures = {};
  for (let page = 1; page <= 30; page++) {
    const path = `/novel/1/2${page === 1 ? '' : `_${page}`}.html`;
    fixtures[origin + path] = { html: `url_next:'/novel/1/2_${page + 1}.html'`, content: ['正文'] };
  }
  pages(source, fixtures);
  await assert.rejects(source.watch('/novel/1/2.html'), /分页过多/);
});
