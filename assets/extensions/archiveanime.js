// ==MiruExtension==
// @name         Internet Archive 动画
// @version      v1.0.0
// @author       FusionReader
// @lang         all
// @license      MIT
// @package      archiveanime
// @type         bangumi
// @icon         https://archive.org/favicon.ico
// @webSite      https://archive.org
// @nsfw         false
// ==/MiruExtension==

export default class extends Extension {
  mapDocs(res) {
    const docs = ((res.response || {}).docs) || [];
    return docs.map((doc) => ({
      title: doc.title || doc.identifier,
      url: doc.identifier,
      cover: `https://archive.org/services/img/${doc.identifier}`,
    }));
  }

  async latest(page) {
    const q = encodeURIComponent('collection:(animationandcartoons) AND mediatype:(movies)');
    const res = await this.request(
      `/advancedsearch.php?q=${q}&fl[]=identifier&fl[]=title&sort[]=downloads+desc&rows=24&page=${page}&output=json`
    );
    return this.mapDocs(typeof res === 'string' ? JSON.parse(res) : res);
  }

  async search(kw, page) {
    const q = encodeURIComponent(
      `collection:(animationandcartoons) AND mediatype:(movies) AND title:(${kw})`
    );
    const res = await this.request(
      `/advancedsearch.php?q=${q}&fl[]=identifier&fl[]=title&sort[]=downloads+desc&rows=24&page=${page}&output=json`
    );
    return this.mapDocs(typeof res === 'string' ? JSON.parse(res) : res);
  }

  async detail(url) {
    const res = await this.request(`/metadata/${url}`);
    const data = typeof res === 'string' ? JSON.parse(res) : res;
    const meta = data.metadata || {};
    let desc = meta.description || '';
    if (Array.isArray(desc)) desc = desc.join('\n');
    desc = String(desc).replace(/<[^>]+>/g, '');

    const files = (data.files || []).filter(
      (f) => f.name && (f.name.endsWith('.mp4') || f.name.endsWith('.ogv'))
    );
    // Prefer mp4 over ogv when both exist for the same basename.
    const mp4Names = new Set(files.filter((f) => f.name.endsWith('.mp4')).map((f) => f.name.replace(/\.mp4$/, '')));
    const chosen = files.filter(
      (f) => f.name.endsWith('.mp4') || !mp4Names.has(f.name.replace(/\.ogv$/, ''))
    );

    // mp4 entries first — better codec support across platforms.
    chosen.sort((a, b) => (a.name.endsWith('.mp4') ? 0 : 1) - (b.name.endsWith('.mp4') ? 0 : 1));
    const urls = chosen.map((f) => ({
      name: f.name.replace(/\.(mp4|ogv)$/, ''),
      url: `https://archive.org/download/${url}/${encodeURIComponent(f.name)}`,
    }));

    return {
      title: Array.isArray(meta.title) ? meta.title[0] : (meta.title || url),
      cover: `https://archive.org/services/img/${url}`,
      desc,
      episodes: [{ title: '视频', urls }],
    };
  }

  async watch(url) {
    return { type: 'mp4', url };
  }
}
