USE [master];
GO

IF DB_ID('test-audit-v1') IS NOT NULL
BEGIN
  ALTER DATABASE [test-audit-v1] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
  DROP DATABASE [test-audit-v1];
END;
GO

CREATE DATABASE [test-audit-v1];
GO
ALTER DATABASE [test-audit-v1] SET RECOVERY SIMPLE WITH NO_WAIT
GO