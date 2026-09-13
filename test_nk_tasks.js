/*
 * NK Warehouse — My Tasks (Phase A) browser verification.
 *
 * Drives the REAL index.html in headless Chromium at a phone viewport
 * (390×844) with Project Zero and Supabase replaced by in-test fakes
 * (page.route). Proves:
 *   the gate keeps the tapped names for Orders and shows a visually separate
 *   "My Tasks" entry; My Tasks asks for the code (Hindi first); a wrong
 *   code is refused; the right code opens the personal list and the only
 *   thing the phone stores is its own opaque token; the list shows Blocked
 *   first, Pending, Done today; Blocked needs a reason and Done needs a
 *   result (each one POST with the token, never a name or an id from the
 *   phone); the warehouse database gets no task row; Orders work WITHOUT a
 *   task login and are unchanged after one (same feed calls, same board);
 *   a 401 throws the phone back to the code screen; Logout clears the token.
 *
 * Usage: NODE_PATH=$(npm root -g) node test_nk_tasks.js
 *   SHOT_DIR=/some/dir saves phone screenshots for a visual check.
 */
const fs = require('fs'), http = require('http'), path = require('path');
const { chromium } = require('playwright');

const PORT = 8796, DIR = __dirname;
const PZ = 'https://project-zero-xafh.onrender.com', SB = 'https://enjlgflisuywkaorxetv.supabase.co';
const PASS = [], FAIL = [];
function check(name, cond, detail) { (cond ? PASS : FAIL).push(name); console.log((cond ? 'PASS ' : 'FAIL ') + name + (cond ? '' : '  -- ' + String(detail === undefined ? '' : (typeof detail === 'string' ? detail : JSON.stringify(detail))).slice(0, 800))); }
const json = (route, obj, status) => route.fulfill({ status: status || 200, contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify(obj) });

const STAFF = [{ id: 1, name: 'Arjun', order_tags: [] }, { id: 2, name: 'Vishal', order_tags: [] }];
const KINDS = [{ id: 1, name: 'Order' }, { id: 2, name: 'Door' }];
const LISTS = [{ id: 1, kind_id: 2, category: 'Door', position: 1, legacy_status: 'pending', name: 'Pending' }, { id: 2, kind_id: 2, category: 'Door', position: 2, legacy_status: 'received', name: 'Received' }, { id: 3, kind_id: 2, category: 'Door', position: 3, legacy_status: 'delivered', name: 'Delivered' }];
const FEED = [{ book_number: '490', page_number: 83, category: 'Door', status: 'pending', list_id: 1, title: 'Sharma ji', img: 'book1/p83.jpg', customer: 'Amar Traders', tagged_at: '2026-09-01T10:00:00Z' }];

// the stand-in Project Zero work service: one code, one token, three tasks
const WORK = { code: 'ABCD2345', token: null, revoked: false, acts: [], log: [], sbWrites: [] };
const TASKS = [
  { id: 11, instruction: 'Amar ji से ₹12,500 लेकर आना', employee_id: 'e-arjun', due_on: '2026-09-15', ref_type: 'customer', ref_id: 'Amar Traders', created_at: '2026-09-13T04:00:00Z', created_by: 'Shanky', state: 'pending', note: null, state_at: '2026-09-13T04:00:00Z', state_by: 'Shanky', employee_name: 'Arjun', ref_label: 'Amar Traders' },
  { id: 12, instruction: 'बिल 490/83 के दरवाज़े पहुँचाना', employee_id: 'e-arjun', due_on: null, ref_type: 'bill_page', ref_id: '490/83', created_at: '2026-09-13T04:01:00Z', created_by: 'Shanky', state: 'blocked', note: 'गाड़ी नहीं मिली', state_at: '2026-09-13T05:00:00Z', state_by: 'Arjun', employee_name: 'Arjun', ref_label: 'बिल बुक 490 · पेज 83' },
  { id: 13, instruction: 'चाबी वापस देना', employee_id: 'e-arjun', due_on: null, ref_type: null, ref_id: null, created_at: '2026-09-12T04:00:00Z', created_by: 'Shanky', state: 'done', note: 'दे दी', state_at: '2026-09-13T06:00:00Z', state_by: 'Arjun', employee_name: 'Arjun', ref_label: null },
];
function authed(req) { const a = req.headers()['authorization'] || ''; return !WORK.revoked && WORK.token && a === 'Bearer ' + WORK.token; }

