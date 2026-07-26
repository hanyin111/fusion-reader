// ==MiruExtension==
// @name         樱花动漫
// @version      v1.0.0
// @author       FusionReader
// @lang         zh-cn
// @license      MIT
// @package      yhdm
// @type         bangumi
// @icon         https://www.yhdm.one/static/favicon.ico
// @webSite      https://www.yhdm.one
// @nsfw         false
// @network      proxy
// ==/MiruExtension==
//
// Routing note: the site's own HTML is only reachable through a proxy from
// many networks, while its video CDNs reject proxy exits outright. So pages
// go through the source route and streams are pinned to a direct connection.

export default class extends Extension {
  abs(url) {
    if (!url) return '';
    if (url.startsWith('http')) return url;
    return this.webSite + url;
  }

  async parseVodList(html) {
    // Each entry appears as two anchors (thumbnail and title), and only the
    // first few thumbnails carry a real `src` — the rest are lazy-loaded via
    // `data-original`. So merge the anchors per url and treat the cover as
    // optional, otherwise most of the page is thrown away.
    const links = await this.querySelectorAll(html, 'a[href^="/vod/"]');
    const order = [];
    const byUrl = {};
    for (const el of links) {
      const href = await el.getAttributeText('href');
      if (!href) continue;
      const content = await el.content;
      const cover =
        (await this.getAttributeText(content, 'img', 'src')) ||
        (await this.getAttributeText(content, 'img', 'data-original')) ||
        '';
      const title =
        (await this.getAttributeText(content, 'img', 'alt')) ||
        (await el.text).trim();

      if (!byUrl[href]) {
        byUrl[href] = { title: '', url: href, cover: '' };
        order.push(href);
      }
      const entry = byUrl[href];
      if (!entry.title && title) entry.title = title;
      if (!entry.cover && cover) entry.cover = this.abs(cover);
    }
    return order.map((u) => byUrl[u]).filter((e) => e.title);
  }

  async channels() {
    return [
      { title: '全部', key: '' },
      { title: '日本', key: 'country=jp' },
      { title: '国产', key: 'country=cn' },
      { title: '欧美', key: 'country=us' },
      { title: 'TV', key: 'type=TV' },
      { title: '剧场版', key: 'type=' + encodeURIComponent('剧场版') },
      { title: 'OVA', key: 'type=OVA' },
      { title: '热血', key: 'genre=re-xue' },
      { title: '恋爱', key: 'genre=ai-qing' },
      { title: '科幻', key: 'genre=ke-huan' },
      { title: '奇幻', key: 'genre=qi-huan' },
      { title: '悬疑', key: 'genre=xuan-yi' },
      { title: '搞笑', key: 'genre=gao-xiao' },
    ];
  }

  async latest(page, channel) {
    const extra = channel ? `&${channel}` : '';
    const html = await this.request(`/list/?page=${page}${extra}`);
    return this.parseVodList(html);
  }

  async search(kw, page) {
    const html = await this.request(`/search?q=${encodeURIComponent(kw)}&page=${page}`);
    return this.parseVodList(html);
  }

  async detail(url) {
    const html = await this.request(url);
    const titleEl = await this.querySelector(html, 'h1.names');
    const title = (await titleEl.text).trim();
    const cover = await this.getAttributeText(html, 'div.detail-poster img', 'src');

    let desc = '';
    const descEl = await this.querySelector(html, 'div.detail-desc');
    if (descEl) desc = (await descEl.text).trim();
    if (!desc) {
      // Fall back to the introduction paragraph on the page.
      const pEl = await this.querySelector(html, 'p.short-text');
      if (pEl) desc = (await pEl.text).trim();
    }

    const epLinks = await this.querySelectorAll(html, 'div.ep-panel a[href*="/vod-play/"]');
    const episodes = [];
    const seen = new Set();
    for (const el of epLinks) {
      const href = await el.getAttributeText('href');
      const name = (await el.text).trim();
      if (!href || seen.has(href)) continue;
      seen.add(href);
      episodes.push({ name: name || href, url: href });
    }
    episodes.reverse(); // page lists newest episode first

    return {
      title,
      cover: this.abs(cover),
      desc,
      episodes: [{ title: '剧集', urls: episodes }],
    };
  }

  async watch(url) {
    // /vod-play/{id}/{ep}.html  ->  /_get_plays/{id}/{ep}
    const m = url.match(/\/vod-play\/([^/]+)\/([^/.]+)/);
    if (!m) throw new Error('无法解析播放地址: ' + url);
    const res = await this.request(`/_get_plays/${m[1]}/${m[2]}`, {
      headers: { Referer: this.webSite + url },
    });
    const data = typeof res === 'string' ? JSON.parse(res) : res;
    const plays = data.video_plays || [];
    if (!plays.length) throw new Error('没有可用线路');

    const errors = [];
    for (const play of plays) {
      const streamUrl = play.play_data;
      if (!streamUrl || !streamUrl.startsWith('http')) continue;
      try {
        // Probe over the same direct route the player will use, so a line that
        // passes here is genuinely playable rather than merely resolvable.
        const probe = await this.request(streamUrl, { netMode: 'direct' });
        const text = typeof probe === 'string' ? probe : JSON.stringify(probe);
        if (text.includes('#EXTM3U') || streamUrl.includes('.mp4')) {
          // Hand back the media playlist, not the master one.
          const resolved = this.resolveHlsVariant(streamUrl, text);
          return {
            type: resolved.includes('.m3u8') ? 'hls' : 'mp4',
            url: resolved,
            netMode: 'direct',
          };
        }
        errors.push(`${play.src_site}: 非 m3u8 响应`);
      } catch (e) {
        errors.push(`${play.src_site}: ${e.message}`);
      }
    }
    throw new Error('所有线路均无法直连播放\n' + errors.join('\n'));
  }
}
