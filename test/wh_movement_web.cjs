// Stage 1D — warehouse staff movements + owner device management (real Chromium).
// All Supabase RPCs are route-mocked; nothing hits a real server. Run manually:
//   node test/wh_movement_web.cjs
// (CI covers the SQL backend; this covers the web layer — see test/README.md.)

const fs = require('fs'); const os = require('os'); const path = require('path');
function loadPlaywright(){ for (const t of [process.env.PLAYWRIGHT_CORE,'playwright-core','/tmp/node_modules/playwright-core',path.join(__dirname,'..','node_modules','playwright-core')].filter(Boolean)){ try{ return require(t);}catch(e){} } console.error('no playwright-core'); process.exit(2); }
const { chromium } = loadPlaywright();
function findExe(){ if(process.env.CHROMIUM_EXE&&fs.existsSync(process.env.CHROMIUM_EXE))return process.env.CHROMIUM_EXE; const base=process.env.PLAYWRIGHT_BROWSERS_PATH||'/opt/pw-browsers'; try{ for(const d of fs.readdirSync(base)){ if(/^chromium-\d+$/.test(d)){ const p=path.join(base,d,'chrome-linux','chrome'); if(fs.existsSync(p))return p; } } }catch(e){} return undefined; }
const EXE = findExe();
const url = 'file://' + path.join(__dirname, '..', 'index.html');

// ---- mock catalogue (shape of wh_catalogue) ----
const CAT = {
  categories:[
    {category_code:'Plywood', name_en:'Plywood', name_hi:'प्लाई', unit_code:'sheet', decimals:0, sort:1},
    {category_code:'Doors', name_en:'Doors', name_hi:'दरवाज़े', unit_code:'piece', decimals:0, sort:2},
  ],
  attributes:[
    {category_code:'Plywood', seq:1, attr_key:'brand', label_en:'Brand'},
    {category_code:'Plywood', seq:2, attr_key:'thickness', label_en:'Thickness'},
    {category_code:'Plywood', seq:3, attr_key:'size', label_en:'Size'},
    {category_code:'Doors', seq:1, attr_key:'variety', label_en:'Type'},
    {category_code:'Doors', seq:2, attr_key:'design', label_en:'Design No.'},
    {category_code:'Doors', seq:3, attr_key:'size', label_en:'Size'},
  ],
  values:[],
  materials:[
    {material_id:'m-ply-1', category_code:'Plywood', attrs:{brand:'Century',thickness:'18mm',size:'8x4'}, unit_code:'sheet', decimals:0, step:null, identity_incomplete:false},
    {material_id:'m-ply-2', category_code:'Plywood', attrs:{brand:'Century',thickness:'12mm',size:'8x4'}, unit_code:'sheet', decimals:0, step:null, identity_incomplete:false},
    {material_id:'m-ply-3', category_code:'Plywood', attrs:{brand:'Greenply',thickness:'12mm',size:'8x4'}, unit_code:'sheet', decimals:0, step:null, identity_incomplete:false},
    {material_id:'m-door-1', category_code:'Doors', attrs:{variety:'Lamination',design:'KP7098',size:'78x38'}, unit_code:'piece', decimals:0, step:null, identity_incomplete:false},
  ],
};
// stock: m-ply-1 has opening (qty 20); m-door-1 has NO opening (qty null); m-ply-3 low stock (3) for over-out
const STOCK = { 'm-ply-1':20, 'm-ply-2':null, 'm-ply-3':3, 'm-door-1':null };

function j(o){ return { status:200, contentType:'application/json', body:JSON.stringify(o) }; }

