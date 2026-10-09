// ==MiruExtension==
// @name         禁漫天堂
// @version      v1.0.0
// @author       FusionReader
// @lang         zh-cn
// @license      MIT
// @package      jmcomic
// @type         manga
// @icon         https://18comic.vip/favicon.ico
// @webSite      https://18comic.vip
// @nsfw         true
// @network      auto
// ==/MiruExtension==
// API protocol and image reconstruction adapted from Aidoku Community's
// zh.jmcomic source (MIT). See assets/licenses/Aidoku-sources-MIT.txt.

const JM_UA = 'Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Version/4.0 Chrome/130.0.0.0 Mobile Safari/537.36';
const JM_HEADERS = {
  'User-Agent': JM_UA,
  'X-Requested-With': 'com.example.app',
  Referer: 'https://localhost/',
  Origin: 'https://localhost',
  Accept: '*/*',
};
const JM_REFRESH_URLS = [
  'https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt',
  'https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt',
];

export default class extends Extension {
  async load() {
    await this.registerSetting({
      key: 'apiDomain', title: '接口域名（可选）', type: 'input', defaultValue: '',
      description: '留空自动获取可用域名；可填写手机 App 接口域名',
    });
    await this.registerSetting({
      key: 'imageShunt', title: '图片线路', type: 'input', defaultValue: '3',
      description: '可选 1、2、3、4；图片加载失败时可尝试其他线路',
    });
    this._context = null;
    this._connecting = null;
  }

  object(value) {
    return typeof value === 'string' ? JSON.parse(value.replace(/^\uFEFF/, '').trim()) : value;
  }

