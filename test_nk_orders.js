/*
 * NK Warehouse — Orders (department work board, Work Board v1)
 * browser verification.
 *
 * Drives the REAL index.html in headless Chromium at a phone viewport with
 * Project Zero and Supabase replaced by in-test fakes (page.route), entering
 * exactly as a human does (tap the name, tap the button), and proves:
 *   Orders opens straight onto the person's department board on the Pending
 *   column; one category = one board (no "सभी"); Pending / Received /
 *   Delivered are columns swiped sideways, one per screen, with counts;
 *   one card = one bill + this department, with an editable name, the bill
 *   reference, the date only when known, no status button and no repeated
 *   department name; card names are created, changed and cleared, persist
 *   across reload and show on every board of the same page while the Tally
 *   customer stays untouched; moving a card is an explicit act on the
 *   existing status route that persists; Door and Glass cards of one bill
 *   move independently; moving never opens the bill and opening never
 *   moves; staff permissions, owner and runtime categories work; search
 *   finds the card name and every existing field within the department;
 *   line-level Door receiving is unchanged; screenshots are captured.
 *
 * Usage: NODE_PATH=$(npm root -g) node test_nk_orders.js
 *   SHOT_DIR=/some/dir saves phone screenshots for a visual check.
 */
const fs = require('fs'), http = require('http'), path = require('path');
const { chromium } = require('playwright');

const PORT = 8794, DIR = __dirname;
const PZ = 'https://project-zero-xafh.onrender.com', SB = 'https://enjlgflisuywkaorxetv.supabase.co';
const PASS = [], FAIL = [];
function check(name, cond, detail) { (cond ? PASS : FAIL).push(name); console.log((cond ? 'PASS ' : 'FAIL ') + name + (cond ? '' : '  -- ' + String(detail === undefined ? '' : (typeof detail === 'string' ? detail : JSON.stringify(detail))).slice(0, 300))); }

// ---- the fakes ------------------------------------------------------------
const KINDS = [{ id: 1, name: 'Order' }, { id: 2, name: 'Door' }, { id: 3, name: 'Glass' }, { id: 4, name: 'Aluminium' }, { id: 5, name: 'Mesh' }];
const PAGES = [
  { book: '490', page: 83, cats: ['Door', 'Glass'], cust: 'Amar Traders', date: '2026-08-20', lines: [{ design_no: 'D-101', size: '7x3' }] },
  { book: '490', page: 84, cats: ['Glass'], cust: 'Bhola Glass', date: null, lines: [] },
  { book: '491', page: 5, cats: ['Door'], cust: null, date: null, lines: [{ design_no: 'Teak-9', size: '6.5x2.5' }] },
  { book: '491', page: 7, cats: ['Mesh'], cust: 'Chandan', date: '2026-09-01', lines: [] },
  { book: '492', page: 1, cats: [], cust: 'Dinesh', date: '2026-09-02', lines: [] },
  { book: '492', page: 2, cats: ['Aluminium'], cust: 'Eknath Windows', date: '2026-09-02', lines: [] },
];
const COMMITMENTS = [
  { id: 11, book_number: '490', page_number: 83, design_no: 'D-101', size: '7x3', qty: 4, received: 1, receipts: [], tally_name: 'Amar Traders', agreed_on: '2026-08-20', tags: ['Door', 'Glass', 'Order'] },
  { id: 12, book_number: '491', page_number: 5, design_no: 'Teak-9', size: '6.5x2.5', qty: 2, received: 0, receipts: [], tally_name: null, agreed_on: null, tags: [] },
];
const STAFF = [
  { id: 's1', name: 'Raju', active: true, order_tags: ['Door'] },
  { id: 's2', name: 'Gopal', active: true, order_tags: ['Glass'] },
  { id: 's3', name: 'Meena', active: true, order_tags: [] },
];
const events = [];      // status acts {book,page,cat,status,by} — append-only, like production
const titles = [];      // name acts {book,page,title|null,by} — append-only, like production
const receipts = [];    // POST /api/cl/receipt bodies
const pzLog = [];       // every request the app made to Project Zero: "METHOD path"
const lastTitle = (book, page) => { const t = titles.slice().reverse().find(e => e.book === book && e.page === page); return t ? t.title : null; };
function feed() {
  const out = [];
  PAGES.forEach(p => (p.cats.length ? p.cats : [null]).forEach(cat => {
    const ev = events.slice().reverse().find(e => e.book === p.book && e.page === p.page && e.cat === cat);
    out.push({ book_number: p.book, page_number: p.page, category: cat,
      status: ev ? ev.status : (cat ? 'pending' : null), status_by: ev ? ev.by : null, status_at: ev ? 'now' : null,
      tally_name: p.cust, agreed_on: p.date, title: lastTitle(p.book, p.page), lines: p.lines });
  }));
  return out;
}
function latest(book, page, cat) { const ev = events.slice().reverse().find(e => e.book === book && e.page === page && e.cat === cat); return ev ? ev.status : 'pending'; }
const json = (route, obj, status) => route.fulfill({ status: status || 200, contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify(obj) });

