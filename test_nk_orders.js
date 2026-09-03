/*
 * NK Warehouse — Orders (Warehouse Work List v1) browser verification.
 *
 * Drives the REAL index.html in headless Chromium with Project Zero and
 * Supabase replaced by in-test fakes (page.route), and proves what the
 * warehouse relies on:
 *   opens to a FLAT bill list (no books, no page counts, no progress);
 *   default status filter Pending; every card shows customer, category,
 *   status and "बही N · पन्ना M"; date only when the feed has one;
 *   Pending → Received → Delivered through the touch control; the change
 *   is one POST per act, survives a reload, and events only ever grow;
 *   Door and Glass on the same bill stay independent; a Door worker
 *   never sees or touches Glass; owner sees everything; a runtime
 *   category works untouched; search filters the list by customer, book,
 *   page, design and size; line-level Door receiving is unchanged.
 *
 * Usage: NODE_PATH=$(npm root -g) node test_nk_orders.js
 *   (needs the playwright package and a Chromium; the remote sandbox has
 *    both at /opt/pw-browsers/chromium-*\/chrome-linux/chrome)
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
    if (u.pathname === '/billview') return route.fulfill({ status: 200, contentType: 'text/html', body: '<html><body>BILLVIEW ' + u.search + '</body></html>' });
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

async function cards(page) {
  return page.$$eval('#wbBody .wbbill', els => els.map(e => ({
    ref: e.querySelector('.wbref').textContent, cust: e.querySelector('.wbcust').textContent,
    date: e.querySelector('.wbdate') ? e.querySelector('.wbdate').textContent : null,
    chips: Array.from(e.querySelectorAll('.wbst')).map(c => ({ cat: c.dataset.cat || null, st: c.dataset.st || null, txt: c.textContent })) })));
}
const tabs = page => page.$$eval('#wbTabs .wbtab', els => els.map(e => e.dataset.t));
const stOn = page => page.$eval('#wbSt .wbtab.on', e => e.dataset.s);
async function pickStaff(page, name) {
  await page.waitForSelector('#staffBtns .namebtn');
  await page.locator('#staffBtns .namebtn', { hasText: name }).first().click();
  await page.waitForSelector('#add:not(.hide), #dorders:not(.hide)');
}
async function openOrders(page) { await page.click('#doBtn'); await page.waitForSelector('#dorders:not(.hide)'); await settled(page); }
async function settled(page) { await page.waitForFunction(() => { const b = document.getElementById('wbBody'); return b && !/लोड हो रहा/.test(b.textContent); }); await page.waitForTimeout(150); }
async function setStatus(page, chipSel, status) {
  await page.click(chipSel);
  await page.waitForSelector('#wbStOpts .chip');
  const n0 = events.length;
  await page.click('#wbStOpts .chip[data-s="' + status + '"]');
  await page.waitForFunction(n => window.__evn === undefined || true, n0);
  await page.waitForTimeout(400); await settled(page);
}
async function search(page, q) { await page.fill('#wbSearch', q); await page.waitForTimeout(450); }

async function run(page) {
  await page.goto('http://127.0.0.1:' + PORT + '/index.html');

  // ---- Raju: Door only ---------------------------------------------------
  await pickStaff(page, 'Raju');
  await openOrders(page);
  check('N1 the Orders button opens the flat list at #o', await page.evaluate(() => location.hash) === '#o');
  let c = await cards(page);
  check('N2 no books, no page counts, no progress bars', await page.$$eval('#wbBody', els => !/पन्ने|कुल .* ऑर्डर/.test(els[0].textContent)) && (await page.$$('.wbbar')).length === 0);
  check('N3 Raju (Door) sees exactly his two Door bills', c.length === 2 && c.every(x => x.chips.length === 1 && x.chips[0].cat === 'Door'), c);
  check('N4 the Glass-only, Mesh and uncategorised bills are absent for him', !c.some(x => /84|491 · पन्ना 7|492/.test(x.ref)), c);
  check('N5 default status filter is Pending and every chip reads pending', (await stOn(page)) === 'pending' && c.every(x => x.chips[0].st === 'pending' && /बाकी/.test(x.chips[0].txt)));
  check('N6 every card carries the bill reference "बही N · पन्ना M"', c[0].ref === 'बही 490 · पन्ना 83' && c[1].ref === 'बही 491 · पन्ना 5', c);
  check('N7 customer is the primary text; the unnamed bill says so honestly', c[0].cust === 'Amar Traders' && /नाम बिल पर है/.test(c[1].cust), c);
  check('N8 date shown only when the feed has one (never invented)', c[0].date === '20-08-2026' && c[1].date === null, c);
  check('N9 category tabs respect the staff assignment: सभी + Door only', JSON.stringify(await tabs(page)) === '["All","Door"]', await tabs(page));
  check('N10 the Door+Glass bill shows ONLY the Door chip to a Door worker', c[0].chips.length === 1, c[0]);

  // Pending → Received
  await setStatus(page, '.wbbill[data-book="490"][data-page="83"] .wbst[data-cat="Door"]', 'received');
  check('N11 one explicit POST /api/cl/status for Door 490/83 by Raju', events.length === 1 && JSON.stringify(events[0]) === JSON.stringify({ book: '490', page: 83, cat: 'Door', status: 'received', by: 'Raju' }), events);
  c = await cards(page);
  check('N12 under Pending the received bill leaves the list', c.length === 1 && c[0].ref === 'बही 491 · पन्ना 5', c);
  await page.click('#wbSt .wbtab[data-s="received"]'); await page.waitForTimeout(100);
  c = await cards(page);
  check('N13 the Received filter shows it with the chip reading received', c.length === 1 && c[0].chips[0].st === 'received' && /आ गया/.test(c[0].chips[0].txt), c);

  // reload: persists
  await page.reload(); await pickStaff(page, 'Raju'); await page.waitForSelector('#dorders:not(.hide)'); await settled(page);
  check('N14 deep link survives reload and the filter resets to Pending', (await page.evaluate(() => location.hash)) === '#o' && (await stOn(page)) === 'pending');
  c = await cards(page);
  check('N15 the status persisted across reload (490/83 still not pending)', c.length === 1 && c[0].ref === 'बही 491 · पन्ना 5', c);
  await page.click('#wbSt .wbtab[data-s="received"]'); await page.waitForTimeout(100);
  c = await cards(page);
  check('N16 …and reads received after reload', c.length === 1 && c[0].chips[0].st === 'received', c);

  // Received → Delivered
  await setStatus(page, '.wbbill[data-book="490"][data-page="83"] .wbst[data-cat="Door"]', 'delivered');
  check('N17 Received → Delivered appends a second event; the first still stands', events.length === 2 && events[0].status === 'received' && events[1].status === 'delivered', events);
  check('N18 the app only ever POSTs status acts (never PATCH/DELETE)', pzLog.filter(l => /\/api\/cl\/status/.test(l)).every(l => /^(POST|OPTIONS) /.test(l)), pzLog);
  await page.click('#wbSt .wbtab[data-s="delivered"]'); await page.waitForTimeout(100);
  c = await cards(page);
  check('N19 the Delivered filter shows it', c.length === 1 && c[0].chips[0].st === 'delivered' && /दे दिया/.test(c[0].chips[0].txt), c);
  await page.click('#wbSt .wbtab[data-s="all"]'); await page.waitForTimeout(100);
  c = await cards(page);
  check('N20 "सब" shows every status together', c.length === 2, c);

  // ---- Gopal: Glass only — independence ----------------------------------
  await page.click('#dorders .iconlink'); await page.waitForSelector('#add:not(.hide)');
  await page.click('#addBack'); await pickStaff(page, 'Gopal'); await openOrders(page);
  c = await cards(page);
  check('N21 Gopal (Glass) sees his two Glass bills, both pending — Door delivered did not hide his work', c.length === 2 && c.every(x => x.chips.length === 1 && x.chips[0].cat === 'Glass' && x.chips[0].st === 'pending'), c);
  check('N22 tabs for Gopal: सभी + Glass', JSON.stringify(await tabs(page)) === '["All","Glass"]');
  await setStatus(page, '.wbbill[data-book="490"][data-page="83"] .wbst[data-cat="Glass"]', 'received');
  check('N23 Gopal\'s act names Glass, and Door on the same bill is still delivered', events.length === 3 && events[2].cat === 'Glass' && events[2].by === 'Gopal' && latest('490', 83, 'Door') === 'delivered' && latest('490', 83, 'Glass') === 'received', events);

  // ---- Owner: everything ---------------------------------------------------
  await page.click('#dorders .iconlink'); await page.waitForSelector('#add:not(.hide)');
  await page.click('#addBack'); await page.waitForSelector('#gate:not(.hide)');
  await page.click('#gate .linkbtn'); await page.waitForSelector('#pwIn'); await page.fill('#pwIn', 'secret'); await page.click('#pwBtn');
  await page.waitForSelector('#owner:not(.hide)');
  await page.locator('#owner button', { hasText: 'Add stock' }).first().click(); await page.waitForSelector('#add:not(.hide)');
  await openOrders(page);
  check('N24 owner tabs carry every category incl. the runtime one', JSON.stringify(await tabs(page)) === '["All","Door","Glass","Aluminium","Mesh"]', await tabs(page));
  c = await cards(page);
  check('N25 owner, Pending: 490/84, 491/5, 491/7 and the uncategorised 492/1 (490/83 has no pending work)', c.map(x => x.ref).join('|') === 'बही 490 · पन्ना 84|बही 491 · पन्ना 5|बही 491 · पन्ना 7|बही 492 · पन्ना 1', c);
  check('N26 an Order with no category says so instead of inventing a status', c[3].chips.length === 1 && c[3].chips[0].cat === null && /विभाग चुना नहीं/.test(c[3].chips[0].txt), c[3]);
  await page.click('#wbSt .wbtab[data-s="all"]'); await page.waitForTimeout(100);
  c = await cards(page);
  const c83 = c.find(x => x.ref === 'बही 490 · पन्ना 83');
  check('N27 owner sees both departments on 490/83, each with its own status', c83 && c83.chips.map(x => x.cat + ':' + x.st).join(',') === 'Door:delivered,Glass:received', c83);
  await page.click('#wbTabs .wbtab[data-t="Mesh"]'); await page.waitForTimeout(100);
  c = await cards(page);
  check('N28 the runtime category Mesh has its own tab and lists only its bill', c.length === 1 && c[0].ref === 'बही 491 · पन्ना 7' && c[0].chips[0].cat === 'Mesh', c);
  await setStatus(page, '.wbbill[data-book="491"][data-page="7"] .wbst[data-cat="Mesh"]', 'received');
  check('N29 a runtime category takes a status like any other', latest('491', 7, 'Mesh') === 'received');
  await page.click('#wbTabs .wbtab[data-t="All"]'); await page.waitForTimeout(100);

  // ---- Search over the flat list -----------------------------------------
  const refs = async () => (await cards(page)).map(x => x.ref).join('|');
  await search(page, 'Amar'); check('N30 search by customer', await refs() === 'बही 490 · पन्ना 83', await refs());
  await search(page, '490'); check('N31 search by book number', await refs() === 'बही 490 · पन्ना 83|बही 490 · पन्ना 84', await refs());
  await search(page, '84'); check('N32 search by page number', await refs() === 'बही 490 · पन्ना 84', await refs());
  await search(page, 'Teak'); check('N33 search by design', await refs() === 'बही 491 · पन्ना 5', await refs());
  await search(page, '7x3'); check('N34 search by size', await refs() === 'बही 490 · पन्ना 83', await refs());
  await search(page, '3x7'); check('N35 size matches either orientation', await refs() === 'बही 490 · पन्ना 83', await refs());
  await search(page, 'zzz'); check('N36 no match says so', (await cards(page)).length === 0 && /कुछ नहीं मिला/.test(await page.$eval('#wbBody', e => e.textContent)));
  await search(page, ''); check('N37 clearing search restores the list', (await cards(page)).length >= 4);

  // ---- One bill: photo, status, and the unchanged receive flow -----------
  await page.click('#wbSt .wbtab[data-s="pending"]'); await page.waitForTimeout(100);
  await page.click('.wbbill[data-book="491"][data-page="5"]'); await page.waitForSelector('.wbif'); await settled(page);
  check('N38 tapping a card opens the bill workspace with the bill viewer', (await page.evaluate(() => location.hash)) === '#o/491/5' && /billview\?book=491&page=5/.test(await page.$eval('.wbif', e => e.getAttribute('src'))));
  check('N39 the workspace shows the reference and a big status control', /बही 491 · पन्ना 5/.test(await page.$eval('#wbBody', e => e.textContent)) && (await page.$$('.wbst.big[data-cat="Door"]')).length === 1);
  check('N40 category filters are hidden inside a bill, the search stays', await page.$eval('#wbTabs', e => e.classList.contains('hide')) && await page.$eval('#wbSearch', e => !e.classList.contains('hide')));
  await page.click('#wbBody .wbrow'); await page.waitForSelector('#don');
  check('N41 the Door line opens the existing receive sheet prefilled with the remaining count', (await page.$eval('#don', e => e.value)) === '2');
  await page.fill('#don', '1'); await page.click('#sheetInner .pri'); await page.waitForTimeout(400); await settled(page);
  check('N42 receiving posts the same line-level receipt as before (mark_id, qty, noted_by)', receipts.length === 1 && receipts[0].mark_id === 12 && receipts[0].qty === 1 && receipts[0].noted_by === 'Owner' && receipts[0].force === false, receipts);
  check('N43 receiving a door did NOT change the work status (no automatic derivation)', latest('491', 5, 'Door') === 'pending' && events.length === 4);
  await setStatus(page, '.wbst.big[data-cat="Door"]', 'received');
  check('N44 status can be changed from inside the bill too', latest('491', 5, 'Door') === 'received' && events.length === 5);
  await page.click('#dorders .iconlink'); await page.waitForTimeout(200);
  check('N45 back from a bill returns to the flat list', (await page.evaluate(() => location.hash)) === '#o' && (await page.$$('.wbbill')).length >= 1);
}

(async () => {
  const srv = await serve();
  const browser = await chromium.launch({ executablePath: process.env.CHROME || fs.readdirSync('/opt/pw-browsers').filter(d => /^chromium-\d+$/.test(d)).map(d => '/opt/pw-browsers/' + d + '/chrome-linux/chrome').find(fs.existsSync) });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block', isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  page.on('dialog', d => d.accept());
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  await routes(page);
  try { await run(page); } catch (e) { check('run completed without throwing', false, e && e.stack || e); }
  check('N0 no uncaught page errors', errors.length === 0, errors);
  await browser.close(); srv.close();
  console.log('\n' + PASS.length + ' passed, ' + FAIL.length + ' failed — NK Orders (Work List v1) verified.');
  process.exit(FAIL.length ? 1 : 0);
})();
