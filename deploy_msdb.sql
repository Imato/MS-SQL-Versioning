use msdb
go

CREATE TABLE [dbo].[DatabaseAudit] (
    [DbName]      VARCHAR (100)  NOT NULL,
    [EventType]   VARCHAR (50)   NOT NULL,
    [EventDate]   DATETIME2 (7)  NOT NULL,
    [LoginName]   NVARCHAR (255) NOT NULL,
    [ObjectType]  NVARCHAR (100) NOT NULL,
    [ObjectName]  NVARCHAR (255) NOT NULL,
    [Version]     INT            NULL,
    [CommandText] NVARCHAR (MAX) NOT NULL,
    [DiffText]    NVARCHAR (MAX) NOT NULL
);


GO
CREATE NONCLUSTERED INDEX [DatabaseAudit_ObjectName_IDX]
    ON [dbo].[DatabaseAudit]([DbName] ASC, [ObjectName] ASC);


GO
CREATE CLUSTERED INDEX [DatabaseAudit_EventDate_IDX]
    ON [dbo].[DatabaseAudit]([EventDate] ASC);


GO


CREATE TRIGGER [dbo].[TG_DatabaseAudit]
ON [dbo].[DatabaseAudit]
INSTEAD OF UPDATE, DELETE
AS
  PRINT 'You cannot delete or update table dbo.DatabaseAudit';
GO

CREATE TABLE [dbo].[DatabaseAuditExclude] (
    [ID]         INT            IDENTITY (1, 1) NOT NULL,
    [DbName]     VARCHAR (100)  NULL,
    [ObjectType] NVARCHAR (100) NOT NULL,
    [ObjectName] NVARCHAR (255) NOT NULL,
    CONSTRAINT [DatabaseAuditExclude_PKC] PRIMARY KEY CLUSTERED ([ID] ASC)
);


GO
CREATE UNIQUE NONCLUSTERED INDEX [DatabaseAuditExclude_UIDX]
    ON [dbo].[DatabaseAuditExclude]([DbName] ASC, [ObjectType] ASC, [ObjectName] ASC);
GO

use [same-db]
go

