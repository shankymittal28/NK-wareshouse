// Owner Warehouse Preview — real-browser test (Stage 1A + Stage 1B).
//
// This proves the owner-only, read-only preview in a real Chromium, with the
// Supabase calls route-mocked. It covers both the shipped behaviour (flag off
// leaves the app untouched) and the Stage 1B inspection tools: category chips,
// multi-word search, the single "Show" filter, sorting, the honest
// negative-quantity indicator, and review tap-throughs into the trail.
//
// It is a manual/local test: the repo's CI (warehouse.yml) only runs the SQL
// suite on warehouse/** changes and does not cover the web layer. Run it after
// any change to the preview in index.html.
//
//   How to run (Node 18+ and a Chromium available):
//     npm i -D playwright-core          # or point PLAYWRIGHT_CORE at an install
//     node test/wh_preview_web.cjs
//
//   Environment overrides (all optional):
//     PLAYWRIGHT_CORE   path to a playwright-core module folder
//     CHROMIUM_EXE      path to a chromium/chrome executable
//
// It writes nothing to any server and calls only the three owner READ rpcs.

const fs = require('fs');
const os = require('os');
const path = require('path');

// ---- locate playwright-core across the likely install spots ----
function loadPlaywright() {
  const tries = [
    process.env.PLAYWRIGHT_CORE,
    'playwright-core',
    'playwright',
    path.join(__dirname, '..', 'node_modules', 'playwright-core'),
    '/tmp/node_modules/playwright-core',
  ].filter(Boolean);
  for (const t of tries) {
    try { return require(t); } catch (e) { /* keep trying */ }
  }
  console.error('Could not load playwright-core. Set PLAYWRIGHT_CORE or `npm i -D playwright-core`.');
  process.exit(2);
}
const { chromium } = loadPlaywright();

// ---- locate a Chromium executable ----
function findExe() {
  if (process.env.CHROMIUM_EXE && fs.existsSync(process.env.CHROMIUM_EXE)) return process.env.CHROMIUM_EXE;
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers';
  try {
    for (const d of fs.readdirSync(base)) {
      if (/^chromium-\d+$/.test(d)) {
        const p = path.join(base, d, 'chrome-linux', 'chrome');
        if (fs.existsSync(p)) return p;
      }
    }
  } catch (e) { /* fall through */ }
  return undefined; // let playwright use its own resolution
}
const EXE = findExe();

// ---- build the two page variants from the real index.html ----
const SRC = path.join(__dirname, '..', 'index.html');
const raw = fs.readFileSync(SRC, 'utf8');
if (!/const WAREHOUSE_PREVIEW=/.test(raw)) {
  console.error('WAREHOUSE_PREVIEW flag not found in index.html — test needs updating.');
  process.exit(2);
}
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'whprev-'));
const offFile = path.join(tmp, 'index_off.html');
const onFile = path.join(tmp, 'index_on.html');
fs.writeFileSync(offFile, raw.replace(/const WAREHOUSE_PREVIEW=true;/, 'const WAREHOUSE_PREVIEW=false;'));
fs.writeFileSync(onFile, raw.replace(/const WAREHOUSE_PREVIEW=false;/, 'const WAREHOUSE_PREVIEW=true;'));
const off = 'file://' + offFile;
const on = 'file://' + onFile;

