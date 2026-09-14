/*
 * NK Warehouse — My Team Today for an authorised head, beside My Tasks.
 *
 * Drives the REAL index.html in headless Chromium at 390×844. Project Zero is
 * not stubbed here: every /api/work/* call is FORWARDED to the real server
 * running on its stand-in database (../project-zero/serve_fake.py on 8802), so
 * the permission and presence rules under test are the production ones.
 * Supabase (the warehouse's own database) stays a stub, and every write it
 * receives is recorded — there must be none.
 *
 *   NODE_PATH=$(npm root -g) node test_nk_team.js
 *   SHOT_DIR=/some/dir saves phone screenshots.
 */
const fs = require('fs'), http = require('http'), path = require('path'), { spawn } = require('child_process');
const { chromium } = require('playwright');

const PORT = 8792, PZPORT = 8802, DIR = __dirname;
const PZ_DIR = process.env.PZ_DIR || path.join(DIR, '..', 'project-zero');
const PZ = 'https://project-zero-xafh.onrender.com', SB = 'https://enjlgflisuywkaorxetv.supabase.co';
const OWNER = 'owner.test.token';
const PASS = [], FAIL = [];
function check(name, cond, detail) { (cond ? PASS : FAIL).push(name); console.log((cond ? 'PASS ' : 'FAIL ') + name + (cond ? '' : '  -- ' + String(detail === undefined ? '' : (typeof detail === 'string' ? detail : JSON.stringify(detail))).slice(0, 400))); }
const json = (route, obj, status) => route.fulfill({ status: status || 200, contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify(obj) });
function pzReq(method, p, token, body) {
  return new Promise((res, rej) => {
    const data = body == null ? null : Buffer.from(JSON.stringify(body));
    const r = http.request({ host: '127.0.0.1', port: PZPORT, path: p, method, headers: Object.assign({}, token ? { Authorization: 'Bearer ' + token } : {}, data ? { 'Content-Type': 'application/json', 'Content-Length': data.length } : {}) },
      x => { let b = ''; x.on('data', d => b += d); x.on('end', () => { let j = null; try { j = JSON.parse(b); } catch (e) {} res({ status: x.statusCode, json: j }); }); });
    r.on('error', rej); if (data) r.write(data); r.end();
  });
}
const rows = t => pzReq('GET', '/__rows?table=' + t).then(r => r.json || []);
async function shot(page, nm) { if (process.env.SHOT_DIR) await page.screenshot({ path: path.join(process.env.SHOT_DIR, nm + '.png'), fullPage: true }); }
const vis = (page, sel) => page.isVisible(sel).catch(() => false);

const STAFF = [{ id: 1, name: 'Arjun', order_tags: [] }, { id: 2, name: 'Vishal', order_tags: [] }];
const KINDS = [{ id: 1, name: 'Order' }, { id: 2, name: 'Door' }];
const LISTS = [{ id: 1, kind_id: 2, category: 'Door', position: 1, legacy_status: 'pending', name: 'Pending' }];
const FEED = [{ book_number: '490', page_number: 83, category: 'Door', status: 'pending', list_id: 1, title: 'Sharma ji', img: 'book1/p83.jpg', customer: 'Amar Traders', tagged_at: '2026-09-01T10:00:00Z' }];

async function routes(page, log, sbWrites) {
  await page.route(PZ + '/**', async route => {
    const rq = route.request(), u = new URL(rq.url()), m = rq.method();
    log.push(m + ' ' + u.pathname);
    if (u.pathname === '/api/bbk/img') return route.fulfill({ status: 200, contentType: 'image/svg+xml', headers: { 'Access-Control-Allow-Origin': '*' }, body: '<svg xmlns="http://www.w3.org/2000/svg" width="60" height="80"><rect width="60" height="80" fill="#fdf6e3"/></svg>' });
    if (u.pathname === '/api/cl/work') return json(route, FEED);
    if (u.pathname === '/api/cl/lists') return json(route, LISTS);
    if (u.pathname === '/api/cl/orders' || u.pathname === '/api/cl/tagged') return json(route, []);
    if (u.pathname === '/api/cl/tags') return json(route, KINDS);
    if (u.pathname === '/api/version') return json(route, { commit: 'test' });
    if (!u.pathname.startsWith('/api/work/')) return json(route, { error: 'not found' }, 404);
    // forward the real thing
    const data = rq.postDataBuffer();
    const hdr = {};
    if (rq.headers()['authorization']) hdr['Authorization'] = rq.headers()['authorization'];
    if (data) { hdr['Content-Type'] = rq.headers()['content-type'] || 'application/json'; hdr['Content-Length'] = data.length; }
    const res = await new Promise((ok, bad) => {
      const r = http.request({ host: '127.0.0.1', port: PZPORT, path: u.pathname + u.search, method: m, headers: hdr }, x => {
        const c = []; x.on('data', d => c.push(d)); x.on('end', () => ok({ status: x.statusCode, type: x.headers['content-type'] || 'application/json', body: Buffer.concat(c) }));
      }); r.on('error', bad); if (data) r.write(data); r.end();
    });
    return route.fulfill({ status: res.status, contentType: res.type,
      headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS' },
      body: res.body });
  });
  await page.route(SB + '/**', async route => {
    const rq = route.request(), u = new URL(rq.url()), m = rq.method();
    if (m !== 'GET' && m !== 'OPTIONS') sbWrites.push(m + ' ' + u.pathname);
    if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*' } });
    if (u.pathname === '/rest/v1/nkg_staff') return json(route, STAFF);
    return json(route, []);
  });
}