ALTER TRIGGER [TR_DDL_Audit]
ON DATABASE
FOR DDL_DATABASE_LEVEL_EVENTS
AS
/*
  Add changes into database objects into table DatabaseAudit.
  Add properties: VersionMajor, VersionMinor, UpdateDate, UpdateLogin to modified object.
*/
BEGIN
  SET NOCOUNT ON;

  DECLARE
		@SchemaName         NVARCHAR(255),
    @ObjectName         NVARCHAR(500),
		@ObjectFullName     NVARCHAR(500),
    @ObjectType         NVARCHAR(500),
    @UpdateLogin        NVARCHAR(255),
    @UpdateDate         DATETIME2,
    @Version		        INT,
    @VersionDate        DATE,
    @VersionPrev				INT,
    @CommandText        NVARCHAR(MAX),
    @EventType          VARCHAR(50),
    @DbName             VARCHAR(255) = DB_NAME(),
		@NewLine						NVARCHAR(1) = CHAR(10) + CHAR(13);

	if (object_id('msdb.dbo.DatabaseAudit') is null)
		return;

  BEGIN TRY
    DECLARE @ED XML;
    SET @ED = EVENTDATA();

    SELECT
			@SchemaName = isnull(@ED.value('(/EVENT_INSTANCE/SchemaName)[1]','NVARCHAR(255)'), ''),
      @ObjectName = ISNULL(@ED.value('(/EVENT_INSTANCE/ObjectName)[1]','NVARCHAR(500)'), ''),
      @ObjectType = ISNULL(@ED.value('(/EVENT_INSTANCE/ObjectType)[1]','NVARCHAR(500)'), ''),
      @UpdateLogin = ISNULL(@ED.value('(/EVENT_INSTANCE/LoginName)[1]','NVARCHAR(255)'), ''),
      @UpdateDate = ISNULL(@ED.value('(/EVENT_INSTANCE/PostTime)[1]','DATETIME2'), ''),
      @CommandText = ISNULL(@ED.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]','NVARCHAR(MAX)'), ''),
      @EventType = ISNULL(@ED.value('(/EVENT_INSTANCE/EventType)[1]','VARCHAR(50)'), '');

		set @ObjectFullName = iif(len(@SchemaName) > 0, '[' + @SchemaName + '].[' + @ObjectName + ']', @ObjectName);

    IF (@ObjectType IN ('STATISTICS')
        OR EXISTS (SELECT TOP 1 1
                    FROM [msdb].dbo.DatabaseAuditExclude e
                    WHERE e.DbName = @DbName
                      AND e.ObjectType = @ObjectType
                      AND e.ObjectName = @ObjectName))
      RETURN;

    -- View current object defenition

    DECLARE @CurrentText VARCHAR(MAX);

    SELECT TOP 1
      @CurrentText = a.CommandText
    FROM [msdb].dbo.DatabaseAudit a
    WHERE a.ObjectName = @ObjectFullName
      AND a.DbName = @DbName
    ORDER BY a.EventDate DESC;

    -- Get difference

    DECLARE @DiffText NVARCHAR(MAX) = '';

    -- Get difference
    IF (@CurrentText IS NOT NULL)
    BEGIN
        WITH
          LINES1
          AS (SELECT
                    RTRIM(LTRIM(REPLACE([value], CHAR(13), ''))) AS Line
              FROM STRING_SPLIT(@CurrentText, @NewLine)),
          DATA1
          AS (SELECT
                    Line,
                    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS LineId
              FROM LINES1
              WHERE Line != ''),
          LINES2
          AS (SELECT
                    RTRIM(LTRIM(REPLACE([value], CHAR(13), ''))) AS Line
              FROM STRING_SPLIT(@CommandText, @NewLine)),
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
    IF (@DiffText = '')
			return;

		if OBJECT_ID(@ObjectFullName) is not null
			and @ObjectType not in ('TRIGGER', 'INDEX', 'STATISTICS')
		begin

			select
					@VersionPrev = CAST(p.value AS INT)
				from sys.extended_properties AS p
				where
					p.major_id = OBJECT_ID(@ObjectFullName)
					AND p.name = 'Version';

			if @VersionPrev is null
			begin
				SET @Version = 1;
				exec sys.sp_addextendedproperty
					@name=N'Version', @value=@Version,
					@level0type=N'SCHEMA', @level0name=@SchemaName,
					@level1type=@ObjectType, @level1name=@ObjectName;
			end
			else
			begin
				SET @Version = ISNULL(@VersionPrev, 0) + 1;
				exec sys.sp_updateextendedproperty
					@name=N'Version', @value=@Version,
					@level0type=N'SCHEMA', @level0name=@SchemaName,
					@level1type=@ObjectType, @level1name=@ObjectName;
			end;

			if not exists
				(select top 1 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID(@ObjectFullName) and name = 'UpdateDate')
			begin
				exec sys.sp_addextendedproperty
					@name=N'UpdateDate', @value=@UpdateDate,
					@level0type=N'SCHEMA', @level0name=@SchemaName,
					@level1type=@ObjectType, @level1name=@ObjectName;
			end
			else
			begin
				exec sys.sp_updateextendedproperty
					@name=N'UpdateDate', @value=@UpdateDate,
					@level0type=N'SCHEMA', @level0name=@SchemaName,
					@level1type=@ObjectType, @level1name=@ObjectName;
			end;

			if not exists
				(select top 1 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID(@ObjectFullName) and name = 'UpdateLogin')
			begin
				exec sys.sp_addextendedproperty
					@name=N'UpdateLogin', @value=@UpdateLogin,
					@level0type=N'SCHEMA', @level0name=@SchemaName,
					@level1type=@ObjectType, @level1name=@ObjectName;
			end
			else
			begin
				exec sys.sp_updateextendedproperty
					@name=N'UpdateLogin', @value=@UpdateLogin,
					@level0type=N'SCHEMA', @level0name=@SchemaName,
					@level1type=@ObjectType, @level1name=@ObjectName;
			end;
		end

		-- Put data into audit table

    insert into [msdb].dbo.DatabaseAudit
      (DbName, EventType, EventDate, LoginName, ObjectType, ObjectName, Version, CommandText, DiffText)
    values
      (@DbName, @EventType, @UpdateDate, @UpdateLogin, @ObjectType, @ObjectFullName, @Version, @CommandText, @DiffText);

  END TRY
  BEGIN CATCH
    DECLARE @ERROR VARCHAR(MAX) = 'ERROR FROM DATABASE TRIGGER TR_DDL_Audit: ' + ERROR_MESSAGE();
    PRINT @ERROR;
  END CATCH

END;
GO
