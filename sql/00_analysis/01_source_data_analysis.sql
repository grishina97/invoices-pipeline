
-- =====================================================================
-- 0. first look
-- =====================================================================
select 'customers' as tbl, count(*) from stage.customers
union all select 'invoices', count(*) from stage.invoices
union all select 'payments', count(*) from stage.payments;
-- -> customers 15,750, invoices 90,823, payments 99,462
-- -> more payments than invoices -> some invoices are paid in several parts? check later
-- -> let me check what the data looks like (distinct values)
	SELECT
	DISTINCT
	--CustomerId--15,715 CONTAINS LETTERS AND DIGITS (e.g. 86639, C871268)
	--CustomerName--15,715 Customer_CustomerId anonymised, no extra information
	--CustomerCategory--4 categories (GOLD, SILVER, BRONZE, OTHERS), looks ok
	FROM stage.customers;
	SELECT
	DISTINCT
	--CustomerId--15,712 fewer than in customers -> some customers have no invoices
	--CompanyId--only 101
	--CountryId--29 countries
	--DocumentNumber--INV-<country>-<number>
	--PostingDate--2023-01-15 2023-01-30 == invoices were issued within these 16 days, but payments come on different dates
	--Amount-- has negatives and maybe too big spread, and why is there no currency?
	FROM stage.invoices;
		with t as (
			select try_cast(Amount as decimal(18, 2)) as amount
			from stage.invoices -- same for payments
		)
		select
			min(amount)                                as min_amount,
			max(amount)                                as max_amount,
			avg(amount)                                as avg_amount,
			stdev(amount)                              as stdev_amount
		from t;
		-- -> invoices: min -253,894.45 | max 58,205,305.00 | avg 40,595.31 | stdev 572,089.28
		-- -> payments: min -253,894.45 | max 58,205,305.00 | avg 36,985.93 | stdev 538,944.19
		-- -> stdev is 14x the average -> a few huge amounts, check in section 4
			select count(*)
			from stage.invoices i
			left join stage.customers c on c.CustomerId = i.CustomerId
			where c.CustomerId is null;
			-- -> 0 -> all invoice customers exist in customers
	SELECT
	DISTINCT
	--CustomerId--15,485 fewer than in customers -> some customers have no payments
	--CompanyId--only 101
	--CountryId--29 countries
	--InvoiceNumber--INV-<country>-<number>
	--PostingDate--443 distinct dates (invoices only 16) -> wider date range + different format (04.02.2023 = dd.mm.yyyy)
	--Amount-- has negatives and maybe too big spread, and why is there no currency?
	--DocumentType--5 types -> decide which document types count as "payment"
	FROM stage.payments;
		select count(*)
		from stage.payments p
		left join stage.customers c on c.CustomerId = p.CustomerId
		where c.CustomerId is null;
		-- -> 0 -> all payment customers exist in customers

''' TO DO:
1. check duplicates, keys and nulls, and understand why there are more payments than invoices
2. to work with the data I need to convert the types, check first that it is possible
3. check join between tables + DocumentNumber in invoices = InvoiceNumber in payments ? check both directions, link between invoices and payments
4. check amount in payments and invoices - has negatives and maybe too big spread, and why is there no currency?
5. must check PostingDate: payment date vs. date of its invoice
	1. payment before the invoice, on the same day or after
	2. how many days until customers pay (only payments after the invoice)
	3. the oldest payments: a payment from 2018 for an invoice from 2023 looks strange
6. DocumentType 5 types -> decide which document types count as "payment"
7. check the logic paid vs invoiced
'''

-- =====================================================================
-- 1. check duplicates, keys and nulls, and understand why there are more payments than invoices
-- =====================================================================

-- invoices
select CompanyId, CustomerId, CountryId, DocumentNumber, count(*)
from stage.invoices
group by CompanyId, CustomerId, CountryId, DocumentNumber
having count(*) > 1;
-- -> 0 duplicates in invoices
select count(*), count(distinct DocumentNumber) from stage.invoices;
-- -> 90,823 = 90,823 -> key = DocumentNumber