(async () => {
  const pz = spawn('python3', ['serve_fake.py', String(PZPORT)], { cwd: PZ_DIR, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(res => pz.stdout.on('data', d => { if (String(d).includes('serve_fake on')) res(); }));
  const srv = http.createServer((q, r) => { const f = path.join(DIR, q.url.split('?')[0] === '/' ? 'index.html' : q.url.split('?')[0]); fs.readFile(f, (e, d) => { if (e) { r.writeHead(404); return r.end(); } r.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html' : 'application/octet-stream' }); r.end(d); }); });
  await new Promise(res => srv.listen(PORT, '127.0.0.1', res));
  const browser = await chromium.launch({ executablePath: process.env.CHROME || fs.readdirSync('/opt/pw-browsers').filter(d => /^chromium-\d+$/.test(d)).map(d => '/opt/pw-browsers/' + d + '/chrome-linux/chrome').find(fs.existsSync) });
  try {
    await pzReq('GET', '/__reset');
    const emps = (await pzReq('GET', '/api/work/owner/employees', OWNER)).json.employees;
    const ID = {}; emps.forEach(e => ID[e.name] = e.id);
    const T = (await pzReq('POST', '/api/work/owner/team', OWNER, { action: 'create', name: 'Workshop' })).json.team_id;
    for (const n of ['Arjun', 'Vishal']) await pzReq('POST', '/api/work/owner/team/member', OWNER, { team_id: T, employee_id: ID[n], role: 'member', act: 'added' });
    await pzReq('POST', '/api/work/owner/team/member', OWNER, { team_id: T, employee_id: ID.Vishal, role: 'head', act: 'added' });
    const codeHead = (await pzReq('POST', '/api/work/owner/access/issue', OWNER, { employee_id: ID.Vishal })).json.code;
    const codePlain = (await pzReq('POST', '/api/work/owner/access/issue', OWNER, { employee_id: ID.Arjun })).json.code;

    async function open(code) {
      const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2, serviceWorkers: 'block' });
      const page = await ctx.newPage(); page.errors = []; page.on('pageerror', e => page.errors.push(String(e)));
      page.on('dialog', d => d.accept());
      page.log = []; page.sbWrites = [];
      await routes(page, page.log, page.sbWrites);
      await page.goto('http://127.0.0.1:' + PORT + '/', { waitUntil: 'networkidle' });
      await page.waitForSelector('#staffBtns .namebtn');
      if (code) {
        await page.click('#myTasksBtn'); await page.waitForSelector('#mtCode:not(.hide)');
        await page.fill('#mtCodeIn', code); await page.click('#mtCodeBtn');
        await page.waitForSelector('#mtList:not(.hide)', { timeout: 8000 }); await page.waitForTimeout(400);
      }
      return page;
    }

    // ---- Orders, with no personal login at all ---------------------------
    const plainOrders = await open(null);
    await plainOrders.click('#staffBtns .namebtn >> text=Arjun'); await plainOrders.waitForSelector('#add:not(.hide)');
    await plainOrders.click('#doBtn'); await plainOrders.waitForSelector('#dorders:not(.hide)'); await plainOrders.waitForTimeout(500);
    const before = plainOrders.log.filter(l => l.includes('/api/cl/')).sort().join('|');
    check('K1 Orders open with the tapped name and no personal login at all',
      (await plainOrders.textContent('#dorders')).includes('Sharma ji') && !plainOrders.log.some(l => l.includes('/api/work/')), plainOrders.log);

    // ---- an ordinary employee --------------------------------------------
    const plain = await open(codePlain);
    check('K2 an ordinary employee sees My Tasks and no team tab',
      !(await vis(plain, '#mtTabs')) && (await plain.textContent('#mtName')).trim() === 'Arjun');
    await shot(plain, 'nk-team-01-employee');

    // ---- the head ---------------------------------------------------------
    const head = await open(codeHead);
    check('K3 a head gets a My Team tab beside My Tasks', await vis(head, '#mtTabs') && (await head.$$('#mtTabs button')).length === 2);
    await head.click('#mtTabs button >> nth=1'); await head.waitForSelector('#mtTeam:not(.hide)'); await head.waitForTimeout(300);
    const names = await head.$$eval('#mtTeamList .mtmrow .mn b', els => els.map(e => e.textContent.trim()));
    check('K4 My Team lists only that team, straight from Project Zero', names.sort().join(',') === 'Arjun,Vishal', names);
    await shot(head, 'nk-team-02-roster');
    await head.click('.mtmrow[data-emp="' + ID.Arjun + '"]'); await head.waitForSelector('#sheet.on');
    await head.click('#sheetInner .pri');
    await head.waitForFunction((id) => document.querySelector('.mtmrow[data-emp="' + id + '"] .mtst').textContent.trim() === 'आ गया', ID.Arjun, { timeout: 8000 });
    check('K5 one tap records one arrival on the server',
      (await rows('pz_presence_event')).filter(e => e.kind === 'arrived').length === 1);
    await head.click('.mtmrow[data-emp="' + ID.Vishal + '"]'); await head.waitForSelector('#sheet.on');
    await head.click('#sheetInner .pri');
    await head.waitForFunction((id) => document.querySelector('.mtmrow[data-emp="' + id + '"] .mtst').textContent.trim() === 'आ गया', ID.Vishal, { timeout: 8000 });
    await head.click('#mtTeamBatch button[data-batch="lunch_started"]'); await head.waitForSelector('#sheetInner .mtpickrow');
    const boxes = await head.$$eval('#sheetInner .mtpickrow input', els => els.map(e => e.checked));
    await head.uncheck('#sheetInner input[data-mtpick="' + ID.Arjun + '"]');
    await head.click('#mtBGo');
    await head.waitForFunction((id) => !document.getElementById('sheet').classList.contains('on')
      && document.querySelector('.mtmrow[data-emp="' + id + '"] .mtst').textContent.trim() === 'खाने पर', ID.Vishal, { timeout: 8000 });
    const lunches = (await rows('pz_presence_event')).filter(e => e.kind === 'lunch_started');
    check('K6 a batch preselects both eligible people, and the unticked one is left alone',
      boxes.length === 2 && boxes.every(Boolean) && lunches.length === 1
      && String(lunches[0].employee_id) === ID.Vishal
      && (await head.$eval('.mtmrow[data-emp="' + ID.Arjun + '"] .mtst', e => e.textContent.trim())) === 'आ गया',
      [boxes, lunches.length]);
    await head.click('#mtTeam .pri'); await head.waitForSelector('#mtFinal:not(.hide)'); await head.waitForTimeout(300);
    check('K7 the finalise screen warns that salary is affected',
      (await head.textContent('.mtwarn')).includes('तनख़्वाह'));
    await head.click('#mtFinal button[data-emp="' + ID.Arjun + '"][data-st="Present"]');
    await head.waitForFunction((id) => document.querySelector('#mtFinal button[data-emp="' + id + '"][data-st="Present"]').classList.contains('on'), ID.Arjun, { timeout: 8000 });
    const att = await rows('staff_attendance');
    check('K8 official attendance is written by the server, with its audit act',
      att.length === 1 && att[0].device === 'pz-server' && (await rows('pz_attendance_act')).length === 1, att);
    await shot(head, 'nk-team-03-finalise');

    // ---- Orders are untouched by any of it --------------------------------
    await head.click('#mytasks .top .iconlink >> nth=0'); await head.waitForSelector('#gate:not(.hide)');
    const mark = head.log.length;
    await head.click('#staffBtns .namebtn >> text=Vishal'); await head.waitForSelector('#add:not(.hide)');
    await head.click('#doBtn'); await head.waitForSelector('#dorders:not(.hide)'); await head.waitForTimeout(500);
    const after = head.log.slice(mark).filter(l => l.includes('/api/cl/')).sort().join('|');
    check('K9 Orders after a head has been marking make the same calls and show the same board',
      after === before && (await head.textContent('#dorders')).includes('Sharma ji'), [before, after]);
    check('K10 no team action wrote anything to the warehouse database',
      head.sbWrites.length === 0 && plain.sbWrites.length === 0, [head.sbWrites, plain.sbWrites]);
    check('K11 no Orders, stock or receipt route was called by a team action',
      !head.log.some(l => l.includes('/api/cl/receipt') || l.includes('/api/cl/move') || l.includes('/api/cl/status')), head.log.filter(l => l.includes('/api/cl/')));
    check('K12 no page error on any phone', head.errors.length === 0 && plain.errors.length === 0 && plainOrders.errors.length === 0,
      [head.errors, plain.errors, plainOrders.errors]);
  } finally { await browser.close(); srv.close(); pz.kill(); }
  console.log('\n%d passed, %d failed — NK My Team verified.', PASS.length, FAIL.length);
  process.exit(FAIL.length ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
