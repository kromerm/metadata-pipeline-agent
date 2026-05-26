-- =============================================================================
-- Fabric Metadata-Driven Pipeline Agent — SQL Schema
-- Target: Fabric SQL Database (or Azure SQL Database)
-- 
-- Table 1: pipeline_parameters
--   Controls runtime behavior of each pipeline. Each row is one parameter
--   for one pipeline. The Fabric pipeline reads these at run-time via a
--   Lookup activity before executing any work.
--
-- Table 2: pipeline_logging
--   Custom logging table. Each pipeline activity writes one or more rows
--   here (via a Script / Stored Procedure activity) for observability.
--   Add custom columns to this table to capture domain-specific context.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- TABLE: pipeline_parameters
-- ---------------------------------------------------------------------------
-- One row per pipeline-parameter pair.
-- The pipeline uses a Lookup activity to retrieve all rows WHERE
--   pipeline_name = @pipelineName AND is_enabled = 1
-- and then passes them as parameters into downstream activities.
-- ---------------------------------------------------------------------------

CREATE TABLE dbo.pipeline_parameters (
    id                  INT             IDENTITY(1,1)   NOT NULL,
    pipeline_name       NVARCHAR(200)   NOT NULL,           -- matches the Fabric pipeline item name
    parameter_name      NVARCHAR(200)   NOT NULL,           -- e.g. 'source_schema', 'batch_size'
    parameter_value     NVARCHAR(MAX)   NULL,               -- stored as string; cast in pipeline
    data_type           NVARCHAR(50)    NOT NULL            -- 'string' | 'int' | 'bool' | 'float' | 'datetime'
                        DEFAULT 'string',
    description         NVARCHAR(500)   NULL,               -- human-readable description of this param
    is_enabled          BIT             NOT NULL DEFAULT 1, -- 0 = skip this param at run time
    environment         NVARCHAR(50)    NOT NULL DEFAULT 'all',  -- 'dev' | 'test' | 'prod' | 'all'
    created_by          NVARCHAR(200)   NULL,
    created_at          DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    modified_by         NVARCHAR(200)   NULL,
    modified_at         DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT PK_pipeline_parameters PRIMARY KEY (id),
    CONSTRAINT UQ_pipeline_parameters UNIQUE (pipeline_name, parameter_name, environment)
);

GO

-- Index for the Lookup activity hot path
CREATE INDEX IX_pipeline_parameters_lookup
    ON dbo.pipeline_parameters (pipeline_name, is_enabled, environment)
    INCLUDE (parameter_name, parameter_value, data_type);
GO

-- ---------------------------------------------------------------------------
-- TABLE: pipeline_logging
-- ---------------------------------------------------------------------------
-- One row per log event. Activities write here via a Script activity or
-- an Execute Stored Procedure activity.
-- 
-- CUSTOM COLUMNS: Add your own columns below the "-- CUSTOM COLUMNS" marker.
-- The agent will generate INSERT statements that include them automatically.
-- ---------------------------------------------------------------------------

CREATE TABLE dbo.pipeline_logging (
    id                  BIGINT          IDENTITY(1,1)   NOT NULL,
    pipeline_name       NVARCHAR(200)   NOT NULL,           -- Fabric pipeline item name
    pipeline_run_id     NVARCHAR(200)   NOT NULL,           -- @pipeline().RunId
    trigger_name        NVARCHAR(200)   NULL,               -- @pipeline().TriggerName
    trigger_type        NVARCHAR(50)    NULL,               -- 'Manual' | 'Schedule' | 'TumblingWindow'
    activity_name       NVARCHAR(200)   NULL,               -- name of the activity that logged this row
    log_level           NVARCHAR(20)    NOT NULL DEFAULT 'INFO',  -- 'DEBUG' | 'INFO' | 'WARN' | 'ERROR'
    status              NVARCHAR(50)    NULL,               -- 'Started' | 'Succeeded' | 'Failed' | 'Skipped'
    message             NVARCHAR(MAX)   NULL,               -- free-form log message
    error_code          NVARCHAR(100)   NULL,               -- error code if status = 'Failed'
    error_message       NVARCHAR(MAX)   NULL,               -- error detail if status = 'Failed'
    rows_read           BIGINT          NULL,               -- e.g. from Copy activity output
    rows_written        BIGINT          NULL,
    duration_seconds    INT             NULL,               -- activity duration
    logged_at           DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),

    -- -------------------------------------------------------------------------
    -- CUSTOM COLUMNS — add domain-specific context below this line
    -- Example: source_table NVARCHAR(200) NULL,
    --          target_table  NVARCHAR(200) NULL,
    --          batch_id      NVARCHAR(100) NULL,
    -- -------------------------------------------------------------------------

    CONSTRAINT PK_pipeline_logging PRIMARY KEY (id)
);

