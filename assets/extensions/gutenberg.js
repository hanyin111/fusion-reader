// ==MiruExtension==
// @name         Project Gutenberg
// @version      v1.0.0
// @author       FusionReader
// @lang         all
// @license      MIT
// @package      gutenberg
// @type         fikushon
// @icon         https://www.gutenberg.org/gutenberg/favicon.ico
// @webSite      https://gutendex.com
// @nsfw         false
// ==/MiruExtension==

export default class extends Extension {
  mapBooks(res) {
    return (res.results || []).map((book) => ({
      title: book.title,
      url: String(book.id),
      cover: (book.formats || {})['image/jpeg'] || '',
      update: (book.authors || []).map((a) => a.name).join(', '),
    }));
  }

  async latest(page) {
    const res = await this.request(`/books/?page=${page}`); // sorted by popularity
    return this.mapBooks(res);
  }

  async search(kw, page) {
    const res = await this.request(`/books/?search=${encodeURIComponent(kw)}&page=${page}`);
    return this.mapBooks(res);
  }

  textUrlOf(book) {
    const formats = book.formats || {};
    for (const key of Object.keys(formats)) {
      if (key.startsWith('text/plain') && !formats[key].endsWith('.zip')) {
        return formats[key];
      }
    }
    return '';
  }

  async detail(url) {
    const book = await this.request(`/books/${url}`);
    const authors = (book.authors || []).map((a) => a.name).join(', ');
    const summary = (book.summaries || [])[0] || '';
    const textUrl = this.textUrlOf(book);
    const episodes = [];
    if (textUrl) {
      episodes.push({ title: '正文', urls: [{ name: '全文阅读', url: textUrl }] });
    }
    return {
      title: book.title,
      cover: (book.formats || {})['image/jpeg'] || '',
      desc: `${authors ? '作者: ' + authors + '\n\n' : ''}${summary}`,
      episodes,
    };
  }

  async watch(url) {
    const text = await this.request(url);
    const raw = typeof text === 'string' ? text : String(text);
    // Strip the Gutenberg license header/footer when the markers are present.
    let body = raw;
    const start = raw.indexOf('*** START OF');
    if (start >= 0) {
      const afterStart = raw.indexOf('\n', start);
      const end = raw.indexOf('*** END OF');
      body = raw.slice(afterStart + 1, end > 0 ? end : raw.length);
    }
    const paragraphs = body
      .split(/\r?\n\r?\n+/)
      .map((p) => p.replace(/\r?\n/g, ' ').trim())
      .filter((p) => p.length > 0);
    return { content: paragraphs };
  }
}