  domain(value) {
    const host = String(value || '').trim().replace(/^https?:\/\//i, '').replace(/\/+$/, '');
    if (!/^[a-z0-9.-]+(?::\d+)?$/i.test(host) || host.includes('..')) return '';
    return host;
  }

  async domains(manual) {
    if (manual) {
      const host = this.domain(manual);
      if (!host) throw new Error('接口域名格式不正确，请仅填写域名或 HTTPS 地址');
      return [host];
    }
    let lastError;
    for (const url of JM_REFRESH_URLS) {
      try {
        const encrypted = await this.request(url, {
          headers: { 'User-Agent': JM_UA }, timeoutMs: 6000, retry: false,
        });
        const key = await this.md5('diosfjckwpqpdfjkvnqQjsik');
        const data = this.object(await this.aesEcbDecrypt(String(encrypted).replace(/^\uFEFF/, '').trim(), key));
        const servers = Array.isArray(data.Server) ? data.Server : [];
        const hosts = [...new Set(servers.map(value => this.domain(value)).filter(Boolean))];
        if (hosts.length) return hosts.slice(0, 4);
        throw new Error('接口域名列表为空');
      } catch (error) { lastError = error; }
    }
    const cached = this.domain(await this.getSetting('__lastDomain'));
    if (cached) return [cached];
    throw new Error('无法获取接口域名，请检查本源的网络线路。' + String(lastError || ''));
  }

  async apiOn(host, path) {
    const ts = String(Math.floor(Date.now() / 1000));
    const token = await this.md5(ts + '18comicAPPContent');
    const outer = this.object(await this.request('https://' + host + path, {
      headers: { ...JM_HEADERS, token, tokenparam: ts + ',2.0.16' },
      timeoutMs: 8000, retry: false,
    }));
    if (!outer || (outer.code != null && Number(outer.code) !== 200)) {
      throw new Error('接口请求失败：' + String(outer && (outer.errorMsg || outer.msg || outer.message || outer.code) || '响应为空'));
    }
    if (outer.data && typeof outer.data === 'object') return outer.data;
    if (typeof outer.data !== 'string' || !outer.data) throw new Error('接口未返回有效数据');
    const key = await this.md5(ts + '185Hcomic3PAPP7R');
    const text = await this.aesEcbDecrypt(outer.data, key);
    const start = text.search(/[\[{]/);
    const end = Math.max(text.lastIndexOf('}'), text.lastIndexOf(']'));
    if (start < 0 || end < start) throw new Error('接口解密后数据格式不正确');
    return this.object(text.slice(start, end + 1));
  }

  async context(exclude) {
    const manual = String(await this.getSetting('apiDomain') || '').trim();
    const shunt = String(await this.getSetting('imageShunt') || '3').trim();
    if (!/^[1-4]$/.test(shunt)) throw new Error('图片线路请填写 1、2、3 或 4');
    const config = manual + '|' + shunt;
    if (!exclude && this._context && this._context.config === config &&
        Date.now() - this._context.time < 15 * 60 * 1000) return this._context;
    if (this._connecting) {
      const result = await this._connecting;
      if (!exclude && result.config === config) return result;
    }
    const connecting = (async () => {
      const hosts = await this.domains(manual);
      let lastError;
      for (const host of hosts.filter(value => value !== exclude)) {
        try {
          const setting = await this.apiOn(host, '/setting?app_img_shunt=' + shunt + '&express=');
          const cdn = String(setting.img_host || '').replace(/\/+$/, '');
          if (!/^https:\/\/[a-z0-9.-]+(?::\d+)?(?:\/[^?#]*)?$/i.test(cdn)) {
            throw new Error('接口没有返回有效的图片服务器');
          }
          const result = { host, cdn, config, time: Date.now() };
          this._context = result;
          await this.setSetting('__lastDomain', host);
          return result;
        } catch (error) { lastError = error; }
      }
      this._context = null;
      throw new Error('当前接口域名不可用，请检查网络或更换接口域名。' + String(lastError || ''));
    })();
    this._connecting = connecting;
    try { return await connecting; }
    finally { if (this._connecting === connecting) this._connecting = null; }
  }

  async api(path) {
    let ctx = await this.context();
    try { return { data: await this.apiOn(ctx.host, path), ctx }; }
    catch (error) {
      if (String(await this.getSetting('apiDomain') || '').trim()) throw error;
      this._context = null;
      ctx = await this.context(ctx.host);
      return { data: await this.apiOn(ctx.host, path), ctx };
    }
  }

  cover(cdn, id) { return cdn + '/media/albums/' + id + '_3x4.jpg'; }

  items(data, ctx) {
    const list = Array.isArray(data.content) ? data.content : (Array.isArray(data.list) ? data.list : []);
    return list.filter(item => /^\d+$/.test(String(item.id || ''))).map(item => ({
      title: String(item.name || item.title || item.id),
      url: '/album/' + item.id,
      cover: /^https?:\/\//.test(String(item.image || '')) ? item.image : this.cover(ctx.cdn, item.id),
      update: String(item.author || ''),
    }));
  }

  async channels() {
    return [{ key: 'mr', title: '最新漫画' }, { key: 'mv', title: '最多观看' }, { key: 'tf', title: '最多喜欢' }];
  }

  async latest(page, channel) {
    const order = ['mr', 'mv', 'tf'].includes(channel) ? channel : 'mr';
    const { data, ctx } = await this.api('/categories/filter?o=' + order + '&page=' + Math.max(1, Number(page) || 1));
    return this.items(data, ctx);
  }

  id(url, kind) {
    const value = String(url || '').trim();
    if (/^\d+$/.test(value)) return value;
    const match = value.match(new RegExp('/' + kind + '/(\\d+)(?:[/?#]|$)'));
    if (!match) throw new Error('无效的作品或章节地址');
    return match[1];
  }

  async search(keyword, page) {
    const query = String(keyword || '').trim();
    if (!query) return [];
    if (Number(page) <= 1 && (/^\d+$/.test(query) || /\/album\/\d+/.test(query))) {
      const id = this.id(query, 'album');
      const { data, ctx } = await this.api('/album?id=' + id);
      return data.name ? [{ title: data.name, url: '/album/' + id, cover: this.cover(ctx.cdn, id) }] : [];
    }
    const { data, ctx } = await this.api('/search?search_query=' + encodeURIComponent(query) + '&o=mr&page=' + Math.max(1, Number(page) || 1));
    return this.items(data, ctx);
  }

  async searchAuthor(author, page) { return this.search(author.name, page); }

  async detail(url) {
    const id = this.id(url, 'album');
    const { data, ctx } = await this.api('/album?id=' + id);
    if (!String(data.name || '').trim()) throw new Error('作品不存在或暂时无法访问');
    const series = Array.isArray(data.series) ? data.series : [];
    const chapters = series.map((chapter, index) => ({ ...chapter, index }))
      .filter(chapter => /^\d+$/.test(String(chapter.id || '')))
      .sort((a, b) => {
        const left = Number(a.sort) > 0 ? Number(a.sort) : Infinity;
        const right = Number(b.sort) > 0 ? Number(b.sort) : Infinity;
        return left === right ? a.index - b.index : left - right;
      }).map((chapter, index) => ({
        name: String(chapter.name || '').trim() || '第 ' + (index + 1) + ' 话',
        url: '/photo/' + chapter.id,
      }));
    const names = Array.isArray(data.author) ? data.author : [data.author];
    return {
      title: String(data.name), cover: this.cover(ctx.cdn, id),
      desc: [String(data.description || ''), Array.isArray(data.tags) ? data.tags.join(' · ') : ''].filter(Boolean).join('\n\n'),
      authors: [...new Set(names.map(name => String(name || '').trim()).filter(Boolean))].map(name => ({ name })),
      episodes: [{ title: '章节', urls: chapters.length ? chapters : [{ name: '第 1 话', url: '/photo/' + id }] }],
    };
  }

  async watch(url) {
    const id = this.id(url, 'photo');
    const { data, ctx } = await this.api('/chapter?id=' + id);
    const epId = /^\d+$/.test(String(data.id || '')) ? String(data.id) : id;
    const images = Array.isArray(data.images) ? data.images : [];
    const urls = images.filter(name => typeof name === 'string' && /^[^/?#]+\.(?:jpe?g|png|webp|gif)$/i.test(name))
      .map(name => ctx.cdn + '/media/photos/' + epId + '/' + encodeURIComponent(name) + '#fusion-jmcomic=' + epId);
    if (!urls.length) throw new Error('该章节没有可读取的图片');
    return { urls, headers: JM_HEADERS };
  }
}