async function routes(page) {
  await page.route(PZ + '/**', async route => {
    const req = route.request(), u = new URL(req.url()), m = req.method();
    WORK.log.push(m + ' ' + u.pathname + u.search);
    if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS', 'Access-Control-Allow-Headers': 'Authorization, Content-Type' } });
    if (u.pathname === '/api/bbk/img') return route.fulfill({ status: 200, contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="60" height="80"><rect width="60" height="80" fill="#fdf6e3"/></svg>' });
    if (u.pathname === '/api/cl/work') return json(route, FEED);
    if (u.pathname === '/api/cl/lists') return json(route, LISTS);
    if (u.pathname === '/api/cl/orders') return json(route, []);
    if (u.pathname === '/api/cl/tags') return json(route, KINDS);
    if (u.pathname === '/api/cl/tagged') return json(route, []);
    if (u.pathname === '/api/version') return json(route, { commit: 'test' });
    if (u.pathname === '/api/work/activate' && m === 'POST') {
      const b = req.postDataJSON(); const code = String(b.code || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
      if (code !== WORK.code) return json(route, { ok: false, error: 'invalid' }, 401);
      if (WORK.token) return json(route, { ok: false, error: 'used' }, 401);
      WORK.token = 'tok-' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
      return json(route, { ok: true, token: WORK.token, name: 'Arjun', superseded: false });
    }
    if (u.pathname.startsWith('/api/work/')) {
      if (!authed(req)) return json(route, { ok: false, error: 'unauthorised' }, 401);
      if (u.pathname === '/api/work/tasks') return json(route, { ok: true, today: '2026-09-13', name: 'Arjun', tasks: TASKS.filter(t => t.state !== 'withdrawn').sort((a, b) => ({ blocked: 0, pending: 1, done: 2 }[a.state] - { blocked: 0, pending: 1, done: 2 }[b.state])) });
      if (u.pathname === '/api/work/task') {
        const t = TASKS.find(x => x.id === Number(u.searchParams.get('id'))); if (!t) return json(route, { ok: false, error: 'no such task' }, 404);
        const ref = t.ref_type === 'customer' ? { type: 'customer', id: t.ref_id, found: true, data: { id: t.ref_id, name: 'Amar ji', tally_name: 'Amar Traders', phone: '9876500001', outstanding: 13000, address: 'Katra Bazar' } }
          : t.ref_type === 'bill_page' ? { type: 'bill_page', id: t.ref_id, found: true, data: { id: '490/83', label: 'बिल बुक 490 · पेज 83', img: '/api/bbk/img?p=book1%2Fp83.jpg', title: 'Sharma ji', party: 'Amar Traders' } } : null;
        return json(route, { ok: true, task: Object.assign({}, t, { reference: ref, evidence: [], acts: [{ act: 'created', by: 'Shanky', at: t.created_at, note: null }] }) });
      }
      if ((u.pathname === '/api/work/task/blocked' || u.pathname === '/api/work/task/done') && m === 'POST') {
        const b = req.postDataJSON(); WORK.acts.push({ path: u.pathname, body: b, headers: req.headers() });
        if (!b.note) return json(route, { ok: false, error: 'reason needed' }, 400);
        const t = TASKS.find(x => x.id === Number(b.task_id)); t.state = u.pathname.endsWith('blocked') ? 'blocked' : 'done'; t.note = b.note;
        return json(route, { ok: true });
      }
      if (u.pathname === '/api/work/logout' && m === 'POST') { WORK.token = null; return json(route, { ok: true }); }
    }
    return json(route, { error: 'not found' }, 404);
  });
  await page.route(SB + '/**', async route => {
    const req = route.request(), u = new URL(req.url()), m = req.method();
    if (m !== 'GET' && m !== 'OPTIONS') WORK.sbWrites.push(m + ' ' + u.pathname);
    if (u.pathname === '/rest/v1/nkg_staff' && m === 'GET') return json(route, STAFF);
    if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*' } });
    return json(route, [], 200);
  });
}
async function shot(page, nm) { if (process.env.SHOT_DIR) await page.screenshot({ path: path.join(process.env.SHOT_DIR, nm + '.png'), fullPage: true }); }
const vis = (page, sel) => page.isVisible(sel).catch(() => false);

(async () => {
  const srv = http.createServer((q, r) => { const f = path.join(DIR, q.url.split('?')[0] === '/' ? 'index.html' : q.url.split('?')[0]); fs.readFile(f, (e, d) => { if (e) { r.writeHead(404); return r.end(); } r.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html' : 'application/octet-stream' }); r.end(d); }); });
  await new Promise(res => srv.listen(PORT, '127.0.0.1', res));
  const browser = await chromium.launch({ executablePath: process.env.CHROME || fs.readdirSync('/opt/pw-browsers').filter(d => /^chromium-\d+$/.test(d)).map(d => '/opt/pw-browsers/' + d + '/chrome-linux/chrome').find(fs.existsSync) });
  try {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2, serviceWorkers: 'block' });
    const page = await ctx.newPage(); page.errors = []; page.on('pageerror', e => page.errors.push(String(e))); page.on('dialog', d => d.accept());
    await routes(page);
    await page.goto('http://127.0.0.1:' + PORT + '/', { waitUntil: 'networkidle' });
    await page.waitForSelector('#staffBtns .namebtn');
    check('N1 the gate still offers the tapped names for Orders, plus a separate My Tasks entry',
      (await page.$$('#staffBtns .namebtn')).length === 2 && await vis(page, '#myTasksBtn') && /मेरा काम/.test(await page.textContent('#myTasksBtn')) && /अलग सिस्टम/.test(await page.textContent('#myTasksBtn')));
    await shot(page, 'nk-tasks-01-gate');

    // Orders without any task login
    await page.click('#staffBtns .namebtn >> text=Arjun'); await page.waitForSelector('#add:not(.hide)');
    await page.click('#doBtn'); await page.waitForSelector('#dorders:not(.hide)'); await page.waitForTimeout(500);
    const ordersBefore = WORK.log.filter(l => l.includes('/api/cl/')).map(l => l.split('?')[0]).sort();
    check('N2 Orders open with the tapped name and NO task login (no /api/work call, feed calls as before)',
      ordersBefore.length >= 3 && !WORK.log.some(l => l.includes('/api/work/')) && (await page.textContent('#dorders')).includes('Sharma ji'), WORK.log);
    await page.click('#dorders .top .iconlink >> nth=0'); await page.waitForTimeout(200); await page.click('#addBack'); await page.waitForSelector('#gate:not(.hide)');

    // My Tasks
    await page.click('#myTasksBtn'); await page.waitForSelector('#mytasks:not(.hide)');
    check('N3 My Tasks opens its own screen with a "personal · separate from Orders" band and the code prompt (Hindi first)',
      await vis(page, '#mtCode') && /ऑर्डर बोर्ड नहीं/.test(await page.textContent('.mtband')) && /Shanky जी ने जो कोड दिया है/.test(await page.textContent('#mtCode')) && /Enter the code Shanky gave you/.test(await page.textContent('#mtCode')));
    await shot(page, 'nk-tasks-02-code');
    await page.fill('#mtCodeIn', 'WRONG123'); await page.click('#mtCodeBtn'); await page.waitForTimeout(300);
    check('N4 a wrong code is refused with a plain message', /कोड गलत है/.test(await page.textContent('#mtCodeErr')) && await vis(page, '#mtCode'));
    await page.fill('#mtCodeIn', 'abcd 2345'); await page.click('#mtCodeBtn'); await page.waitForSelector('#mtList:not(.hide)'); await page.waitForTimeout(200);
    check('N5 the right code opens the personal list as Arjun', (await page.textContent('#mtName')).trim() === 'Arjun' && await vis(page, '#mtLogout'));
    const ls = await page.evaluate(() => Object.assign({}, localStorage));
    check('N6 the phone stores only its opaque token for tasks (nkg_work_token), nothing else task-related',
      ls.nkg_work_token === WORK.token && !Object.keys(ls).some(k => /task|code|employee/i.test(k)), Object.keys(ls));
    const secs = await page.$$eval('#mtItems .mtsec', els => els.map(e => e.textContent));
    check('N7 the list shows Blocked first (with reason), then To do, then Done today',
      secs.length === 3 && /अटका हुआ/.test(secs[0]) && /करना है/.test(secs[1]) && /आज पूरा/.test(secs[2]) && (await page.textContent('#mtItems .mttask.blocked .note')).includes('गाड़ी'), secs);
    await shot(page, 'nk-tasks-03-list');

    // Done with a result
    await page.click('#mtItems [data-task="11"]'); await page.waitForSelector('#mtDetail:not(.hide)');
    check('N8 the detail shows the live customer reference (name, outstanding, tap-to-call) and big Done / Blocked actions',
      (await page.textContent('#mtDetail')).includes('Amar ji') && (await page.textContent('#mtDetail')).includes('13,000') && await page.$eval('#mtDetail a[href^="tel:"]', a => a.getAttribute('href')) === 'tel:9876500001' && await vis(page, '#mtDoneBtn') && await vis(page, '#mtBlockBtn'));
    await shot(page, 'nk-tasks-04-detail');
    await page.click('#mtDoneBtn'); await page.click('#mtSend'); await page.waitForTimeout(200);
    check('N9 Done without a result is refused on the phone (no request sent)', /नतीजा लिखें/.test(await page.textContent('#mtFErr')) && WORK.acts.length === 0);
    await page.fill('#mtNote', '₹12,500 मिल गए'); await page.click('#mtSend'); await page.waitForSelector('#mtList:not(.hide)'); await page.waitForTimeout(200);
    check('N10 Done sends ONE act with the token and only task_id + note (no name, no employee id from the phone)',
      WORK.acts.length === 1 && WORK.acts[0].path === '/api/work/task/done' && Object.keys(WORK.acts[0].body).sort().join() === 'note,task_id' && WORK.acts[0].headers['authorization'] === 'Bearer ' + WORK.token, WORK.acts);
    check('N11 the list now shows two Done today and one Blocked', (await page.$$('#mtItems .mttask.done')).length === 2 && (await page.$$('#mtItems .mttask.blocked')).length === 1);

    // Blocked path from a fresh pending task
    TASKS.push({ id: 14, instruction: 'नया काम', employee_id: 'e-arjun', due_on: null, ref_type: null, ref_id: null, created_at: '2026-09-13T07:00:00Z', created_by: 'Shanky', state: 'pending', note: null, state_at: '2026-09-13T07:00:00Z', state_by: 'Shanky', employee_name: 'Arjun', ref_label: null });
    await page.click('#mtRefresh'); await page.waitForTimeout(300);
    await page.click('#mtItems [data-task="14"]'); await page.waitForSelector('#mtDetail:not(.hide)');
    await page.click('#mtBlockBtn'); await page.fill('#mtNote', 'सामान नहीं आया'); await page.click('#mtSend'); await page.waitForSelector('#mtList:not(.hide)'); await page.waitForTimeout(200);
    check('N12 Blocked with a reason is one act; the task moves to the Blocked section', WORK.acts.length === 2 && WORK.acts[1].body.note === 'सामान नहीं आया' && (await page.$$('#mtItems .mttask.blocked')).length === 2);

    // separation: Orders after a task login, unchanged
    await page.click('#mytasks .top .iconlink >> nth=0'); await page.waitForSelector('#gate:not(.hide)');
    const before = WORK.log.length;
    await page.click('#staffBtns .namebtn >> text=Arjun'); await page.waitForSelector('#add:not(.hide)');
    await page.click('#doBtn'); await page.waitForSelector('#dorders:not(.hide)'); await page.waitForTimeout(500);
    const ordersAfter = WORK.log.slice(before).filter(l => l.includes('/api/cl/')).map(l => l.split('?')[0]).sort();
    check('N13 Orders after a task login make the same feed calls and show the same board; no /api/work call, no token sent to Orders',
      JSON.stringify(ordersAfter) === JSON.stringify(ordersBefore) && !WORK.log.slice(before).some(l => l.includes('/api/work/')) && (await page.textContent('#dorders')).includes('Sharma ji'), [ordersBefore, ordersAfter]);
    check('N14 the warehouse database received no task write (no nkg_* POST/PATCH at all)', WORK.sbWrites.length === 0, WORK.sbWrites);
    await shot(page, 'nk-tasks-05-orders-unchanged');

    // revoked -> code screen; logout clears
    await page.click('#dorders .top .iconlink >> nth=0'); await page.waitForTimeout(200); await page.click('#addBack'); await page.waitForSelector('#gate:not(.hide)');
    WORK.revoked = true;
    await page.click('#myTasksBtn'); await page.waitForSelector('#mtCode:not(.hide)');
    check('N15 a revoked phone (401) is thrown back to the code screen, token cleared, no task text left on screen',
      /पहुँच बंद है/.test(await page.textContent('#mtCodeErr')) && (await page.evaluate(() => localStorage.getItem('nkg_work_token'))) === null && !(await page.textContent('#mytasks')).includes('Amar ji'));
    WORK.revoked = false; WORK.token = null; WORK.code = 'EFGH6789';
    await page.fill('#mtCodeIn', 'EFGH6789'); await page.click('#mtCodeBtn'); await page.waitForSelector('#mtList:not(.hide)');
    await page.click('#mtLogout'); await page.waitForSelector('#mtCode:not(.hide)');
    check('N16 Logout posts to the server and clears the token', WORK.token === null && (await page.evaluate(() => localStorage.getItem('nkg_work_token'))) === null && /लॉग आउट/.test(await page.textContent('#mtCodeErr')));
    check('N17 no page error', page.errors.length === 0, page.errors);
  } finally { await browser.close(); srv.close(); }
  console.log('\n%d passed, %d failed — NK My Tasks (Phase A) verified.', PASS.length, FAIL.length);
  process.exit(FAIL.length ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
