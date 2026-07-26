// FusionReader extension runtime prelude.
// Provides a Miru-compatible `Extension` base class plus the async bridge
// between QuickJS and Dart. Loaded before every extension script.

globalThis.__pendingCalls = {};
globalThis.__callSeq = 0;

function __bridgeCall(channel, payload) {
  return new Promise((resolve, reject) => {
    const id = ++globalThis.__callSeq;
    globalThis.__pendingCalls[id] = { resolve, reject };
    sendMessage(channel, JSON.stringify({ id, payload }));
  });
}

// Called from Dart when an async bridge call settles.
globalThis.__resolveBridge = function (id, ok, dataJson) {
  const p = globalThis.__pendingCalls[id];
  if (!p) return;
  delete globalThis.__pendingCalls[id];
  let data;
  try {
    data = dataJson === undefined || dataJson === null ? null : JSON.parse(dataJson);
  } catch (e) {
    data = dataJson;
  }
  if (ok) p.resolve(data);
  else p.reject(new Error(typeof data === 'string' ? data : JSON.stringify(data)));
};

globalThis.console = {
  log: (...args) => sendMessage('console', JSON.stringify({ level: 'log', args: args.map(String) })),
  warn: (...args) => sendMessage('console', JSON.stringify({ level: 'warn', args: args.map(String) })),
  error: (...args) => sendMessage('console', JSON.stringify({ level: 'error', args: args.map(String) })),
};

// DOM-less element wrapper matching Miru's async accessor style:
//   const el = await this.querySelector(html, 'div.title');
//   const text = await el.text;         // innerText
//   const html2 = await el.content;     // outerHTML
//   const href = await el.getAttributeText('href');
class Element {
  constructor(data) {
    this.__data = data || {};
  }
  get text() {
    return Promise.resolve(this.__data.text ?? '');
  }
  get content() {
    return Promise.resolve(this.__data.content ?? '');
  }
  getAttributeText(name) {
    const attrs = this.__data.attributes || {};
    return Promise.resolve(attrs[name] ?? null);
  }
}

class XPathResultWrapper {
  constructor(data) {
    this.__data = data || {};
  }
  get asText() {
    return Promise.resolve(this.__data.text ?? '');
  }
  get asHtml() {
    return Promise.resolve(this.__data.html ?? '');
  }
  get allText() {
    return Promise.resolve(this.__data.allText ?? []);
  }
  get allHtml() {
    return Promise.resolve(this.__data.allHtml ?? []);
  }
}

class Extension {
  // These fields are injected by the Dart side after instantiation.
  package = '';
  name = '';
  webSite = '';

  async request(url, options) {
    options = options || {};
    options.headers = options.headers || {};
    const miruUrl = options.headers['Miru-Url'];
    if (miruUrl) {
      delete options.headers['Miru-Url'];
      url = miruUrl + url;
    } else if (!/^https?:\/\//.test(url)) {
      url = this.webSite + url;
    }
    // options.netMode ('direct' | 'proxy') overrides this source's routing for
    // a single request — some sites serve HTML and media over different paths.
    return __bridgeCall('request', { url, options, package: this.package });
  }

  async querySelector(content, selector) {
    const data = await __bridgeCall('querySelector', { content, selector });
    return new Element(data);
  }

  async querySelectorAll(content, selector) {
    const list = await __bridgeCall('querySelectorAll', { content, selector });
    return (list || []).map((d) => new Element(d));
  }

  async getAttributeText(content, selector, attr) {
    return __bridgeCall('getAttributeText', { content, selector, attr });
  }

  async queryXPath(content, expression) {
    const data = await __bridgeCall('queryXPath', { content, expression });
    return new XPathResultWrapper(data);
  }

