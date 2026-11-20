# Design decisions

## Pipeline
`pl_master_daily` (daily trigger)
1. `pl_load_stage` – 3 Copy activities: files from Blob Storage -> `stage.*` (truncate + load)
2. Stored procedures: `core.load_customers` -> `core.load_invoices` -> `core.load_payments`
   (payments last: `IsOrphan` needs `core.invoices`)
3. Mart (later)

## Layers
- **stage** – raw text, no constraints, truncated and reloaded every run
- **core** – cleaned and typed data, all columns NOT NULL, keys enforced, loaded with MERGE (idempotent)
- **meta** – `meta.load_log`: one row per procedure run (status, row counts, error message)

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
