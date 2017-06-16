USE [test-audit-v1];
GO

---------
IF EXISTS 
    (SELECT TOP 1 1 FROM sys.triggers WHERE name = 'TR_DDL_Audit')
  DROP TRIGGER TR_DDL_Audit
  ON DATABASE;
  GO

-- Function for split string 

IF OBJECT_ID('dbo.STRING_SPLIT') IS NOT NULL
  DROP FUNCTION dbo.STRING_SPLIT;
GO

IF (SELECT compatibility_level FROM  sys.databases WHERE name = 'test-audit-v1') < 130
EXECUTE(
'CREATE FUNCTION dbo.STRING_SPLIT
  (@string NVARCHAR(MAX), @separator NVARCHAR(10))
RETURNS @VALUES TABLE (ID INT IDENTITY(1,1), [value] NVARCHAR(MAX))
AS
BEGIN
  
  -- Replace special strings 

  WITH REPLC
  AS (SELECT ''<'' AS string, ''&lt;'' AS replacment
      UNION ALL SELECT ''>'', ''&gt;''
      UNION ALL SELECT ''&'', ''&amp;''
      UNION ALL SELECT '''''''', ''&apos;''
      UNION ALL SELECT ''"'', ''&quot;'')

  SELECT @string = REPLACE(@string, string, replacment)
  FROM REPLC;
 
  -- Split string frow xml

  DECLARE @XML XML = CAST(''<X>'' + REPLACE(@string, @separator ,''</X><X>'') + ''</X>'' AS XML);
  INSERT INTO @VALUES
  SELECT n.value(''.'', ''NVARCHAR(MAX)'') AS [value]
  FROM @XML.nodes(''X'') AS t(n); 
  RETURN;
END
GO')
GO

-- Audit table 

IF OBJECT_ID('dbo.DatabaseAudit') IS NOT NULL
  DROP TABLE dbo.DatabaseAudit;
GO

CREATE TABLE dbo.DatabaseAudit
  (EventType VARCHAR(50) NOT NULL,
  EventDate DATETIME2 NOT NULL,
  LoginName NVARCHAR(255) NOT NULL,
  ObjectType NVARCHAR(100) NOT NULL,
  ObjectName NVARCHAR(255) NOT NULL,
  VersionMajor INT NOT NULL,
  VersionMinor INT NOT NULL,
  CommandText NVARCHAR(MAX) NOT NULL,
  DiffText NVARCHAR(MAX) NOT NULL);
GO

CREATE CLUSTERED INDEX DatabaseAudit_EventDate_IDX
  ON dbo.DatabaseAudit (EventDate);
GO

CREATE INDEX DatabaseAudit_ObjectName_IDX
  ON dbo.DatabaseAudit (ObjectName);
GO

IF EXISTS (SELECT TOP 1 1 FROM sys.triggers WHERE name = 'TG_DatabaseAudit')
  DROP TRIGGER TG_DatabaseAudit;
GO

CREATE TRIGGER TG_DatabaseAudit
  ON dbo.DatabaseAudit
  INSTEAD OF UPDATE, DELETE 
  AS
    PRINT 'You cannot delete or update table dbo.DatabaseAudit';
GO

IF OBJECT_ID('dbo.system_ExtendedProperties_Update') IS NOT NULL
  DROP PROCEDURE dbo.system_ExtendedProperties_Update;
GO

CREATE PROCEDURE dbo.system_ExtendedProperties_Update
  (@ObjectName    NVARCHAR(500),
  @ObjectType     NVARCHAR(500),
  @PropertyName   NVARCHAR(MAX),
  @PropertyValue  NVARCHAR(500))

AS 
BEGIN 
/*
  Update extended properties @PropertyName 
  with value  @PropertyValue for database object.
*/

  SET NOCOUNT ON;

  -- Update object properties
    
  -- Is deleted
  IF (OBJECT_ID(@ObjectName) IS NULL)
    RETURN;

  -- Except this object type
  IF (@ObjectType IN ('TRIGGER', 'INDEX', 'STATISTICS'))
    RETURN;

  DECLARE 
    @level0name NVARCHAR(500),
    @level1name NVARCHAR(500),
    @value      SQL_VARIANT = CAST(@PropertyValue AS SQL_VARIANT);

  SELECT 
    @level0name = SCHEMA_NAME(o.schema_id),
    @level1name = o.name
  FROM sys.objects AS o
  WHERE o.object_id = OBJECT_ID(@ObjectName);

  IF NOT EXISTS (SELECT TOP 1 1  
                FROM sys.extended_properties AS p
                WHERE p.major_id = OBJECT_ID(@ObjectName)
                  AND p.name = @PropertyName)
    EXEC sys.sp_addextendedproperty @name=@PropertyName, 
                                    @value=@value, 
                                    @level0type=N'SCHEMA',
                                    @level0name=@level0name, 
                                    @level1type=@ObjectType,
                                    @level1name=@level1name;
  ELSE
    EXEC sys.sp_updateextendedproperty  @name=@PropertyName, 
                                        @value=@value, 
                                        @level0type=N'SCHEMA',
                                        @level0name=@level0name, 
                                        @level1type=@ObjectType,
                                        @level1name=@level1name;
END;
GO

IF EXISTS (SELECT TOP 1 1 FROM sys.triggers WHERE name = 'TR_DDL_Audit')
  DROP TRIGGER TR_DDL_Audit;
GO

CREATE TRIGGER TR_DDL_Audit
  ON DATABASE
  FOR DDL_DATABASE_LEVEL_EVENTS
AS
/*
  Add changes in database objects into table DatabaseAudit.
  Add properties: VersionMajor, VersionMinor, UpdateDate, UpdateLogin to modified object.
*/
BEGIN 
  SET NOCOUNT ON;

  DECLARE 
    @ObjectName     NVARCHAR(500),
    @ObjectType     NVARCHAR(500),
    @UpdateLogin    NVARCHAR(255),
    @UpdateDate     DATETIME2,
    @VersionMajor   INT = 1,
    @VersionMinor   INT = 1,
    @CommandText    NVARCHAR(MAX),
    @EventType      VARCHAR(50);

  BEGIN TRY
    DECLARE @ED XML;
    SET @ED = EVENTDATA();

    SELECT
      @ObjectName = 
        ISNULL(
        -- '[' + @ED.value('(/EVENT_INSTANCE/SchemaName)[1]','NVARCHAR(500)') +'].[' +
        @ED.value('(/EVENT_INSTANCE/ObjectName)[1]','NVARCHAR(500)'),
        -- +']', 
            ''),
      @ObjectType = ISNULL(@ED.value('(/EVENT_INSTANCE/ObjectType)[1]','NVARCHAR(500)'), ''),
      @UpdateLogin = ISNULL(@ED.value('(/EVENT_INSTANCE/LoginName)[1]','NVARCHAR(255)'), ''),
      @UpdateDate = ISNULL(@ED.value('(/EVENT_INSTANCE/PostTime)[1]','DATETIME2'), ''),
      @CommandText = ISNULL(@ED.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]','NVARCHAR(MAX)'), ''),
      @EventType = ISNULL(@ED.value('(/EVENT_INSTANCE/EventType)[1]','VARCHAR(50)'), '');

    IF (@ObjectType IN ('STATISTICS'))
      RETURN;

    -- View current object defenition

    DECLARE @CurrentText VARCHAR(MAX);

    SELECT TOP 1 
      @CurrentText = CommandText 
    FROM dbo.DatabaseAudit
    WHERE ObjectName = @ObjectName
    ORDER BY EventDate DESC;

    -- Get difference 

    DECLARE @DiffText NVARCHAR(MAX) = '';

    -- Get difference
    IF (@CurrentText IS NOT NULL)
    BEGIN
        WITH 
          LINES1
          AS (SELECT 
                    RTRIM(LTRIM(REPLACE([value], CHAR(13), ''))) AS Line
              FROM STRING_SPLIT(@CurrentText, CHAR(13))),
          DATA1 
          AS (SELECT 
                    Line,
                    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS LineId
              FROM LINES1
              WHERE Line != ''),
          LINES2
          AS (SELECT 
                    RTRIM(LTRIM(REPLACE([value], CHAR(13), ''))) AS Line
              FROM STRING_SPLIT(@CommandText, CHAR(13))),
          DATA2
          AS (SELECT 
                    Line,
                    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS LineId
              FROM LINES2
              WHERE Line != '')

      SELECT
        @DiffText += ISNULL(d2.Line, '') + CHAR(13)
      FROM DATA1 AS d1
        FULL OUTER JOIN DATA2 AS d2 
          ON d1.LineId = d2.LineId
      WHERE 
        -- First line
        (ISNULL(REPLACE(d1.Line, 'ALTER', 'CREATE'), '') != ISNULL(REPLACE(d2.Line, 'ALTER', 'CREATE'), '') 
        AND d1.LineId = 1)
        OR
        -- Other
        (ISNULL(d1.Line, '') != ISNULL(d2.Line, '')
        AND ISNULL(d1.LineId, 2) > 1)
    END;

    -- If it is first change
    IF (@CurrentText IS NULL)
      SET @DiffText = @CommandText;

    -- If object was changed
    IF (@DiffText != '')
    BEGIN

      -- View last version
      SELECT 
        @VersionMajor = ISNULL(CAST(p.value AS INT), 1)
      FROM sys.extended_properties AS p
      WHERE  
        p.major_id = OBJECT_ID(@ObjectName)
        AND p.name = 'VersionMajor'

      SELECT 
        @VersionMinor = ISNULL(CAST(p.value AS INT), 0) + 1
      FROM sys.extended_properties AS p
      WHERE  
        p.major_id = OBJECT_ID(@ObjectName)
        AND p.name = 'VersionMinor'

      -- Update object properties

       -- VersionMinor 
      EXECUTE system_ExtendedProperties_Update @ObjectName, 
                                               @ObjectType, 
                                               @PropertyName = 'VersionMajor',
                                               @PropertyValue = @VersionMajor;

      -- VersionMinor 
      EXECUTE system_ExtendedProperties_Update @ObjectName, 
                                               @ObjectType, 
                                               @PropertyName = 'VersionMinor',
                                               @PropertyValue = @VersionMinor;
    
      -- UpdateDate 
      EXECUTE system_ExtendedProperties_Update @ObjectName, 
                                               @ObjectType, 
                                               @PropertyName = 'UpdateDate',
                                               @PropertyValue = @UpdateDate;

      -- UpdateLogin 
      EXECUTE system_ExtendedProperties_Update @ObjectName, 
                                               @ObjectType, 
                                               @PropertyName = 'UpdateLogin',
                                               @PropertyValue = @UpdateLogin;

      -- Put data into audit table

      INSERT INTO dbo.DatabaseAudit
        (EventType, EventDate, LoginName, ObjectType, ObjectName, VersionMajor, VersionMinor, CommandText, DiffText)
      VALUES 
        (@EventType, @UpdateDate, @UpdateLogin, @ObjectType, @ObjectName, @VersionMajor, @VersionMinor, @CommandText, @DiffText);

    END;
  END TRY
  BEGIN CATCH
    DECLARE @ERROR VARCHAR(MAX) = 'ERROR FROM DATABASE TRIGGER TR_DDL_Audit: ' + ERROR_MESSAGE();
    PRINT @ERROR;
  END CATCH

END;
GO