  decodeEntities(text) {
    return String(text)
      .replace(/&nbsp;/g, ' ')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#0?39;|&apos;/g, "'")
      .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(parseInt(d, 10)))
      .replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCharCode(parseInt(h, 16)))
      .replace(/&amp;/g, '&');
  }

  // Turn a chapter container's HTML into ordered text/image blocks.
  //
  // Walking the string rather than querying the DOM keeps illustrations in
  // their original position regardless of how the site nests them, and catches
  // the various lazy-loading attributes sites use instead of a plain `src`.
  htmlToBlocks(html, baseUrl) {
    if (typeof html !== 'string') return [];
    const blocks = [];

    const pushText = (chunk) => {
      const parts = chunk
        .replace(/<\s*br\s*\/?\s*>/gi, '\n')
        .replace(/<\/\s*(p|div|h[1-6]|li|tr)\s*>/gi, '\n')
        .replace(/<[^>]*>/g, '')
        .split('\n');
      for (const part of parts) {
        const text = this.decodeEntities(part).replace(/\s+/g, ' ').trim();
        if (text) blocks.push(text);
      }
    };

    const srcOf = (tag) => {
      // Prefer lazy-loading attributes; a plain `src` is often a placeholder.
      // The leading separator stops the bare `src` pattern matching data-src.
      const patterns = [
        /\bdata-src\s*=\s*["']([^"']+)["']/i,
        /\bdata-original\s*=\s*["']([^"']+)["']/i,
        /\bdata-echo\s*=\s*["']([^"']+)["']/i,
        /\bdata-lazy-src\s*=\s*["']([^"']+)["']/i,
        /[\s"']src\s*=\s*["']([^"']+)["']/i,
      ];
      for (const pattern of patterns) {
        const m = tag.match(pattern);
        if (m && m[1] && !/^data:/.test(m[1])) return m[1];
      }
      return null;
    };

    const imgTag = /<img\b[^>]*>/gi;
    let last = 0;
    let match;
    while ((match = imgTag.exec(html)) !== null) {
      pushText(html.slice(last, match.index));
      const src = srcOf(match[0]);
      if (src) blocks.push({ type: 'image', url: this.absoluteUrl(baseUrl, src) });
      last = match.index + match[0].length;
    }
    pushText(html.slice(last));
    return blocks;
  }

  // Resolve `ref` against `base` the way a browser would.
  absoluteUrl(base, ref) {
    if (/^https?:\/\//.test(ref)) return ref;
    // Protocol-relative urls are common on image CDNs.
    if (/^\/\//.test(ref)) return 'https:' + ref;
    const m = base.match(/^(https?:\/\/[^/]+)(\/[^?#]*)?/);
    if (!m) return ref;
    const origin = m[1];
    if (ref.startsWith('/')) return origin + ref;
    const dir = (m[2] || '/').replace(/[^/]*$/, '');
    return origin + dir + ref;
  }

  // Turn an HLS master playlist into the absolute URL of its best variant.
  //
  // Players tend to mis-resolve root-relative variant entries (mpv treats
  // "/a/b.m3u8" as a local file path), so sources hand back a media playlist
  // rather than a master one.
  resolveHlsVariant(url, body) {
    if (typeof body !== 'string' || !body.includes('#EXT-X-STREAM-INF')) return url;
    const lines = body.split(/\r?\n/);
    let best = null;
    let bestBandwidth = -1;
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      const bwMatch = lines[i].match(/BANDWIDTH=(\d+)/);
      const bandwidth = bwMatch ? parseInt(bwMatch[1], 10) : 0;
      for (let j = i + 1; j < lines.length; j++) {
        const candidate = lines[j].trim();
        if (!candidate || candidate.startsWith('#')) continue;
        if (bandwidth > bestBandwidth) {
          bestBandwidth = bandwidth;
          best = candidate;
        }
        break;
      }
    }
    return best ? this.absoluteUrl(url, best) : url;
  }

  // Pace requests against sources that rate-limit bursts.
  async sleep(ms) {
    return __bridgeCall('sleep', { ms });
  }

  // Hashing helpers — QuickJS has no crypto, so these cross to Dart.
  async md5(text) {
    return __bridgeCall('md5', { text });
  }

  async hmacSha256(key, data) {
    return __bridgeCall('hmacSha256', { key, data });
  }

  async base64Encode(text) {
    return __bridgeCall('base64Encode', { text });
  }

  async registerSetting(setting) {
    return __bridgeCall('registerSetting', { package: this.package, setting });
  }

  async getSetting(key) {
    return __bridgeCall('getSetting', { package: this.package, key });
  }

  async setSetting(key, value) {
    return __bridgeCall('setSetting', { package: this.package, key, value });
  }

  // Lifecycle + API surface; extensions override what they support.
  async load() {}
  async unload() {}

  // Optional browse channels (categories, rankings, sort orders).
  // Return [{ title, key }]; the key is handed back to latest() as its second
  // argument. An empty list means the source only offers a plain latest feed.
  async channels() {
    return [];
  }

  async latest(page, channel) {
    throw new Error('latest() not implemented');
  }
  async search(kw, page, filter) {
    throw new Error('search() not implemented');
  }
  async detail(url) {
    throw new Error('detail() not implemented');
  }
  async watch(url) {
    throw new Error('watch() not implemented');
  }
  async checkUpdate(url) {
    return '';
  }
}

globalThis.Element = Element;
globalThis.Extension = Extension;

// Invoked by Dart: runs an extension method, resolves with JSON string.
globalThis.__invoke = function (method, argsJson) {
  const args = JSON.parse(argsJson);
  return Promise.resolve()
    .then(() => globalThis.__ext[method](...args))
    .then((r) => JSON.stringify({ ok: true, data: r === undefined ? null : r }))
    .catch((e) =>
      JSON.stringify({
        ok: false,
        error: String(e && e.message ? e.message : e) + (e && e.stack ? '\n' + e.stack : ''),
      })
    );
};