-- payments
select CompanyId, CustomerId, CountryId, DocumentNumber, InvoiceNumber, count(*)
from stage.payments
group by CompanyId, CustomerId, CountryId, DocumentNumber, InvoiceNumber
having count(*) > 1;
-- -> 0 duplicates in payments
select count(*), count(distinct DocumentNumber) from stage.payments;
-- -> 99,462 rows but only 88,161 documents -> DocumentNumber is not the key, I need to find the key
select *
from stage.payments
where DocumentNumber = 'PAY-CZ-106556954';
-- -> same payment document, several rows, each with a different InvoiceNumber
select DocumentNumber, InvoiceNumber, count(*)
from stage.payments
group by DocumentNumber, InvoiceNumber
having count(*) > 1;
-- -> 0 -> pair is unique -> key = DocumentNumber + InvoiceNumber
select top 10 DocumentNumber, count(distinct InvoiceNumber) as invoices
from stage.payments
group by DocumentNumber
order by invoices desc;
select top 10 InvoiceNumber, count(distinct DocumentNumber) as payments
from stage.payments
group by InvoiceNumber
order by payments desc;
-- -> one payment can settle up to 26 invoices
-- -> this file is "which payment settled which invoice", not a list of payments
-- -> count of payments must be count(distinct DocumentNumber)
/*
one row != one payment
matching payments to invoices, typical for accounts receivable. A customer often pays several invoices with one transfer or one invoice in parts,
and accounting then splits the payment across the specific invoices. Thanks to this we can see how much is left to pay on each invoice.
why more payment rows than invoices: one payment can settle several invoices + one invoice can be settled by several payments !!!
*/

-- customers
select CustomerId, count(*)
from stage.customers
group by CustomerId
having count(*) > 1;
-- -> 35 customers twice
select * from stage.customers where CustomerId = '10831';
-- -> both rows identical (same name, same category)
select CustomerId,
       count(*)                         as rows_cnt,
       count(distinct CustomerName)     as names,
       count(distinct CustomerCategory) as categories
from stage.customers
group by CustomerId
having count(*) > 1
   and (count(distinct CustomerName) > 1 or count(distinct CustomerCategory) > 1);
-- -> 0 -> all duplicates are exact copies
-- -> fix: distinct in core

-- generated check for every column (null and '' because stage is all text)
declare @schema sysname = 'stage';
declare @table  sysname = 'customers';   -- run for customers, invoices, payments
declare @sql    nvarchar(max);
select @sql = string_agg(
    cast('select ''' + COLUMN_NAME + ''' as column_name, count(*) as total_rows, '
       + 'sum(case when ' + quotename(COLUMN_NAME) + ' is null then 1 else 0 end) as null_count, '
       + 'sum(case when trim(cast(' + quotename(COLUMN_NAME) + ' as nvarchar(max))) = '''' then 1 else 0 end) as empty_count '
       + 'from ' + quotename(@schema) + '.' + quotename(@table) as nvarchar(max)),
    ' union all ')
from INFORMATION_SCHEMA.COLUMNS
where TABLE_SCHEMA = @schema
  and TABLE_NAME   = @table
  and COLUMN_NAME not in ('SourceFileName', 'LoadedDateTime');
exec sp_executesql @sql;
-- -> no nulls and no empty strings in any table

''' MY CONCLUSIONS:
nulls: 0
duplicates: 35 exact duplicate customers -> distinct in core
keys:
	customers = CustomerId
	payments  = DocumentNumber + InvoiceNumber
	invoices  = DocumentNumber
'''

-- =====================================================================
-- 2. to work with the data I need to convert the types, check first that it is possible
-- =====================================================================

-- * CustomerId, CountryId, DocumentNumber, InvoiceNumber, DocumentType, EntryType -> text
-- 1. customers -> CustomerId, CustomerName, CustomerCategory = text -> nothing to convert
-- 2. invoices  -> PostingDate (date), Amount (decimal), Entry (bigint), CompanyId (int)
select
  count(*)                                                                    as total_rows,
  sum(case when try_convert(date, PostingDate) is null then 1 else 0 end)       as bad_posting_date,
  sum(case when try_cast(Amount as decimal(18, 2)) is null then 1 else 0 end)   as bad_amount,
  sum(case when try_cast(Entry as bigint) is null then 1 else 0 end)            as bad_entry,
  sum(case when try_cast(CompanyId as int) is null then 1 else 0 end)           as bad_company_id,
  min(try_convert(date, PostingDate))                                           as min_date,
  max(try_convert(date, PostingDate))                                           as max_date
