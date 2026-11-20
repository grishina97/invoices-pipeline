-- =====================================================================
-- DDL: core + meta schemas and tables
-- Run once. Core = cleaned, typed data (all columns NOT NULL); meta = load log
-- =====================================================================

if not exists (select 1 from sys.schemas where name = 'core') exec('create schema core');
if not exists (select 1 from sys.schemas where name = 'meta') exec('create schema meta');

-- log: one row per procedure run
if object_id('meta.load_log', 'U') is null
create table meta.load_log (
    RunId          int identity(1, 1) primary key,
    ProcName       nvarchar(200) not null,
    StartTime      datetime2     not null default sysutcdatetime(),
    EndTime        datetime2     null,
    Status         nvarchar(20)  not null,          -- Running / Success / Failed
    RowsSource     int           null,
    RowsLoaded     int           null,
    ErrorMessage   nvarchar(4000) null
);

-- core.customers
if object_id('core.customers', 'U') is null
create table core.customers (
    CustomerId       nvarchar(50)  not null primary key,
    CustomerName     nvarchar(255) not null,
    CustomerCategory nvarchar(50)  not null,   -- GOLD / SILVER / BRONZE / OTHERS
    SourceFileName   nvarchar(500) null,
    InsertedDateTime datetime2     not null default sysutcdatetime(),
    UpdatedDateTime  datetime2     null
);

-- core.invoices
if object_id('core.invoices', 'U') is null
create table core.invoices (
    InvoiceNumber    nvarchar(50)  not null primary key,   -- = DocumentNumber in source
    CompanyId        int           not null,
    CustomerId       nvarchar(50)  not null,
    CountryId        char(2)       not null,
    PostingDate      date          not null,
    Entry            bigint        not null,
    Amount           decimal(18,2) not null,
    SourceFileName   nvarchar(500) null,
    InsertedDateTime datetime2     not null default sysutcdatetime(),
    UpdatedDateTime  datetime2     null
);
-- DocumentType (always 'Invoice') and EntryType (always 'Initial Entry') are not loaded: no information

-- core.payments
if object_id('core.payments', 'U') is null
create table core.payments (
    PaymentNumber    nvarchar(50)  not null,   -- = DocumentNumber in source
    InvoiceNumber    nvarchar(50)  not null,
    CompanyId        int           not null,
    CustomerId       nvarchar(50)  not null,
    CountryId        char(2)       not null,
    DocumentType     nvarchar(50)  not null,   -- Payment / Blank / CR/Adj Note / Refund / Finance Charge Memo
    PostingDate      date          not null,
    Entry            bigint        not null,
    InvoiceEntry     bigint        not null,
    Amount           decimal(18,2) not null,   -- signed: negative applications settle credit invoices
    IsOrphan         bit           not null default 0,   -- 1 = invoice not found in core.invoices "we see payment but we dont invoice for this"
    SourceFileName   nvarchar(500) null,
    InsertedDateTime datetime2     not null default sysutcdatetime(),
    UpdatedDateTime  datetime2     null,
    constraint PK_core_payments primary key (PaymentNumber, InvoiceNumber)   -- one row = one payment applied to one invoice
);
