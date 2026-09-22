-- Undo 0003. DESTRUCTIVE: drops recorded movements. Stage 0 rehearsal only.
drop table if exists wh.event_correction;
drop table if exists wh.line_correction;
drop trigger if exists event_line_guard_trg on wh.event_line;
drop function if exists wh.event_line_guard();
drop table if exists wh.event_line;
drop table if exists wh.stock_event;
