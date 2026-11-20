-- =====================================================================
-- Procedure core.load_payments
-- stage -> core: trim + convert -> checks -> dedupe + merge -> quality check -> log
-- =====================================================================

create or alter procedure core.load_payments
as
begin
  set nocount on;
  declare @RunId int, @RowsSource int, @RowsLoaded int;
  -- 1. log start
  insert into meta.load_log (ProcName, Status) values ('core.load_payments', 'Running');
  set @RunId = scope_identity();
  begin try
    select @RowsSource = count(*) from stage.payments;
    -- 2. trim + convert (date is dd.mm.yyyy -> style 104; failed conversion -> NULL, caught in step 3)
    select trim(DocumentNumber)                      as PaymentNumber,
           trim(InvoiceNumber)                       as InvoiceNumber,
           try_cast(trim(CompanyId) as int)          as CompanyId,
           trim(CustomerId)                          as CustomerId,
           trim(CountryId)                           as CountryId,
           trim(DocumentType)                        as DocumentType,
           try_convert(date, trim(PostingDate), 104) as PostingDate,
           try_cast(trim(Entry) as bigint)           as Entry,
           try_cast(trim(InvoiceEntry) as bigint)    as InvoiceEntry,
           try_cast(trim(Amount) as decimal(18, 2))  as Amount,
           SourceFileName,
           LoadedDateTime
    into #src
    from stage.payments;
    -- 3. checks -> fail the load (fix the source and rerun)
    -- 3.1 empty or not convertible values: all core columns are NOT NULL
    if exists (select 1 from #src
               where isnull(PaymentNumber, '') = '' or isnull(InvoiceNumber, '') = '' or isnull(CustomerId, '') = ''
                  or isnull(CountryId, '') = '' or isnull(DocumentType, '') = ''
                  or CompanyId is null or PostingDate is null or Entry is null or InvoiceEntry is null or Amount is null)
      throw 50002, 'core.load_payments: rows with missing or not convertible values in stage', 1;
    -- 3.2 conflicting duplicates: same payment + invoice pair with different data
    if exists (select PaymentNumber, InvoiceNumber from #src
               group by PaymentNumber, InvoiceNumber
               having count(distinct DocumentType) > 1 or count(distinct PostingDate) > 1 or count(distinct Amount) > 1)
      throw 50003, 'core.load_payments: same payment and invoice with different type, date or amount', 1;
    begin transaction;
    -- 4.1 dedupe on the composite key (0 duplicates today, protection for future files) -> merge into core
    with clean as (
      select *,
             row_number() over (partition by PaymentNumber, InvoiceNumber order by LoadedDateTime desc) as rn
      from #src
    )
    merge core.payments as t
    using (select * from clean where rn = 1) as s
      on t.PaymentNumber = s.PaymentNumber and t.InvoiceNumber = s.InvoiceNumber                   -- key (2 columns)
    when matched and (t.Amount <> s.Amount or t.PostingDate <> s.PostingDate
                      or t.DocumentType <> s.DocumentType or t.CustomerId <> s.CustomerId) then   -- did anything change?
      update set t.CompanyId = s.CompanyId, t.CustomerId = s.CustomerId, t.CountryId = s.CountryId,
                 t.DocumentType = s.DocumentType, t.PostingDate = s.PostingDate, t.Entry = s.Entry,
                 t.InvoiceEntry = s.InvoiceEntry, t.Amount = s.Amount,
                 t.SourceFileName = s.SourceFileName, t.UpdatedDateTime = sysutcdatetime()
    when not matched by target then
      insert (PaymentNumber, InvoiceNumber, CompanyId, CustomerId, CountryId, DocumentType,
              PostingDate, Entry, InvoiceEntry, Amount, SourceFileName)
      values (s.PaymentNumber, s.InvoiceNumber, s.CompanyId, s.CustomerId, s.CountryId, s.DocumentType,
              s.PostingDate, s.Entry, s.InvoiceEntry, s.Amount, s.SourceFileName);
    set @RowsLoaded = @@rowcount;   -- inserted + updated
    -- 4.2 IsOrphan: payment whose invoice is not in core.invoices
    --     recalculated for ALL rows every run -> if the missing invoice arrives later, the flag goes back to 0
    update p
    set IsOrphan = case when i.InvoiceNumber is null then 1 else 0 end
    from core.payments p
    left join core.invoices i on i.InvoiceNumber = p.InvoiceNumber
    where p.IsOrphan <> case when i.InvoiceNumber is null then 1 else 0 end;   -- update only what changed
    -- 5. quality check: every stage row must exist in core
    if exists (select 1 from #src s
               where not exists (select 1 from core.payments c
                                 where c.PaymentNumber = s.PaymentNumber and c.InvoiceNumber = s.InvoiceNumber))
      throw 50001, 'core.load_payments: not all stage rows are in core', 1;
    commit;
    -- 6. log success
    update meta.load_log
    set EndTime = sysutcdatetime(), Status = 'Success',
        RowsSource = @RowsSource, RowsLoaded = @RowsLoaded
    where RunId = @RunId;
  end try
  begin catch
    if @@trancount > 0 rollback;
    -- 7. log error and fail -> ADF shows the activity as failed
    update meta.load_log
    set EndTime = sysutcdatetime(), Status = 'Failed', ErrorMessage = error_message()
    where RunId = @RunId;
    throw;
  end catch
end;
