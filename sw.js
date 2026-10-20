/* PostAngola: service worker
   - Páginas: tenta a rede primeiro (conteúdo sempre atual) e, sem internet, usa a última cópia guardada.
   - Ficheiros do site, tipos de letra, biblioteca e imagens: servem a cópia guardada e atualizam em segundo plano.
   - Dados das notícias (Supabase): guardados pela própria aplicação (localStorage). */
const VERSION = 'v1';
const SHELL = 'pa-shell-' + VERSION;
const RUNTIME = 'pa-runtime-' + VERSION;
const IMG = 'pa-img-' + VERSION;

const SHELL_URLS = [
  './', 'index.html', 'sobre.html', 'politica-de-privacidade.html', 'termos.html',
  'config.js', 'manifest.webmanifest',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/apple-touch-icon.png',
  'logo/postangola-logo.svg', 'logo/favicon.svg'
];
const CDN_URLS = [
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js'
];
const CORS_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com', 'cdn.jsdelivr.net'];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const shell = await caches.open(SHELL);
    // allSettled: se um ficheiro falhar, a instalação não falha
    await Promise.allSettled(SHELL_URLS.map((u) => shell.add(new Request(u, { cache: 'reload' }))));
    const rt = await caches.open(RUNTIME);
    await Promise.allSettled(CDN_URLS.map(async (u) => {
      const r = await fetch(u, { mode: 'cors', credentials: 'omit' });
      if (r.ok) await rt.put(u, r);
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keep = [SHELL, RUNTIME, IMG];
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('pa-') && !keep.includes(k)).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

async function trim(name, max) {
  const cache = await caches.open(name);
  const keys = await cache.keys();
  for (let i = 0; i < keys.length - max; i++) await cache.delete(keys[i]);
}

async function networkFirst(request) {
  const cache = await caches.open(SHELL);
  try {
    const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 4500));
    const res = await Promise.race([fetch(request), timeout]);
    if (res && res.ok) cache.put(request, res.clone());
    return res;
  } catch (err) {
    const hit = await caches.match(request, { ignoreSearch: true });
    return hit || (await caches.match('index.html')) || Response.error();
  }
}

function staleWhileRevalidate(event, cacheName, forceCors) {
  const request = event.request;
  const update = (async () => {
    try {
      const cross = new URL(request.url).origin !== self.location.origin;
      const res = (forceCors && cross)
        ? await fetch(new Request(request.url, { mode: 'cors', credentials: 'omit' }))
        : await fetch(request);
      if (res && res.ok && res.type !== 'opaque') {
        const cache = await caches.open(cacheName);
        await cache.put(request, res.clone());
        if (cacheName === IMG) trim(IMG, 90);
      }
      return res;
    } catch (e) { return null; }
  })();
  event.waitUntil(update);
  return caches.match(request).then((hit) => hit || update.then((r) => r || Response.error()));
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (req.mode === 'navigate') { event.respondWith(networkFirst(req)); return; }

  if (url.hostname.endsWith('.supabase.co')) {
    // dados (REST/auth): deixar passar; imagens públicas: guardar
    if (url.pathname.startsWith('/storage/v1/object/public/')) {
      event.respondWith(staleWhileRevalidate(event, IMG, true));
    }
    return;
  }
  if (CORS_HOSTS.includes(url.hostname)) { event.respondWith(staleWhileRevalidate(event, RUNTIME, true)); return; }
  if (url.origin === self.location.origin) { event.respondWith(staleWhileRevalidate(event, SHELL, false)); }
});
