# Source data analysis

This document summarises the analysis of the three source files: what the data looks like, which issues were found,
and how each issue is handled in the core layer and in the report.

All queries with their results are in `sql/00_analysis/01_source_data_analysis.sql`.

## 1. Source files

| File | Format | Rows | One row = | Key |
|---|---|---|---|---|
| `DS1_Customers.txt` | tab-delimited text | 15,750 | one customer | `CustomerId` |
| `DS2_Invoices.xlsx` | Excel | 90,823 | one invoice | `DocumentNumber` |
| `DS3_Payments.csv` | semicolon-delimited, dates `dd.mm.yyyy` | 99,462 | one payment applied to one invoice | `DocumentNumber` + `InvoiceNumber` |

Invoices cover only 16 days (15.01.2023 – 30.01.2023, an invoice on every day). Payments cover 05.01.2018 – 29.03.2023:
they include old credits applied to these invoices and payments made up to 2 months after them.

```
customers.CustomerId     1 ──< invoices.CustomerId
invoices.DocumentNumber  1 ──< payments.InvoiceNumber
```

**Payments is not a list of payments.** One payment can settle several invoices (up to 26), and one invoice can be
settled by several payments. That is why there are more payment rows than invoices. The number of payments is
`count(distinct DocumentNumber)` = 88,161.

## 2. Data issues and how they are handled

| # | Area | Finding | Handling |
|---|---|---|---|
| 1 | Keys & duplicates | 35 customers appear twice, all exact copies. No NULLs or empty values in any file | Deduplicated in core (`row_number` by `CustomerId`), primary keys on all core tables |
| 2 | Types | All values convert. Invoice dates are `yyyy-mm-dd`, payment dates `dd.mm.yyyy` | `try_convert` in core (style 104 for payments). If a future file has values that do not convert, the load fails and the error is logged |
| 3 | Joins | 79 payment rows (56 invoices, 500,522.55) have no invoice. Their dates are in the same period as the other invoices, so these invoices are missing in the source extract. 1,205 invoices have no payment | Orphan payments are kept in core with `IsOrphan = 1` and are not part of invoice totals. Invoices without payment are valid: status Open |
| 4 | Amounts | No currency column. HU is 77 % of all money (amounts look like HUF). 473 negative invoices (credit invoices) and 20 invoices with amount 0 | Amounts kept as they are, currency is a question for the business. Negative invoices: status Credit. Zero invoices: status Zero |
| 5 | Dates | Some payments are up to 5 years older than the invoice. Payment document numbers grow with the date (6–7 digits = 2018, 9 digits = since 09/2022), so the dates are real: old customer credit applied to a new invoice. Blank payments up to 1 year before the invoice = prepayment | All payments are kept. The report date filter uses the **invoice** date |
| 6 | Document types | 5 types: Payment, Blank, CR/Adj Note, Refund, Finance Charge Memo. Each type has its own number prefix and each type closes invoices on its own | Paid amount = signed sum of **all** types. Blank behaves like Payment |
| 7 | Paid vs invoiced | 98.1 % of invoices are fully paid, 0 overpaid. One invoice differs by 0.03, the next difference is 0.43 | Invoice status with a tolerance of 0.05 (see below) |

## 3. Business rules

- **Invoiced** = invoice amount.
- **Paid** = signed sum of all payment rows for the invoice (all document types).
- **Remaining** = invoiced − paid.

| Status | Rule | Invoices |
|---|---|---|
| Paid | amount > 0 and remaining between −0.05 and 0.05 | 89,125 |
| Open | amount > 0 and nothing paid | 1,094 |
| Partially paid | amount > 0, something paid, remaining > 0.05 | 111 |
| Overpaid | amount > 0 and remaining < −0.05 | 0 |
| Credit | amount < 0 | 473 |
| Zero | amount = 0 | 20 |

- **Open invoices** in the report = Open + Partially paid. **Remaining** in the customer list = remaining of these invoices.
- **Paid invoices** in the report = Paid.
- Statuses are valid **as of 29.03.2023**, the last payment date in the data.

## 4. Open questions for the business

1. In which currency are the amounts? Local currency of `CountryId`?
2. What is the document type `Blank`?
3. Where are the 56 invoices referenced by orphan payments?
4. Is a tolerance of 0.05 for cent differences acceptable?
