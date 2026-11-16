-- 001 · Core model: tenants (real-estate agencies) and their CRM leads.
-- Every row in core.leads belongs to exactly one tenant; (tenant_id, crm_id) is the natural key,
-- which is what makes the sync idempotent (re-delivering a record can never create a duplicate).

create schema core;

create table core.tenants (
  id           int  primary key,
  slug         text not null unique,
  name         text not null,
  crm_org_id   text not null unique,
  sync_enabled boolean not null default true
);

create table core.leads (
  tenant_id       int         not null references core.tenants (id),
  crm_id          text        not null,
  full_name       text        not null,
  phone           text,
  email           text,
  source          text,
  stage           text        not null,
  owner           text,
  budget_aed      numeric(14, 2),
  community       text,
  crm_modified_at timestamptz not null,
  synced_at       timestamptz not null default now(),
  primary key (tenant_id, crm_id)
);

create index leads_tenant_modified_idx on core.leads (tenant_id, crm_modified_at desc);

-- Fictional agencies used by the demo.
insert into core.tenants (id, slug, name, crm_org_id) values
  (1, 'palm-crest', 'Palm Crest Realty (demo)', 'org_palmcrest'),
  (2, 'blue-dune',  'Blue Dune Properties (demo)', 'org_bluedune');