GO

-- Indexes for common query patterns
CREATE INDEX IX_pipeline_logging_run
    ON dbo.pipeline_logging (pipeline_run_id, logged_at DESC);

CREATE INDEX IX_pipeline_logging_pipeline_date
    ON dbo.pipeline_logging (pipeline_name, logged_at DESC)
    INCLUDE (log_level, status, message);

GO

-- ---------------------------------------------------------------------------
-- STORED PROCEDURE: usp_log_pipeline_event
-- ---------------------------------------------------------------------------
-- Call this from a Script activity or Execute Stored Procedure activity
-- inside your pipeline. Pass @custom_json for any extra key/value pairs
-- you want to capture without adding new columns.
-- ---------------------------------------------------------------------------

CREATE OR ALTER PROCEDURE dbo.usp_log_pipeline_event
    @pipeline_name      NVARCHAR(200),
    @pipeline_run_id    NVARCHAR(200),
    @trigger_name       NVARCHAR(200)   = NULL,
    @trigger_type       NVARCHAR(50)    = NULL,
    @activity_name      NVARCHAR(200)   = NULL,
    @log_level          NVARCHAR(20)    = 'INFO',
    @status             NVARCHAR(50)    = NULL,
    @message            NVARCHAR(MAX)   = NULL,
    @error_code         NVARCHAR(100)   = NULL,
    @error_message      NVARCHAR(MAX)   = NULL,
    @rows_read          BIGINT          = NULL,
    @rows_written       BIGINT          = NULL,
    @duration_seconds   INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.pipeline_logging (
        pipeline_name,
        pipeline_run_id,
        trigger_name,
        trigger_type,
        activity_name,
        log_level,
        status,
        message,
        error_code,
        error_message,
        rows_read,
        rows_written,
        duration_seconds
    )
    VALUES (
        @pipeline_name,
        @pipeline_run_id,
        @trigger_name,
        @trigger_type,
        @activity_name,
        @log_level,
        @status,
        @message,
        @error_code,
        @error_message,
        @rows_read,
        @rows_written,
        @duration_seconds
    );
END;
GO

-- ---------------------------------------------------------------------------
-- SAMPLE DATA — seed pipeline_parameters for a demo metadata pipeline
-- ---------------------------------------------------------------------------

INSERT INTO dbo.pipeline_parameters (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('pl_metadata_demo', 'source_schema',       'dbo',              'string',   'Schema of the source tables',          'all'),
    ('pl_metadata_demo', 'target_schema',        'staging',          'string',   'Schema of the target tables',          'all'),
    ('pl_metadata_demo', 'batch_size',           '10000',            'int',      'Rows per batch for copy activities',   'all'),
    ('pl_metadata_demo', 'enable_logging',       'true',             'bool',     'Write to pipeline_logging table',      'all'),
    ('pl_metadata_demo', 'log_level',            'INFO',             'string',   'Minimum log level to write',           'all'),
    ('pl_metadata_demo', 'watermark_column',     'ModifiedDate',     'string',   'Column used for incremental loads',    'all'),
    ('pl_metadata_demo', 'watermark_value',      '1900-01-01',       'datetime', 'Last-loaded watermark value',          'dev'),
    ('pl_metadata_demo', 'watermark_value',      '2024-01-01',       'datetime', 'Last-loaded watermark value',          'prod');
GO
