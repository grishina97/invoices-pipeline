IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stage')
    EXEC('CREATE SCHEMA stage');
	
IF OBJECT_ID('stage.customers', 'U') IS NULL
CREATE TABLE stage.customers (
    CustomerId        NVARCHAR(255) NULL,
    CustomerName      NVARCHAR(255) NULL,
    CustomerCategory  NVARCHAR(255) NULL,
    SourceFileName    NVARCHAR(500) NULL,                             
    LoadedDateTime    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()     
);
IF OBJECT_ID('stage.invoices', 'U') IS NULL
CREATE TABLE stage.invoices (
    CompanyId		NVARCHAR(255) NULL,
	CustomerId      NVARCHAR(255) NULL,  
    CountryId       NVARCHAR(255) NULL,
	DocumentNumber  NVARCHAR(255) NULL,
	DocumentType    NVARCHAR(255) NULL,
	PostingDate     NVARCHAR(255) NULL,
	Entry           NVARCHAR(255) NULL,
	EntryType       NVARCHAR(255) NULL,
	Amount          NVARCHAR(255) NULL,
    SourceFileName  NVARCHAR(500) NULL,                             
    LoadedDateTime  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()     
);
IF OBJECT_ID('stage.payments', 'U') IS NULL
CREATE TABLE stage.payments (
    CompanyId		NVARCHAR(255) NULL,
	CustomerId      NVARCHAR(255) NULL,  
    CountryId       NVARCHAR(255) NULL,
	DocumentNumber  NVARCHAR(255) NULL,
	DocumentType    NVARCHAR(255) NULL,
	PostingDate     NVARCHAR(255) NULL,
	Entry           NVARCHAR(255) NULL,
	EntryType       NVARCHAR(255) NULL,
	Amount          NVARCHAR(255) NULL,
	InvoiceNumber	NVARCHAR(255) NULL,
	InvoiceEntry	NVARCHAR(255) NULL,
    SourceFileName  NVARCHAR(500) NULL,                             
    LoadedDateTime  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()     
);
