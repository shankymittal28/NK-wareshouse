/*
 * NK Warehouse — Orders (departmental pending register, Work List v1.1)
 * browser verification.
 *
 * Drives the REAL index.html in headless Chromium with Project Zero and
 * Supabase replaced by in-test fakes (page.route), entering exactly as a
 * human does (tap the name, tap the button), and proves:
 *   Orders opens straight onto the person's PENDING bills — no shelf, no
 *   intermediate screen, no combined "सभी" list; a single-category staff
 *   member lands in their department without tapping it; multi-category
 *   staff and the owner get one department selector and see one
 *   department at a time; one card = one bill + the selected department
 *   with exactly one status control and no category label; a Door+Glass
 *   bill is a separate card in each register; Pending is the default and
 *   Received / Delivered / All sit behind one compact selector; status
 *   acts are explicit POSTs that persist across reload and only ever
 *   grow; the department is remembered within a session; runtime
 *   categories appear; search stays within the department and status;
 *   line-level Door receiving is unchanged; the phone layout is captured.
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
const events = [];      // {book,page,cat,status,by} — append-only, like production
const receipts = [];    // POST /api/cl/receipt bodies
const pzLog = [];       // every request the app made to Project Zero: "METHOD path"
function feed() {
  const out = [];
  PAGES.forEach(p => (p.cats.length ? p.cats : [null]).forEach(cat => {
    const ev = events.slice().reverse().find(e => e.book === p.book && e.page === p.page && e.cat === cat);
    out.push({ book_number: p.book, page_number: p.page, category: cat,
      status: ev ? ev.status : (cat ? 'pending' : null), status_by: ev ? ev.by : null, status_at: ev ? 'now' : null,
      tally_name: p.cust, agreed_on: p.date, lines: p.lines });
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
async function cards(page) {
  return page.$$eval('#wbBody .wbbill', els => els.map(e => ({
    ref: e.querySelector('.wbref').textContent, cust: e.querySelector('.wbcust').textContent,
    date: e.querySelector('.wbdate') ? e.querySelector('.wbdate').textContent.replace(/^\s*·\s*/, '') : null,
    text: e.textContent,
    chips: Array.from(e.querySelectorAll('.wbst')).map(c => ({ cat: c.dataset.cat || null, st: c.dataset.st || null, txt: c.textContent })) })));
}
const refs = async page => (await cards(page)).map(x => x.ref).join('|');
const tabs = page => page.$$eval('#wbTabs .wbtab', els => els.map(e => e.dataset.t));
const tabOn = page => page.$eval('#wbTabs .wbtab.on', e => e.dataset.t).catch(() => null);
const tabsHidden = page => page.$eval('#wbTabs', e => e.classList.contains('hide'));
const stSel = page => page.$eval('#wbStSel', e => ({ s: e.dataset.s, txt: e.textContent }));
const title = page => page.$eval('#wbTitle', e => e.textContent);
const bodyText = page => page.$eval('#wbBody', e => e.textContent);
async function settled(page) { await page.waitForFunction(() => { const b = document.getElementById('wbBody'); return b && !/लोड हो रहा/.test(b.textContent); }); await page.waitForTimeout(150); }
async function pickStaff(page, name) {
  await page.waitForSelector('#staffBtns .namebtn');
  await page.locator('#staffBtns .namebtn', { hasText: name }).first().click();
  await page.waitForSelector('#add:not(.hide), #dorders:not(.hide)');
}
async function openOrders(page) { await page.click('#doBtn'); await page.waitForSelector('#dorders:not(.hide)'); await settled(page); }
async function leaveOrders(page) { await page.click('#dorders .iconlink'); await page.waitForSelector('#add:not(.hide)'); }
async function switchTo(page, name) { await leaveOrders(page); await page.click('#addBack'); await pickStaff(page, name); await openOrders(page); }
async function setStatus(page, chipSel, status) {
  await page.click(chipSel); await page.waitForSelector('#wbStOpts .chip');
  await page.click('#wbStOpts .chip[data-s="' + status + '"]');
  await page.waitForTimeout(400); await settled(page);
}
async function view(page, status) { await page.click('#wbStSel'); await page.waitForSelector('#wbStMenu .chip'); await page.click('#wbStMenu .chip[data-s="' + status + '"]'); await page.waitForTimeout(150); }
async function tab(page, cat) { await page.click('#wbTabs .wbtab[data-t="' + cat + '"]'); await page.waitForTimeout(150); }
async function search(page, q) { await page.fill('#wbSearch', q); await page.waitForTimeout(450); }
async function shot(page, name) { if (process.env.SHOT_DIR) await page.screenshot({ path: path.join(process.env.SHOT_DIR, name + '.png') }); }

