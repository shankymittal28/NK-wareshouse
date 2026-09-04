/*
 * NK Warehouse — Orders (Trello-style department board, Work Board v2)
 * browser verification.
 *
 * Drives the REAL index.html in headless Chromium at a phone viewport
 * (390×844) with Project Zero and Supabase replaced by in-test fakes
 * (page.route), entering exactly as a human does, and proves:
 *   three real list containers stand side by side, Pending first, with a
 *   meaningful part of the next list visible; cards carry the bill
 *   photograph (lazy), with a clean placeholder when it cannot load; the
 *   editable name sits below the photo and persists; the board scrolls
 *   sideways and long lists scroll down to the last card; a long-press
 *   drag moves exactly one card and writes one status act, an ordinary
 *   swipe moves nothing; the ⋯ menu moves and renames; Door and Glass
 *   cards of one bill move independently; search keeps cards in their
 *   lists; staff permissions, owner and runtime boards work; opening a
 *   card never moves it; returning lands on the same list; browser back
 *   works; receiving is unchanged; screenshots are captured.
 *
 * Usage: NODE_PATH=$(npm root -g) node test_nk_orders.js
 *   SHOT_DIR=/some/dir saves phone screenshots for a visual check.
 */
const fs = require('fs'), http = require('http'), path = require('path');
const { chromium } = require('playwright');

const PORT = 8794, DIR = __dirname;
const PZ = 'https://project-zero-xafh.onrender.com', SB = 'https://enjlgflisuywkaorxetv.supabase.co';
const PASS = [], FAIL = [];
function check(name, cond, detail) { (cond ? PASS : FAIL).push(name); console.log((cond ? 'PASS ' : 'FAIL ') + name + (cond ? '' : '  -- ' + String(detail === undefined ? '' : (typeof detail === 'string' ? detail : JSON.stringify(detail))).slice(0, 1800))); }

// ---- the fakes ------------------------------------------------------------
const KINDS = [{ id: 1, name: 'Order' }, { id: 2, name: 'Door' }, { id: 3, name: 'Glass' }, { id: 4, name: 'Aluminium' }, { id: 5, name: 'Mesh' }];
const PAGES = [
  { book: '490', page: 83, cats: ['Door', 'Glass'], cust: 'Amar Traders', date: '2026-08-20', photo: 'book1/p83.jpg', lines: [{ design_no: 'D-101', size: '7x3' }] },
  { book: '490', page: 84, cats: ['Glass'], cust: 'Bhola Glass', date: null, photo: 'broken/p84.jpg', lines: [] },
  { book: '491', page: 5, cats: ['Door'], cust: null, date: null, photo: 'book2/p5.jpg', lines: [{ design_no: 'Teak-9', size: '6.5x2.5' }] },
  { book: '491', page: 7, cats: ['Mesh'], cust: 'Chandan', date: '2026-09-01', photo: null, lines: [] },
  { book: '492', page: 1, cats: [], cust: 'Dinesh', date: '2026-09-02', photo: 'book3/p1.jpg', lines: [] },
  { book: '492', page: 2, cats: ['Aluminium'], cust: 'Eknath Windows', date: '2026-09-02', photo: 'book3/p2.jpg', lines: [] },
];
['Ganesh Ply', 'Harish Verma', 'Iqbal', 'Jai Ambe Traders', 'Kiran Interiors', 'Lalit'].forEach((c, i) =>
  PAGES.push({ book: '493', page: i + 1, cats: ['Door'], cust: c, date: '2026-09-0' + (i + 1), photo: 'book4/p' + (i + 1) + '.jpg', lines: [] }));
