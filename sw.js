// CRM Grupo BVEK — service worker (v34)
// Deixa o CRM instalável como app no Android e no iPhone e mostra os avisos do sistema.
// Nunca guarda dados do banco: só a casca do site (para abrir rápido) e as imagens.
const VERSAO = 'bvek-v36';
const ESTATICOS = ['/', '/index.html', '/manifest.json', '/vendor/supabase-js-2.117.3.js',
  '/img/icone-192.png', '/img/icone-512.png', '/img/apple-touch-icon.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSAO).then((c) => c.addAll(ESTATICOS)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== VERSAO).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== location.origin) return;           // Supabase, CDNs: direto na rede
  if (req.mode === 'navigate') {                                                   // páginas: sempre a versão mais nova
    e.respondWith(fetch(req).then((r) => { const c = r.clone(); caches.open(VERSAO).then((k) => k.put('/index.html', c)); return r; })
      .catch(() => caches.match('/index.html')));
    return;
  }
  if (/^\/(img|vendor)\//.test(url.pathname)) {                                    // imagens e biblioteca fixa: cache
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((r) => {
      if (r.ok) { const c = r.clone(); caches.open(VERSAO).then((k) => k.put(req, c)); } return r; })));
  }
});
// clique no aviso: abre (ou traz para frente) o CRM
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const alvo = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((ws) => {
    for (const w of ws) { if ('focus' in w) { w.navigate && w.navigate(alvo); return w.focus(); } }
    return self.clients.openWindow(alvo);
  }));
});
// pronto para avisos "push" do servidor (fase 2: Web Push)
self.addEventListener('push', (e) => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (_) { d = { corpo: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.titulo || 'CRM Grupo BVEK', {
    body: d.corpo || '', icon: '/img/icone-192.png', badge: '/img/icone-192.png', data: { url: d.url || '/' }, tag: d.tag || 'bvek' }));
});
