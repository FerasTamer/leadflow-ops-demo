-- 002 · Sync engine: watermarks, run log, quarantine, and the three functions n8n calls.
--
-- Design rules
--   * The watermark only moves in the SAME transaction that stores the data (sync.complete_run).
--     A failed run therefore leaves the watermark where it was, and the next run replays the window.
--   * Upserts are keyed on (tenant_id, crm_id) and only overwrite with a NEWER Modified_Time,
--     so replays, retries and out-of-order deliveries are harmless.
--   * A malformed record is quarantined with its reason; it never blocks the rest of the batch.
--   * Only CRM-sourced fields are written here; the CRM is the source of truth.

create schema sync;

create table sync.watermarks (
  tenant_id        int primary key references core.tenants (id),
  last_modified_at timestamptz not null default 'epoch',
  updated_at       timestamptz not null default now()
);
insert into sync.watermarks (tenant_id) select id from core.tenants;

create table sync.runs (
  id          bigserial primary key,
  tenant_id   int         not null references core.tenants (id),
  trigger     text        not null check (trigger in ('schedule', 'manual', 'replay')),
  replay_of   bigint      references sync.runs (id),
  window_from timestamptz not null,
  page        int         not null default 1,
  max_modified timestamptz,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  status      text        not null default 'running' check (status in ('running', 'succeeded', 'failed')),
  fetched     int,
  inserted    int,
  updated     int,
  unchanged   int,
  quarantined int,
  error       text
);
create index runs_tenant_status_idx on sync.runs (tenant_id, status, id desc);
-- At most one run in flight per tenant, enforced by the database rather than by a check-then-insert.
create unique index runs_one_running_per_tenant on sync.runs (tenant_id) where status = 'running';

-- Returns NULL instead of raising for anything that is not a real timestamp (e.g. 2026-02-30).
create function sync.try_timestamptz(p text) returns timestamptz
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
begin
  if p is null or p !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}([.]\d+)?(Z|[+-]\d{2}:?\d{2})$' then
    return null;
  end if;
  return p::timestamptz;
exception when others then
  return null;
end;
$$;

create table sync.quarantine (
  id           bigserial primary key,
  run_id       bigint not null references sync.runs (id),
  tenant_id    int    not null references core.tenants (id),
  crm_id       text,
  modified_raw text,
  reason       text   not null,
  payload      jsonb  not null,
  created_at   timestamptz not null default now()
);
create unique index quarantine_dedupe_idx
  on sync.quarantine (tenant_id, coalesce(crm_id, ''), reason, coalesce(modified_raw, ''));