const COMMITMENTS = [
  { id: 11, book_number: '490', page_number: 83, design_no: 'D-101', size: '7x3', qty: 4, received: 1, receipts: [], tally_name: 'Amar Traders', agreed_on: '2026-08-20', tags: ['Door', 'Glass', 'Order'] },
  { id: 12, book_number: '491', page_number: 5, design_no: 'Teak-9', size: '6.5x2.5', qty: 2, received: 0, receipts: [], tally_name: null, agreed_on: null, tags: [] },
];
const STAFF = [
  { id: 's1', name: 'Raju', active: true, order_tags: ['Door'] },
  { id: 's2', name: 'Gopal', active: true, order_tags: ['Glass'] },
  { id: 's3', name: 'Meena', active: true, order_tags: [] },
];
const events = [], titles = [], receipts = [], pzLog = [], imgLog = [];
const lastTitle = (book, page) => { const t = titles.slice().reverse().find(e => e.book === book && e.page === page); return t ? t.title : null; };
function feed() {
  const out = [];
  PAGES.forEach(p => (p.cats.length ? p.cats : [null]).forEach(cat => {
    const ev = events.slice().reverse().find(e => e.book === p.book && e.page === p.page && e.cat === cat);
    out.push({ book_number: p.book, page_number: p.page, category: cat,
      status: ev ? ev.status : (cat ? 'pending' : null), status_by: ev ? ev.by : null, status_at: ev ? 'now' : null,
      tally_name: p.cust, agreed_on: p.date, title: lastTitle(p.book, p.page), photo: p.photo, lines: p.lines });
  }));
  return out;
}
function latest(book, page, cat) { const ev = events.slice().reverse().find(e => e.book === book && e.page === page && e.cat === cat); return ev ? ev.status : 'pending'; }
const json = (route, obj, status) => route.fulfill({ status: status || 200, contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify(obj) });
// a stand-in for the archive photograph: a portrait "handwritten bill" drawn as SVG
const billSvg = p => '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="800" viewBox="0 0 600 800"><rect width="600" height="800" fill="#f3ecd8"/>' +
  [90, 150, 210, 270, 330, 390, 450, 510, 570, 630, 690].map(y => '<line x1="40" y1="' + y + '" x2="560" y2="' + y + '" stroke="#b9ad8e" stroke-width="2"/>').join('') +
  '<text x="50" y="70" font-family="serif" font-size="34" fill="#1c2a5a" font-style="italic">Mittal Hardware · ' + p + '</text>' +
  '<path d="M60 130 q40 -30 80 0 t80 0 t80 0 t80 0" stroke="#233" stroke-width="3" fill="none"/><path d="M60 190 q30 -25 60 0 t60 0 t60 0" stroke="#233" stroke-width="3" fill="none"/>' +
  '<path d="M60 250 q50 -30 100 0 t100 0 t100 0" stroke="#233" stroke-width="3" fill="none"/><path d="M60 310 q30 -25 60 0 t60 0 t60 0 t60 0 t60 0" stroke="#233" stroke-width="3" fill="none"/></svg>';

async function routes(page) {
  await page.route(PZ + '/**', async route => {
    const req = route.request(), u = new URL(req.url()), m = req.method();
    pzLog.push(m + ' ' + u.pathname);
    if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' } });
    if (u.pathname === '/api/bbk/img') { const p = u.searchParams.get('p'); imgLog.push(p); if (/^broken/.test(p)) return route.fulfill({ status: 404, body: 'no' }); return route.fulfill({ status: 200, contentType: 'image/svg+xml', body: billSvg(p) }); }
    if (u.pathname === '/api/cl/work') return json(route, feed());
    if (u.pathname === '/api/cl/orders') return json(route, COMMITMENTS);
    if (u.pathname === '/api/cl/tags') return json(route, KINDS);
    if (u.pathname === '/api/cl/tagged') return json(route, []);
    if (u.pathname === '/api/version') return json(route, { commit: 'test' });
    if (u.pathname === '/billview') return route.fulfill({ status: 200, contentType: 'text/html', body: '<html><body style="background:#333;color:#eee;font:16px sans-serif;padding:20px">BILL PHOTO ' + u.search + '</body></html>' });
    if (u.pathname === '/api/cl/status' && m === 'POST') {
      const b = req.postDataJSON();
      const pg = PAGES.find(p => p.book === String(b.book_number) && p.page === Number(b.page_number));
      if (!pg || pg.cats.indexOf(b.category) < 0) return json(route, { ok: false, error: 'This bill has no ' + b.category + ' work' });
      if (['pending', 'received', 'delivered'].indexOf(b.status) < 0 || !b.changed_by) return json(route, { ok: false, error: 'bad' });
      events.push({ book: pg.book, page: pg.page, cat: b.category, status: b.status, by: b.changed_by });
      return json(route, { ok: true, book_number: pg.book, page_number: pg.page, category: b.category, status: b.status });
    }
    if (u.pathname === '/api/cl/title' && m === 'POST') {
      const b = req.postDataJSON(), t = String(b.title || '').replace(/\s+/g, ' ').trim();
      const pg = PAGES.find(p => p.book === String(b.book_number) && p.page === Number(b.page_number));
      if (!pg || !b.changed_by || t.length > 60) return json(route, { ok: false, error: 'bad' });
      titles.push({ book: pg.book, page: pg.page, title: t || null, by: b.changed_by });
      return json(route, { ok: true, book_number: pg.book, page_number: pg.page, title: t || null });
    }
    if (u.pathname === '/api/cl/receipt' && m === 'POST') { receipts.push(req.postDataJSON()); return json(route, { ok: true, id: receipts.length }); }
    return json(route, { error: 'not found' }, 404);
  });
  await page.route(SB + '/**', async route => {
    const req = route.request(), u = new URL(req.url()), m = req.method();
    if (u.pathname.startsWith('/auth/v1/token')) return json(route, { access_token: 'owner-token', refresh_token: 'r' });
    if (u.pathname === '/rest/v1/nkg_staff' && m === 'GET') return json(route, STAFF);
    return json(route, []);
  });
}

