// ==MiruExtension==
// @name         MangaDex
// @version      v1.1.0
// @author       FusionReader
// @lang         all
// @license      MIT
// @package      mangadex
// @type         manga
// @icon         https://mangadex.org/favicon.ico
// @webSite      https://api.mangadex.org
// @nsfw         false
// ==/MiruExtension==

export default class extends Extension {
  covers(manga) {
    const rel = (manga.relationships || []).find((r) => r.type === 'cover_art');
    if (!rel || !rel.attributes) return '';
    return `https://uploads.mangadex.org/covers/${manga.id}/${rel.attributes.fileName}.256.jpg`;
  }

  titleOf(manga) {
    const t = manga.attributes.title || {};
    return (
      t.en ||
      t['ja-ro'] ||
      t.ja ||
      t['zh-hk'] ||
      t.zh ||
      Object.values(t)[0] ||
      'Untitled'
    );
  }

  mapList(res) {
    return (res.data || []).map((manga) => ({
      title: this.titleOf(manga),
      url: manga.id,
      cover: this.covers(manga),
    }));
  }

  async latest(page) {
    const offset = (page - 1) * 20;
    const res = await this.request(
      `/manga?limit=20&offset=${offset}&order[latestUploadedChapter]=desc&includes[]=cover_art&hasAvailableChapters=true&contentRating[]=safe&contentRating[]=suggestive`
    );
    return this.mapList(res);
  }

  async search(kw, page) {
    const offset = (page - 1) * 20;
    const res = await this.request(
      `/manga?limit=20&offset=${offset}&title=${encodeURIComponent(kw)}&includes[]=cover_art&order[relevance]=desc&contentRating[]=safe&contentRating[]=suggestive`
    );
    return this.mapList(res);
  }

  async searchAuthor(author, page) {
    if (!author.id) return this.search(author.name, page);
    const offset = (page - 1) * 20;
    const res = await this.request(
      `/manga?limit=20&offset=${offset}&authors[]=${encodeURIComponent(author.id)}` +
      '&includes[]=cover_art&order[latestUploadedChapter]=desc&contentRating[]=safe&contentRating[]=suggestive'
    );
    return this.mapList(res);
  }

  async detail(url) {
    const res = await this.request(`/manga/${url}?includes[]=cover_art&includes[]=author`);
    const manga = res.data;
    const descMap = manga.attributes.description || {};
    const desc = descMap.en || descMap.zh || Object.values(descMap)[0] || '';

    // Ask for the preferred languages up front. Sweeping every language and
    // truncating at a page cap silently drops chapters on long series, which
    // is what made lists look incomplete.
    const fetchFeed = async (langQuery) => {
      const byLang = {};
      let offset = 0;
      let total = Infinity;
      while (offset < total && offset < 10000) {
        const feed = await this.request(
          `/manga/${url}/feed?limit=500&offset=${offset}${langQuery}` +
            `&order[chapter]=asc&contentRating[]=safe&contentRating[]=suggestive&contentRating[]=erotica`
        );
        total = feed.total ?? 0;
        const list = feed.data || [];
        if (!list.length) break;
        for (const ch of list) {
          // Skip chapters hosted externally (e.g. MangaPlus) — no pages on MD.
          if (ch.attributes.externalUrl) continue;
          if ((ch.attributes.pages || 0) === 0) continue;
          const lang = ch.attributes.translatedLanguage || '?';
          const num = ch.attributes.chapter || '?';
          const title = ch.attributes.title ? ` - ${ch.attributes.title}` : '';
          (byLang[lang] = byLang[lang] || []).push({
            name: `Ch.${num}${title}`,
            url: ch.id,
            num: parseFloat(num) || 0,
          });
        }
        offset += 500;
      }
      return byLang;
    };

    let byLang = await fetchFeed(
      '&translatedLanguage[]=zh&translatedLanguage[]=zh-hk&translatedLanguage[]=en'
    );
    // Titles with no zh/en release fall back to whatever languages exist.
    if (!Object.keys(byLang).length) byLang = await fetchFeed('');

    const langNames = { zh: '中文', 'zh-hk': '中文(繁)', en: 'English' };
    const priority = ['zh', 'zh-hk', 'en'];
    const langs = Object.keys(byLang).sort((a, b) => {
      const pa = priority.indexOf(a), pb = priority.indexOf(b);
      if (pa !== -1 || pb !== -1) return (pa === -1 ? 99 : pa) - (pb === -1 ? 99 : pb);
      return byLang[b].length - byLang[a].length;
    }).slice(0, 8);

    const episodes = [];
    for (const lang of langs) {
      // Deduplicate by chapter number, keep the first upload.
      const seen = new Set();
      const unique = [];
      for (const ch of byLang[lang]) {
        if (seen.has(ch.num)) continue;
        seen.add(ch.num);
        unique.push({ name: ch.name, url: ch.url });
      }
      if (unique.length) episodes.push({ title: langNames[lang] || lang, urls: unique });
    }

    return {
      title: this.titleOf(manga),
      cover: this.covers(manga),
      desc,
      authors: (manga.relationships || [])
        .filter((r) => r.type === 'author' && r.attributes && r.attributes.name)
        .map((r) => ({ name: r.attributes.name, id: r.id })),
      episodes,
    };
  }

  async watch(url) {
    const res = await this.request(`/at-home/server/${url}`);
    const base = res.baseUrl;
    const hash = res.chapter.hash;
    return {
      urls: (res.chapter.data || []).map((f) => `${base}/data/${hash}/${f}`),
    };
  }
}
