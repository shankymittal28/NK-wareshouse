\set QUIET on
\set ON_ERROR_STOP on
-- What a client role can actually reach. Staff hold the public key; the owner
-- holds a signed-in session. Neither holds any privilege inside wh: the whole
-- warehouse is reached through the wrappers in 0009 and nowhere else.

\set M '''cccccccc-0000-0000-0000-000000000002'''

-- some history and a rate to try to steal
select t.act_as('tok-raj-1');
select wh.record_opening(:M::uuid, 40, now() - interval '2 days');
select wh.submit_event(jsonb_build_object('draft_id','88880000-0000-0000-0000-0000000000a1',
  'event_type','IN','effective_at',now()::text,
  'lines', jsonb_build_array(jsonb_build_object('material_id',:M,'qty',10))), 0);
select t.act_as_owner();
select wh.set_rate(:M::uuid, 1250);

-- ---------------------------------------------------------------- the public key
set role anon;

select t.raises($$select count(*) from wh.material$$, 'permission denied',
                'the public key cannot read the catalogue table');
select t.raises($$select count(*) from wh.stock_event$$, 'permission denied',
                'nor any movement');
select t.raises($$select count(*) from wh.rate$$, 'permission denied',
                'nor a valuation rate');
select t.raises($$select count(*) from wh.person$$, 'permission denied',
                'nor who works here');
select t.raises($$select count(*) from wh.device$$, 'permission denied',
                'nor the phone list');
select t.raises($$select count(*) from wh.activation_code$$, 'permission denied',
                'nor a pending activation code');
select t.raises($$select count(*) from wh.secret$$, 'permission denied',
                'nor the pepper');
select t.raises($$select count(*) from wh.audit$$, 'permission denied',
                'nor the audit trail');
select t.raises($$select count(*) from wh.material_value$$, 'permission denied',
                'nor the money view');

select t.raises($$select wh.stock_as_of('cccccccc-0000-0000-0000-000000000002')$$, 'permission denied',
                'it cannot call an internal warehouse function');
select t.raises($$select wh.assume_device('anything')$$, 'permission denied',
                'not even the one that checks credentials');
select t.raises($$select wh.fingerprint_token('anything')$$, 'permission denied',
                'nor the one that fingerprints them');
select t.raises($$select wh.bootstrap_owner('me','me@example.test')$$, 'permission denied',
                'nor the deploy-time door');
select t.raises($$select wh.issue_activation_code('22222222-2222-2222-2222-222222222222')$$,
                'permission denied', 'nor the code issuer');

-- ---- what it CAN do: the deliberate API, and only with a credential --------
select t.raises($$select public.wh_catalogue('not-a-credential')$$, 'unauthorised',
                'the API refuses a forged credential');
select t.raises($$select public.wh_submit_event('not-a-credential','{}'::jsonb,0)$$, 'unauthorised',
                'and will not record for one');
select t.eq(public.wh_ping('not-a-credential') ->> 'error', 'unauthorised',
            'ping answers plainly rather than leaking why');

select t.ok(jsonb_array_length(public.wh_catalogue('tok-raj-1') -> 'materials') = 5,
            'a real credential reads the catalogue');
select t.eq(public.wh_stock_for_staff('tok-raj-1', :M::uuid) ->> 'qty', '50.0000',
            'and the stock quantity of a material');

-- the money question, asked every way a staff phone could ask it
select t.eq((select count(*)::int from jsonb_object_keys(
              public.wh_stock_for_staff('tok-raj-1', :M::uuid)) k
             where k in ('rate','value','material_value','category_value','valuation')), 0,
            'the staff stock answer carries no rate and no value');
select t.ok(public.wh_catalogue('tok-raj-1')::text not like '%1250%',
            'and the catalogue carries no rate either');
select t.raises($$select public.wh_owner_stock()$$, 'permission denied',
                'a staff phone cannot call the owner money function at all');

-- ---------------------------------------------------------------- a signed-in session
reset role;
set role authenticated;

select t.raises($$select count(*) from wh.rate$$, 'permission denied',
                'a signed-in session has no direct reach into wh either');
select t.raises($$select count(*) from wh.stock_event$$, 'permission denied',
                'nor into its history');

-- signed in, but not as the owner.
-- (t.act_as_nobody() first: this whole file is one transaction, which is what a
-- single request is, and the credential used earlier is still in force. In
-- production each request carries exactly one identity and ends with it.)
select t.act_as_nobody();
select set_config('request.jwt.claims','{"email":"someone.else@example.test","role":"authenticated"}', true);
select t.raises($$select public.wh_owner_stock()$$, 'not activated',
                'a signed-in stranger is not the owner and sees no money');
select t.raises($$select public.wh_owner_devices()$$, 'not activated',
                'nor the phone list');
select t.raises($$select public.wh_owner_issue_code('22222222-2222-2222-2222-222222222222', 15, 'add')$$,
                'not activated', 'nor may issue a code to enrol a phone of their own');

-- the owner
select t.act_as_owner();
select t.ok(jsonb_array_length(public.wh_owner_stock()) > 0, 'the owner sees the valued stock');
select t.ok(public.wh_owner_stock()::text like '%1250%', 'including the rate he set');
select t.ok(jsonb_array_length(public.wh_owner_devices()) = 3, 'and the phone list');
select t.ok(public.wh_owner_devices()::text not like '%token_hash%',
            'which carries no credential material of any kind');