function serve() {
  return new Promise(res => {
    const srv = http.createServer((req, r) => {
      const f = path.join(DIR, req.url.split('?')[0] === '/' ? 'index.html' : req.url.split('?')[0]);
      if (!fs.existsSync(f)) { r.writeHead(404); return r.end(); }
      r.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html; charset=utf-8' : f.endsWith('.js') ? 'application/javascript' : 'application/octet-stream' });
      fs.createReadStream(f).pipe(r);
    }).listen(PORT, '127.0.0.1', () => res(srv));
  });
}

// ---- helpers ----------------------------------------------------------------
async function list(page, s) {
  return page.$$eval('#wbBoard .wblist[data-s="' + s + '"] .wbk', els => els.map(e => ({
    ref: e.querySelector('.wbref').textContent, name: e.querySelector('.wbcust').textContent,
    date: e.querySelector('.wbdate') ? e.querySelector('.wbdate').textContent.replace(/^\s*·\s*/, '') : null,
    img: e.querySelector('img.wbk-img') ? e.querySelector('img.wbk-img').getAttribute('src') : null,
    lazy: e.querySelector('img.wbk-img') ? e.querySelector('img.wbk-img').getAttribute('loading') : null,
    noimg: !!e.querySelector('.wbk-noimg'), coverFirst: e.firstElementChild.classList.contains('wbk-cover'),
    text: e.textContent, menu: e.querySelectorAll('.wbk-menu').length, stButtons: e.querySelectorAll('.wbst,.wbk-mv').length })));
}
const refs = async (page, s) => (await list(page, s)).map(x => x.ref).join('|');
const counts = page => page.$$eval('#wbBoard .wblist', els => els.map(e => e.dataset.s + ':' + e.querySelector('.wblist-n').textContent).join(','));
const rects = page => page.$$eval('#wbBoard .wblist', els => els.map(e => { const r = e.getBoundingClientRect(); return { s: e.dataset.s, l: Math.round(r.left), r: Math.round(r.right), w: Math.round(r.width) }; }));
const scrollX = page => page.$eval('#wbBoard', e => e.scrollLeft);
const step = page => page.$eval('#wbBoard .wblist', e => e.offsetWidth + 12);
const tabs = page => page.$$eval('#wbTabs .wbtab', els => els.map(e => e.dataset.t));
const tabOn = page => page.$eval('#wbTabs .wbtab.on', e => e.dataset.t).catch(() => null);
const tabsHidden = page => page.$eval('#wbTabs', e => e.classList.contains('hide'));
const title = page => page.$eval('#wbTitle', e => e.textContent);
const hash = page => page.evaluate(() => location.hash);
async function settled(page) { await page.waitForFunction(() => { const b = document.getElementById('wbBoard'), y = document.getElementById('wbBody'); return b && y && !/लोड हो रहा/.test(b.textContent + y.textContent); }); await page.waitForTimeout(150); }
async function pickStaff(page, name) {
  await page.waitForSelector('#staffBtns .namebtn');
  await page.locator('#staffBtns .namebtn', { hasText: name }).first().click();
  await page.waitForSelector('#add:not(.hide), #dorders:not(.hide)');
}
async function openOrders(page) { await page.click('#doBtn'); await page.waitForSelector('#dorders:not(.hide)'); await settled(page); }
async function leaveOrders(page) { await page.click('#dorders .iconlink'); await page.waitForSelector('#add:not(.hide)'); }
async function switchTo(page, name) { await leaveOrders(page); await page.click('#addBack'); await pickStaff(page, name); await openOrders(page); }
async function menu(page, book, pg) { await page.click('#wbBoard .wbk[data-book="' + book + '"][data-page="' + pg + '"] .wbk-menu'); await page.waitForSelector('#wbMenuOpts .chip'); }
async function moveVia(page, book, pg, to) { await menu(page, book, pg); await page.click('#wbMoveOpts .chip[data-s="' + to + '"]'); await page.waitForTimeout(450); await settled(page); }
async function rename(page, book, pg, value) {
  await menu(page, book, pg); await page.click('#wbMenuOpts .chip[data-a="rename"]'); await page.waitForSelector('#wbTitleIn');
  const before = await page.$eval('#wbTitleIn', e => e.value);
  await page.fill('#wbTitleIn', value); await page.click('#sheetInner .pri'); await page.waitForTimeout(450); await settled(page); return before;
}
async function tab(page, cat) { await page.click('#wbTabs .wbtab[data-t="' + cat + '"]'); await page.waitForTimeout(200); }
async function search(page, q) { if (await page.$eval('#wbSearch', e => e.classList.contains('hide'))) await page.click('#wbSearchBtn'); await page.fill('#wbSearch', q); await page.waitForTimeout(450); }
async function shot(page, nm) { if (process.env.SHOT_DIR) await page.screenshot({ path: path.join(process.env.SHOT_DIR, nm + '.png') }); }
const center = async (page, sel) => page.$eval(sel, e => { const r = e.getBoundingClientRect(); return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + Math.min(r.height / 2, 120)) }; });
async function stable(page) { let a = -1; for (let i = 0; i < 30; i++) { const b = await page.$eval('#wbBoard', e => e.scrollLeft); if (b === a) return; a = b; await page.waitForTimeout(120); } }
async function touch(cdp, type, x, y) { await cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y }] }); }

