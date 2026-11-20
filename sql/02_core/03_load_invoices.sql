-- =====================================================================
-- Procedure core.load_invoices
-- stage -> core: trim + convert -> checks -> dedupe + merge -> quality check -> log
-- =====================================================================

create or alter procedure core.load_invoices
as
begin
  set nocount on;
  declare @RunId int, @RowsSource int, @RowsLoaded int;
  -- 1. log start
  insert into meta.load_log (ProcName, Status) values ('core.load_invoices', 'Running');
  set @RunId = scope_identity();
  begin try
    select @RowsSource = count(*) from stage.invoices;
    -- 2. trim + convert (failed conversion -> NULL, caught in step 3)
    select trim(DocumentNumber)                     as InvoiceNumber,
           try_cast(trim(CompanyId) as int)         as CompanyId,
           trim(CustomerId)                         as CustomerId,
           trim(CountryId)                          as CountryId,
           try_convert(date, trim(PostingDate))     as PostingDate,
           try_cast(trim(Entry) as bigint)          as Entry,
           try_cast(trim(Amount) as decimal(18, 2)) as Amount,
           SourceFileName,
           LoadedDateTime
    into #src
    from stage.invoices;
    -- 3. checks -> fail the load (fix the source and rerun)
    -- 3.1 empty or not convertible values: all core columns are NOT NULL
    if exists (select 1 from #src
               where isnull(InvoiceNumber, '') = '' or isnull(CustomerId, '') = '' or isnull(CountryId, '') = ''
                  or CompanyId is null or PostingDate is null or Entry is null or Amount is null)
      throw 50002, 'core.load_invoices: rows with missing or not convertible values in stage', 1;
    -- 3.2 conflicting duplicates: same InvoiceNumber with different data
    if exists (select InvoiceNumber from #src
               group by InvoiceNumber
               having count(distinct CustomerId) > 1 or count(distinct PostingDate) > 1 or count(distinct Amount) > 1)
      throw 50003, 'core.load_invoices: same InvoiceNumber with different customer, date or amount', 1;
    begin transaction;
    -- 4. dedupe (0 duplicates today, protection for future files) -> merge into core
    with clean as (
      select *,
             row_number() over (partition by InvoiceNumber order by LoadedDateTime desc) as rn
      from #src
    )
    merge core.invoices as t
    using (select * from clean where rn = 1) as s
      on t.InvoiceNumber = s.InvoiceNumber                                                    -- key
    when matched and (t.Amount <> s.Amount or t.PostingDate <> s.PostingDate
                      or t.CustomerId <> s.CustomerId or t.CountryId <> s.CountryId) then   -- did anything change?
      update set t.CompanyId = s.CompanyId, t.CustomerId = s.CustomerId, t.CountryId = s.CountryId,
                 t.PostingDate = s.PostingDate, t.Entry = s.Entry, t.Amount = s.Amount,
                 t.SourceFileName = s.SourceFileName, t.UpdatedDateTime = sysutcdatetime()
    when not matched by target then
      insert (InvoiceNumber, CompanyId, CustomerId, CountryId, PostingDate, Entry, Amount, SourceFileName)
      values (s.InvoiceNumber, s.CompanyId, s.CustomerId, s.CountryId, s.PostingDate, s.Entry, s.Amount, s.SourceFileName);
    set @RowsLoaded = @@rowcount;   -- inserted + updated
    -- 5. quality check: every stage invoice must exist in core
    if exists (select 1 from #src s
               where not exists (select 1 from core.invoices c where c.InvoiceNumber = s.InvoiceNumber))
      throw 50001, 'core.load_invoices: not all stage invoices are in core', 1;
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
