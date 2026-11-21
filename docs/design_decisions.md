# Design decisions

## Pipeline
`pl_master_daily` (daily trigger `tr_daily`)
1. `pl_load_stage` – 3 Copy activities: files from Blob Storage -> `stage.*` (truncate + load)
2. `pl_load_core` – 3 Stored procedure activities: `core.load_customers` -> `core.load_invoices` -> `core.load_payments`
   (payments last: `IsOrphan` needs `core.invoices`)
3. Mart = views on top of core, no load step needed

Both child pipelines are called with *Execute Pipeline* and *Wait on completion*, so core starts only after stage is loaded.
Core can be rerun on its own (`pl_load_core`) without copying the files again.

All Copy and Stored procedure activities have Retry = 3, interval 60 s.
Reason: the serverless Azure SQL database auto-pauses and needs about a minute to resume;
the first scheduled run failed with a connection timeout, the retry handles it.

## Layers
- **stage** – raw text (NVARCHAR), no constraints, truncated and reloaded every run
- **core** – cleaned and typed data, all columns NOT NULL, primary keys, loaded with MERGE (idempotent)
- **mart** – star schema for Power BI: `dim_customer`, `dim_date`, `fct_invoice`
- **meta** – `meta.load_log`: one row per procedure run (status, row counts, error message)

## Core procedures
Every procedure follows the same 7 steps:
1. log start
2. trim + convert types (`try_convert`, style 104 for `dd.mm.yyyy`)
3. checks: missing / not convertible values, conflicting duplicates -> fail the load
4. dedupe (`row_number`) + MERGE (update only changed rows, insert new ones)
5. quality check: every stage row exists in core
6. log success
7. on error: rollback, log the error, rethrow -> ADF shows the activity as failed

**Idempotence:** running the pipeline twice does not change the row counts; the second run logs `RowsLoaded = 0`.

## NOT NULL in core
The analysis showed no missing values and every column is needed (keys for joins, dates for the report
filter, amounts for totals). NULLs fail silently, so for financial data the load fails fast: if a file has
missing or invalid values, the procedure stops and logs the error. The raw file stays in storage, so it can
be fixed and reloaded. If the business prefers partial loads, a rejected-rows table can be added.

## Customers = SCD1
The current category overwrites the old one. If the business needs to report by the category valid at the
invoice date, customers should be switched to SCD2 (ValidFrom / ValidTo / IsCurrent).

## Orphan payments
Payments whose invoice is not in the source (79 rows, 500,522.55) are kept with `IsOrphan = 1`.
The flag is recalculated every run, so it goes back to 0 when the invoice arrives.
They are not part of the report, because the report starts from invoices.

## Mart
**Views, not tables.** ~90k invoices is not much. A view always shows fresh data from core, so the mart does not
need its own load step and the pipeline stays the same. If the data grows, the views can be turned into tables
loaded by a procedure.

- `fct_invoice` – one row per invoice: invoiced, paid, remaining, status, flags for the report
  - paid = signed sum of all payment types
  - status: Paid / Partially paid / Open / Overpaid / Credit / Zero, tolerance 0.05 for cent differences
  - `IsOpen` (Open + Partially paid), `IsPaid` (Paid), `OpenRemainingAmount` (remaining of open invoices)
- `dim_customer` – customer, category, `CategoryOrder` (sort GOLD, SILVER, BRONZE, OTHERS in the report)
- `dim_date` – **table**, not view: the calendar does not depend on our data. One row per day,
  2023-01-01 to 2025-12-31, filled once by a script. Before loading data from 2026 or later, change the end date
  in the script and run it again (existing days are skipped).

## Report (Power BI)
- **Import mode:** small data, refreshed once a day after the pipeline. Faster for users, full DAX, and the
  Azure SQL database is not queried on every click. DirectQuery would make sense for much larger data or near
  real-time reporting.
- **Date filter = invoice date.** The date slicer shows only days with invoices (visual filter: Invoiced is not
  blank), so the range grows automatically with new loads.
- **Remaining (net)** in the KPI cards = all invoices incl. credit invoices (8,793,785.59).
  **Open Remaining** in the customer list = only Open + Partially paid invoices (8,835,219.52), as asked in the task.
- Statuses are valid as of the last payment date in the data ("Data as of" card, currently 29.03.2023).
- Amounts are in source currency (no currency column) – totals across countries mix currencies.
- Production: publish to Power BI Service and schedule refresh after the pipeline; use a read-only SQL user
  (`select` on schema `mart` only).

## Next steps
- **Currency:** get a currency column (or country -> currency mapping) and exchange rates, report in EUR.
- **History:** customers as SCD2 if needed.
- **Monitoring:** alert on failed pipeline runs (ADF alerts).