from stage.invoices;
-- -> 0 everything could be converted. 2023-01-15 2023-01-30
-- 3. payments  -> PostingDate (date, dd.mm.yyyy), Amount (decimal), Entry, InvoiceEntry (bigint), CompanyId (int)
select
  count(*)                                                                      as total_rows,
  sum(case when try_convert(date, PostingDate, 104) is null then 1 else 0 end)    as bad_posting_date,
  sum(case when try_cast(Amount as decimal(18, 2)) is null then 1 else 0 end)     as bad_amount,
  sum(case when try_cast(Entry as bigint) is null then 1 else 0 end)              as bad_entry,
  sum(case when try_cast(InvoiceEntry as bigint) is null then 1 else 0 end)       as bad_invoice_entry,
  sum(case when try_cast(CompanyId as int) is null then 1 else 0 end)             as bad_company_id,
  min(try_convert(date, PostingDate, 104))                                        as min_date,
  max(try_convert(date, PostingDate, 104))                                        as max_date
from stage.payments;
-- -> 0 everything could be converted. 2018-01-05 2023-03-29
-- -> strange: some payments are older than the invoices -> compare payment date with invoice date

'''
MY CONCLUSIONS: everything could be converted
TO DO: compare payment date with invoice date !!!
'''

-- =====================================================================
-- 3. check join between tables + DocumentNumber in invoices = InvoiceNumber in payments ? check both directions, link between invoices and payments
-- =====================================================================
-- same format everywhere?
select count(*)
from stage.payments
where InvoiceNumber not like 'INV-[A-Z][A-Z]-%'
   or InvoiceNumber <> trim(InvoiceNumber);
-- -> 0
select count(*)
from stage.invoices
where DocumentNumber not like 'INV-[A-Z][A-Z]-%'
   or DocumentNumber <> trim(DocumentNumber);
-- -> 0

-- check CustomerId
select sum(case when p.CustomerId <> i.CustomerId then 1 else 0 end) as customer_mismatch
from stage.payments p
join stage.invoices i on i.DocumentNumber = p.InvoiceNumber;
-- -> 0 ok

-- payments -> invoices: does every payment find its invoice?
select p.DocumentType,
       count(*)                                    as row_cnt,
       count(distinct p.InvoiceNumber)             as missing_invoices,
       sum(try_cast(p.Amount as decimal(18, 2)))   as amount
from stage.payments p
left join stage.invoices i on i.DocumentNumber = p.InvoiceNumber
where i.DocumentNumber is null -- no invoice
group by p.DocumentType;
-- -> Payment 61 rows / 40 invoices, CR/Adj Note 15 / 15, Blank 3 / 3
-- -> total 79 rows, 56 invoices, 500,522.55 -> payments we have, but invoices we don't
select min(try_convert(date, p.PostingDate, 104)), max(try_convert(date, p.PostingDate, 104))
from stage.payments p
left join stage.invoices i on i.DocumentNumber = p.InvoiceNumber
where i.DocumentNumber is null;
-- -> 15.01.2023 - 28.03.2023 -> same period as the invoices, not old ones
-- -> we loaded the whole invoice file -> these invoices are missing in the source extract

-- invoices -> payments: is every invoice paid?
select count(*)                                    as invoices_without_payment
from stage.invoices i
where not exists (select 1 from stage.payments p where p.InvoiceNumber = i.DocumentNumber);
-- -> 1,205 invoices without any payment

''' MY CONCLUSIONS:
- all invoice and payment customers exist in customers (first look)
- payments.InvoiceNumber = invoices.DocumentNumber, same format, CustomerId matches
- payments without invoice (79 rows, 56 invoices, 500,522.55) -> keep, flag as orphan
  ("money came in, but the invoice is missing in the source extract") -> question for business
- invoices without payments (1,205) -> unpaid, not an error
'''

