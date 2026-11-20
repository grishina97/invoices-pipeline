-- =====================================================================
-- Procedure core.load_customers
-- stage -> core: trim + convert -> checks -> dedupe + merge -> quality check -> log
-- =====================================================================

create or alter procedure core.load_customers
as
begin
  set nocount on;
  declare @RunId int, @RowsSource int, @RowsLoaded int;
  -- 1. log start
  insert into meta.load_log (ProcName, Status) values ('core.load_customers', 'Running');
  set @RunId = scope_identity();
  begin try
    select @RowsSource = count(*) from stage.customers;
    -- 2. trim (all columns are text, nothing to convert)
    select trim(CustomerId)              as CustomerId,
           trim(CustomerName)            as CustomerName,
           upper(trim(CustomerCategory)) as CustomerCategory,   -- 'gold ' -> 'GOLD'
           SourceFileName,
           LoadedDateTime
    into #src
    from stage.customers;
    -- 3. checks -> fail the load (fix the source and rerun)
    -- 3.1 empty values: all core columns are NOT NULL
    if exists (select 1 from #src
               where isnull(CustomerId, '') = '' or isnull(CustomerName, '') = '' or isnull(CustomerCategory, '') = '')
      throw 50002, 'core.load_customers: rows with missing CustomerId, name or category in stage', 1;
    -- 3.2 conflicting duplicates: same CustomerId with different name or category
    if exists (select CustomerId from #src
               group by CustomerId
               having count(distinct CustomerName) > 1 or count(distinct CustomerCategory) > 1)
      throw 50003, 'core.load_customers: same CustomerId with different name or category', 1;
    begin transaction;
    -- 4. dedupe: exact duplicates in source (35 today) -> 1 row per CustomerId -> merge into core
    with clean as (
      select *,
             row_number() over (partition by CustomerId
                                order by LoadedDateTime desc, CustomerCategory) as rn   -- tie-breaker -> same result every run
      from #src
    )
    merge core.customers as t
    using (select * from clean where rn = 1) as s
      on t.CustomerId = s.CustomerId                                                                         -- key
    when matched and (t.CustomerName <> s.CustomerName or t.CustomerCategory <> s.CustomerCategory) then  -- did anything change?
      update set t.CustomerName = s.CustomerName, t.CustomerCategory = s.CustomerCategory,
                 t.SourceFileName = s.SourceFileName, t.UpdatedDateTime = sysutcdatetime()
    when not matched by target then
      insert (CustomerId, CustomerName, CustomerCategory, SourceFileName)
      values (s.CustomerId, s.CustomerName, s.CustomerCategory, s.SourceFileName);
    set @RowsLoaded = @@rowcount;   -- inserted + updated
    -- 5. quality check: every stage customer must exist in core
    if exists (select 1 from #src s
               where not exists (select 1 from core.customers c where c.CustomerId = s.CustomerId))
      throw 50001, 'core.load_customers: not all stage customers are in core', 1;
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