// ---- rich mock payloads: several categories, edge cases for every filter ----
// material_id 'aaaa...' also appears in REV.possible_same_material, so the
// look-alike filter and pill have something real to match against.
const CAT = { materials: [
  { material_id:'aaaaaaaa-0000-0000-0000-000000000001', category_code:'Plywood', name:'Century · 18mm · 8x4', unit_code:'sheet', decimals:0, origin:'legacy_import', identity_incomplete:false, legacy_expected_qty:73, has_opening:false, recorded_qty:null, rate:1250, indicative_value:91250 },
  { material_id:'bbbbbbbb-0000-0000-0000-000000000002', category_code:'Plywood', name:'Greenply · 12mm · 8x4', unit_code:'sheet', decimals:0, origin:'legacy_import', identity_incomplete:false, legacy_expected_qty:5, has_opening:false, recorded_qty:null, rate:900, indicative_value:4500 },
  { material_id:'cccccccc-0000-0000-0000-000000000003', category_code:'Doors', name:'(not recorded) · Membrane · 80x42', unit_code:'piece', decimals:0, origin:'legacy_import', identity_incomplete:true, legacy_expected_qty:7, has_opening:false, recorded_qty:null, rate:null, indicative_value:null },
  { material_id:'dddddddd-0000-0000-0000-000000000004', category_code:'Doors', name:'Flush · Teak · 84x36', unit_code:'piece', decimals:0, origin:'legacy_import', identity_incomplete:false, legacy_expected_qty:-4, has_opening:false, recorded_qty:null, rate:2100, indicative_value:null },
  { material_id:'eeeeeeee-0000-0000-0000-000000000005', category_code:'Hardware', name:'Hinges · Steel · 4inch', unit_code:'box', decimals:0, origin:'legacy_import', identity_incomplete:false, legacy_expected_qty:40, has_opening:true, recorded_qty:38, rate:null, indicative_value:null },
], coverage:{ rated_value:0, rated_materials:0, stocked_materials:0, materials_without_opening:4 },
   totals:{ materials:5, rated:3, with_opening:1, categories:3 } };

const REV = { possible_same_material: [
  { group_id:'g1', category_code:'Plywood', material_id:'aaaaaaaa-0000-0000-0000-000000000001', material_name:'Century 18mm 8x4', legacy_expectation:73, legacy_lines:10, recorded_by:'Raj' },
  { group_id:'g1', category_code:'Plywood', material_id:'ffffffff-0000-0000-0000-000000000009', material_name:'CENTURY-18MM-8X4', legacy_expectation:0, legacy_lines:2, recorded_by:'Suresh' },
], incomplete_identity: [
  { material_id:'cccccccc-0000-0000-0000-000000000003', material_name:'(not recorded) · Membrane · 80x42', category_code:'Doors', missing_attrs:['variety'], legacy_lines:3, legacy_expectation:7, recorded_by:'Raj' },
], valuation_coverage:[] };

const TRAIL = [
  { kind:'legacy', at:'2026-08-01T10:00:00Z', delta:10, running:0, label:'Ricemill1', detail:{ recorded_by_name:'Raj', photos:2, suspect_duplicate:false }, event_id:null, counts:false },
  { kind:'legacy', at:'2026-08-05T10:00:00Z', delta:-3, running:0, label:'Walk-in', detail:{ recorded_by_name:'Suresh', photos:0, suspect_duplicate:true }, event_id:null, counts:false },
];

function j(o){ return { status:200, contentType:'application/json', body:JSON.stringify(o) }; }