-- =====================================================================
-- 4. check amount in payments and invoices - has negatives and maybe too big spread, and why is there no currency?
-- =====================================================================
-- same sql for invoices and payments:

-- does decimal(18,2) lose anything?
select count(try_cast(Amount as decimal(18, 2))) as amount from stage.invoices;
-- -> 90,823 = all rows -> ok

-- check spread
select top 10 *
from stage.invoices
order by try_cast(Amount as decimal(18, 2)) desc;
-- -> biggest amounts are all HU
select CountryId,
       count(*) as invoices,
       sum(try_cast(Amount as decimal(18, 2))) as total_amount
from stage.invoices
group by CountryId
order by total_amount desc;
-- -> HU = 2,838,078,396
select sum(try_cast(Amount as decimal(18, 2))) as total_amount
from stage.invoices;
-- -> total = 3,686,987,959 -> HU is 77 % of all money
-- -> probably because there is no currency: HUF is ~400x smaller than EUR

-- check negative
select CountryId, count(*)
from stage.invoices
where try_cast(Amount as decimal(18, 2)) < 0
group by CountryId
order by 2 desc;
-- -> in many countries

-- check zero
select * from stage.invoices
where try_cast(Amount as decimal(18, 2)) = 0;
-- -> 20 invoices with 0 !!!

-- check negative in payments type
select DocumentType,
       sum(case when try_cast(Amount as decimal(18, 2)) < 0 then 1 else 0 end) as negative,
       sum(case when try_cast(Amount as decimal(18, 2)) > 0 then 1 else 0 end) as positive,
       sum(try_cast(Amount as decimal(18, 2)))                                 as total
from stage.payments
group by DocumentType;
-- -> negatives mostly in Payment (163) and Blank (234), Refund 5 (ok, money back to customer), CR/Adj 1

''' MY CONCLUSIONS:
- decimal(18,2) is safe
- big spread is not an error: HU amounts are huge -> most likely local currency (HUF)
- need currency column !!! without it amounts of different countries cannot be added together
  -> report totals mix currencies -> question for business
- negative invoices in many countries -> probably credit invoices, not errors
- 20 zero invoices -> nothing to pay, neither open nor paid
- negatives in Payment and Blank -> answered in 6 / 7: negative applications settle credit (negative) invoices
'''

-- =====================================================================
-- 5. must check PostingDate: payment date vs. date of its invoice
-- =====================================================================
-- when was the invoice paid, by document type?
select
  p.DocumentType,
  sum(case when try_convert(date, p.PostingDate, 104) <  try_convert(date, i.PostingDate) then 1 else 0 end) as before_invoice,
  sum(case when try_convert(date, p.PostingDate, 104) =  try_convert(date, i.PostingDate) then 1 else 0 end) as same_day,
  sum(case when try_convert(date, p.PostingDate, 104) >  try_convert(date, i.PostingDate) then 1 else 0 end) as after_invoice,
  count(*)                                                                                                   as total
from stage.payments p
join stage.invoices i on i.DocumentNumber = p.InvoiceNumber
group by p.DocumentType
order by total desc;
-- -> Payment: mostly after (ok), but why some before? checked below
-- -> Blank: mostly before -> "prepayment"? checked below
-- -> CR/Adj: mostly same day (ok)
-- -> Refund and Finance Charge Memo: ok

-- order payments by date
select top 20 p.DocumentNumber, p.DocumentType, p.PostingDate as payment_date,
       i.DocumentNumber as invoice, i.PostingDate as invoice_date, p.Amount
from stage.payments p
join stage.invoices i on i.DocumentNumber = p.InvoiceNumber
order by try_convert(date, p.PostingDate, 104);
-- -> payment 5 years before invoice -> strange, are the dates real or typos? check the document numbers
-- check length of the number, after the last '-'
select 'invoices.DocumentNumber' as col,
       min(len(right(DocumentNumber, charindex('-', reverse(DocumentNumber)) - 1))) as min_digits,
       max(len(right(DocumentNumber, charindex('-', reverse(DocumentNumber)) - 1))) as max_digits