async function run(page, cdp) {
  await page.goto('http://127.0.0.1:' + PORT + '/index.html');

  // ---- Raju (Door only): the Door board, Pending list first --------------
  await pickStaff(page, 'Raju');
  await openOrders(page);
  let R = await rects(page);
  check('T1 Orders opens the board at #o with three list containers side by side: Pending, Received, Delivered', (await hash(page)) === '#o' && R.map(x => x.s).join() === 'pending,received,delivered' && R[0].l < R[1].l && R[1].l < R[2].l, R);
  check('T2 Pending is in view first (board at the start), a real part of Received visible beside it', (await scrollX(page)) === 0 && R[0].l >= 0 && R[1].l < 390 && (390 - R[1].l) >= 30, R);
  check('T3 each list is 82–88% of the viewport width with a clear gap', R[0].w >= 0.82 * 362 && R[0].w <= 0.88 * 362 && (R[1].l - R[0].r) >= 8, R);
  check('T4 single-department staff: board titled Door, no switcher, no सभी, no status strip or dropdown', (await tabsHidden(page)) && /Door/.test(await title(page)) && (await page.$$('#wbCols, #wbStSel, .wbcol')).length === 0 && !/सभी/.test(await page.$eval('#dorders', e => e.textContent)));
  check('T5 list headers carry the title and card count', (await counts(page)) === 'pending:8,received:0,delivered:0' && /बाकी.*Pending/.test(await page.$eval('.wblist[data-s="pending"] .wblist-h', e => e.textContent)));
  let L = await list(page, 'pending');
  check('T6 cards are photo-first: a real lazy <img> of the archive photograph is the cover, name below it', L[0].coverFirst && L[0].lazy === 'lazy' && /\/api\/bbk\/img\?p=book1%2Fp83\.jpg$/.test(L[0].img) && L[0].name === 'Amar Traders', L[0]);
  check('T7 one card = one job: no status button, no department name, one ⋯ menu', L.every(x => x.stButtons === 0 && x.menu === 1 && !/Door|Glass|Aluminium|Mesh/.test(x.text)), L);
  check('T8 name precedence: Tally customer, else "नाम जोड़ें" — never "? — नाम बिल पर है"', L[1].name === 'नाम जोड़ें' && !/नाम बिल पर है/.test(await page.$eval('#wbBoard', e => e.textContent)));
  check('T9 reference on every card; date only when known', L[0].ref === 'बही 490 · पन्ना 83' && L[0].date === '20-08-2026' && L[1].date === null, L);
  check('T10 no "+ Add card" anywhere', !/Add card|कार्ड जोड़ें/.test(await page.$eval('#dorders', e => e.textContent)));
  await page.waitForFunction(() => Array.from(document.querySelectorAll('.wblist[data-s="pending"] img.wbk-img')).slice(0, 2).every(i => i.complete && i.naturalWidth > 0));
  check('T11 the first photographs are loaded and rendered', (await page.$eval('.wblist[data-s="pending"] img.wbk-img', e => e.naturalWidth)) > 0 && imgLog.length >= 2);
  await shot(page, '1-door-board-pending-with-received-peeking');

  // vertical: a long list reaches its last card by ordinary page scroll
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); await page.waitForTimeout(200);
  const last = await page.$eval('.wblist[data-s="pending"] .wbk:last-child', e => { const r = e.getBoundingClientRect(); return { top: r.top, bottom: r.bottom }; });
  check('T12 vertical scrolling reaches the last card of a long list (no nested-scroll trap)', last.bottom <= 845 && last.top >= 0, last);
  await shot(page, '2-pending-stack-scrolled');
  await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(150);

  // horizontal: the board itself scrolls sideways
  const st = await step(page);
  await page.$eval('#wbBoard', (e, x) => e.scrollTo({ left: x }), st); await page.waitForTimeout(400);
  R = await rects(page);
  check('T13 the board scrolls sideways: Received now in view, Delivered peeking', (await scrollX(page)) >= st - 2 && R[1].l < 30 && R[2].l < 390, R);
  await shot(page, '3-board-moved-to-received');
  await page.$eval('#wbBoard', e => e.scrollTo({ left: 0 })); await page.waitForTimeout(300);

  // an ordinary swipe never lifts a card
  let c = await center(page, '.wblist[data-s="pending"] .wbk[data-book="490"]');
  const n0 = events.length;
  await touch(cdp, 'touchStart', c.x, c.y);
  for (let i = 1; i <= 4; i++) { await touch(cdp, 'touchMove', c.x - 30 * i, c.y); await page.waitForTimeout(25); }
  await touch(cdp, 'touchEnd'); await page.waitForTimeout(400);
  check('T14 an ordinary quick swipe lifts nothing, writes nothing and opens nothing', events.length === n0 && (await page.$$('.wbghost')).length === 0 && (await hash(page)) === '#o' && !(await page.$eval('#wbBoard', e => e.classList.contains('hide'))) && (await refs(page, 'pending')).startsWith('बही 490 · पन्ना 83'), await hash(page));
  await stable(page); await page.$eval('#wbBoard', e => e.scrollTo({ left: 0 })); await stable(page);

  // long-press drag: lift, carry to the peeking Received list, drop
  c = await center(page, '.wblist[data-s="pending"] .wbk[data-book="490"]');
  await touch(cdp, 'touchStart', c.x, c.y); await page.waitForTimeout(550);
  check('T15 a long press lifts the card (ghost follows the finger, source dimmed)', (await page.$$('.wbghost')).length === 1 && await page.$eval('.wblist[data-s="pending"] .wbk[data-book="490"]', e => e.classList.contains('wblift')));
  await touch(cdp, 'touchMove', c.x + 30, c.y); await page.waitForTimeout(60);
  await touch(cdp, 'touchMove', c.x + 120, c.y - 40); await page.waitForTimeout(60);
  await touch(cdp, 'touchMove', 372, 200); await page.waitForTimeout(700);   // the edge slides the board one list; Received now under the finger
  await touch(cdp, 'touchMove', 200, 200); await page.waitForTimeout(150);
  check('T16 the destination list is highlighted while hovering', await page.$eval('.wblist[data-s="received"]', e => e.classList.contains('wbdrop')));
  await shot(page, '5-drag-in-progress');
  await touch(cdp, 'touchEnd'); await page.waitForTimeout(500); await settled(page);
  check('T17 the drop writes exactly ONE status act (Door 490/83 → received by Raju) and nothing else', events.length === n0 + 1 && JSON.stringify(events[n0]) === JSON.stringify({ book: '490', page: 83, cat: 'Door', status: 'received', by: 'Raju' }), events);
  check('T18 the card now sits in Received; the bill did not open; no ghost left behind', (await hash(page)) === '#o' && await refs(page, 'received') === 'बही 490 · पन्ना 83' && (await counts(page)) === 'pending:7,received:1,delivered:0' && (await page.$$('.wbghost')).length === 0);
  await stable(page); await page.$eval('#wbBoard', e => e.scrollTo({ left: 0 })); await stable(page); await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(200);

  // menu movement (the reliable fallback) and rename
  await moveVia(page, '491', 5, 'received');
  check('T19 the ⋯ menu "Move to" moves a card with one act too', events.length === n0 + 2 && events[n0 + 1].cat === 'Door' && events[n0 + 1].book === '491' && (await counts(page)) === 'pending:6,received:2,delivered:0');
  await menu(page, '493', 1);
  check('T20 the menu offers Rename, Open bill and Move to (current list marked)', (await page.$$('#wbMenuOpts .chip[data-a="rename"], #wbMenuOpts .chip[data-a="open"]')).length === 2 && await page.$eval('#wbMoveOpts .chip[data-s="pending"]', e => e.disabled));
  await page.click('#sheet', { position: { x: 10, y: 10 } }); await page.waitForTimeout(250);
  let before = await rename(page, '491', 5, 'Sharma ji bedroom');
  check('T21 rename: empty for an unnamed bill; one row on /api/cl/title; the name shows below the photo at once', before === '' && titles.length === 1 && titles[0].title === 'Sharma ji bedroom' && (await list(page, 'received')).find(x => x.ref === 'बही 491 · पन्ना 5').name === 'Sharma ji bedroom');
  await menu(page, '490', 83); await page.click('#wbMenuOpts .chip[data-a="rename"]'); await page.waitForSelector('#wbTitleIn');
  check('T22 a bill with a Tally name opens the rename sheet prefilled with it', (await page.$eval('#wbTitleIn', e => e.value)) === 'Amar Traders');
  await shot(page, '4-rename');
  await page.fill('#wbTitleIn', 'Amar – first floor'); await page.click('#sheetInner .pri'); await page.waitForTimeout(450); await settled(page);
  await menu(page, '490', 83); await page.click('#wbMenuOpts .chip[data-a="rename"]'); await page.waitForSelector('#wbTitleIn');
  await page.locator('#sheetInner .chip', { hasText: 'Tally का नाम वापस' }).click(); await page.waitForTimeout(450); await settled(page);
  check('T23 clearing records an explicit clearing row and the Tally name returns', titles.length === 3 && titles[2].title === null && (await list(page, 'received')).find(x => x.ref === 'बही 490 · पन्ना 83').name === 'Amar Traders');
  await rename(page, '490', 83, 'Amar – first floor');

  // reload: persisted, Pending first again
  await page.reload(); await pickStaff(page, 'Raju'); await page.waitForSelector('#dorders:not(.hide)'); await settled(page);
  check('T24 after reload: Door board, Pending first, moves and names persisted', (await scrollX(page)) === 0 && (await counts(page)) === 'pending:6,received:2,delivered:0' && (await list(page, 'received')).map(x => x.name).join('|') === 'Amar – first floor|Sharma ji bedroom');

  // search keeps cards inside their lists
  await search(page, 'Sharma'); check('T25 search by card name keeps the card in its own list', (await counts(page)) === 'pending:0,received:1,delivered:0' && await refs(page, 'received') === 'बही 491 · पन्ना 5' && /कुछ नहीं मिला/.test(await page.$eval('.wblist[data-s="pending"]', e => e.textContent)));
  await search(page, 'Amar'); check('T26 search by Tally customer', (await counts(page)) === 'pending:0,received:1,delivered:0');
  await search(page, 'Teak'); check('T27 search by design', await refs(page, 'received') === 'बही 491 · पन्ना 5');
  await search(page, '3x7'); check('T28 search by size, either orientation', await refs(page, 'received') === 'बही 490 · पन्ना 83');
  await search(page, '493'); check('T29 search by book', (await counts(page)) === 'pending:6,received:0,delivered:0');
  await search(page, '83'); check('T30 search by page', (await counts(page)) === 'pending:0,received:1,delivered:0');
  await search(page, 'Bhola'); check('T31 a Glass bill is never found from the Door board', (await counts(page)) === 'pending:0,received:0,delivered:0');
  await page.click('#wbSearchBtn'); await page.waitForTimeout(300);
  check('T32 closing search restores the board', (await counts(page)) === 'pending:6,received:2,delivered:0' && await page.$eval('#wbSearch', e => e.classList.contains('hide')));

  // ---- Gopal (Glass only): its own board, same photo and name, independent ----
  await switchTo(page, 'Gopal');
  L = await list(page, 'pending');
  check('T33 Gopal lands on the Glass board, Pending first, no switcher', (await tabsHidden(page)) && /Glass/.test(await title(page)) && (await scrollX(page)) === 0);
  check('T34 the Door+Glass bill is a separate Glass card here, still Pending, same photo and same name', await refs(page, 'pending') === 'बही 490 · पन्ना 83|बही 490 · पन्ना 84' && L[0].name === 'Amar – first floor' && /book1%2Fp83/.test(L[0].img), L);
  await page.waitForSelector('.wbk[data-book="490"][data-page="84"] .wbk-noimg');
  check('T35 a photograph that cannot load shows a clean placeholder', (await list(page, 'pending'))[1].noimg && !(await list(page, 'pending'))[0].noimg);
  await moveVia(page, '490', 83, 'delivered');
  check('T36 Gopal\'s move names Glass; the Door card of the same bill stays received', events[events.length - 1].cat === 'Glass' && events[events.length - 1].by === 'Gopal' && latest('490', 83, 'Door') === 'received' && latest('490', 83, 'Glass') === 'delivered');

  // ---- Meena (unassigned): switcher, one board at a time, runtime board ------
  await switchTo(page, 'Meena');
  check('T37 multi-department person: switcher Door|Glass|Aluminium|Mesh, no सभी, Door first', JSON.stringify(await tabs(page)) === '["Door","Glass","Aluminium","Mesh"]' && !(await tabsHidden(page)) && (await tabOn(page)) === 'Door' && (await counts(page)) === 'pending:6,received:2,delivered:0');
  await page.$eval('#wbBoard', (e, x) => e.scrollTo({ left: x }), st); await page.waitForTimeout(300);
  await tab(page, 'Glass');
  check('T38 switching department resets the board to its Pending list; Glass shows Glass only (490/83 in Delivered)', (await scrollX(page)) === 0 && (await counts(page)) === 'pending:1,received:0,delivered:1' && await refs(page, 'delivered') === 'बही 490 · पन्ना 83');
  check('T39 the uncategorised Order (492/1) is on no board', !/492 · पन्ना 1/.test(await page.$eval('#wbBoard', e => e.textContent)));
  await tab(page, 'Aluminium'); check('T40 Aluminium board is its own', await refs(page, 'pending') === 'बही 492 · पन्ना 2');
  await tab(page, 'Mesh'); check('T41 runtime category Mesh has its own board; a bill with no photograph shows the placeholder', await refs(page, 'pending') === 'बही 491 · पन्ना 7' && (await list(page, 'pending'))[0].noimg);

  // ---- Owner: every department, one at a time ------------------------------
  await leaveOrders(page); await page.click('#addBack'); await page.waitForSelector('#gate:not(.hide)');
  await page.click('#gate .linkbtn'); await page.waitForSelector('#pwIn'); await page.fill('#pwIn', 'secret'); await page.click('#pwBtn');
  await page.waitForSelector('#owner:not(.hide)');
  await page.locator('#owner button', { hasText: 'Add stock' }).first().click(); await page.waitForSelector('#add:not(.hide)');
  await openOrders(page);
  check('T42 owner: every department in the switcher, Door board, Pending first', JSON.stringify(await tabs(page)) === '["Door","Glass","Aluminium","Mesh"]' && (await tabOn(page)) === 'Door' && (await scrollX(page)) === 0);
  await shot(page, '6-owner-department-switcher');
  await tab(page, 'Glass');
  check('T43 owner switches to the Glass board and sees Glass cards only', (await counts(page)) === 'pending:1,received:0,delivered:1');
  await tab(page, 'Door');

  // ---- One bill: opening never moves; position kept; back works; receiving ----
  const n1 = events.length;
  await page.$eval('#wbBoard', (e, x) => e.scrollTo({ left: x }), st); await page.waitForTimeout(400);
  await page.click('.wblist[data-s="received"] .wbk[data-book="491"][data-page="5"] .wbk-cover'); await page.waitForSelector('.wbif'); await settled(page);
  check('T44 tapping the photograph opens the bill workspace with the full viewer; the board is hidden', (await hash(page)) === '#o/491/5' && /billview\?book=491&page=5/.test(await page.$eval('.wbif', e => e.getAttribute('src'))) && await page.$eval('#wbBoard', e => e.classList.contains('hide')));
  check('T45 opening changed nothing; it shows the name, the reference and this department\'s list', events.length === n1 && /Sharma ji bedroom/.test(await page.$eval('#wbBody .wbcust', e => e.textContent)) && /बही 491 · पन्ना 5/.test(await page.$eval('#wbBody', e => e.textContent)) && /आ गया/.test(await page.$eval('#wbBody .wbk-st', e => e.textContent)));
  await page.click('#wbBody .wbrow'); await page.waitForSelector('#don');
  check('T46 the Door line opens the existing receive sheet prefilled with the remaining count', (await page.$eval('#don', e => e.value)) === '2');
  await page.fill('#don', '1'); await page.click('#sheetInner .pri'); await page.waitForTimeout(450); await settled(page);
  check('T47 receiving posts the same line-level receipt as before and never moves the card', receipts.length === 1 && receipts[0].mark_id === 12 && receipts[0].qty === 1 && receipts[0].noted_by === 'Owner' && latest('491', 5, 'Door') === 'received' && events.length === n1, receipts);
  await page.goBack(); await page.waitForSelector('#wbBoard:not(.hide)'); await settled(page); await page.waitForTimeout(300);
  check('T48 browser back returns to the same board on the same list (Received still in view)', (await hash(page)) === '#o' && (await tabOn(page)) === 'Door' && Math.abs((await scrollX(page)) - st) < 30 && await refs(page, 'received') === 'बही 490 · पन्ना 83|बही 491 · पन्ना 5', await scrollX(page));
}

(async () => {
  const srv = await serve();
  const browser = await chromium.launch({ executablePath: process.env.CHROME || fs.readdirSync('/opt/pw-browsers').filter(d => /^chromium-\d+$/.test(d)).map(d => '/opt/pw-browsers/' + d + '/chrome-linux/chrome').find(fs.existsSync) });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, serviceWorkers: 'block', isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  const cdp = await ctx.newCDPSession(page);
  page.on('dialog', d => d.accept());
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  await routes(page);
  try { await run(page, cdp); } catch (e) { check('run completed without throwing', false, e && e.stack || e); }
  check('T0 no uncaught page errors', errors.length === 0, errors);
  await browser.close(); srv.close();
  console.log('\n' + PASS.length + ' passed, ' + FAIL.length + ' failed — NK Orders (Trello-style board) verified.');
  process.exit(FAIL.length ? 1 : 0);
})();
