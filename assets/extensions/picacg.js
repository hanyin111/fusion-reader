// ==MiruExtension==
// @name         哔咔漫画
// @version      v1.0.0
// @author       FusionReader
// @lang         zh-cn
// @license      MIT
// @package      picacg
// @type         manga
// @icon         https://picacomic.com/favicon.ico
// @webSite      https://picaapi.picacomic.com
// @nsfw         true
// @network      auto
// ==/MiruExtension==
//
// Requires a Picacomic account: fill 帐号/密码 in this extension's settings.
// The API rejects anonymous reads, so there is no usable guest mode.

const API_KEY = 'C69BAF41DA5ABD1FFEDC6D2FEA56B';
const SIGN_SECRET =
  '~d}$Q7$eIni=V)9\\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn';

export default class extends Extension {
  async load() {
    await this.registerSetting({
      title: '哔咔帐号',
      key: 'email',
      type: 'input',
      description: '在哔咔 App 注册的邮箱或用户名',
      defaultValue: '',
    });
    await this.registerSetting({
      title: '哔咔密码',
      key: 'password',
      type: 'password',
      description: '仅保存在本机，用于换取访问令牌',
      defaultValue: '',
    });
  }

  randomHex(length) {
    const chars = '0123456789abcdef';
    let out = '';
    for (let i = 0; i < length; i++) {
      // The nonce only needs to vary per request, not be cryptographically strong.
      out += chars[Math.floor(Math.random() * 16)];
    }
    return out;
  }

  async signedHeaders(path, method) {
    const time = String(Math.floor(Date.now() / 1000));
    const nonce = this.randomHex(32);
    const raw = (path + time + nonce + method + API_KEY).toLowerCase();
    const signature = await this.hmacSha256(SIGN_SECRET, raw);
    return {
      'api-key': API_KEY,
      accept: 'application/vnd.picacomic.com.v1+json',
      'app-channel': '3',
      time,
      nonce,
      signature,
      'app-version': '2.2.1.3.3.4',
      'app-uuid': 'defaultUuid',
      'app-platform': 'android',
      'app-build-version': '45',
      'image-quality': 'original',
      'Content-Type': 'application/json; charset=UTF-8',
      'User-Agent': 'okhttp/3.8.1',
    };
  }

  async token() {
    const cached = await this.getSetting('__token');
    if (cached) return cached;
    return this.signIn();
  }

  async signIn() {
    const email = (await this.getSetting('email')) || '';
    const password = (await this.getSetting('password')) || '';
    if (!email || !password) {
      throw new Error('未配置哔咔帐号。请在「扩展」页点击本源的设置按钮填写帐号和密码。');
    }
    const path = 'auth/sign-in';
    const headers = await this.signedHeaders(path, 'POST');
    const res = await this.request(`/${path}`, {
      method: 'post',
      headers,
      data: { email, password },
      allowErrorStatus: true,
    });
    const body = typeof res === 'string' ? JSON.parse(res) : res;
    if (!body.data || !body.data.token) {
      throw new Error(
        `登录失败: ${body.message || body.error || JSON.stringify(body)}`
      );
    }
    await this.setSetting('__token', body.data.token);
    return body.data.token;
  }

  // Perform a signed, authenticated call, re-logging in once if the token died.
  async api(path, method, data, retried) {
    const token = await this.token();
    const headers = await this.signedHeaders(path, method || 'GET');
    headers.authorization = token;
    const res = await this.request(`/${path}`, {
      method: (method || 'GET').toLowerCase(),
      headers,
      data,
      allowErrorStatus: true,
    });
    const body = typeof res === 'string' ? JSON.parse(res) : res;
    if (body.code && body.code !== 200) {
      if (!retried && (body.code === 401 || body.error === '1005')) {
        await this.setSetting('__token', '');
        return this.api(path, method, data, true);
      }
      throw new Error(`${body.code} ${body.message || body.error || ''}`);
    }
    return body.data;
  }

