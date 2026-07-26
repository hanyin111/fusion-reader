// ==MiruExtension==
// @name         哔哩轻小说
// @version      v1.0.0
// @author       FusionReader
// @lang         zh-cn
// @license      MIT
// @package      linovelib
// @type         fikushon
// @icon         https://www.linovelib.com/images/favicon.ico
// @webSite      https://www.linovelib.com
// @nsfw         false
// @network      auto
// ==/MiruExtension==
//
// The site rejects requests that arrive without a plausible referer chain, so
// every call states where it "came from". Chapter bodies are also split across
// numbered sub-pages which are stitched back together in watch().

const MOBILE_UA =
  'Mozilla/5.0 (Linux; Android 12; Pixel 5) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

export default class extends Extension {
  async get(path, referer) {
    return this.request(path, {
      headers: {
        'User-Agent': MOBILE_UA,
        Referer: referer || `${this.webSite}/`,
        'Accept-Language': 'zh-CN,zh;q=0.9',
      },
    });
  }

  async parseNovelLinks(html) {
    const links = await this.querySelectorAll(html, 'a[href*="/novel/"]');
    const out = [];
    const seen = new Set();
    for (const link of links) {
      const href = await link.getAttributeText('href');
      const m = href && href.match(/\/novel\/(\d+)\.html$/);
      if (!m || seen.has(m[1])) continue;
      const content = await link.content;
      let title = await this.getAttributeText(content, 'img', 'alt');
      if (!title) title = (await link.text).trim();
      if (!title) continue;
      let cover = await this.getAttributeText(content, 'img', 'data-src');
      if (!cover) cover = await this.getAttributeText(content, 'img', 'src');
      seen.add(m[1]);
      out.push({
        title,
        url: `/novel/${m[1]}.html`,
        cover: cover && cover.startsWith('http') ? cover : '',
      });
    }
    return out;
  }

  async latest(page) {
    const html = await this.get(`/top/lastupdate/${page}.html`);
    const items = await this.parseNovelLinks(html);
    if (items.length) return items;
    // Fall back to the home page when the ranking path moves.
    return this.parseNovelLinks(await this.get('/'));
  }

