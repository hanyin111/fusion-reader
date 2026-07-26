// ==MiruExtension==
// @name         Royal Road
// @version      v1.0.0
// @author       FusionReader
// @lang         en
// @license      MIT
// @package      royalroad
// @type         fikushon
// @icon         https://www.royalroad.com/icons/favicon-32x32.png
// @webSite      https://www.royalroad.com
// @nsfw         false
// ==/MiruExtension==

export default class extends Extension {
  async parseList(html) {
    const items = await this.querySelectorAll(html, 'div.fiction-list-item');
    const result = [];
    for (const el of items) {
      const content = await el.content;
      const url = await this.getAttributeText(content, 'a.bold', 'href')
        || await this.getAttributeText(content, 'h2.fiction-title a', 'href');
      const titleEl = await this.querySelector(content, 'h2.fiction-title');
      const title = (await titleEl.text).trim();
      let cover = await this.getAttributeText(content, 'img', 'src');
      if (!url || !title) continue;
      result.push({
        title,
        url,
        cover: cover || '',
      });
    }
    return result;
  }

  async latest(page) {
    const html = await this.request(`/fictions/latest-updates?page=${page}`);
    return this.parseList(html);
  }

  async search(kw, page) {
    const html = await this.request(`/fictions/search?title=${encodeURIComponent(kw)}&page=${page}`);
    return this.parseList(html);
  }

  async detail(url) {
    const html = await this.request(url);
    const titleEl = await this.querySelector(html, 'div.fic-title h1');
    const title = (await titleEl.text).trim();
    const cover = await this.getAttributeText(html, 'div.fic-header img', 'src');
    const descEl = await this.querySelector(html, 'div.description');
    const desc = (await descEl.text).trim();

    const rows = await this.querySelectorAll(html, 'table#chapters tbody tr');
    const chapters = [];
    for (const row of rows) {
      const content = await row.content;
      const href = await this.getAttributeText(content, 'a', 'href');
      const linkEl = await this.querySelector(content, 'a');
      const name = (await linkEl.text).trim();
      if (href && name) chapters.push({ name, url: href });
    }

    return {
      title,
      cover: cover || '',
      desc,
      episodes: [{ title: 'Chapters', urls: chapters }],
    };
  }

  async watch(url) {
    const html = await this.request(url);
    const paras = await this.querySelectorAll(html, 'div.chapter-content p');
    let content = [];
    for (const p of paras) {
      const t = (await p.text).trim();
      if (t) content.push(t);
    }
    if (!content.length) {
      // Some chapters use divs or raw text inside the container.
      const container = await this.querySelector(html, 'div.chapter-content');
      content = (await container.text)
        .split('\n')
        .map((s) => s.trim())
        .filter((s) => s.length > 0);
    }
    const titleEl = await this.querySelector(html, 'h1');
    return { content, subtitle: (await titleEl.text).trim() };
  }
}