async function run(page) {
  await page.goto('http://127.0.0.1:' + PORT + '/index.html');

  // ---- Raju: assigned Door only → lands in Door, Pending, at once ----------
  await pickStaff(page, 'Raju');
  await openOrders(page);
  let c = await cards(page);
  check('N1 Orders opens straight onto the pending register at #o', (await page.evaluate(() => location.hash)) === '#o' && c.length > 0);
  check('N2 single-category staff enters Door automatically — no tab to tap, department in the title', (await tabsHidden(page)) && /Door/.test(await title(page)) && (await tabOn(page)) === 'Door');
  check('N3 no "सभी" combined tab and no second row of status tabs', (await page.$$('#wbTabs .wbtab[data-t="All"]')).length === 0 && !/सभी/.test(await page.$eval('#wbHead', e => e.textContent)) && (await page.$$('#wbSt')).length === 0);
  check('N4 Pending is the default: compact selector reads बाकी, every card pending', (await stSel(page)).s === 'pending' && /बाकी/.test((await stSel(page)).txt) && c.every(x => x.chips[0].st === 'pending'));
  check('N5 Raju sees exactly his two Door bills', await refs(page) === 'बही 490 · पन्ना 83|बही 491 · पन्ना 5', c);
  check('N6 one card = one control, and the category is not repeated on the card', c.every(x => x.chips.length === 1 && !/Door|Glass|Aluminium|Mesh/.test(x.text)), c);
  check('N7 the Door+Glass bill carries only its Door status here', c[0].chips[0].cat === 'Door', c[0]);
  check('N8 no books, page counts or progress bars', !/पन्ने|कुल/.test(await bodyText(page)) && (await page.$$('.wbbar')).length === 0);
  check('N9 customer first; the unnamed bill says so; date only when known', c[0].cust === 'Amar Traders' && /नाम बिल पर है/.test(c[1].cust) && c[0].date === '20-08-2026' && c[1].date === null, c);
  await shot(page, '1-raju-door-pending');

  await setStatus(page, '.wbbill[data-book="490"][data-page="83"] .wbst', 'received');
  check('N10 one explicit POST for Door 490/83 by Raju', events.length === 1 && JSON.stringify(events[0]) === JSON.stringify({ book: '490', page: 83, cat: 'Door', status: 'received', by: 'Raju' }), events);
  check('N11 the received bill leaves the pending register', await refs(page) === 'बही 491 · पन्ना 5', await refs(page));
  await view(page, 'received');
  check('N12 the compact selector switches to Received and shows it', (await stSel(page)).s === 'received' && await refs(page) === 'बही 490 · पन्ना 83' && (await cards(page))[0].chips[0].st === 'received');
  await shot(page, '2-raju-received-view');

  await page.reload(); await pickStaff(page, 'Raju'); await page.waitForSelector('#dorders:not(.hide)'); await settled(page);
  check('N13 after reload: back to Pending by default, Door entered automatically', (await stSel(page)).s === 'pending' && (await tabOn(page)) === 'Door' && await refs(page) === 'बही 491 · पन्ना 5');
  await view(page, 'received');
  check('N14 the status persisted across reload', await refs(page) === 'बही 490 · पन्ना 83');
  await setStatus(page, '.wbbill[data-book="490"][data-page="83"] .wbst', 'delivered');
  check('N15 Received → Delivered appends; the first event still stands', events.length === 2 && events[0].status === 'received' && events[1].status === 'delivered', events);
  check('N16 the app only ever POSTs status acts', pzLog.filter(l => /\/api\/cl\/status/.test(l)).every(l => /^(POST|OPTIONS) /.test(l)));
  await view(page, 'delivered');
  check('N17 Delivered view shows it', await refs(page) === 'बही 490 · पन्ना 83' && (await cards(page))[0].chips[0].st === 'delivered');
  await view(page, 'all');
  check('N18 All view lists both Door bills, still one control each', await refs(page) === 'बही 490 · पन्ना 83|बही 491 · पन्ना 5' && (await cards(page)).every(x => x.chips.length === 1));
  await view(page, 'pending'); await search(page, 'Amar');
  check('N19 search stays within Pending: the delivered Amar bill is not found', (await cards(page)).length === 0 && /कुछ नहीं मिला/.test(await bodyText(page)));
  await view(page, 'all');
  check('N20 …and is found once the selector says All', await refs(page) === 'बही 490 · पन्ना 83');
  await search(page, '');

  // ---- Gopal: assigned Glass only — separate register, independent -------
  await switchTo(page, 'Gopal');
  c = await cards(page);
  check('N21 Gopal lands in Glass automatically, Pending', (await tabsHidden(page)) && (await tabOn(page)) === 'Glass' && (await stSel(page)).s === 'pending');
  check('N22 the Door+Glass bill appears again here as a Glass card, still pending — Door delivered did not hide it', await refs(page) === 'बही 490 · पन्ना 83|बही 490 · पन्ना 84' && c.every(x => x.chips.length === 1 && x.chips[0].cat === 'Glass' && x.chips[0].st === 'pending'), c);
  await setStatus(page, '.wbbill[data-book="490"][data-page="83"] .wbst', 'received');
  check('N23 Gopal\'s act names Glass; Door on the same bill stays delivered', events[2].cat === 'Glass' && events[2].by === 'Gopal' && latest('490', 83, 'Door') === 'delivered' && latest('490', 83, 'Glass') === 'received', events);
  check('N24 empty state is honest: Glass pending now holds only 490/84', await refs(page) === 'बही 490 · पन्ना 84');
  await setStatus(page, '.wbbill[data-book="490"][data-page="84"] .wbst', 'received');
  check('N25 no pending Glass work → plain message, nothing mixed in', (await cards(page)).length === 0 && /कोई Pending ऑर्डर नहीं/.test(await bodyText(page)));
  await shot(page, '3-gopal-glass-empty');

  // ---- Meena: unassigned → one department at a time, never combined -------
  await switchTo(page, 'Meena');
  check('N26 multi-department person: tabs Door|Glass|Aluminium|Mesh, no सभी, first selected', JSON.stringify(await tabs(page)) === '["Door","Glass","Aluminium","Mesh"]' && !(await tabsHidden(page)) && (await tabOn(page)) === 'Door', await tabs(page));
  check('N27 Door register: only pending Door work', await refs(page) === 'बही 491 · पन्ना 5');
  await tab(page, 'Glass');
  check('N28 Glass register: no pending Glass work now, and no Door work leaks in', (await cards(page)).length === 0 && /कोई Pending/.test(await bodyText(page)));
  await view(page, 'all');
  check('N29 Glass · All: 490/83 as a Glass card (received) and 490/84 — Door\'s delivered status nowhere', await refs(page) === 'बही 490 · पन्ना 83|बही 490 · पन्ना 84' && (await cards(page)).every(x => x.chips.length === 1 && x.chips[0].cat === 'Glass') && (await cards(page))[0].chips[0].st === 'received');
  await tab(page, 'Door');
  check('N30 switching department keeps the status view: Door · All shows 490/83 as a Door card (delivered)', (await stSel(page)).s === 'all' && (await cards(page)).find(x => x.ref === 'बही 490 · पन्ना 83').chips[0].cat === 'Door' && (await cards(page)).find(x => x.ref === 'बही 490 · पन्ना 83').chips[0].st === 'delivered');
  check('N31 the uncategorised Order (492/1) is in no department register', !(await refs(page)).includes('492 · पन्ना 1'));
  await tab(page, 'Aluminium');
  check('N32 Aluminium register is its own list', await refs(page) === 'बही 492 · पन्ना 2' && (await cards(page))[0].chips[0].cat === 'Aluminium');
  await tab(page, 'Mesh');
  check('N33 runtime category Mesh has its own register', await refs(page) === 'बही 491 · पन्ना 7' && (await cards(page))[0].chips[0].cat === 'Mesh');
  await shot(page, '4-meena-tabs-mesh');
  await leaveOrders(page); await openOrders(page);
  check('N34 reopening Orders keeps the department chosen this session and resets to Pending', (await tabOn(page)) === 'Mesh' && (await stSel(page)).s === 'pending' && await refs(page) === 'बही 491 · पन्ना 7');

  // ---- Owner: every department, one at a time ------------------------------
  await leaveOrders(page); await page.click('#addBack'); await page.waitForSelector('#gate:not(.hide)');
  await page.click('#gate .linkbtn'); await page.waitForSelector('#pwIn'); await page.fill('#pwIn', 'secret'); await page.click('#pwBtn');
  await page.waitForSelector('#owner:not(.hide)');
  await page.locator('#owner button', { hasText: 'Add stock' }).first().click(); await page.waitForSelector('#add:not(.hide)');
  await openOrders(page);
  check('N35 owner: every department as tabs, no सभी, Door selected, Pending', JSON.stringify(await tabs(page)) === '["Door","Glass","Aluminium","Mesh"]' && (await tabOn(page)) === 'Door' && (await stSel(page)).s === 'pending');
  check('N36 owner sees one department at a time', await refs(page) === 'बही 491 · पन्ना 5' && (await cards(page)).every(x => x.chips[0].cat === 'Door'));
  await tab(page, 'Glass'); await view(page, 'all');
  check('N37 owner switches to Glass and sees Glass cards only', (await cards(page)).length === 2 && (await cards(page)).every(x => x.chips.length === 1 && x.chips[0].cat === 'Glass'));
  await tab(page, 'Door'); await view(page, 'pending');

  // ---- Search within the department --------------------------------------
  await search(page, 'Teak'); check('N38 search by design within Door · Pending', await refs(page) === 'बही 491 · पन्ना 5');
  await search(page, 'Bhola'); check('N39 a Glass customer is not found from the Door register', (await cards(page)).length === 0);
  await search(page, '491'); check('N40 search by book', await refs(page) === 'बही 491 · पन्ना 5');
  await search(page, '5'); check('N41 search by page', await refs(page) === 'बही 491 · पन्ना 5');
  await search(page, '2.5x6.5'); check('N42 search by size, either orientation', await refs(page) === 'बही 491 · पन्ना 5');
  await search(page, ''); check('N43 clearing search restores the register', await refs(page) === 'बही 491 · पन्ना 5');

  // ---- One bill: photo, this department\'s status, unchanged receiving ----
  await page.click('.wbbill[data-book="491"][data-page="5"]'); await page.waitForSelector('.wbif'); await settled(page);
  check('N44 tapping a card opens the bill workspace with the viewer and the department in the title', (await page.evaluate(() => location.hash)) === '#o/491/5' && /billview\?book=491&page=5/.test(await page.$eval('.wbif', e => e.getAttribute('src'))) && /Door/.test(await title(page)));
  check('N45 exactly one status control inside the bill; the department bar is hidden', (await page.$$('.wbst')).length === 1 && await page.$eval('#wbHead', e => e.classList.contains('hide')));
  await shot(page, '5-owner-bill-workspace');
  await page.click('#wbBody .wbrow'); await page.waitForSelector('#don');
  check('N46 the Door line opens the existing receive sheet prefilled with the remaining count', (await page.$eval('#don', e => e.value)) === '2');
  await page.fill('#don', '1'); await page.click('#sheetInner .pri'); await page.waitForTimeout(400); await settled(page);
  check('N47 receiving posts the same line-level receipt as before', receipts.length === 1 && receipts[0].mark_id === 12 && receipts[0].qty === 1 && receipts[0].noted_by === 'Owner' && receipts[0].force === false, receipts);
  const n = events.length;
  check('N48 receiving a door did NOT change the work status', latest('491', 5, 'Door') === 'pending');
  await setStatus(page, '.wbst.big', 'received');
  check('N49 status can be changed from inside the bill', latest('491', 5, 'Door') === 'received' && events.length === n + 1);
  await page.click('#dorders .iconlink'); await page.waitForTimeout(250);
  check('N50 back returns to the Door register (now empty of pending work)', (await page.evaluate(() => location.hash)) === '#o' && (await tabOn(page)) === 'Door' && /कोई Pending ऑर्डर नहीं/.test(await bodyText(page)));
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
  check('N0 no uncaught page errors', errors.length === 0, errors);
  await browser.close(); srv.close();
  console.log('\n' + PASS.length + ' passed, ' + FAIL.length + ' failed — NK Orders (departmental register) verified.');
  process.exit(FAIL.length ? 1 : 0);
})();
