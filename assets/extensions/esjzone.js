// ==MiruExtension==
// @name         ESJ Zone
// @version      v1.0.0
// @author       FusionReader
// @lang         zh-tw
// @license      MIT
// @package      esjzone
// @type         fikushon
// @icon         https://img.kookapp.cn/assets/2023-01/rhv1ugUjQw0dd0ef.png
// @webSite      https://www.esjzone.cc
// @nsfw         false
// @network      auto
// ==/MiruExtension==

export default class extends Extension {
  async load() {
    await this.registerSetting({
      title: 'ESJ 帳號 (Email)',
      key: 'email',
      type: 'input',
      description: '部分作品需登入後才能閱讀；留空則以訪客身分瀏覽',
      defaultValue: '',
    });
    await this.registerSetting({
      title: 'ESJ 密碼',
      key: 'password',
      type: 'password',
      description: '僅保存在本機，用於換取站點的登入 Cookie',
      defaultValue: '',
    });
    this.loggedIn = false;
  }

  /// Sign in if credentials are configured. Returns false when the user has
  /// not supplied any, so callers can fall back to guest browsing.
  async ensureLogin(force) {
    if (this.loggedIn && !force) return true;
    const email = await this.getSetting('email');
    const password = await this.getSetting('password');
    if (!email || !password) return false;

    const res = await this.request('/inc/mem_login.php', {
      method: 'post',
      headers: {
        'X-Requested-With': 'XMLHttpRequest',
        Referer: `${this.webSite}/my/login`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      data: `email=${encodeURIComponent(email)}&pwd=${encodeURIComponent(
        password
      )}&remember_me=on`,
      allowErrorStatus: true,
    });
    const body = typeof res === 'string' ? JSON.parse(res) : res;
    // 200/301 carry the post-login redirect; 202/203 are validation and
    // credential failures respectively.
    if (body.status === 200 || body.status === 301) {
      this.loggedIn = true;
      return true;
    }
    this.loggedIn = false;
    throw new Error(`ESJ 登入失敗: ${body.msg || `status ${body.status}`}`);
  }

  // Cards on list and tag pages share the same markup.
  async parseCards(html) {
    const cards = await this.querySelectorAll(html, 'div.card');
    const out = [];
    const seen = new Set();
    for (const card of cards) {
      const content = await card.content;
      const href = await this.getAttributeText(content, 'h5.card-title a', 'href');
      if (!href || !/\/detail\/\d+\.html/.test(href) || seen.has(href)) continue;
      const titleEl = await this.querySelector(content, 'h5.card-title a');
      const title = titleEl ? (await titleEl.text).trim() : '';
      if (!title) continue;
      seen.add(href);
      // Covers are injected client-side, so list pages carry no usable image.
      out.push({ title, url: href, cover: '' });
    }
    return out;
  }

  pagePath(base, page) {
    return page <= 1 ? `${base}/` : `${base}/${page}.html`;
  }

  async channels() {
    return [
      { title: '最新更新', key: '' },
      // Doubles as a login probe: it works only with a live session cookie.
      { title: '我的收藏', key: 'favorites' },
    ];
  }

  async latest(page, channel) {
    if (channel === 'favorites') return this.favorites(page);
    const html = await this.request(this.pagePath('/list-1', page));
    return this.parseCards(html);
  }

  async favorites(page) {
    const email = await this.getSetting('email');
    if (!email) {
      throw new Error('「我的收藏」需要登入。請在「扩展」頁點本源的設定按鈕填入 ESJ 帳號密碼。');
    }
    await this.ensureLogin(page <= 1); // page 1 re-authenticates; later pages reuse the session
    const html = await this.request(this.pagePath('/my/favorite', page), {
      allowErrorStatus: true,
    });
    // The member area bounces guests via a script redirect, not a 302. If we
    // still land there after ensureLogin() reported success, the login cookie
    // was not kept — which is exactly what this channel exists to expose.
    if (/window\.location\.href='\/my\/login'/.test(html)) {
      throw new Error('登入請求已通過，但站點未保留登入狀態（Cookie 未生效）。');
    }
    const cards = await this.parseCards(html);
    if (cards.length) return cards;
    // Member pages have gone through several layouts; fall back to scanning
    // every novel link on the page rather than assuming the card markup.
    const links = await this.querySelectorAll(html, 'a');
    const out = [];
    const seen = new Set();
    for (const link of links) {
      const href = await link.getAttributeText('href');
      if (!href || !/\/detail\/\d+\.html/.test(href) || seen.has(href)) continue;
      const title = (await link.text).trim();
      if (!title) continue;
      seen.add(href);
      out.push({ title, url: href, cover: '' });
    }
    return out;
  }

  async search(kw, page) {
    // The site has no plain search endpoint; its tag browser doubles as one.
    const html = await this.request(
      this.pagePath(`/tags/${encodeURIComponent(kw)}`, page)
    );
    return this.parseCards(html);
  }

  async detail(url) {
    await this.ensureLogin(false).catch(() => false);
    let html = await this.request(url);
    let links = await this.querySelectorAll(html, '#chapterList a');
    if (!links.length) {
      // Member-only titles hide their chapter list from guests.
      if (await this.ensureLogin(true).catch(() => false)) {
        html = await this.request(url);
        links = await this.querySelectorAll(html, '#chapterList a');
      }
    }

    const titleEl = await this.querySelector(html, 'h2.p-t-10');
    const title = titleEl ? (await titleEl.text).trim() : '';

    let desc = '';
    const descEl = await this.querySelector(html, 'div.description');
    if (descEl) desc = (await descEl.text).trim();

    const chapters = [];
    for (const link of links) {
      const href = await link.getAttributeText('href');
      if (!href) continue;
      let name = await link.getAttributeText('data-title');
      if (!name) name = (await link.text).trim();
      if (name) chapters.push({ name, url: href });
    }

    return {
      title,
      cover: '',
      desc,
      episodes: [{ title: '章節', urls: chapters }],
    };
  }

  async readChapter(url) {
    const html = await this.request(url);
    // Text and illustrations in one pass, keeping document order.
    let content = [];
    const container = await this.querySelector(html, 'div.forum-content');
    if (container) {
      content = this.htmlToBlocks(await container.content, `${this.webSite}/`);
    }
    if (!content.length && container) {
      // Some chapters put their body in bare text nodes rather than tags.
      for (const line of (await container.text).split('\n')) {
        const t = line.trim();
        if (t) content.push(t);
      }
    }
    const titleEl = await this.querySelector(html, 'h2');
    return {
      content,
      subtitle: titleEl ? (await titleEl.text).trim() : '',
      // Illustrations are hotlink-protected on the site's image hosts.
      headers: { Referer: `${this.webSite}/` },
    };
  }

  async watch(url) {
    await this.ensureLogin(false).catch(() => false);
    let result = await this.readChapter(url);

    if (!result.content.length) {
      // Empty body usually means the chapter is behind the login wall.
      let signedIn = false;
      try {
        signedIn = await this.ensureLogin(true);
      } catch (e) {
        throw new Error(`本章需要登入，但登入失敗：${e.message}`);
      }
      if (!signedIn) {
        throw new Error(
          '本章沒有可讀內容，可能需要登入。請在「扩展」頁點本源的設定按鈕填入 ESJ 帳號密碼。'
        );
      }
      result = await this.readChapter(url);
      if (!result.content.length) {
        throw new Error('已登入，但本章仍沒有可讀內容（可能是圖片章節或已下架）。');
      }
    }
    return result;
  }
}
