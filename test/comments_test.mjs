import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';

function extension(packageName) {
  const context = vm.createContext({ sendMessage() {} });
  vm.runInContext(fs.readFileSync(new URL('../assets/js/runtime.js', import.meta.url), 'utf8'), context);
  vm.runInContext(fs.readFileSync(new URL(`../assets/extensions/${packageName}.js`, import.meta.url), 'utf8')
    .replace('export default class', 'globalThis.Source = class'), context);
  const source = vm.runInContext('new Source()', context);
  source.webSite = packageName === 'linovelib' ? 'https://www.bilinovel.net' : 'https://picaapi.picacomic.com';
  return source;
}

test('Linovelib reads the same chapter thread from any numbered sub-page', async () => {
  const source = extension('linovelib');
  source.request = async (path, options) => {
    assert.equal(path, '/comment/php/api.php?action=get_list');
    assert.equal(options.method, 'post');
    assert.equal(options.headers.Referer, 'https://www.bilinovel.net/novel/2139/76673.html');
    assert.match(options.headers['User-Agent'], /Mobile/);
    const form = new URLSearchParams(options.data);
    assert.equal(form.get('cmtid'), '76673');
    assert.equal(form.get('catid'), '2139');
    assert.equal(form.get('pageIndex'), '2');
    return JSON.stringify({ err_msg: 'success', cmtid: '76673', catid: '2139', hasmore: 1, total: '21', data: [
      { plid: 9, plusername: '读者', saytext: '<div>引用 &amp; 正文</div><img src="/image.jpg">', zcnum: '3', ispoiler: '1' },
    ] });
  };
  const result = await source.comments('/novel/2139.html', 'https://www.linovelib.com/novel/2139/76673_2.html', 2);
  assert.equal(result.comments[0].text, '引用 & 正文');
  assert.equal(result.comments[0].images[0], 'https://www.bilinovel.net/image.jpg');
  assert.equal(result.comments[0].spoiler, true);
  assert.equal(result.comments[0].likes, 3);
  assert.equal(result.hasMore, true);
});

test('Linovelib rejects cross-book chapters and responses missing the chapter ID', async () => {
  const source = extension('linovelib');
  source.request = async () => ({ err_msg: 'success', cmtid: null, catid: null, data: [], total: '0' });
  await assert.rejects(source.comments('/novel/2139.html', '/novel/999/76673.html', 1), /无效/);
  await assert.rejects(source.comments('/novel/2139.html', '/novel/2139/76673.html', 1), /未返回本章/);
});

test('Pica uses comic-wide GET comments and deduplicates pinned entries', async () => {
  const source = extension('picacg');
  const pinned = { _id: 'pinned', _user: { name: '读者' }, content: '置顶正文', likesCount: 2, commentsCount: 1 };
  source.api = async (path, method) => {
    assert.equal(path, 'comics/comic-id/comments?page=1');
    assert.equal(method, 'GET');
    return { topComments: [pinned], comments: { docs: [pinned, { _id: 'hidden', hide: true, content: '隐藏内容' }], pages: 2, total: 21 } };
  };
  const result = await source.comments('comic-id', 'comic-id/10', 1);
  assert.equal(result.comments.length, 2);
  assert.equal(result.comments[0].pinned, true);
  assert.equal(result.comments[0].replyCount, 1);
  assert.equal(result.comments[1].text, '');
  assert.equal(result.comments[1].hidden, true);
  assert.equal(result.hasMore, true);
});

test('Pica reads replies without posting or liking comments', async () => {
  const source = extension('picacg');
  source.api = async (path, method) => {
    assert.equal(path, 'comments/parent-id/childrens?page=2');
    assert.equal(method, 'GET');
    return { comments: { docs: [{ _id: 'reply', content: '回复' }], pages: 2, total: 1 } };
  };
  const result = await source.comments('comic-id', 'comic-id/2', 2, 'parent-id');
  assert.equal(result.comments[0].text, '回复');
  assert.equal(result.hasMore, false);
});

test('Pica treats unexpected API responses as errors, not empty comment lists', async () => {
  const source = extension('picacg');
  source.api = async () => ({});
  await assert.rejects(source.comments('comic-id', 'comic-id/1', 1), /加载失败/);
});