-- Opens one run per enabled tenant that is not already syncing, and returns the window to fetch.
create function sync.start_runs(p_trigger text default 'schedule')
returns table (run_id bigint, tenant_id int, tenant_slug text, crm_org_id text, window_from text, page int)
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
#variable_conflict use_column
begin
  if p_trigger is null or p_trigger not in ('schedule', 'manual', 'replay') then
    raise exception 'unknown trigger: %', p_trigger using errcode = '22023';
  end if;

  -- A run that never reported back (worker crashed) must not block the tenant forever.
  update sync.runs
     set status = 'failed', finished_at = now(), error = 'abandoned: no completion within 10 minutes'
   where status = 'running' and started_at < now() - interval '10 minutes';

  return query
  with eligible as (
    select t.id, t.slug, t.crm_org_id, w.last_modified_at
      from core.tenants t
      join sync.watermarks w on w.tenant_id = t.id
     where t.sync_enabled
       and not exists (select 1 from sync.runs r where r.tenant_id = t.id and r.status = 'running')
       for update of w skip locked
  ), opened as (
    -- The window starts 2 minutes before the watermark, so a record committed late in the CRM with a
    -- slightly older Modified_Time is still picked up. Overlap is harmless: it is counted as unchanged.
    insert into sync.runs (tenant_id, trigger, replay_of, window_from)
    select e.id,
           p_trigger,
           case when p_trigger = 'replay' then
             (select r.id from sync.runs r
               where r.tenant_id = e.id and r.status = 'failed'
               order by r.id desc limit 1)
           end,
           e.last_modified_at - interval '2 minutes'
      from eligible e
    on conflict (tenant_id) where status = 'running' do nothing
    returning id, tenant_id, window_from
  )
  select o.id, o.tenant_id, e.slug, e.crm_org_id,
         to_char(o.window_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 1
    from opened o
    join eligible e on e.id = o.tenant_id
   order by o.tenant_id;
end;
$$;

-- Stores one page from the CRM. While p_more is true the run stays open and the next page number
-- is returned; on the last page the watermark advances and the run closes, in the same transaction.
-- If a later page fails, the watermark has not moved, so a replay refetches every page (idempotently).
create function sync.complete_run(p_run_id bigint, p_records jsonb, p_more boolean default false)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_run    sync.runs%rowtype;
  v_result jsonb;
  v_state  text;
  v_msg    text;
  c_max_pages constant int := 100;  -- guard against a CRM that never reports the last page
begin
  select * into v_run from sync.runs where id = p_run_id for update;
  if not found then
    raise exception 'run % not found', p_run_id using errcode = 'P0002';
  end if;
  if v_run.status <> 'running' then
    raise exception 'run % is already %', p_run_id, v_run.status using errcode = '55000';
  end if;
  if p_records is null or jsonb_typeof(p_records) <> 'array' then
    raise exception 'payload for run % must be a JSON array', p_run_id using errcode = '22023';
  end if;

  -- Everything below runs in a sub-transaction: if storing fails, its writes are rolled back,
  -- and the run is recorded as failed with the real Postgres error, in the same transaction.
  begin
  with raw as (
    select r from jsonb_array_elements(p_records) as t (r)
  ), parsed as (
    select r,
           nullif(btrim(r ->> 'id'), '')        as crm_id,
           nullif(btrim(r ->> 'Full_Name'), '') as full_name,
           nullif(btrim(r ->> 'Mobile'), '')    as phone,
           r ->> 'Modified_Time'                as modified_raw
      from raw
  ), typed as (
    select p.*, sync.try_timestamptz(p.modified_raw) as modified_at from parsed p
  ), classified as (
    select p.*,
           case
             when p.crm_id is null then 'missing id'
             when p.modified_at is null then 'invalid Modified_Time'
             when p.full_name is null then 'missing Full_Name'
             when p.phone is not null and p.phone !~ '^\+?[0-9]{7,15}$' then 'invalid Mobile'
             when p.r ->> 'Budget' is not null and p.r ->> 'Budget' !~ '^\d{1,12}(\.\d{1,2})?$'
               then 'invalid Budget'
           end as reject_reason
      from typed p
  ), quarantined as (
    insert into sync.quarantine (run_id, tenant_id, crm_id, modified_raw, reason, payload)
    select p_run_id, v_run.tenant_id, c.crm_id, c.modified_raw, c.reject_reason, c.r
      from classified c
     where c.reject_reason is not null
    on conflict (tenant_id, (coalesce(crm_id, '')), reason, (coalesce(modified_raw, ''))) do nothing
    returning 1
  ), valid as (
    -- If the same lead appears twice in one batch, keep its newest version.
    select distinct on (c.crm_id) c.*
      from classified c
     where c.reject_reason is null
     order by c.crm_id, c.modified_at desc
  ), upserted as (
    insert into core.leads as l (tenant_id, crm_id, full_name, phone, email, source, stage, owner,
                                 budget_aed, community, crm_modified_at, synced_at)
    select v_run.tenant_id, v.crm_id, v.full_name, v.phone,
           v.r ->> 'Email', v.r ->> 'Lead_Source', coalesce(v.r ->> 'Stage', 'New'),
           v.r -> 'Owner' ->> 'name', (v.r ->> 'Budget')::numeric, v.r ->> 'Community',
           v.modified_at, now()
      from valid v
    on conflict (tenant_id, crm_id) do update
       set full_name = excluded.full_name, phone = excluded.phone, email = excluded.email,
           source = excluded.source, stage = excluded.stage, owner = excluded.owner,
           budget_aed = excluded.budget_aed, community = excluded.community,
           crm_modified_at = excluded.crm_modified_at, synced_at = now()
     where l.crm_modified_at < excluded.crm_modified_at
    returning (xmax = 0) as is_insert
  )
  select jsonb_build_object(
           'fetched',      (select count(*) from classified),
           'inserted',     (select count(*) from upserted where is_insert),
           'updated',      (select count(*) from upserted where not is_insert),
           'unchanged',    (select count(*) from valid) - (select count(*) from upserted),
           'quarantined',  (select count(*) from classified where reject_reason is not null),
           'max_modified', (select max(modified_at) from classified)
         )
    into v_result;

  update sync.runs
     set fetched      = coalesce(fetched, 0)     + (v_result ->> 'fetched')::int,
         inserted     = coalesce(inserted, 0)    + (v_result ->> 'inserted')::int,
         updated      = coalesce(updated, 0)     + (v_result ->> 'updated')::int,
         unchanged    = coalesce(unchanged, 0)   + (v_result ->> 'unchanged')::int,
         quarantined  = coalesce(quarantined, 0) + (v_result ->> 'quarantined')::int,
         max_modified = greatest(max_modified, (v_result ->> 'max_modified')::timestamptz)
   where id = p_run_id
  returning * into v_run;

  if coalesce(p_more, false) then
    if v_run.page >= c_max_pages then
      raise exception 'CRM still reports more records after % pages', c_max_pages using errcode = '54000';
    end if;
    update sync.runs set page = page + 1 where id = p_run_id returning * into v_run;
    return jsonb_build_object(
      'status', 'more', 'run_id', p_run_id, 'page', v_run.page,
      'crm_org_id', (select crm_org_id from core.tenants where id = v_run.tenant_id),
      'window_from', to_char(v_run.window_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  end if;

  update sync.watermarks
     set last_modified_at = greatest(last_modified_at, coalesce(v_run.max_modified, last_modified_at)),
         updated_at = now()
   where tenant_id = v_run.tenant_id;

  update sync.runs set status = 'succeeded', finished_at = now() where id = p_run_id;

  return jsonb_build_object('status', 'succeeded', 'run_id', p_run_id, 'tenant_id', v_run.tenant_id,
                            'pages', v_run.page, 'fetched', v_run.fetched, 'inserted', v_run.inserted,
                            'updated', v_run.updated, 'unchanged', v_run.unchanged,
                            'quarantined', v_run.quarantined);

  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    return sync.fail_run(p_run_id, 'SQLSTATE ' || v_state || ': ' || v_msg)
           || jsonb_build_object('status', 'failed');
  end;
end;
$$;

-- Marks a run failed and returns what the alert needs. The watermark is NOT touched.
create function sync.fail_run(p_run_id bigint, p_error text)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_run      sync.runs%rowtype;
  v_tenant   core.tenants%rowtype;
  v_streak   int;
begin
  update sync.runs
     set status = 'failed', finished_at = now(), error = left(coalesce(p_error, 'unknown error'), 2000)
   where id = p_run_id and status = 'running'
  returning * into v_run;
  if not found then
    select * into v_run from sync.runs where id = p_run_id;
    if not found then
      raise exception 'run % not found', p_run_id using errcode = 'P0002';
    end if;
  end if;

  select * into v_tenant from core.tenants where id = v_run.tenant_id;
  select count(*) into v_streak
    from sync.runs r
   where r.tenant_id = v_run.tenant_id and r.status = 'failed'
     and r.id > coalesce((select max(s.id) from sync.runs s
                           where s.tenant_id = v_run.tenant_id and s.status = 'succeeded'), 0);

  -- status is the run's REAL status: if it had already succeeded (e.g. n8n lost the response after
  -- the commit), it stays succeeded and the workflow does not raise a false alert.
  return jsonb_build_object(
    'status', v_run.status, 'run_id', v_run.id, 'tenant', v_tenant.name, 'window_from', v_run.window_from,
    'error', v_run.error, 'failures_in_a_row', v_streak);
end;
$$;

create view sync.run_report as
select r.id as run, t.slug as tenant, r.trigger, r.replay_of, r.status, r.page as pages,
       r.fetched, r.inserted, r.updated, r.unchanged, r.quarantined,
       to_char(r.started_at at time zone 'Asia/Dubai', 'HH24:MI:SS') as started,
       left(r.error, 70) as error
  from sync.runs r
  join core.tenants t on t.id = r.tenant_id;
