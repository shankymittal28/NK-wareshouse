/*
 * NK Warehouse — Orders (Trello-style department board with runtime lists,
 * Board Lists v1) browser verification.
 *
 * Drives the REAL index.html in headless Chromium at a phone viewport
 * (390×844) with Project Zero and Supabase replaced by in-test fakes
 * (page.route), entering exactly as a human does, and proves:
 *   every department board is built from ITS OWN runtime lists (stable ids,
 *   any number, in position order); existing Pending/Received/Delivered
 *   history lands on the matching starter lists; new work enters the first
 *   list; the owner renames lists (header changes at once, cards stay,
 *   persists) and adds lists at the end (empty, persists, usable at once);
 *   duplicates are refused only within one board; staff see no list
 *   controls; cards move onto runtime lists by drag and by menu with one
 *   placement act each; Door and Glass stay independent; search keeps the
 *   layout across any number of lists; a board of eight lists scrolls
 *   fluently; photo cards, names, workspace, receiving and permissions are
 *   as before; returning restores department and list position; six
 *   screenshots are captured.
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
// what migration board_lists_v1 seeded: three starter lists per department, each an identity of its own
const LISTS = [];
KINDS.filter(k => k.name !== 'Order').forEach(k => [['Pending', 'pending'], ['Received', 'received'], ['Delivered', 'delivered']].forEach(([n, st], i) =>
  LISTS.push({ id: k.id * 10 + i + 1, kind_id: k.id, category: k.name, position: i + 1, legacy_status: st, name: n })));
const listsOf = cat => LISTS.filter(l => l.category === cat).sort((a, b) => a.position - b.position);
const legacy = [{ book: '490', page: 83, cat: 'Door', status: 'received' }];   // production history that predates boards
const placements = [], titles = [], receipts = [], listLog = [], pzLog = [], imgLog = [];
const lastTitle = (book, page) => { const t = titles.slice().reverse().find(e => e.book === book && e.page === page); return t ? t.title : null; };
function listOfCard(book, page, cat) {
  const pl = placements.slice().reverse().find(e => e.book === book && e.page === page && e.cat === cat);
  if (pl) return LISTS.find(l => l.id === pl.list_id);
  const lg = legacy.slice().reverse().find(e => e.book === book && e.page === page && e.cat === cat);
  if (lg) return listsOf(cat).find(l => l.legacy_status === lg.status);
  return listsOf(cat)[0];
}
function feed() {
  const out = [];
  PAGES.forEach(p => (p.cats.length ? p.cats : [null]).forEach(cat => {
    const l = cat ? listOfCard(p.book, p.page, cat) : null;
    out.push({ book_number: p.book, page_number: p.page, category: cat, list_id: l ? l.id : null, list: l ? l.name : null,
      status: l ? l.legacy_status : null, status_by: null, status_at: null,
      tally_name: p.cust, agreed_on: p.date, title: lastTitle(p.book, p.page), photo: p.photo, lines: p.lines });
  }));
  return out;
}
const json = (route, obj, status) => route.fulfill({ status: status || 200, contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify(obj) });
const billSvg = p => '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="800" viewBox="0 0 600 800"><rect width="600" height="800" fill="#f3ecd8"/>' +
  [90, 150, 210, 270, 330, 390, 450, 510, 570, 630, 690].map(y => '<line x1="40" y1="' + y + '" x2="560" y2="' + y + '" stroke="#b9ad8e" stroke-width="2"/>').join('') +
  '<text x="50" y="70" font-family="serif" font-size="34" fill="#1c2a5a" font-style="italic">Mittal Hardware · ' + p + '</text>' +
  '<path d="M60 130 q40 -30 80 0 t80 0 t80 0 t80 0" stroke="#233" stroke-width="3" fill="none"/><path d="M60 190 q30 -25 60 0 t60 0 t60 0" stroke="#233" stroke-width="3" fill="none"/>' +
  '<path d="M60 250 q50 -30 100 0 t100 0 t100 0" stroke="#233" stroke-width="3" fill="none"/><path d="M60 310 q30 -25 60 0 t60 0 t60 0 t60 0 t60 0" stroke="#233" stroke-width="3" fill="none"/></svg>';
const tidy = s => String(s || '').replace(/\s+/g, ' ').trim();

async function routes(page) {
  await page.route(PZ + '/**', async route => {
    const req = route.request(), u = new URL(req.url()), m = req.method();
    pzLog.push(m + ' ' + u.pathname);
    if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' } });
    if (u.pathname === '/api/bbk/img') { const p = u.searchParams.get('p'); imgLog.push(p); if (/^broken/.test(p)) return route.fulfill({ status: 404, body: 'no' }); return route.fulfill({ status: 200, contentType: 'image/svg+xml', body: billSvg(p) }); }
    if (u.pathname === '/api/cl/work') return json(route, feed());
    if (u.pathname === '/api/cl/lists') return json(route, LISTS.slice().sort((a, b) => a.kind_id - b.kind_id || a.position - b.position));
    if (u.pathname === '/api/cl/orders') return json(route, COMMITMENTS);
    if (u.pathname === '/api/cl/tags') return json(route, KINDS);
    if (u.pathname === '/api/cl/tagged') return json(route, []);
    if (u.pathname === '/api/version') return json(route, { commit: 'test' });
    if (u.pathname === '/billview') return route.fulfill({ status: 200, contentType: 'text/html', body: '<html><body style="background:#333;color:#eee;font:16px sans-serif;padding:20px">BILL PHOTO ' + u.search + '</body></html>' });
    if (u.pathname === '/api/cl/list' && m === 'POST') {
      const b = req.postDataJSON(), name = tidy(b.name); listLog.push(b);
      if (!b.changed_by || !name || name.length > 30) return json(route, { ok: false, error: 'List name is required' });
      if (b.action === 'rename') {
        const l = LISTS.find(x => x.id === Number(b.list_id)); if (!l) return json(route, { ok: false, error: 'That list does not exist' });
        if (LISTS.some(x => x.category === l.category && x.id !== l.id && x.name.toLowerCase() === name.toLowerCase())) return json(route, { ok: false, error: 'The ' + l.category + ' board already has a list called ' + name });
        l.name = name; return json(route, { ok: true, id: l.id, category: l.category, name });
      }
      const mine = listsOf(b.category); if (!mine.length) return json(route, { ok: false, error: 'Unknown category' });
      if (mine.some(x => x.name.toLowerCase() === name.toLowerCase())) return json(route, { ok: false, error: 'The ' + b.category + ' board already has a list called ' + name });
      const l = { id: 100 + LISTS.length, kind_id: mine[0].kind_id, category: b.category, position: mine[mine.length - 1].position + 1, legacy_status: null, name };
      LISTS.push(l); return json(route, { ok: true, id: l.id, category: l.category, position: l.position, name });
    }
    if (u.pathname === '/api/cl/move' && m === 'POST') {
      const b = req.postDataJSON();
      const pg = PAGES.find(p => p.book === String(b.book_number) && p.page === Number(b.page_number));
      if (!pg || pg.cats.indexOf(b.category) < 0) return json(route, { ok: false, error: 'This bill has no ' + b.category + ' work' });
      const l = LISTS.find(x => x.id === Number(b.list_id));
      if (!l || l.category !== b.category) return json(route, { ok: false, error: 'That list is not on the ' + b.category + ' board' });
      if (!b.changed_by) return json(route, { ok: false, error: 'bad' });
      placements.push({ book: pg.book, page: pg.page, cat: b.category, list_id: l.id, by: b.changed_by });
      return json(route, { ok: true, book_number: pg.book, page_number: pg.page, category: b.category, list_id: l.id, list: l.name });
    }
    if (u.pathname === '/api/cl/title' && m === 'POST') {
      const b = req.postDataJSON(), t = tidy(b.title);
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
const boardLists = page => page.$$eval('#wbBoard .wblist:not(.wbadd)', els => els.map(e => ({ id: Number(e.dataset.id), name: e.querySelector('.wblist-t').textContent, n: Number(e.querySelector('.wblist-n').textContent), menu: e.querySelectorAll('.wblist-menu').length })));
const names = async page => (await boardLists(page)).map(l => l.name).join('|');
const inList = (page, id) => page.$$eval('#wbBoard .wblist[data-id="' + id + '"] .wbk', els => els.map(e => e.querySelector('.wbref').textContent));
const cardIn = async (page, book, pg) => page.$eval('#wbBoard .wbk[data-book="' + book + '"][data-page="' + pg + '"]', e => Number(e.closest('.wblist').dataset.id)).catch(() => null);
const addPanel = page => page.$$('#wbAddList');
const rects = page => page.$$eval('#wbBoard .wblist', els => els.map(e => { const r = e.getBoundingClientRect(); return { id: e.dataset.id || 'add', l: Math.round(r.left), r: Math.round(r.right) }; }));
const scrollX = page => page.$eval('#wbBoard', e => e.scrollLeft);
const step = page => page.$eval('#wbBoard .wblist', e => e.offsetWidth + 12);
const tabs = page => page.$$eval('#wbTabs .wbtab', els => els.map(e => e.dataset.t));
const tabOn = page => page.$eval('#wbTabs .wbtab.on', e => e.dataset.t).catch(() => null);
const tabsHidden = page => page.$eval('#wbTabs', e => e.classList.contains('hide'));
const title = page => page.$eval('#wbTitle', e => e.textContent);
const hash = page => page.evaluate(() => location.hash);
const toastText = page => page.$eval('#toast', e => e.textContent);
async function settled(page) { await page.waitForFunction(() => { const b = document.getElementById('wbBoard'), y = document.getElementById('wbBody'); return b && y && !/लोड हो रहा/.test(b.textContent + y.textContent); }); await page.waitForTimeout(150); }
async function pickStaff(page, name) { await page.waitForSelector('#staffBtns .namebtn'); await page.locator('#staffBtns .namebtn', { hasText: name }).first().click(); await page.waitForSelector('#add:not(.hide), #dorders:not(.hide)'); }
async function openOrders(page) { await page.click('#doBtn'); await page.waitForSelector('#dorders:not(.hide)'); await settled(page); }
async function leaveOrders(page) { await page.click('#dorders .iconlink'); await page.waitForSelector('#add:not(.hide)'); }
async function switchTo(page, name) { await leaveOrders(page); await page.click('#addBack'); await pickStaff(page, name); await openOrders(page); }
async function ownerIn(page) {
  await page.click('#gate .linkbtn'); await page.waitForSelector('#pwIn, #owner:not(.hide)');
  if (await page.$('#pwIn')) { await page.fill('#pwIn', 'secret'); await page.click('#pwBtn'); }
  await page.waitForSelector('#owner:not(.hide)');
  await page.locator('#owner button', { hasText: 'Add stock' }).first().click(); await page.waitForSelector('#add:not(.hide), #dorders:not(.hide)');
  if (await page.$('#dorders:not(.hide)')) await settled(page); else await openOrders(page);   // a deep link (#o) lands straight on the board
}
async function menu(page, book, pg) { await page.click('#wbBoard .wbk[data-book="' + book + '"][data-page="' + pg + '"] .wbk-menu'); await page.waitForSelector('#wbMenuOpts .chip'); }
async function moveVia(page, book, pg, listId) { await menu(page, book, pg); await page.click('#wbMoveOpts .chip[data-list="' + listId + '"]'); await page.waitForTimeout(450); await settled(page); }
async function renameList(page, listId, value) {
  await page.click('#wbBoard .wblist[data-id="' + listId + '"] .wblist-menu'); await page.waitForSelector('#wbListOpts .chip[data-a="rename"]');
  await page.click('#wbListOpts .chip[data-a="rename"]'); await page.waitForSelector('#wbListIn');
  const before = await page.$eval('#wbListIn', e => e.value);
  await page.fill('#wbListIn', value); await page.click('#sheetInner .pri'); await page.waitForTimeout(450); await settled(page); return before;
}
async function addList(page, value) {
  await page.$eval('#wbBoard', e => e.scrollTo({ left: e.scrollWidth })); await stable(page);
  await page.click('#wbAddList'); await page.waitForSelector('#wbListIn');
  await page.fill('#wbListIn', value); await page.click('#sheetInner .pri'); await page.waitForTimeout(500); await settled(page); await stable(page);
}
async function tab(page, cat) { await page.click('#wbTabs .wbtab[data-t="' + cat + '"]'); await page.waitForTimeout(200); await settled(page); }
async function search(page, q) { if (await page.$eval('#wbSearch', e => e.classList.contains('hide'))) await page.click('#wbSearchBtn'); await page.fill('#wbSearch', q); await page.waitForTimeout(450); }
async function shot(page, nm) { if (process.env.SHOT_DIR) await page.screenshot({ path: path.join(process.env.SHOT_DIR, nm + '.png') }); }
const center = async (page, sel) => page.$eval(sel, e => { const r = e.getBoundingClientRect(); return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + Math.min(r.height / 2, 120)) }; });
async function stable(page) { let a = -1; for (let i = 0; i < 30; i++) { const b = await page.$eval('#wbBoard', e => e.scrollLeft); if (b === a) return; a = b; await page.waitForTimeout(120); } }
async function touch(cdp, type, x, y) { await cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y }] }); }

async function run(page, cdp) {
  await page.goto('http://127.0.0.1:' + PORT + '/index.html');
  const D = listsOf('Door'), G = listsOf('Glass');

  // ---- Raju (Door only): the Door board from its own lists ----------------
  await pickStaff(page, 'Raju'); await openOrders(page);
  let L = await boardLists(page);
  check('L1 the Door board is built from Door\'s own three lists, by id, in position order', L.map(l => l.id).join() === D.map(l => l.id).join() && await names(page) === 'Pending|Received|Delivered' && (await scrollX(page)) === 0, L);
  check('L2 staff see no list controls: no list ⋯ menu, no "+ Add another list"', L.every(l => l.menu === 0) && (await addPanel(page)).length === 0);
  check('L3 existing history survives migration exactly: 490/83 (legacy "received") sits on the Received list', (await cardIn(page, '490', 83)) === D[1].id && (await inList(page, D[1].id)).join() === 'बही 490 · पन्ना 83');
  check('L4 new work with no placement sits on the FIRST list', (await cardIn(page, '491', 5)) === D[0].id && (await cardIn(page, '493', 1)) === D[0].id && L[0].n === 7);
  await menu(page, '493', 1);
  check('L5 the card menu "Move to" lists the board\'s runtime lists, current one marked', (await page.$$eval('#wbMoveOpts .chip', els => els.map(e => e.dataset.list + ':' + e.disabled))).join() === D.map((l, i) => l.id + ':' + (i === 0)).join());
  await page.click('#sheet', { position: { x: 10, y: 10 } }); await page.waitForTimeout(250);
  await moveVia(page, '493', 1, D[2].id);
  check('L6 a menu move writes ONE placement with the list id; the card lands there', placements.length === 1 && placements[0].list_id === D[2].id && placements[0].by === 'Raju' && (await cardIn(page, '493', 1)) === D[2].id);
  // drag onto the peeking second list
  await stable(page); await page.$eval('#wbBoard', e => e.scrollTo({ left: 0 })); await stable(page);
  let c = await center(page, '.wblist[data-id="' + D[0].id + '"] .wbk[data-book="491"]');
  await touch(cdp, 'touchStart', c.x, c.y); await page.waitForTimeout(550);
  await touch(cdp, 'touchMove', c.x + 30, c.y); await page.waitForTimeout(60);
  await touch(cdp, 'touchMove', 372, 200); await page.waitForTimeout(700);
  await touch(cdp, 'touchMove', 200, 200); await page.waitForTimeout(150);
  const hl = await page.$$eval('.wblist.wbdrop', els => els.map(e => e.dataset.id));
  await touch(cdp, 'touchEnd'); await page.waitForTimeout(500); await settled(page);
  check('L7 a long-press drag onto another runtime list writes ONE placement', hl.join() === String(D[1].id) && placements.length === 2 && placements[1].list_id === D[1].id && (await cardIn(page, '491', 5)) === D[1].id && (await hash(page)) === '#o', { hl, placements });
  await stable(page); await page.$eval('#wbBoard', e => e.scrollTo({ left: 0 })); await stable(page);

  // ---- Owner: rename and add lists, per department -------------------------
  await leaveOrders(page); await page.click('#addBack'); await page.waitForSelector('#gate:not(.hide)');
  await ownerIn(page);
  L = await boardLists(page);
  check('L8 owner sees a ⋯ on every list header and "+ Add another list" after the last list', L.every(l => l.menu === 1) && (await addPanel(page)).length === 1 && (await rects(page)).slice(-1)[0].id === 'add' && (await tabOn(page)) === 'Door');
  const before = await renameList(page, D[0].id, '  Order   Received ');
  check('L9 Rename list: prefilled with the current name, one call, header changes at once, cards stay', before === 'Pending' && listLog.length === 1 && listLog[0].action === 'rename' && await names(page) === 'Order Received|Received|Delivered' && (await inList(page, D[0].id)).length === 5);
  await renameList(page, D[1].id, 'order received');
  check('L10 a duplicate name (case-insensitive) is refused on the same board', listLog.length === 2 && await names(page) === 'Order Received|Received|Delivered' && /already/.test(await toastText(page)));
  await page.click('#sheet', { position: { x: 10, y: 10 } }).catch(() => {}); await page.waitForTimeout(250);
  await addList(page, 'Cutting');
  L = await boardLists(page);
  check('L11 "+ Add another list" appends an empty list at the END of this board and scrolls to it', await names(page) === 'Order Received|Received|Delivered|Cutting' && L[3].n === 0 && (await scrollX(page)) > (await step(page)) * 2 && (await rects(page)).slice(-1)[0].id === 'add');
  await stable(page); await page.$eval('#wbBoard', e => e.scrollTo({ left: 0 })); await stable(page); await shot(page, '1-door-board-renamed-lists');
  await tab(page, 'Glass');
  check('L12 Glass has its own untouched lists; switching department resets to its first list', await names(page) === 'Pending|Received|Delivered' && (await scrollX(page)) === 0);
  check('L13 the Door+Glass bill is on Glass\'s first list here although its Door card was moved', (await cardIn(page, '490', 83)) === G[0].id);
  await renameList(page, G[0].id, 'Cutting'); await renameList(page, G[1].id, 'Ready');
  check('L14 the same name ("Cutting") is allowed on two different boards', await names(page) === 'Cutting|Ready|Delivered' && listsOf('Door')[3].name === 'Cutting');
  await stable(page); await page.$eval('#wbBoard', e => e.scrollTo({ left: 0 })); await stable(page); await shot(page, '2-glass-board-different-lists');
  await page.$eval('#wbBoard', e => e.scrollTo({ left: e.scrollWidth })); await stable(page);
  await shot(page, '3-add-another-list');
  await addList(page, 'Packed');
  const packed = listsOf('Glass')[3];
  check('L15 the new Glass list "Packed" is empty and last', await names(page) === 'Cutting|Ready|Delivered|Packed' && (await boardLists(page))[3].n === 0 && packed.position === 4);
  await shot(page, '4-new-empty-list');
  await stable(page); await page.$eval('#wbBoard', e => e.scrollTo({ left: 0 })); await stable(page);
  await moveVia(page, '490', 84, packed.id);
  check('L16 a card moves into the runtime-added list at once (one placement); the Door board is untouched', placements.slice(-1)[0].list_id === packed.id && (await cardIn(page, '490', 84)) === packed.id && listsOf('Door').length === 4);
  await page.$eval('#wbBoard', e => e.scrollTo({ left: e.scrollWidth })); await stable(page);
  await shot(page, '5-card-moved-into-new-list');
  check('L17 Door and Glass placements of one bill stay independent', (await cardIn(page, '490', 83)) === G[0].id && placements.filter(p => p.book === '490' && p.page === 83).every(p => p.cat === 'Door' || p.cat === 'Glass') && listsOf('Door')[0].name === 'Order Received');
  await search(page, 'Bhola');
  check('L18 search across four lists keeps the card inside its own list (Packed) and the layout intact', (await boardLists(page)).length === 4 && (await inList(page, packed.id)).join() === 'बही 490 · पन्ना 84' && (await inList(page, G[0].id)).length === 0);
  await page.click('#wbSearchBtn'); await page.waitForTimeout(300);

  // eight lists stay fluent
  await tab(page, 'Aluminium');
  for (const n of ['Manufacturing', 'Ready', 'Packed', 'Dispatched', 'Installed']) await addList(page, n);
  L = await boardLists(page);
  await page.$eval('#wbBoard', e => e.scrollTo({ left: e.scrollWidth })); await stable(page);
  const R = await rects(page);
  check('L19 a board of eight lists renders and scrolls to its last list and the add panel', L.length === 8 && R[7].l < 390 && R[7].r > 0 && R.slice(-1)[0].id === 'add', { n: L.length, R });
  await menu(page, '492', 2);
  check('L20 the move menu offers all eight lists', (await page.$$('#wbMoveOpts .chip')).length === 8);
  await page.click('#wbMoveOpts .chip[data-list="' + L[7].id + '"]'); await page.waitForTimeout(450); await settled(page);
  check('L21 a card moves straight to the eighth list', (await cardIn(page, '492', 2)) === L[7].id);

  // persists after reload
  await page.reload(); await page.waitForSelector('#gate:not(.hide)'); await ownerIn(page);
  check('L22 after reload: Door\'s renamed and added lists persist, cards where they were', await names(page) === 'Order Received|Received|Delivered|Cutting' && (await cardIn(page, '493', 1)) === D[2].id && (await cardIn(page, '491', 5)) === D[1].id);
  await tab(page, 'Glass');
  check('L23 …and Glass\'s own names and the card in Packed persist', await names(page) === 'Cutting|Ready|Delivered|Packed' && (await cardIn(page, '490', 84)) === packed.id);
  await tab(page, 'Mesh');
  check('L24 a runtime category has its own starter board and its work sits on the first list', await names(page) === 'Pending|Received|Delivered' && (await cardIn(page, '491', 7)) === listsOf('Mesh')[0].id);

  // ---- staff view of a customised board -------------------------------------
  await leaveOrders(page); await page.click('#addBack'); await page.waitForSelector('#owner:not(.hide)');   // the owner's Switch returns to the owner screen
  await page.locator('#owner button', { hasText: 'Exit' }).first().click(); await page.waitForSelector('#gate:not(.hide)');
  await pickStaff(page, 'Gopal'); await openOrders(page);
  L = await boardLists(page);
  check('L25 Gopal sees Glass\'s customised lists, the card in Packed, and no configuration controls', await names(page) === 'Cutting|Ready|Delivered|Packed' && (await cardIn(page, '490', 84)) === packed.id && L.every(l => l.menu === 0) && (await addPanel(page)).length === 0 && (await tabsHidden(page)));
  await page.$eval('#wbBoard', e => e.scrollTo({ left: e.scrollWidth })); await stable(page);
  await shot(page, '6-staff-view-no-controls');
  await stable(page); await page.$eval('#wbBoard', e => e.scrollTo({ left: 0 })); await stable(page);
  await moveVia(page, '490', 83, G[1].id);
  check('L26 staff move cards between runtime lists; Door\'s card of the same bill stays put', (await cardIn(page, '490', 83)) === G[1].id && placements.slice(-1)[0].cat === 'Glass');

  // ---- workspace, receiving, position restore --------------------------------
  await switchTo(page, 'Meena'); await tab(page, 'Door');
  const st = await step(page);
  await page.$eval('#wbBoard', (e, x) => e.scrollTo({ left: x }), st); await stable(page);
  const n1 = placements.length;
  await page.click('.wblist[data-id="' + D[1].id + '"] .wbk[data-book="491"][data-page="5"] .wbk-cover'); await page.waitForSelector('.wbif'); await settled(page);
  check('L27 the bill workspace shows the runtime list name and opening changed nothing', /Received/.test(await page.$eval('#wbBody .wbk-st', e => e.textContent)) && placements.length === n1 && (await hash(page)) === '#o/491/5');
  await page.click('#wbBody .wbrow'); await page.waitForSelector('#don'); await page.fill('#don', '1'); await page.click('#sheetInner .pri'); await page.waitForTimeout(450); await settled(page);
  check('L28 receiving is unchanged and never moves the card', receipts.length === 1 && receipts[0].mark_id === 12 && placements.length === n1);
  await page.click('#wbBody .wbk-mv'); await page.waitForSelector('#wbMoveOpts .chip'); await page.click('#wbMoveOpts .chip[data-list="' + listsOf('Door')[3].id + '"]'); await page.waitForTimeout(450); await settled(page);
  check('L29 a card moves to a runtime list from inside the bill', (placements.slice(-1)[0].list_id) === listsOf('Door')[3].id);
  await page.goBack(); await page.waitForSelector('#wbBoard:not(.hide)'); await settled(page); await page.waitForTimeout(300);
  check('L30 back returns to the same department and list position', (await hash(page)) === '#o' && (await tabOn(page)) === 'Door' && Math.abs((await scrollX(page)) - st) < 30);
  check('L31 the app never called the retired status route', !pzLog.some(l => /\/api\/cl\/status/.test(l)));
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
  check('L0 no uncaught page errors', errors.length === 0, errors);
  await browser.close(); srv.close();
  console.log('\n' + PASS.length + ' passed, ' + FAIL.length + ' failed — NK Orders (runtime board lists) verified.');
  process.exit(FAIL.length ? 1 : 0);
})();
