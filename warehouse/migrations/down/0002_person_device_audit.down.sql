-- Undo 0002. DESTRUCTIVE: drops people, devices and the audit log.
drop function if exists wh.touch_device(uuid);
drop function if exists wh.revoke_device(uuid,text);
drop function if exists wh.activate_device(text,text);
drop function if exists wh.issue_activation_code(uuid,int);
drop function if exists wh.require_owner();
drop function if exists wh.require_actor();
drop function if exists wh.is_owner();
drop function if exists wh.current_role();
drop function if exists wh.current_person_id();
drop function if exists wh.current_device();
drop function if exists wh.log(text,text,uuid,text,jsonb);
drop table if exists wh.audit;
drop table if exists wh.activation_code;
drop function if exists wh.hash_code(text,text);
drop table if exists wh.device;
drop table if exists wh.person;