(async () => {
  const browser = await chromium.launch(EXE ? { executablePath: EXE } : {});
  let fail = 0;
  const say = (n,c) => { console.log((c?'PASS ':'FAIL ')+n); if(!c) fail++; };
  const body = p => p.$eval('#whBody', e => e.innerText);

  // ================= TEST 1: flag OFF (shipped) — app unchanged =================
  let p = await browser.newPage();
  await p.route('**/rest/v1/**', r => r.fulfill(j([])));
  await p.route('**/auth/v1/**', r => r.fulfill(j({})));
  await p.goto(off, { waitUntil:'domcontentloaded' });
  await p.waitForTimeout(400);
  say('flag OFF: gate visible', !(await p.$eval('#gate', e => e.classList.contains('hide'))));
  say('flag OFF: preview hidden', await p.$eval('#whprev', e => e.classList.contains('hide')));
  say('flag OFF: WAREHOUSE_PREVIEW is false', await p.evaluate(() => WAREHOUSE_PREVIEW === false));
  await p.close();

  // ================= TEST 2: flag ON + mocked owner + mocked RPCs =================
  p = await browser.newPage();
  const calls = [];
  await p.route('**/rest/v1/**', r => r.fulfill(j([])));
  await p.route('**/auth/v1/**', r => r.fulfill(j({})));
  await p.route('**/rest/v1/rpc/**', route => { const u = route.request().url(); calls.push(u);
    if (u.includes('wh_owner_catalogue')) return route.fulfill(j(CAT));
    if (u.includes('wh_owner_review'))    return route.fulfill(j(REV));
    if (u.includes('wh_owner_trail'))     return route.fulfill(j(TRAIL));
    return route.fulfill(j([])); });
  await p.addInitScript(() => { try { localStorage.setItem('nkg_sess', JSON.stringify({ access_token:'owner-tok', refresh_token:'r' })); } catch(e){} });
  await p.goto(on, { waitUntil:'domcontentloaded' });
  await p.waitForTimeout(300);
  await p.evaluate(() => { loadSession && loadSession(); });
  await p.evaluate(() => openWhPreview());
  await p.waitForTimeout(500);
  say('flag ON: preview visible', !(await p.$eval('#whprev', e => e.classList.contains('hide'))));

  // ---- Stage 1A honesty (still holds) ----
  let b = await body(p);
  say('catalogue: "Old records suggest"', /Old records suggest/.test(b));
  say('catalogue: legacy 73 shown', /73/.test(b));
  say('catalogue: "Opening not verified"', /Opening not verified/.test(b));
  say('catalogue: never "current/in/available stock"', !/current stock|in stock|available stock/i.test(b));
  say('catalogue: identity-incomplete badge', /Identity incomplete/i.test(b));

  // ---- Stage 1B: category chips ----
  const chipText = await p.$eval('#whChips', e => e.innerText);
  say('chips: All chip present', /All/.test(chipText));
  say('chips: real categories present (no hardcoding)', /Plywood/.test(chipText) && /Doors/.test(chipText) && /Hardware/.test(chipText));
  say('chips: All count = 5', /All\s*5/.test(chipText.replace(/\n/g,' ')));
  const chipCount = await p.$eval('#whChips', e => e.querySelectorAll('button').length);
  say('chips: All + 3 categories = 4 buttons', chipCount === 4);

  // ---- Stage 1B: count line ----
  say('count line: "5 of 5 materials"', /5<\/b> of 5 materials/.test(await p.$eval('#whCount', e => e.innerHTML)) || /Showing\s*5\s*of 5/.test(await p.$eval('#whCount', e => e.innerText)));

  // ---- Stage 1B: honest negative-quantity indicator ----
  say('negative qty: "-4" shown honestly (not clamped)', /-4/.test(b) || /−4/.test(b));
  say('negative qty: "Old records below zero" indicator', /Old records below zero/i.test(b));

  // ---- Stage 1B: look-alike pill in catalogue ----
  say('look-alike pill on flagged material', /Look-alike/i.test(b));

  // ---- Stage 1B: pick a category chip narrows the list ----
  await p.evaluate(() => whPickCat('Doors'));
  await p.waitForTimeout(150);
  b = await body(p);
  say('category Doors: shows door materials', /Membrane|Flush/.test(b));
  say('category Doors: hides Plywood materials', !/Century|Greenply/.test(b));
  say('category Doors: count "2 of 5"', /2<\/b> of 5/.test(await p.$eval('#whCount', e => e.innerHTML)));
  await p.evaluate(() => whPickCat(null)); // back to All
  await p.waitForTimeout(120);

  // ---- Stage 1B: multi-word search across joined attributes ----
  await p.evaluate(() => { $('whSearch').value = 'century 18'; renderWhCat(); });
  await p.waitForTimeout(120);
  b = await body(p);
  say('search "century 18": matches Century 18mm', /Century/.test(b));
  say('search "century 18": excludes Greenply', !/Greenply/.test(b));
  await p.evaluate(() => { $('whSearch').value = ''; renderWhCat(); });
  await p.waitForTimeout(120);

  // ---- Stage 1B: each filter narrows correctly ----
  const setFilter = async v => { await p.evaluate(f => { $('whFilter').value = f; renderWhCat(); }, v); await p.waitForTimeout(120); return body(p); };
  b = await setFilter('incomplete');
  say('filter incomplete: only the incomplete door', /Membrane/.test(b) && !/Greenply/.test(b) && !/Hinges/.test(b));
  b = await setFilter('negqty');
  say('filter negqty: only the negative door', /Flush/.test(b) && !/Century/.test(b));
  say('filter negqty: shows "below zero" indicator', /Old records below zero/i.test(b));
  b = await setFilter('norate');
  say('filter norate: membrane + hinges (no rate)', /Membrane/.test(b) && /Hinges/.test(b) && !/Century/.test(b));
  b = await setFilter('hasrate');
  say('filter hasrate: excludes the no-rate items', /Century/.test(b) && !/Hinges/.test(b));
  b = await setFilter('lookalike');
  say('filter lookalike: only the flagged Century', /Century/.test(b) && !/Greenply/.test(b) && !/Flush/.test(b));
  b = await setFilter('noopen');
  say('filter noopen: excludes counted Hinges', !/Hinges/.test(b) && /Century/.test(b));
  await setFilter('all');

  // ---- Stage 1B: sorting is neutral ordering ----
  const orderOf = async () => p.$eval('#whBody', e => Array.from(e.querySelectorAll('.whm .nm')).map(n => n.textContent));
  await p.evaluate(() => { $('whSort').value = 'qtyhi'; renderWhCat(); });
  await p.waitForTimeout(120);
  let order = await orderOf();
  say('sort qtyhi: Century(73) before Greenply(5)', order.findIndex(x=>/Century/.test(x)) < order.findIndex(x=>/Greenply/.test(x)));
  say('sort qtyhi: negative Flush sorts last-ish (below positives)', order.findIndex(x=>/Flush/.test(x)) > order.findIndex(x=>/Greenply/.test(x)));
  await p.evaluate(() => { $('whSort').value = 'norate'; renderWhCat(); });
  await p.waitForTimeout(120);
  order = await orderOf();
  say('sort norate: a no-rate item is first', /Membrane|Hinges/.test(order[0]));
  await p.evaluate(() => { $('whSort').value = 'name'; renderWhCat(); });
  await p.waitForTimeout(120);

  // ---- Value tab (unchanged Stage 1A honesty) ----
  await p.evaluate(() => setWhView('val'));
  await p.waitForTimeout(150);
  const vb = await body(p);
  say('value: indicative label', /Indicative value from old records/.test(vb));
  say('value: verified value "Not available yet"', /Not available yet/.test(vb));

  // ---- Review tab: tap-through to trail ----
  await p.evaluate(() => setWhView('rev'));
  await p.waitForTimeout(150);
  const rb = await body(p);
  say('review: look-alike group shown', /look alike|look-alike|spellings that look alike/i.test(rb));
  say('review: incomplete identities section', /incomplete identities/i.test(rb));
  say('review: review-only wording', /nothing here is changed/i.test(rb));
  say('review: tap hint present', /Tap any item/i.test(rb));
  // tap the first look-alike member button -> should open the trail
  await p.evaluate(() => { const b = document.querySelector('#whBody .whgo'); if (b) b.click(); });
  await p.waitForTimeout(400);
  say('review tap-through: trail screen opens', !(await p.$eval('#whtrail', e => e.classList.contains('hide'))));
  const tb = await p.$eval('#whTrailBody', e => e.innerText);
  say('review tap-through: trail loaded old records', /IN|OUT/.test(tb));
  say('trail: opening-not-recorded banner', /Opening count not yet recorded/.test(await p.$eval('#whtrail', e => e.innerText)));
  say('trail: recorder name shown', /Raj|Suresh/.test(tb));
  say('trail: suspect duplicate flagged', /possible duplicate/.test(tb));

  // ---- network discipline: read-only, owner rpcs only ----
  say('only owner READ rpcs called', calls.length > 0 && calls.every(u => /wh_owner_(catalogue|review|trail)/.test(u)));
  say('NO write rpc called', !calls.some(u => /(submit_event|draft_put|record_opening|set_rate|activate|correct_|approve_|report_count|attach_evidence|revoke_device|add_person|create_material|resolve_count|supersede|merge)/.test(u)));

  // ---- no horizontal overflow at phone width ----
  await p.setViewportSize({ width: 360, height: 780 });
  await p.evaluate(() => { setWhView('cat'); });
  await p.waitForTimeout(150);
  const overflow = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  say('no horizontal scroll at 360px', overflow <= 1);

  await p.close();

  // ================= TEST 3: Stage 1C — owner opening-count workflow =================
  p = await browser.newPage();
  const c3 = [];              // every rpc url
  const writes = [];          // {url, body} for the opening-count POSTs we care about
  let catCalls = 0;
  // After a successful opening, the catalogue is re-read; return Century as verified then.
  const catVerified = JSON.parse(JSON.stringify(CAT));
  catVerified.materials[0].has_opening = true;
  catVerified.materials[0].recorded_qty = 18;
  catVerified.totals.with_opening = 2;
  await p.route('**/rest/v1/**', r => r.fulfill(j([])));
  await p.route('**/auth/v1/**', r => r.fulfill(j({})));
  await p.route('**/rest/v1/rpc/**', async route => {
    const u = route.request().url(); c3.push(u);
    if (u.includes('wh_owner_catalogue')) { catCalls++; return route.fulfill(j(catCalls === 1 ? CAT : catVerified)); }
    if (u.includes('wh_owner_review'))    return route.fulfill(j(REV));
    if (u.includes('wh_owner_trail'))     return route.fulfill(j(TRAIL));
    if (u.includes('wh_owner_record_opening')) {
      let body = {}; try { body = JSON.parse(route.request().postData() || '{}'); } catch (e) {}
      writes.push({ url: u, body });
      return route.fulfill(j({ opening_id: '00000000-0000-0000-0000-0000000000aa', counted: body.p_counted, note: body.p_note }));
    }
    return route.fulfill(j([]));
  });
  await p.addInitScript(() => { try { localStorage.setItem('nkg_sess', JSON.stringify({ access_token:'owner-tok', refresh_token:'r' })); } catch(e){} });
  await p.goto(on, { waitUntil:'domcontentloaded' });
  await p.waitForTimeout(300);
  await p.evaluate(() => { loadSession && loadSession(); });
  await p.evaluate(() => openWhPreview());
  await p.waitForTimeout(400);

  // open the trail for Century (unverified) -> Verify CTA should appear
  await p.evaluate(() => openWhTrail('aaaaaaaa-0000-0000-0000-000000000001', 'Century · 18mm · 8x4'));
  await p.waitForTimeout(300);
  say('1C trail: "Verify opening count" CTA on an unverified material',
      /Verify opening count/i.test(await p.$eval('#whTrailHead', e => e.innerText)));
  say('1C trail: honest "not verified stock" banner still shown',
      /not verified stock/i.test(await p.$eval('#whTrailHead', e => e.innerText)));

  // open the count screen
  await p.evaluate(() => openWhCount());
  await p.waitForTimeout(200);
  say('1C count screen visible', !(await p.$eval('#whcount', e => e.classList.contains('hide'))));
  say('1C count: physical input is NOT prefilled (no biasing)', (await p.$eval('#whcQty', e => e.value)) === '');
  say('1C count: legacy shown as context + "not" trusted',
      /Old records suggest|not/i.test(await p.$eval('#whcLegacy', e => e.innerText)));
  say('1C count: Review button disabled until a number is entered',
      await p.$eval('#whcReviewBtn', e => e.disabled));

  // fractional count on a whole-unit material -> precision error, still disabled
  await p.evaluate(() => { $('whcQty').value = '18.5'; whcQtyChange(); });
  await p.waitForTimeout(120);
  say('1C count: whole-unit material rejects a fractional count',
      !/hide/.test(await p.$eval('#whcQtyErr', e => e.className)) && await p.$eval('#whcReviewBtn', e => e.disabled));

  // valid count -> review shows the difference vs old records
  await p.evaluate(() => { $('whcQty').value = '18'; whcQtyChange(); });
  await p.waitForTimeout(100);
  say('1C count: valid whole number enables Review', !(await p.$eval('#whcReviewBtn', e => e.disabled)));
  await p.evaluate(() => { $('whcNote').value = 'shed A, 3 damaged kept aside'; whReviewCount(); });
  await p.waitForTimeout(150);
  const rv = await p.$eval('#whCountReview', e => e.innerText);
  say('1C review: shows counted 18', /18/.test(rv));
  say('1C review: shows old-records 73', /73/.test(rv));
  say('1C review: shows the difference (-55)', /-55|−55/.test(rv));
  say('1C review: large-difference warning shown (non-blocking)',
      !/hide/.test(await p.$eval('#whrvWarn', e => e.className)));

  // confirm -> the write rpc is called once, with the right payload
  await p.evaluate(() => confirmWhOpening());
  await p.waitForTimeout(500);
  say('1C confirm: wh_owner_record_opening was called exactly once', writes.length === 1);
  say('1C confirm: payload material id correct', writes[0] && writes[0].body.p_material_id === 'aaaaaaaa-0000-0000-0000-000000000001');
  say('1C confirm: payload counted = 18 (not the legacy 73)', writes[0] && Number(writes[0].body.p_counted) === 18);
  say('1C confirm: payload carries the note', writes[0] && /damaged/.test(writes[0].body.p_note || ''));
  say('1C confirm: payload has an effective time', writes[0] && !!writes[0].body.p_effective_at);
  say('1C confirm: catalogue re-read after saving', catCalls >= 2);
  say('1C after save: trail shows the verified baseline',
      /Verified opening|Trusted stock/i.test(await p.$eval('#whTrailHead', e => e.innerText)));

  // identity-incomplete material must ask to resolve identity, and offer NO count
  await p.evaluate(() => openWhTrail('cccccccc-0000-0000-0000-000000000003', '(not recorded) · Membrane · 80x42'));
  await p.waitForTimeout(300);
  const ih = await p.$eval('#whTrailHead', e => e.innerText);
  say('1C identity-incomplete: asks to resolve identity first', /Resolve its identity|identity is incomplete/i.test(ih));
  say('1C identity-incomplete: no Verify CTA offered', !/Verify opening count/i.test(ih));

  // catalogue now reflects mixed trust
  await p.evaluate(() => { backToWhPreview(); setWhView('cat'); });
  await p.waitForTimeout(200);
  say('1C catalogue: coverage line shows verified count', /Verified:/i.test(await p.$eval('#whCount', e => e.innerText)));

  // discipline: the ONLY write rpc used is record_opening (no other writes leaked)
  say('1C: no unexpected write rpc', !c3.some(u => /(submit_event|draft_put|set_rate|activate|correct_|approve_|resolve_count|supersede|add_person|create_material|attach_evidence|revoke_device|report_count|merge)/.test(u)));

  await p.close();
  await browser.close();
  console.log(fail === 0 ? '\nALL PREVIEW TESTS PASSED' : ('\n' + fail + ' TEST(S) FAILED'));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