from stage.invoices
union all
select 'payments.InvoiceNumber',
       min(len(right(InvoiceNumber, charindex('-', reverse(InvoiceNumber)) - 1))),
       max(len(right(InvoiceNumber, charindex('-', reverse(InvoiceNumber)) - 1)))
from stage.payments
union all
select 'payments.DocumentNumber',
       min(len(right(DocumentNumber, charindex('-', reverse(DocumentNumber)) - 1))),
       max(len(right(DocumentNumber, charindex('-', reverse(DocumentNumber)) - 1)))
from stage.payments;
-- -> payment documents have 6 to 9 digits, invoices always 9 -> payment numbers are different
-- how does the number length relate to the date?
select len(right(DocumentNumber, charindex('-', reverse(DocumentNumber)) - 1)) as digits,
       count(*)                                                                  as row_cnt,
       min(try_convert(date, PostingDate, 104))                                  as min_date,
       max(try_convert(date, PostingDate, 104))                                  as max_date
from stage.payments
group by len(right(DocumentNumber, charindex('-', reverse(DocumentNumber)) - 1))
order by digits;
-- -> 6-7 digits = 2018, 8 digits = 2018-2022, 9 digits = since 09/2022
-- -> number grows with date -> the old dates are real, not typos
-- check Blank
select top 20 p.DocumentNumber, p.DocumentType, p.PostingDate as payment_date,
       i.DocumentNumber as invoice, i.PostingDate as invoice_date, p.Amount
from stage.payments p
join stage.invoices i on i.DocumentNumber = p.InvoiceNumber
where p.DocumentType = 'Blank'
order by try_convert(date, p.PostingDate, 104);
-- -> Blank paid up to 1 year before invoice -> prepayment

''' MY CONCLUSIONS:
Payment type: paid up to 5 years before invoice -> its ok because the customer had money left on the account
			  from an old payment (2018), and finance used it to pay the new invoice in 2023.
			  PostingDate = date of the payment document, not the date it was applied to the invoice.
			  DocumentNumber grows with date -> the old dates are real.
Blank type: paid up to 1 year before invoice -> prepayment.
'''

-- =====================================================================
-- 6. DocumentType 5 types -> decide which document types count as "payment"
-- =====================================================================
-- payment = "what closed the debt"
-- the debt can be closed with money (Payment, Blank), with a credit note or adjustment (CR/Adj, like a discount or a correction)
-- or with a refund, if the debt was ours (Refund)
-- prefix in documents
select DocumentType, count(*) as rows_cnt, left(min(DocumentNumber), charindex('-', min(DocumentNumber))) as prefix
from stage.payments
group by DocumentType
order by rows_cnt desc;
-- -> each type has its own prefix -> Blank is a real document type, not an empty value

-- one invoice can be closed by several documents (e.g. part Payment + part CR/Adj Note)
-- which type combinations exist, and does each type close invoices on its own?
with types as (
  select distinct InvoiceNumber, DocumentType from stage.payments
),
combo as (
  select InvoiceNumber, string_agg(DocumentType, ' + ') within group (order by DocumentType) as types
  from types
  group by InvoiceNumber
),
paid as (
  select InvoiceNumber, sum(try_cast(Amount as decimal(18, 2))) as paid_amount
  from stage.payments
  group by InvoiceNumber
)
select c.types,
       count(*) as invoices,
       sum(case when try_cast(i.Amount as decimal(18, 2)) = p.paid_amount then 1 else 0 end) as fully_paid
from combo c
join paid p on p.InvoiceNumber = c.InvoiceNumber
join stage.invoices i on i.DocumentNumber = c.InvoiceNumber
group by c.types
order by invoices desc;
-- -> every DocumentType closes invoices ALONE -> every type is a real settlement

''' MY CONCLUSIONS:
5 document types, each has its own number prefix
Payment             -> customer paid money (bank transfer)
Blank               -> ??? behaves exactly like Payment (positive, closes invoices alone) -> treat as payment
CR/Adj Note         -> almost all positive -> credit / discount
Refund              -> money returned to the customer, closes credit (negative) invoices
Finance Charge Memo -> 1 row, closes one invoice, too small to matter
'''

