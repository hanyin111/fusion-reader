import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';

function extension(packageName) {
  const context = vm.createContext({ sendMessage() {} });
  vm.runInContext(fs.readFileSync(new URL('../assets/js/runtime.js', import.meta.url), 'utf8'), context);
  vm.runInContext(fs.readFileSync(new URL(`../assets/extensions/${packageName}.js`, import.meta.url), 'utf8')
    .replace('export default class', 'globalThis.Source = class'), context);
  return vm.runInContext('new Source()', context);
}

test('MangaDex filters by author ID and paginates instead of searching titles', async () => {
  const source = extension('mangadex');
  source.request = async path => {
    const query = new URL(path, 'https://api.mangadex.org').searchParams;
    assert.equal(query.get('authors[]'), 'author-id');
    assert.equal(query.get('offset'), '20');
    assert.equal(query.has('title'), false);
    return { data: [{ id: 'other-work', attributes: { title: { en: 'Other work' } } }] };
  };
  assert.equal((await source.searchAuthor({ name: 'Shared name', id: 'author-id' }, 2))[0].url, 'other-work');
});

test('WeebCentral and Royal Road use the author field, including encoded names', async () => {
  for (const packageName of ['weebcentral', 'royalroad']) {
    const source = extension(packageName);
    source.request = async path => {
      const query = new URL(path, 'https://example.com').searchParams;
      assert.equal(query.get('author'), '作者 A & B');
      assert.equal(query.has('text'), false);
      assert.equal(query.has('title'), false);
      if (packageName === 'weebcentral') assert.equal(query.get('offset'), '32');
      else assert.equal(query.get('page'), '2');
      return 'author results';
    };
    source.parseArticles = source.parseList = async html => [{ title: html }];
    assert.equal((await source.searchAuthor({ name: '作者 A & B' }, 2))[0].title, 'author results');
  }
});

test('Gutenberg excludes books whose titles merely mention an author', async () => {
  const source = extension('gutenberg');
  source.request = async path => {
    assert.equal(new URL(path, 'https://gutendex.com').searchParams.get('search'), 'Shelley, Mary');
    return { results: [
      { id: 1, title: 'By the author', authors: [{ name: 'Shelley, Mary' }] },
      { id: 2, title: 'About Shelley, Mary', authors: [{ name: 'Other author' }] },
    ] };
  };
  assert.deepEqual(Array.from(await source.searchAuthor({ name: 'Shelley, Mary' }, 1), b => b.url), ['1']);
});

test('Linovelib parses only the author catalogue, excluding popup suggestions', async () => {
  const source = extension('linovelib');
  source.get = async path => {
    assert.equal(path, '/authorarticle/%E4%BD%9C%E8%80%85%20A.html');
    return 'author page with unrelated popup books';
  };
  source.querySelector = async (html, selector) => {
    assert.equal(selector, '.book-ol');
    return { content: Promise.resolve('only the author list') };
  };
  source.parseNovelLinks = async html => {
    assert.equal(html, 'only the author list');
    return [{ url: '/novel/2.html' }];
  };
  assert.equal((await source.searchAuthor({ name: '作者 A' }, 1))[0].url, '/novel/2.html');
  assert.equal((await source.searchAuthor({ name: '作者 A' }, 2)).length, 0);
  source.querySelector = async () => ({ content: Promise.resolve('') });
  await assert.rejects(source.searchAuthor({ name: '作者 A' }, 1), /作者作品列表加载失败/);
});

test('legacy scripts receive the author keyword and optional filter in their own search', async () => {
  const source = extension('picacg');
  const author = { name: '作者 A', id: '', url: '' };
  source.search = async (keyword, page, filter) => {
    assert.equal(keyword, author.name);
    assert.equal(page, 3);
    assert.equal(filter.author, author);
    return [{ title: 'Other work' }];
  };
  assert.equal((await source.searchAuthor(author, 3))[0].title, 'Other work');
});