async function routes(page) {
  await page.route(PZ + '/**', async route => {
    const req = route.request(), u = new URL(req.url()), m = req.method();
    pzLog.push(m + ' ' + u.pathname);
    if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' } });
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
async function lane(page, s) {
  return page.$$eval('#wbBoard .wblane[data-s="' + s + '"] .wbk', els => els.map(e => ({
    ref: e.querySelector('.wbref').textContent, name: e.querySelector('.wbcust').textContent,
    date: e.querySelector('.wbdate') ? e.querySelector('.wbdate').textContent.replace(/^\s*·\s*/, '') : null,
    text: e.textContent, edit: e.querySelectorAll('.wbk-ed').length, move: e.querySelectorAll('.wbk-mv').length, stButtons: e.querySelectorAll('.wbst').length })));
}
const refs = async (page, s) => (await lane(page, s)).map(x => x.ref).join('|');
const counts = page => page.$$eval('#wbCols .wbcol', els => els.map(e => e.dataset.s + ':' + e.querySelector('b').textContent).join(','));
const colOn = page => page.$eval('#wbCols .wbcol.on', e => e.dataset.s).catch(() => null);
const scrollX = page => page.$eval('#wbBoard', e => e.scrollLeft);
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
async function col(page, s) { await page.click('#wbCols .wbcol[data-s="' + s + '"]'); await page.waitForTimeout(500); }
async function move(page, book, pg, to) {
  await page.click('.wblane .wbk[data-book="' + book + '"][data-page="' + pg + '"] .wbk-mv, #wbBody .wbk-mv');
  await page.waitForSelector('#wbMoveOpts .chip');
  await page.click('#wbMoveOpts .chip[data-s="' + to + '"]');
  await page.waitForTimeout(450); await settled(page);
}
async function name(page, sel, value) {
  await page.click(sel); await page.waitForSelector('#wbTitleIn');
  const before = await page.$eval('#wbTitleIn', e => e.value);
  await page.fill('#wbTitleIn', value); await page.click('#sheetInner .pri');
  await page.waitForTimeout(450); await settled(page); return before;
}
async function tab(page, cat) { await page.click('#wbTabs .wbtab[data-t="' + cat + '"]'); await page.waitForTimeout(150); }
async function search(page, q) { await page.fill('#wbSearch', q); await page.waitForTimeout(450); }
async function shot(page, nm) { if (process.env.SHOT_DIR) await page.screenshot({ path: path.join(process.env.SHOT_DIR, nm + '.png') }); }

async function run(page) {
  await page.goto('http://127.0.0.1:' + PORT + '/index.html');

  // ---- Raju (Door only): lands on the Door board, Pending column ----------
  await pickStaff(page, 'Raju');
  await openOrders(page);
  check('B1 Orders opens straight onto the board at #o, Pending column, scrolled to the start', (await hash(page)) === '#o' && (await colOn(page)) === 'pending' && (await scrollX(page)) === 0);
  check('B2 single-department staff lands on Door: no switcher, department in the title', (await tabsHidden(page)) && /Door/.test(await title(page)) && (await tabOn(page)) === 'Door');
  check('B3 three columns Pending / Received / Delivered, no "सभी" board, no status dropdown', JSON.stringify(await page.$$eval('#wbBoard .wblane', els => els.map(e => e.dataset.s))) === '["pending","received","delivered"]' && (await page.$$('#wbTabs .wbtab[data-t="All"], #wbStSel')).length === 0 && !/सभी/.test(await page.$eval('#dorders', e => e.textContent)));
  check('B4 column headers carry name and count', (await counts(page)) === 'pending:2,received:0,delivered:0' && /बाकी.*Pending · 2/.test(await page.$eval('#wbBoard .wblane[data-s="pending"] .wblanehd', e => e.textContent)));
  let L = await lane(page, 'pending');
  check('B5 Raju\'s two Door bills are cards in Pending', await refs(page, 'pending') === 'बही 490 · पन्ना 83|बही 491 · पन्ना 5', L);
  check('B6 one card = one job: no status button, no department name, one edit and one move action', L.every(x => x.stButtons === 0 && !/Door|Glass|Aluminium|Mesh/.test(x.text) && x.edit === 1 && x.move === 1), L);
  check('B7 name precedence: derived Tally customer, else "नाम जोड़ें" — never "? — नाम बिल पर है"', L[0].name === 'Amar Traders' && L[1].name === 'नाम जोड़ें' && !/नाम बिल पर है/.test(await page.$eval('#wbBoard', e => e.textContent)), L);
  check('B8 the reference on every card; the date only when known', L[0].ref === 'बही 490 · पन्ना 83' && L[0].date === '20-08-2026' && L[1].date === null, L);
  check('B9 one column fills the phone width (next column only peeks)', await page.$eval('#wbBoard .wblane', e => e.getBoundingClientRect().width) > 300 && await page.$eval('#wbBoard', e => e.scrollWidth > e.clientWidth * 2.5));
  await shot(page, '1-pending-column-raju');

  // horizontal navigation
  await col(page, 'received');
  check('B10 tapping the Received header swipes the board to that column', (await colOn(page)) === 'received' && (await scrollX(page)) > 200);
  await page.$eval('#wbBoard', e => { e.scrollLeft = e.scrollWidth; }); await page.waitForTimeout(300);
  check('B11 swiping to the end lands on Delivered and the header follows', (await colOn(page)) === 'delivered');
  await col(page, 'pending');
  check('B12 back to Pending', (await colOn(page)) === 'pending' && (await scrollX(page)) === 0);

  // move a card
  await move(page, '490', 83, 'received');
  check('B13 moving a card is one explicit POST on /api/cl/status (Door, Raju)', events.length === 1 && JSON.stringify(events[0]) === JSON.stringify({ book: '490', page: 83, cat: 'Door', status: 'received', by: 'Raju' }), events);
  check('B14 the move did not open the bill; the card left Pending and the counts moved', (await hash(page)) === '#o' && await refs(page, 'pending') === 'बही 491 · पन्ना 5' && (await counts(page)) === 'pending:1,received:1,delivered:0');
  await col(page, 'received');
  check('B15 the card now sits in the Received column', await refs(page, 'received') === 'बही 490 · पन्ना 83');
  await shot(page, '2-received-column');
  await page.click('.wblane[data-s="received"] .wbk[data-book="490"] .wbk-mv'); await page.waitForSelector('#wbMoveOpts .chip');
  check('B16 the move sheet marks the current column and offers the other two', await page.$eval('#wbMoveOpts .chip[data-s="received"]', e => e.disabled) && (await page.$$('#wbMoveOpts .chip:not([disabled])')).length === 2);
  await page.click('#wbMoveOpts .chip[data-s="delivered"]'); await page.waitForTimeout(450); await settled(page);
  check('B17 Received → Delivered appends a second act; the first still stands', events.length === 2 && events[0].status === 'received' && events[1].status === 'delivered' && (await counts(page)) === 'pending:1,received:0,delivered:1');
  check('B18 the app only ever POSTs acts', pzLog.filter(l => /\/api\/cl\/(status|title)/.test(l)).every(l => /^(POST|OPTIONS) /.test(l)));

  // name a card
  await col(page, 'pending');
  await page.click('.wblane[data-s="pending"] .wbk[data-book="491"] .wbk-ed'); await page.waitForSelector('#wbTitleIn');
  check('B19 the pencil opens the name sheet, empty for an unnamed bill, without opening the bill', (await hash(page)) === '#o' && (await page.$eval('#wbTitleIn', e => e.value)) === '');
  await shot(page, '3-title-edit');
  await page.fill('#wbTitleIn', 'Sharma ji bedroom'); await page.click('#sheetInner .pri'); await page.waitForTimeout(450); await settled(page);
  check('B20 the name is one POST on /api/cl/title and the card shows it at once', titles.length === 1 && titles[0].title === 'Sharma ji bedroom' && titles[0].by === 'Raju' && (await lane(page, 'pending'))[0].name === 'Sharma ji bedroom', titles);
  await col(page, 'delivered');
  let before = await name(page, '.wblane[data-s="delivered"] .wbk[data-book="490"] .wbk-ed', 'Amar – first floor');
  check('B21 a bill with a Tally name opens the sheet prefilled with it; the new name replaces it on the card', before === 'Amar Traders' && (await lane(page, 'delivered'))[0].name === 'Amar – first floor' && titles.length === 2);
  await page.click('.wblane[data-s="delivered"] .wbk[data-book="490"] .wbk-ed'); await page.waitForSelector('#wbTitleIn');
  await page.locator('#sheetInner .chip', { hasText: 'Tally का नाम वापस' }).click(); await page.waitForTimeout(450); await settled(page);
  check('B22 clearing records an explicit clearing act and the Tally name returns', titles.length === 3 && titles[2].title === null && (await lane(page, 'delivered'))[0].name === 'Amar Traders');
  await name(page, '.wblane[data-s="delivered"] .wbk[data-book="490"] .wbk-ed', 'Amar – first floor');
  check('B23 named again for the cross-board check', titles.length === 4 && (await lane(page, 'delivered'))[0].name === 'Amar – first floor');

  // reload: everything persists, board reopens on Pending
  await page.reload(); await pickStaff(page, 'Raju'); await page.waitForSelector('#dorders:not(.hide)'); await settled(page);
  check('B24 after reload: Door board, Pending column, moves and names persisted', (await colOn(page)) === 'pending' && (await tabOn(page)) === 'Door' && (await counts(page)) === 'pending:1,received:0,delivered:1' && (await lane(page, 'pending'))[0].name === 'Sharma ji bedroom' && (await lane(page, 'delivered'))[0].name === 'Amar – first floor');

  // search within the department, across columns
  await search(page, 'Sharma'); check('B25 search finds the card name', await refs(page, 'pending') === 'बही 491 · पन्ना 5' && (await counts(page)) === 'pending:1,received:0,delivered:0');
  await search(page, 'Amar'); check('B26 search finds the Tally customer in another column (the Delivered one)', (await counts(page)) === 'pending:0,received:0,delivered:1' && /कुछ नहीं मिला/.test(await page.$eval('.wblane[data-s="pending"]', e => e.textContent)));
  await search(page, 'first floor'); check('B27 search by the new name', (await counts(page)) === 'pending:0,received:0,delivered:1');
  await search(page, 'Teak'); check('B28 search by design', await refs(page, 'pending') === 'बही 491 · पन्ना 5');
  await search(page, '3x7'); check('B29 search by size, either orientation', (await counts(page)) === 'pending:0,received:0,delivered:1');
  await search(page, '491'); check('B30 search by book', await refs(page, 'pending') === 'बही 491 · पन्ना 5');
  await search(page, '83'); check('B31 search by page', (await counts(page)) === 'pending:0,received:0,delivered:1');
  await search(page, 'Bhola'); check('B32 a Glass bill is never found from the Door board', (await counts(page)) === 'pending:0,received:0,delivered:0');
  await search(page, ''); check('B33 clearing search restores the board', (await counts(page)) === 'pending:1,received:0,delivered:1');

  // ---- Gopal (Glass only): separate board, same name, independent moves --
  await switchTo(page, 'Gopal');
  L = await lane(page, 'pending');
  check('B34 Gopal lands on the Glass board, Pending', (await tabsHidden(page)) && (await tabOn(page)) === 'Glass' && (await colOn(page)) === 'pending');
  check('B35 the Door+Glass bill is a Glass card here, still Pending although Door delivered it — and wears the same name', await refs(page, 'pending') === 'बही 490 · पन्ना 83|बही 490 · पन्ना 84' && L[0].name === 'Amar – first floor' && L[1].name === 'Bhola Glass', L);
  await move(page, '490', 83, 'received');
  check('B36 Gopal\'s move names Glass; Door on the same bill stays delivered', events[2].cat === 'Glass' && events[2].by === 'Gopal' && latest('490', 83, 'Door') === 'delivered' && latest('490', 83, 'Glass') === 'received', events);
  check('B37 Pending Glass now holds only 490/84', await refs(page, 'pending') === 'बही 490 · पन्ना 84');

  // ---- Meena (unassigned): compact switcher, one board at a time ----------
  await switchTo(page, 'Meena');
  check('B38 multi-department person: switcher Door|Glass|Aluminium|Mesh, no सभी, Door first', JSON.stringify(await tabs(page)) === '["Door","Glass","Aluminium","Mesh"]' && !(await tabsHidden(page)) && (await tabOn(page)) === 'Door' && (await counts(page)) === 'pending:1,received:0,delivered:1');
  await tab(page, 'Glass');
  check('B39 Glass board: Glass cards only (490/83 shows Glass\'s Received, not Door\'s Delivered)', (await counts(page)) === 'pending:1,received:1,delivered:0' && await refs(page, 'received') === 'बही 490 · पन्ना 83' && (await colOn(page)) === 'pending');
  check('B40 the uncategorised Order (492/1) is on no board', !/492 · पन्ना 1/.test(await page.$eval('#wbBoard', e => e.textContent)));
  await tab(page, 'Aluminium'); check('B41 Aluminium board is its own', await refs(page, 'pending') === 'बही 492 · पन्ना 2');
  await tab(page, 'Mesh'); check('B42 runtime category Mesh has its own board', await refs(page, 'pending') === 'बही 491 · पन्ना 7');
  await leaveOrders(page); await openOrders(page);
  check('B43 reopening Orders keeps the department chosen this session, back on Pending', (await tabOn(page)) === 'Mesh' && (await colOn(page)) === 'pending' && (await scrollX(page)) === 0);

  // ---- Owner: every department, one at a time ------------------------------
  await leaveOrders(page); await page.click('#addBack'); await page.waitForSelector('#gate:not(.hide)');
  await page.click('#gate .linkbtn'); await page.waitForSelector('#pwIn'); await page.fill('#pwIn', 'secret'); await page.click('#pwBtn');
  await page.waitForSelector('#owner:not(.hide)');
  await page.locator('#owner button', { hasText: 'Add stock' }).first().click(); await page.waitForSelector('#add:not(.hide)');
  await openOrders(page);
  check('B44 owner: every department in the switcher, Door board, Pending', JSON.stringify(await tabs(page)) === '["Door","Glass","Aluminium","Mesh"]' && (await tabOn(page)) === 'Door' && (await colOn(page)) === 'pending');
  await shot(page, '4-owner-multi-department');
  await tab(page, 'Glass');
  check('B45 owner switches to the Glass board and sees Glass cards only', (await counts(page)) === 'pending:1,received:1,delivered:0' && await refs(page, 'pending') === 'बही 490 · पन्ना 84');
  await tab(page, 'Door');

  // ---- One bill: opening never moves; receiving unchanged ------------------
  const n = events.length;
  await page.click('.wblane[data-s="pending"] .wbk[data-book="491"][data-page="5"] .wbk-t .wbcust'); await page.waitForSelector('.wbif'); await settled(page);
  check('B46 tapping the card body opens the bill workspace with the viewer; the board is hidden', (await hash(page)) === '#o/491/5' && /billview\?book=491&page=5/.test(await page.$eval('.wbif', e => e.getAttribute('src'))) && await page.$eval('#wbBoard', e => e.classList.contains('hide')));
  check('B47 opening the bill changed nothing; it shows the name, the reference and this department\'s column', events.length === n && /Sharma ji bedroom/.test(await page.$eval('#wbBody .wbcust', e => e.textContent)) && /बही 491 · पन्ना 5/.test(await page.$eval('#wbBody', e => e.textContent)) && /बाकी/.test(await page.$eval('#wbBody .wbk-st', e => e.textContent)));
  await shot(page, '5-bill-workspace');
  await page.click('#wbBody .wbrow'); await page.waitForSelector('#don');
  check('B48 the Door line opens the existing receive sheet prefilled with the remaining count', (await page.$eval('#don', e => e.value)) === '2');
  await page.fill('#don', '1'); await page.click('#sheetInner .pri'); await page.waitForTimeout(450); await settled(page);
  check('B49 receiving posts the same line-level receipt as before', receipts.length === 1 && receipts[0].mark_id === 12 && receipts[0].qty === 1 && receipts[0].noted_by === 'Owner' && receipts[0].force === false, receipts);
  check('B50 receiving a door did NOT move the card', latest('491', 5, 'Door') === 'pending' && events.length === n);
  await page.click('#wbBody .wbk-mv'); await page.waitForSelector('#wbMoveOpts .chip'); await page.click('#wbMoveOpts .chip[data-s="received"]'); await page.waitForTimeout(450); await settled(page);
  check('B51 the card can be moved from inside the bill', latest('491', 5, 'Door') === 'received' && events.length === n + 1 && /आ गया/.test(await page.$eval('#wbBody .wbk-st', e => e.textContent)));
  await page.click('#wbBody .wbk-ed'); await page.waitForSelector('#wbTitleIn'); await page.fill('#wbTitleIn', 'Sharma ji – bedroom doors'); await page.click('#sheetInner .pri'); await page.waitForTimeout(450); await settled(page);
  check('B52 the name can be edited from inside the bill', titles[titles.length - 1].title === 'Sharma ji – bedroom doors' && /bedroom doors/.test(await page.$eval('#wbBody .wbcust', e => e.textContent)));
  await page.click('#dorders .iconlink'); await page.waitForTimeout(300);
  check('B53 back returns to the Door board; the moved card sits in Received with its new name', (await hash(page)) === '#o' && (await tabOn(page)) === 'Door' && await refs(page, 'received') === 'बही 491 · पन्ना 5' && (await lane(page, 'received'))[0].name === 'Sharma ji – bedroom doors');
}

(async () => {
  const srv = await serve();
  const browser = await chromium.launch({ executablePath: process.env.CHROME || fs.readdirSync('/opt/pw-browsers').filter(d => /^chromium-\d+$/.test(d)).map(d => '/opt/pw-browsers/' + d + '/chrome-linux/chrome').find(fs.existsSync) });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, serviceWorkers: 'block', isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  page.on('dialog', d => d.accept());
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  await routes(page);
  try { await run(page); } catch (e) { check('run completed without throwing', false, e && e.stack || e); }
  check('B0 no uncaught page errors', errors.length === 0, errors);
  await browser.close(); srv.close();
  console.log('\n' + PASS.length + ' passed, ' + FAIL.length + ' failed — NK Orders (work board) verified.');
  process.exit(FAIL.length ? 1 : 0);
})();
