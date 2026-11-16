drop schema api cascade;
drop view if exists sync.health_detail;
drop policy if exists tenant_isolation on core.leads;
alter table core.leads no force row level security;
alter table core.leads disable row level security;
revoke all on all tables in schema core from tenant_user;
revoke usage on schema core from tenant_user;
revoke all on schema sync from sync_worker;
revoke execute on all functions in schema sync from sync_worker;
