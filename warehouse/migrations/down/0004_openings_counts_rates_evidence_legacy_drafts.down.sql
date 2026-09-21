-- Undo 0004. DESTRUCTIVE: drops baselines, counts, rates, evidence rows, legacy history
-- and drafts. Only for a Stage 0 rehearsal, never once real movements exist.
drop table if exists wh.draft;
drop table if exists wh.legacy_photo;
drop table if exists wh.legacy_line;
drop table if exists wh.evidence;
drop table if exists wh.rate_history;
drop table if exists wh.rate;
drop table if exists wh.count_report;
drop table if exists wh.opening;
