-- 004 · RELEASE CANDIDATE (intentionally faulty, used by the rollback scenario)
--
-- Intent: rename leads.phone -> mobile_e164 to match the CRM field naming.
-- Defect: sync.complete_run() still writes to "phone", so the very next sync run fails.
-- The migration itself applies cleanly, which is exactly why it slips through:
-- the damage only shows up when the integration runs.

alter table core.leads rename column phone to mobile_e164;
