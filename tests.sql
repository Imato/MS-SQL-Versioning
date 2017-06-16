USE [test-audit-v1];
GO

-- Test cases

IF (OBJECT_ID('dbo.tmp_test32322556232') IS NOT NULL)
  DROP TABLE dbo.tmp_test32322556232;
GO

CREATE TABLE dbo.tmp_test32322556232(ID INT);
ALTER TABLE dbo.tmp_test32322556232 ADD COL1 TEXT;
ALTER TABLE dbo.tmp_test32322556232 ADD COL2 TEXT;
GO

IF (object_id('dbo.tmp_view_test32322556232') is not null)
  DROP VIEW dbo.tmp_view_test32322556232
GO

CREATE VIEW dbo.tmp_view_test32322556232
AS
SELECT 1 AS c1, 2 AS c2
GO

ALTER VIEW dbo.tmp_view_test32322556232
AS
SELECT 1 AS c1, 2 AS c2
UNION ALL 
SELECT 2, 3
GO

IF (OBJECT_ID('dbo.tmp_proc_test32322556232') IS NOT NULL)
  DROP PROCEDURE dbo.tmp_proc_test32322556232
GO

CREATE PROCEDURE dbo.tmp_proc_test32322556232
AS
 SET NOCOUNT ON;
GO

ALTER PROCEDURE dbo.tmp_proc_test32322556232
AS 
  SET NOCOUNT ON;
  SELECT 1 AS id;
GO

--- Test data

IF OBJECT_ID('dbo._tests_DatabaseAudit') IS NOT NULL
  DROP TABLE dbo._tests_DatabaseAudit;
GO

CREATE TABLE dbo._tests_DatabaseAudit
  (EventType VARCHAR(50) NOT NULL,
  ObjectType NVARCHAR(100) NOT NULL,
  ObjectName NVARCHAR(255) NOT NULL,
  VersionMajor INT NOT NULL,
  VersionMinor INT NOT NULL,
  CommandText NVARCHAR(MAX) NOT NULL);
GO

INSERT dbo._tests_DatabaseAudit 
  (EventType, ObjectType, ObjectName, VersionMajor, VersionMinor, CommandText) 
VALUES 
 (N'CREATE_TABLE', N'TABLE', N'[dbo].[tmp_test32322556232]', 1, 1, N'CREATE TABLE dbo.tmp_test32322556232(ID INT)'),
 (N'ALTER_TABLE', N'TABLE', N'[dbo].[tmp_test32322556232]', 1, 2, N'ALTER TABLE dbo.tmp_test32322556232 ADD COL1 TEXT'),
 (N'ALTER_TABLE',  N'TABLE', N'[dbo].[tmp_test32322556232]', 1, 3, N'ALTER TABLE dbo.tmp_test32322556232 ADD COL2 TEXT'),
 (N'CREATE_VIEW', N'VIEW', N'[dbo].[tmp_view_test32322556232]', 1, 1, N'
CREATE VIEW dbo.tmp_view_test32322556232
AS
SELECT 1 AS c1, 2 AS c2
'),
 (N'ALTER_VIEW', N'VIEW', N'[dbo].[tmp_view_test32322556232]', 1, 2, N'
ALTER VIEW dbo.tmp_view_test32322556232
AS
SELECT 1 AS c1, 2 AS c2
UNION ALL 
SELECT 2, 3
'),
 (N'CREATE_PROCEDURE', N'PROCEDURE', N'[dbo].[tmp_proc_test32322556232]', 1, 1, N'
CREATE PROCEDURE dbo.tmp_proc_test32322556232
AS
 SET NOCOUNT ON;
'),
 (N'ALTER_PROCEDURE',N'PROCEDURE', N'[dbo].[tmp_proc_test32322556232]', 1, 2, N'
ALTER PROCEDURE dbo.tmp_proc_test32322556232
AS 
  SET NOCOUNT ON;
  SELECT 1 AS id;
')
GO

-- Tests

SELECT t.* 
FROM dbo._tests_DatabaseAudit AS t
  LEFT JOIN dbo.DatabaseAudit AS r
    ON r.EventType = t.EventType
    AND r.ObjectType = t.ObjectType
    AND r.ObjectName = t.ObjectName
    AND r.VersionMajor = t.VersionMajor
    AND r.VersionMinor = t.VersionMinor
    and r.CommandText = t.CommandText
WHERE r.EventType IS NULL;

IF @@ROWCOUNT > 0
  THROW 60000, 'Table does not contain values!', 1;
GO

SELECT t.value
FROM 
  STRING_SPLIT('UpdateDate,UpdateLogin,VersionMajor,VersionMinor', ',') AS t
  LEFT JOIN sys.extended_properties AS p
    ON p.major_id = OBJECT_ID('dbo.tmp_proc_test32322556232')
    AND p.name = t.value
WHERE p.major_id IS NULL;

IF @@ROWCOUNT > 0
  THROW 60000, 'Extended properties of dbo.tmp_proc_test32322556232 not containt values for!', 1;
GO

SELECT p.name, p.value
FROM sys.extended_properties AS p
WHERE p.major_id = OBJECT_ID('dbo.tmp_proc_test32322556232')
    AND p.name = 'VersionMinor'
    AND p.value != '2'

IF @@ROWCOUNT > 0
  THROW 60000, 'Extended properties VersionMinor of dbo.tmp_proc_test32322556232 has wrong value!', 1;
GO

BEGIN TRY
  DELETE FROM dbo.DatabaseAudit;
  THROW 60000, 'Trigeir on table dbo.DatabaseAudit not working!', 1;
END TRY

BEGIN CATCH 

END CATCH

-- Clean

DROP TABLE dbo.tmp_test32322556232;
DROP VIEW dbo.tmp_view_test32322556232;
DROP PROCEDURE dbo.tmp_proc_test32322556232;
GO
