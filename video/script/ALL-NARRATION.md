# Narration (one section per audio file)

## 00_intro

Hi Saeed. This is a clean-room replica I built from scratch for this assessment. It uses no employer code and no real data: every agency and every lead here is fictional. The narration was generated with ElevenLabs from my own script, which felt fitting for an automation role. I'll start with the design, then run the five scenarios you asked for.

## 01_arch_system

Here is the system. n8n pulls leads from a Zoho or Bigin style CRM API, and writes them into Postgres through three database functions only. The n8n account cannot read any table directly. Agencies reach their data only through PostgREST, where row level security limits each agency to its own records. Everything runs in Docker, bound to localhost, and the database is never exposed.

## 02_arch_cards

Three rules hold it together. The sync position, called the watermark, only moves in the same transaction that stores the data. Bad records are quarantined, never dropped. And every backup, and every release, has a verified way back.

## 03_arch_run

This is one sync run. It opens one run per agency, fetches one page at a time with three retries, and stores each page in its own transaction. It loops while the CRM reports more records, and the watermark only moves after the last page. Any failure goes to the failure lane, which reads the real status from the database, and sends an alert.

## 04_arch_schema

The schema. The primary key, tenant I D plus CRM I D, is what makes replays safe: a lead can never be duplicated. The runs table is an audit trail of every sync, including which failed run a replay recovered.

## 05_n8n_workflow

And this is the same flow, built in n8n. Trigger, open runs, fetch a page, store it, loop, and the failure path to the alert.

## 11_s1_initial

Scenario one: the CRM sync. The first run pulls every lead for both agencies. Then the script compares the CRM and the database, record by record.

## 12_s1_changes

Now agents work in the CRM. Twelve new enquiries arrive, and eight existing leads move to a new stage.

## 13_s1_incremental

The next run fetches only what changed since each agency's watermark. Eight inserted and five updated for Palm Crest. Four and three for Blue Dune.

## 14_s1_bulk

A bulk import: four hundred and fifty leads with the same timestamp, more than one A P I page. n8n pages through all of them in one run, and nothing is missed.

## 15_s1_idempotent

Running it again with nothing new writes nothing. The sync is idempotent, with zero duplicates.

## 21_s2_blip

Scenario two: failure and replay. First, a small blip. The CRM rate limits one request. n8n retries, the run succeeds, and no alert is needed.

## 22_s2_new_leads

New leads arrive, including one broken record, with no name, and a phone number that reads: call me after six.

## 23_s2_outage

Now a real outage. The CRM starts returning server errors, for Palm Crest only.

## 24_s2_fails

Palm Crest fails after three tries, while Blue Dune syncs normally. The alert says exactly what happened, and that the watermark did not move, so no data is lost. The health check reports degraded.

## 25_s2_replay

The CRM recovers. The replay is linked to the failed run, fetches the same window again, and nothing is duplicated. Health is back to okay.

## 26_s2_quarantine

And the broken record was quarantined, with its reason, instead of blocking the batch. The final check matches the CRM, record by record.

## 31_s3_own_rows

Scenario three: tenant isolation. Same API, same table. Each agency's token sees only its own leads.

## 32_s3_filter

Palm Crest asks for Blue Dune's rows directly. Row level security returns nothing.

## 33_s3_update

Palm Crest tries to reassign one of Blue Dune's leads. Zero rows change, and the database confirms the lead is untouched.

## 34_s3_insert

Palm Crest tries to insert a lead into Blue Dune's book. Rejected, with a four oh three.

## 35_s3_tokens

No token, or a forged token, gets a four oh one.

## 36_s3_worker

And even the n8n account cannot read the leads table. It can only call the three sync functions.

## 41_s4_backup

Scenario four: backup and restore. A backup, with a checksum, and a manifest of exactly what it must contain.

## 42_s4_drill

A restore drill, into a scratch database. The checksum is verified, the restored data is compared with the manifest, and the live database is not touched.

## 43_s4_business

Business continues after the backup. New leads arrive, and are synced.

## 44_s4_accident

Now, an accident. Someone runs a cleanup script against the wrong agency, and all of Palm Crest's leads are gone.

## 45_s4_restore

The restore. Verify, restore to a scratch database, compare with the manifest, then swap it in as the live database. The damaged database is kept for investigation.

## 46_s4_catchup

Because the watermark was restored with the data, the next sync fetches everything created after the backup. Palm Crest is complete again, and matches the CRM.

## 51_s5_version

Scenario five: a faulty release. This is the current schema version.

## 52_s5_deploy

Release four is deployed. An automatic backup is taken first, and the migration applies cleanly.

## 53_s5_breaks

But it breaks the sync, for every agency. The alert carries the exact database error: column phone does not exist.

## 54_s5_rollback

One command rolls the release back, in a single transaction, after another safety backup.

## 55_s5_replay

The replay recovers the failed window. The sync is healthy, and the CRM and the database match again.

## 99_outro

Every run, successful or failed, is recorded in n8n, and in the database. That's the replica: clearly designed, built to fail safely, with every claim checked automatically. I'm happy to walk through any part of it live. Thank you, Saeed.
