// ==MiruExtension==
// @name         WeebCentral
// @version      v1.0.0
// @author       FusionReader
// @lang         en
// @license      MIT
// @package      weebcentral
// @type         manga
// @icon         https://weebcentral.com/favicon.ico
// @webSite      https://weebcentral.com
// @nsfw         false
// ==/MiruExtension==

export default class extends Extension {
  async parseArticles(html) {
    const items = await this.querySelectorAll(html, 'article');
    const result = [];
    const seen = new Set();
    for (const el of items) {
      const content = await el.content;
      const url = await this.getAttributeText(content, 'a[href*="/series/"]', 'href');
      if (!url || seen.has(url)) continue;
      const cover = await this.getAttributeText(content, 'img', 'src');
      let title = await this.getAttributeText(content, 'img', 'alt');
      if (title) title = title.replace(/ cover$/, '');
      if (!title) {
        const linkEl = await this.querySelector(content, 'a[href*="/series/"]');
        title = (await linkEl.text).trim().split('\n')[0];
      }
      if (!title) continue;
      seen.add(url);
      result.push({ title, url, cover: cover || '' });
    }
    return result;
  }

  async latest(page) {
    const html = await this.request(`/latest-updates/${page}`);
    return this.parseArticles(html);
  }

  async search(kw, page) {
    const offset = (page - 1) * 32;
    const html = await this.request(
      `/search/data?limit=32&offset=${offset}&text=${encodeURIComponent(kw)}&sort=Best%20Match&order=Ascending&official=Any&display_mode=Full%20Display`,
      { headers: { 'HX-Request': 'true' } }
    );
    return this.parseArticles(html);
  }

  seriesIdOf(url) {
    const m = url.match(/\/series\/([^/]+)/);
    return m ? m[1] : '';
  }

  async detail(url) {
    const html = await this.request(url);
    const titleEl = await this.querySelector(html, 'h1');
    const title = (await titleEl.text).trim();
    const cover = await this.getAttributeText(html, 'meta[property="og:image"]', 'content');
    const descEl = await this.querySelector(html, 'li strong + p.whitespace-pre-wrap');
    let desc = '';
    if (descEl) desc = (await descEl.text).trim();

    const id = this.seriesIdOf(url);
    const listHtml = await this.request(`/series/${id}/full-chapter-list`);
    const links = await this.querySelectorAll(listHtml, 'a[href*="/chapters/"]');
    const chapters = [];
    for (const link of links) {
      const content = await link.content;
      const href = await this.getAttributeText(content, 'a', 'href');
      const nameEl = await this.querySelector(content, 'span.grow > span');
      let name = nameEl ? (await nameEl.text).trim() : '';
      if (!name) {
        const spanEl = await this.querySelector(content, 'span');
        name = spanEl ? (await spanEl.text).trim() : href;
      }
      if (href) chapters.push({ name, url: href });
    }
    chapters.reverse(); // site lists newest first

    return {
      title,
      cover: cover || '',
      desc,
      episodes: [{ title: 'Chapters', urls: chapters }],
    };
  }

  async watch(url) {
    const html = await this.request(`${url}/images?is_prev=False&current_page=1&reading_style=long_strip`, {
      headers: { 'HX-Request': 'true', Referer: this.webSite + '/' },
    });
    const imgs = await this.querySelectorAll(html, 'img');
    const urls = [];
    for (const img of imgs) {
      const src = await img.getAttributeText('src');
      if (src && src.startsWith('http')) urls.push(src);
    }
    return {
      urls,
      headers: { Referer: 'https://weebcentral.com/' },
    };
  }
}