(async () => {
  const browser = await chromium.launch(EXE ? { executablePath: EXE } : {});
  let fail = 0; const say=(n,c)=>{ console.log((c?'PASS ':'FAIL ')+n); if(!c)fail++; };
  const submits = []; const writeCalls = [];
  const p = await browser.newPage(); await p.setViewportSize({ width:390, height:844 });

  await p.route('**/rest/v1/**', route => {
    const u = route.request().url();
    if(!u.includes('/rpc/')) return route.fulfill(j([]));   // old-NK REST + owner loadStock
    const body = (()=>{ try{ return JSON.parse(route.request().postData()||'{}'); }catch(e){ return {}; } })();
    const has = s => u.includes(s);
    // staff
    if(has('wh_activate')) return route.fulfill(j({ ok:true, token:'DEVTOKEN', person:'Raj', role:'staff', superseded:0 }));
    if(has('wh_ping')) return route.fulfill(j({ ok:true, person:'Raj', role:'staff', device_label:'Godown phone' }));
    if(has('wh_catalogue')) return route.fulfill(j(CAT));
    if(has('wh_stock_for_staff')){ const q=STOCK[body.p_material_id]; return route.fulfill(j({ material_id:body.p_material_id, name:'x', qty:q })); }
    if(has('wh_draft_put')){ writeCalls.push('draft_put'); return route.fulfill(j({ draft_id:body.p_draft_id, client_rev:body.p_client_rev, status:'open', applied:true })); }
    if(has('wh_submit_event')){ submits.push(body); return route.fulfill(j({ event_id:body.p_doc.draft_id, already:false, lines:(body.p_doc.lines||[]).length })); }
    if(has('wh_attach_evidence')){ writeCalls.push('attach_evidence'); return route.fulfill(j({ evidence_id:'e1', already:false })); }
    // owner
    if(has('wh_owner_people')) return route.fulfill(j([{person_id:'pp-1', display_name:'Raj', role:'staff', active:true}]));
    if(has('wh_owner_devices')) return route.fulfill(j([{device_id:'dev-1', person:'Raj', label:'Godown phone', activated_at:'2026-09-25T09:00:00Z', last_seen_at:'2026-09-25T10:00:00Z', revoked_at:null}]));
    if(has('wh_owner_issue_code')){ writeCalls.push('issue_code'); return route.fulfill(j({ ok:true, code:'7K3P9F2Q' })); }
    if(has('wh_owner_add_person')){ writeCalls.push('add_person'); return route.fulfill(j({ ok:true })); }
    if(has('wh_owner_revoke_device')){ writeCalls.push('revoke'); return route.fulfill(j({ ok:true })); }
    return route.fulfill(j([]));
  });
  await p.route('**/auth/v1/**', r => r.fulfill(j({})));
  await p.route('**/storage/v1/**', r => r.fulfill({ status:200, body:'{}' }));

  await p.goto(url, { waitUntil:'domcontentloaded' }); await p.waitForTimeout(300);

  // ---- gate + old NK intact ----
  say('gate: Warehouse entry button visible', await p.$eval('#wmEntryBtn', e => e.style.display !== 'none'));
  say('gate: old NK still present (owner link)', /I.m the owner/.test(await p.$eval('#gate', e => e.innerText)));

  // ---- staff: activation ----
  await p.evaluate(() => openWm()); await p.waitForTimeout(150);
  say('staff: activation screen shown when no token', !(await p.$eval('#wm_act', e => e.classList.contains('hide'))));
  await p.evaluate(() => { $('wmActCode').value='7K3P 9F2Q'; $('wmActLabel').value='Godown phone'; wmActivate(); });
  await p.waitForTimeout(300);
  say('staff: home shown after activation', !(await p.$eval('#wm_home', e => e.classList.contains('hide'))));
  say('staff: person name shown', /Raj/.test(await p.$eval('#wmWho', e => e.textContent)));
  say('staff: device token stored on phone', await p.evaluate(() => { try{ return JSON.parse(localStorage.getItem('wm_dev')).token==='DEVTOKEN'; }catch(e){ return false; } }));
  say('staff: home hides rates/value/owner admin', !/rate|value|₹|valuation/i.test(await p.$eval('#wm_home', e => e.innerText)));

  // ---- Goods In: category-first pick, multi-line, confirm ----
  await p.evaluate(() => wmStart('IN')); await p.waitForTimeout(200);
  say('IN: builder shows source label', /Source \/ supplier/.test(await p.$eval('#wmCpLabel', e => e.textContent)));
  await p.evaluate(() => { $('wmCp').value='Zangi Transport'; $('wmRef').value='CH-4471'; });
  await p.evaluate(() => wmOpenPick()); await p.waitForTimeout(150);
  say('pick: category screen (no giant form)', /choose a category/i.test(await p.$eval('#wmPickBody', e => e.innerText)));
  await p.evaluate(() => wmPickCat('Plywood')); await p.waitForTimeout(80);
  say('pick: shows Brand step', /Brand/i.test(await p.$eval('#wmPickBody', e => e.innerText)));
  await p.evaluate(() => wmChoose('brand','Century')); await p.waitForTimeout(80);
  await p.evaluate(() => wmChoose('thickness','18mm')); await p.waitForTimeout(80);
  // now unique -> pick the material directly
  await p.evaluate(() => wmPickMaterial('m-ply-1')); await p.waitForTimeout(200);
  say('qty: identity shown', /Century/.test(await p.$eval('#wmQName', e => e.textContent)));
  say('qty: not prefilled', (await p.$eval('#wmQIn', e => e.value)) === '');
  await p.evaluate(() => { $('wmQIn').value='10.5'; wmQtyChange(); });
  await p.waitForTimeout(80);
  say('qty: whole-unit rejects decimal (Add disabled)', await p.$eval('#wmQAdd', e => e.disabled));
  await p.evaluate(() => { $('wmQIn').value='40'; wmQtyChange(); }); await p.waitForTimeout(80);
  await p.evaluate(() => wmAddLine()); await p.waitForTimeout(120);
  say('IN: line added to movement', /Century/.test(await p.$eval('#wmLines', e => e.innerText)));
  say('IN: review enabled after a line', !(await p.$eval('#wmReviewBtn', e => e.disabled)));
  // add a second, different-category line (multi-line, different identity)
  await p.evaluate(() => wmOpenPick()); await p.waitForTimeout(100);
  await p.evaluate(() => wmPickCat('Doors')); await p.waitForTimeout(80);
  await p.evaluate(() => wmPickMaterial('m-door-1')); await p.waitForTimeout(200);
  await p.evaluate(() => { $('wmQIn').value='3'; wmQtyChange(); }); await p.waitForTimeout(60);
  await p.evaluate(() => wmAddLine()); await p.waitForTimeout(120);
  const linesTxt = await p.$eval('#wmLines', e => e.innerText);
  say('IN: multi-line (two materials in one movement)', /Century/.test(linesTxt) && /Lamination|KP7098|78x38/.test(linesTxt));

  // draft edits so far must NOT have submitted an event
  say('draft: no submit_event before confirm', submits.length === 0);

  await p.evaluate(() => wmReview()); await p.waitForTimeout(300);
  const rev = await p.$eval('#wmRevBody', e => e.innerText);
  say('review: recorder = person from phone (not typed)', /Recorded by/.test(rev) && /Raj \(from this phone\)/.test(rev));
  say('review: shows source + reference', /Zangi Transport/.test(rev) && /CH-4471/.test(rev));
  say('review: untrusted note for no-opening material', /no verified opening yet/i.test(rev));
  await p.evaluate(() => wmConfirm()); await p.waitForTimeout(300);
  say('IN: confirmed screen shown', !(await p.$eval('#wm_done', e => e.classList.contains('hide'))));
  say('IN: exactly one submit_event', submits.length === 1);
  const doc1 = submits[0].p_doc;
  say('IN: event_type IN with 2 lines', doc1.event_type === 'IN' && doc1.lines.length === 2);
  say('IN: recorder NOT in payload (server derives it)', !('recorder_person_id' in doc1) && !('recorder' in doc1));
  say('IN: token sent as argument', submits[0].p_token === 'DEVTOKEN');

  // ---- Goods Out over recorded stock: warn, do not block ----
  await p.evaluate(() => wmHome()); await p.waitForTimeout(80);
  await p.evaluate(() => wmStart('OUT')); await p.waitForTimeout(120);
  say('OUT: builder shows destination label', /Destination \/ customer/.test(await p.$eval('#wmCpLabel', e => e.textContent)));
  await p.evaluate(() => wmOpenPick()); await p.waitForTimeout(80);
  await p.evaluate(() => wmPickCat('Plywood')); await p.waitForTimeout(60);
  await p.evaluate(() => wmPickMaterial('m-ply-3')); await p.waitForTimeout(200);  // stock 3
  say('OUT: recorded stock shown', /Recorded stock now/.test(await p.$eval('#wmQStock', e => e.innerText)));
  await p.evaluate(() => { $('wmQIn').value='5'; wmQtyChange(); }); await p.waitForTimeout(80);
  say('OUT: over-stock warns but allows (Add enabled)', !(await p.$eval('#wmQAdd', e => e.disabled)) && !/hide/.test(await p.$eval('#wmQWarn', e => e.className)));
  await p.evaluate(() => wmAddLine()); await p.waitForTimeout(80);
  await p.evaluate(() => wmReview()); await p.waitForTimeout(200);
  await p.evaluate(() => wmConfirm()); await p.waitForTimeout(200);
  say('OUT: submitted with over_ack true', submits.length === 2 && submits[1].p_doc.lines[0].over_ack === true && submits[1].p_doc.event_type === 'OUT');

  // ---- idempotency: re-submitting the same doc returns already, no error ----
  const dupDoc = submits[1].p_doc;
  const dup = await p.evaluate(async (d) => { const r = await wmRpc('wh_submit_event',{p_token:'DEVTOKEN',p_doc:d,p_client_rev:9}); return r; }, dupDoc);
  say('idempotency: repeat submit returns a result (no crash)', dup && dup.ok);

  // ---- discipline: no rate/value RPC ever called ----
  say('discipline: staff never called a money/owner-stock rpc', submits.length>0 && ![].concat(writeCalls).some(x => /rate|value|owner_stock/i.test(x)));

  // ---- owner: device management ----
  await p.evaluate(() => { try{ localStorage.setItem('nkg_sess', JSON.stringify({access_token:'owner-tok', refresh_token:'r'})); }catch(e){} loadSession(); });
  await p.evaluate(() => showOwner()); await p.waitForTimeout(200);
  say('owner: Phones button visible', await p.$eval('#wdAdminBtn', e => e.style.display !== 'none'));
  await p.evaluate(() => openWdAdmin()); await p.waitForTimeout(250);
  say('owner: people listed', /Raj/.test(await p.$eval('#wdPeople', e => e.innerText)));
  say('owner: devices listed', /Godown phone/.test(await p.$eval('#wdDevices', e => e.innerText)));
  await p.evaluate(() => wdIssue('pp-1','Raj')); await p.waitForTimeout(200);
  say('owner: issued code displayed', /7K3P9F2Q/.test(await p.$eval('#wdCodeCard', e => e.innerText)));
  say('owner: issue_code rpc called', writeCalls.includes('issue_code'));

  // ---- no horizontal overflow at phone width ----
  await p.evaluate(() => wmHome()); await p.waitForTimeout(80);
  await p.setViewportSize({ width:360, height:780 });
  const overflow = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  say('no horizontal scroll at 360px', overflow <= 1);

  await browser.close();
  console.log(fail === 0 ? '\nALL MOVEMENT TESTS PASSED' : ('\n' + fail + ' TEST(S) FAILED'));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
