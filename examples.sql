USE [test-audit-v1];
GO

-- Create object
CREATE TABLE dbo.test_1 (ID INT);

-- View changes in audit table
SELECT TOP 1 * FROM DatabaseAudit ORDER BY EventDate DESC

-- Update object
ALTER TABLE dbo.test_1 
  ADD [Value] VARCHAR(255);

-- View changes in audit table
SELECT TOP 1 * FROM DatabaseAudit ORDER BY EventDate DESC

-- View object version
SELECT p.name, p.value
FROM sys.extended_properties AS p
WHERE p.major_id = OBJECT_ID('dbo.test_1');

DROP TABLE dbo.test_1 ;