  // The site's own search endpoint is behind a script-computed guard cookie:
  // requests without it are 301'd to https://127.0.0.1/ or answered with 403.
  // Try it anyway in case the guard is satisfied, then fall back to matching
  // titles across the ranking pages. The fallback only sees ranked titles, so
  // it finds popular works rather than the whole catalogue.
  async search(kw, page) {
    try {
      const html = await this.request('/S6/', {
        method: 'post',
        headers: {
          'User-Agent': MOBILE_UA,
          Referer: `${this.webSite}/`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        data: `searchkey=${encodeURIComponent(kw)}&page=${page}`,
        allowErrorStatus: true,
      });
      const direct = await this.parseNovelLinks(html);
      if (direct.length) return direct;
    } catch (e) {
      // Guard rejected us; fall through to the local scan.
    }

    if (page > 1) return [];
    const pool = [];
    const seen = new Set();
    const sources = ['/', '/top/lastupdate/1.html', '/top/monthvisit/1.html', '/top/weekvisit/1.html'];
    for (const path of sources) {
      let items = [];
      try {
        items = await this.parseNovelLinks(await this.get(path));
      } catch (e) {
        continue;
      }
      for (const item of items) {
        if (seen.has(item.url)) continue;
        seen.add(item.url);
        pool.push(item);
      }
    }
    const needle = kw.trim().toLowerCase();
    return pool.filter((item) => item.title.toLowerCase().includes(needle));
  }

  novelId(url) {
    const m = url.match(/\/novel\/(\d+)/);
    return m ? m[1] : '';
  }

  async detail(url) {
    const id = this.novelId(url);
    const html = await this.get(`/novel/${id}.html`);

    const title =
      (await this.getAttributeText(html, 'meta[property="og:title"]', 'content')) || '';
    const cover =
      (await this.getAttributeText(html, 'meta[property="og:image"]', 'content')) || '';
    const desc =
      (await this.getAttributeText(html, 'meta[property="og:description"]', 'content')) || '';
    const author =
      (await this.getAttributeText(html, 'meta[property="og:novel:author"]', 'content')) || '';

    const catalog = await this.get(`/novel/${id}/catalog`, `${this.webSite}/novel/${id}.html`);
    const links = await this.querySelectorAll(catalog, 'li.chapter-li a.chapter-li-a');
    const chapters = [];
    const seen = new Set();
    for (const link of links) {
      const href = await link.getAttributeText('href');
      // vol_*.html entries are volume anchors, not readable chapters.
      if (!href || /vol_\d+\.html/.test(href) || seen.has(href)) continue;
      const name = (await link.text).trim();
      if (!name) continue;
      seen.add(href);
      chapters.push({ name, url: href });
    }

    return {
      title,
      cover,
      desc: author ? `作者: ${author}\n\n${desc}` : desc,
      episodes: [{ title: '章節', urls: chapters }],
    };
  }

  // Pull text and illustrations out of the chapter body in document order.
  // The container id has changed across site revisions, so try the known ones
  // and prefer whichever yields the most content.
  async extractBlocks(html, into) {
    const selectors = ['#acontent', '#TextContent', '.read-content', '#content', '.acontent'];
    let best = [];
    for (const selector of selectors) {
      const container = await this.querySelector(html, selector);
      if (!container) continue;
      const blocks = this.htmlToBlocks(await container.content, `${this.webSite}/`);
      if (blocks.length > best.length) best = blocks;
    }
    if (best.length) {
      into.push(...best);
      return;
    }
    // Nothing matched: fall back to bare paragraphs so text at least renders.
    const paras = await this.querySelectorAll(html, 'p');
    for (const p of paras) {
      const text = (await p.text).trim();
      if (text) into.push(text);
    }
  }

  async watch(url) {
    const id = this.novelId(url);
    const catalogUrl = `${this.webSite}/novel/${id}/catalog`;
    const content = [];

    let current = url;
    let referer = catalogUrl;
    let subtitle = '';
    // Chapters continue onto "<chapter>_<n>.html" pages; follow them until the
    // next link leaves this chapter.
    for (let i = 0; i < 30; i++) {
      // The site rate-limits bursts (HTTP 429), and one chapter can span many
      // sub-pages, so pace the walk instead of firing them back to back.
      if (i > 0) await this.sleep(700);

      const html = await this.get(current, referer);
      if (!subtitle) {
        const titleEl = await this.querySelector(html, '#atitle');
        if (titleEl) subtitle = (await titleEl.text).trim();
      }
      await this.extractBlocks(html, content);

      const match = html.match(/url_next:'([^']+)'/);
      if (!match) break;
      const next = match[1];
      const chapterOf = (u) => {
        const m = u.match(/\/novel\/\d+\/(\d+)(?:_\d+)?\.html/);
        return m ? m[1] : '';
      };
      if (!next || chapterOf(next) !== chapterOf(current)) break;
      referer = this.absoluteUrl(this.webSite + '/', current);
      current = next;
    }

    // The site serves a cut-down page to clients it does not trust: the text
    // stops mid-sentence with its own marker and every illustration is
    // withheld (the only <img> left is an ad banner). Say so rather than
    // presenting half a chapter as if it were whole.
    const truncated = content.some(
      (block) =>
        typeof block === 'string' &&
        /內容加載失敗|内容加载失败|更換瀏覽器|更换浏览器/.test(block)
    );
    if (truncated) {
      content.push(
        '⚠ 本章内容被站点截断：哔哩轻小说对非浏览器客户端只返回部分正文，' +
          '并且不下发插图。这不是本地解析失败，重试也不会有更多内容。'
      );
    }

    return {
      content,
      subtitle,
      // Illustrations, when a chapter does carry them, are hotlink-protected.
      headers: { Referer: `${this.webSite}/`, 'User-Agent': MOBILE_UA },
    };
  }
}
