-- 003 · Security: tenant isolation (RLS), least-privilege roles, and the public API surface.
--
-- Roles
--   authenticator  login used by PostgREST; can only switch into the roles below
--   web_anon       no JWT: may call api.health() and nothing else
--   tenant_user    an agency's app user; sees ONLY rows whose tenant_id matches the JWT claim
--   sync_worker    login used by n8n; may only EXECUTE the three sync functions, cannot read leads
-- Passwords arrive as psql variables from scripts/migrate.sh (read from .env, never committed).

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'web_anon')      then create role web_anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'tenant_user')   then create role tenant_user nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator login noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'sync_worker')   then create role sync_worker login; end if;
end;
$$;

alter role authenticator with login noinherit password :'authenticator_password';
alter role sync_worker   with login password :'sync_worker_password';
grant web_anon, tenant_user to authenticator;

revoke all on schema public from public;
revoke all on schema core, sync from public;

-- Functions are executable by PUBLIC by default in Postgres; close that first.
revoke execute on all functions in schema sync from public;
grant usage on schema sync to sync_worker;
grant execute on function sync.start_runs(text), sync.complete_run(bigint, jsonb, boolean), sync.fail_run(bigint, text)
  to sync_worker;

-- Tenant isolation ------------------------------------------------------------------------
create schema api;
-- Note on writes: insert/update are granted below only so the demo can prove that RLS WITH CHECK
-- stops cross-tenant writes. In production the CRM stays the source of truth: agency edits go back
-- to the CRM through n8n, and this API would be read-only.

create function api.current_tenant() returns int
language sql stable
as $$
  select nullif(current_setting('request.jwt.claims', true)::json ->> 'tenant_id', '')::int
$$;

alter table core.leads enable row level security;
alter table core.leads force row level security;

create policy tenant_isolation on core.leads
  for all to tenant_user
  using (tenant_id = api.current_tenant())
  with check (tenant_id = api.current_tenant());

grant usage on schema core, api to tenant_user;
grant select, insert on core.leads to tenant_user;
grant update (stage, owner) on core.leads to tenant_user;

create view api.leads with (security_invoker = true) as
select tenant_id, crm_id, full_name, phone, email, source, stage, owner, budget_aed, community,
       crm_modified_at
  from core.leads;

grant select, insert on api.leads to tenant_user;
grant update (stage, owner) on api.leads to tenant_user;

-- Health ------------------------------------------------------------------------------------
-- Per-tenant detail is for operators (sync.health_detail, psql only). The public endpoint returns
-- aggregates only, so an anonymous caller learns nothing about which agencies exist.
create view sync.health_detail as
select t.slug as tenant,
       s.finished_at as last_success,
       coalesce(f.failures, 0) as failures_since_success,
       w.last_modified_at as watermark
  from core.tenants t
  join sync.watermarks w on w.tenant_id = t.id
  left join lateral (select max(r.finished_at) as finished_at, max(r.id) as id
                       from sync.runs r where r.tenant_id = t.id and r.status = 'succeeded') s on true
  left join lateral (select count(*) as failures
                       from sync.runs r where r.tenant_id = t.id and r.status = 'failed'
                        and r.id > coalesce(s.id, 0)) f on true;

create function api.health() returns json
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select json_build_object(
    'status', case when bool_or(h.failures_since_success > 0) then 'degraded' else 'ok' end,
    'tenants', count(*),
    'tenants_failing', count(*) filter (where h.failures_since_success > 0),
    'oldest_success_age_s', extract(epoch from now() - min(h.last_success))::int)
  from sync.health_detail h
$$;

revoke execute on all functions in schema api from public;
grant usage on schema api to web_anon;
grant execute on function api.health() to web_anon, tenant_user;
grant execute on function api.current_tenant() to tenant_user;