-- =====================================================================
-- 7. check the logic paid vs invoiced
-- =====================================================================

-- over ALL invoices: how many are paid, and how much money is invoiced / paid / remaining?
with paid as (
  select InvoiceNumber, sum(try_cast(Amount as decimal(18, 2))) as paid_amount
  from stage.payments
  group by InvoiceNumber
)
select count(*)                                                                                         as invoices,
       sum(case when p.InvoiceNumber is null then 1 else 0 end)                                         as without_payment,
       sum(case when try_cast(i.Amount as decimal(18, 2)) = isnull(p.paid_amount, 0) then 1 else 0 end) as fully_paid,
       sum(try_cast(i.Amount as decimal(18, 2)))                                                        as invoiced,
       sum(isnull(p.paid_amount, 0))                                                                    as paid,
       sum(try_cast(i.Amount as decimal(18, 2)) - isnull(p.paid_amount, 0))                             as remaining
from stage.invoices i
left join paid p on p.InvoiceNumber = i.DocumentNumber;   -- left join: keep invoices without payments
-- -> 90,823 invoices, 1,205 without any payment
-- -> fully_paid also contains credit invoices and invoices with 0 -> I need statuses

-- how many invoices are in each status?
with paid as (
  select InvoiceNumber, sum(try_cast(Amount as decimal(18, 2))) as paid_amount
  from stage.payments
  group by InvoiceNumber
),
inv as (
  select i.DocumentNumber,
         try_cast(i.Amount as decimal(18, 2))  as invoiced,
         isnull(p.paid_amount, 0) as paid,
         try_cast(i.Amount as decimal(18, 2)) - isnull(p.paid_amount, 0) as remaining
  from stage.invoices i
  left join paid p on p.InvoiceNumber = i.DocumentNumber
),
st as (
  select *,
         case
			 when invoiced = 0               then 'Zero'
			 when invoiced < 0               then 'Credit'
			 when abs(remaining) <= 0.05     then 'Paid' -- abs = absolute value: removes minus, so this means from -0.05 to +0.05
			 when paid = 0                   then 'Open'
			 when remaining < -0.05          then 'Overpaid'
			 else 'Partially paid'
		end as status
  from inv
)
select status, count(*) as invoices, sum(invoiced) as invoiced, sum(paid) as paid, sum(remaining) as remaining
from st
group by status
order by invoices desc;
-- -> total 90,823 = all invoices -> nothing lost or counted twice

''' MY CONCLUSIONS:
- the logic paid = sum of all types works
-- 98.1 % of invoices are fully paid (89,125 of 90,823), 0 overpaid
-- 95.6 % of it (8.4 mil.) is in Open invoices: nothing was paid at all
-- Credit: we still owe customers 41k (credit invoices not yet paid back)
'''

-- =====================================================================
-- 8. summary: data issues and what I do with them in core / report
-- =====================================================================
'''
1. keys & duplicates		->	35 exact duplicate customers, no nulls (distinct by CustomerId )
								keys: customers = CustomerId,
								invoices = DocumentNumber, payments = DocumentNumber + InvoiceNumber
2. types					->	everything converts; payments date format is dd.mm.yyyy (convert) 
3. joins   					->	79 payment rows without invoice, invoices missing in the source extract (keep in core with flag IsOrphan = 1)
								1,205 invoices without payment - valid, unpaid (keep, status Open)
4. amounts					->	no currency column (HU = 77 % of money) (keep amounts as is, question for business about currency)
5. dates					->	payments up to 5 years before invoice are real (number grows with date) (keep all payments, report date filter = invoice date)
6. document types			->	all 5 types close invoices on their own; Blank behaves like Payment
								paid = signed sum of ALL types; question for business: what is Blank?
7. paid vs invoiced			->	98.1 % invoices fully paid, 0 overpaid;
								statuses Paid / Partially paid / Open / Credit / Zero, tolerance 0.05 
'''
-- TO DO: distinct, convert, IsOrphan, invoice statuses 