  imageUrl(media) {
    if (!media) return '';
    const server = (media.fileServer || '').replace(/\/$/, '');
    const path = media.path || '';
    if (!server) return path;
    if (/\/static$/.test(server)) return `${server}/${path}`;
    return `${server}/static/${path}`;
  }

  // Listings return {comics:{docs:[]}} while leaderboards return {comics:[]}.
  mapComics(docs) {
    return (docs || []).map((c) => ({
      title: c.title,
      url: c._id,
      cover: this.imageUrl(c.thumb),
      update: c.author || '',
    }));
  }

  // Browse channels: sort orders, leaderboards, then the site's own
  // categories fetched live so the list tracks whatever the site offers.
  async channels() {
    const list = [
      { title: '最新', key: 'sort:dd' },
      { title: '最舊', key: 'sort:da' },
      { title: '最多愛心', key: 'sort:ld' },
      { title: '最多觀看', key: 'sort:vd' },
      { title: '24小時排行', key: 'rank:H24' },
      { title: '7天排行', key: 'rank:D7' },
      { title: '30天排行', key: 'rank:D30' },
    ];
    try {
      const data = await this.api('categories', 'GET');
      for (const c of data.categories || []) {
        if (c.title && !c.isWeb) list.push({ title: c.title, key: `cat:${c.title}` });
      }
    } catch (e) {
      // Categories are a bonus; the sorts and rankings still work without them.
    }
    return list;
  }

  async latest(page, channel) {
    const key = channel || 'sort:dd';

    // Leaderboards return a plain array and are not paginated.
    if (key.startsWith('rank:')) {
      if (page > 1) return [];
      const data = await this.api(
        `comics/leaderboard?tt=${key.slice(5)}&ct=VC`,
        'GET'
      );
      return this.mapComics(data.comics);
    }

    if (key.startsWith('cat:')) {
      const category = encodeURIComponent(key.slice(4));
      const data = await this.api(`comics?page=${page}&c=${category}&s=dd`, 'GET');
      return this.mapComics((data.comics || {}).docs);
    }

    const data = await this.api(`comics?page=${page}&s=${key.slice(5)}`, 'GET');
    return this.mapComics((data.comics || {}).docs);
  }

  async search(kw, page) {
    const data = await this.api(`comics/advanced-search?page=${page}`, 'POST', {
      keyword: kw,
      sort: 'dd',
      categories: [],
    });
    return this.mapComics((data.comics || {}).docs);
  }

  async detail(url) {
    const data = await this.api(`comics/${url}`, 'GET');
    const comic = data.comic || {};

    const eps = [];
    let page = 1;
    for (let i = 0; i < 20; i++) {
      const epData = await this.api(`comics/${url}/eps?page=${page}`, 'GET');
      const block = epData.eps || {};
      for (const ep of block.docs || []) {
        eps.push({ name: ep.title, url: `${url}/${ep.order}`, order: ep.order });
      }
      if (page >= (block.pages || 1)) break;
      page += 1;
    }
    eps.sort((a, b) => a.order - b.order);

    return {
      title: comic.title || '',
      cover: this.imageUrl(comic.thumb),
      desc: [
        comic.author ? `作者: ${comic.author}` : '',
        comic.categories && comic.categories.length
          ? `分类: ${comic.categories.join(', ')}`
          : '',
        comic.description || '',
      ]
        .filter(Boolean)
        .join('\n'),
      episodes: [{ title: '章节', urls: eps.map((e) => ({ name: e.name, url: e.url })) }],
    };
  }

  async watch(url) {
    const slash = url.lastIndexOf('/');
    const comicId = url.slice(0, slash);
    const order = url.slice(slash + 1);

    const urls = [];
    let page = 1;
    for (let i = 0; i < 30; i++) {
      const data = await this.api(
        `comics/${comicId}/order/${order}/pages?page=${page}`,
        'GET'
      );
      const block = data.pages || {};
      for (const p of block.docs || []) {
        const link = this.imageUrl(p.media);
        if (link) urls.push(link);
      }
      if (page >= (block.pages || 1)) break;
      page += 1;
    }
    return { urls };
  }
}
