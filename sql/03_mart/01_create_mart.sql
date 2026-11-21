-- =====================================================================
-- MART: views for Power BI (star schema)
-- =====================================================================
if not exists (select 1 from sys.schemas where name = 'mart') exec('create schema mart');
go

-- ---------- dim_customer ----------
create or alter view mart.dim_customer as
select CustomerId,
       CustomerName,
       CustomerCategory,
       case CustomerCategory when 'GOLD'   then 1
                             when 'SILVER' then 2
                             when 'BRONZE' then 3
                             else 4 end as CategoryOrder   -- sort order in the report filter (otherwise, in alphabetical order, Silver will be last)
from core.customers;
go

-- ---------- dim_date: calendar table, filled once ----------
-- covers 2023-01-01 .. 2025-12-31; extend the end date before loading data from 2026
if object_id('mart.dim_date', 'V') is not null drop view mart.dim_date;   -- remove the old view version
if object_id('mart.dim_date', 'U') is null
create table mart.dim_date (
    [Date]      date         not null primary key,
    [Year]      int          not null,
    [Month]     int          not null,
    WeekdayName nvarchar(20) not null
);
declare @d date = '2023-01-01';
while @d <= '2025-12-31'
begin
    if not exists (select 1 from mart.dim_date where [Date] = @d)   -- rerun = no duplicates
        insert into mart.dim_date ([Date], [Year], [Month], WeekdayName)
        values (@d, year(@d), month(@d), datename(weekday, @d));
    set @d = dateadd(day, 1, @d);   -- next day
end;
-- table, not view: the calendar does not depend on our data, it is just a list of days
go

-- ---------- fct_invoice: one row per invoice ----------
-- paid = signed sum of all payment types (analysis section 6)
-- status rules + tolerance 0.05 (analysis section 7)
create or alter view mart.fct_invoice as
with paid as (
  select InvoiceNumber,
         sum(Amount)      as PaidAmount,
         max(PostingDate) as LastPaymentDate
  from core.payments
  group by InvoiceNumber
),
inv as (
  select i.InvoiceNumber,
         i.CustomerId,
         i.CountryId,
         i.PostingDate                          as InvoiceDate,
         i.Amount                               as InvoicedAmount,  -- task a
         isnull(p.PaidAmount, 0)                as PaidAmount,      -- task a
         i.Amount - isnull(p.PaidAmount, 0)     as RemainingAmount, -- task a
         p.LastPaymentDate
  from core.invoices i
  left join paid p on p.InvoiceNumber = i.InvoiceNumber      -- left join: keep invoices without payments
),
st as (
  select *,
         case when InvoicedAmount = 0              then 'Zero'
              when InvoicedAmount < 0              then 'Credit'
              when abs(RemainingAmount) <= 0.05    then 'Paid'         -- tolerance for cent differences
              when PaidAmount = 0                  then 'Open'
              when RemainingAmount < -0.05         then 'Overpaid'
              else 'Partially paid'
         end as InvoiceStatus
  from inv
)
select *,
       case when InvoiceStatus in ('Open', 'Partially paid') then 1 else 0 end as IsOpen,                            -- task b: open invoices
       case when InvoiceStatus = 'Paid'                      then 1 else 0 end as IsPaid,                            -- task b: paid invoices
       case when InvoiceStatus in ('Open', 'Partially paid') then RemainingAmount else 0 end as OpenRemainingAmount  -- task b: remaining of open invoices
from st;
go
