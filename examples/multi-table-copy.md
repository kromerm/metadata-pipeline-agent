# Example: Multi-Table Copy to Lakehouse

This example shows how to use the metadata-driven pipeline agent to copy multiple NYC taxi data sources into a Fabric Lakehouse bronze layer. All source configuration lives in `dbo.pipeline_parameters` — adding a new source means inserting a row, not editing the pipeline.

---

## Scenario

We are ingesting three NYC TLC data sources into the `NYCTaxi_Bronze_Silver` Lakehouse:

| Source | Format | Destination |
|--------|--------|-------------|
| Yellow cab monthly Parquet files | Parquet (HTTP) | `Files/bronze/yellow_taxi/` |
| Green cab monthly Parquet files | Parquet (HTTP) | `Files/bronze/green_taxi/` |
| Taxi zone lookup | CSV (HTTP) | `Tables/taxi_zone_lookup` |

Each source has a different file path template, destination folder, and file format. All three are controlled from the parameters table.

---

## Step 1: Deploy the Schema

If you have not already deployed `sql/schema.sql` to your Fabric SQL Database, do that first. Then add the custom columns we need for this pattern:

```sql
ALTER TABLE dbo.pipeline_logging ADD source_name   NVARCHAR(200) NULL;
ALTER TABLE dbo.pipeline_logging ADD dest_folder   NVARCHAR(500) NULL;
ALTER TABLE dbo.pipeline_logging ADD rows_copied   BIGINT        NULL;
```

---

## Step 2: Seed the Parameters Table

Run the following INSERT statements against your Fabric SQL Database. These rows configure the three NYC taxi sources for the pipeline named `PL_MetaDriven_Bronze_Ingest`.

```sql
-- Yellow Taxi monthly Parquet files
INSERT INTO dbo.pipeline_parameters 
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_name',        'Yellow Taxi',                                          'string',   'Display name for logging',                     'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_type',        'HTTP',                                                 'string',   'Connector type',                               'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_base_url',    'https://d37ci6vzurychx.cloudfront.net/trip-data/',     'string',   'Base URL for TLC CDN',                         'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_path',        'yellow_tripdata_{month}.parquet',                      'string',   'File path template. {month} = yyyy_MM',        'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_format',      'Binary',                                               'string',   'Source format for HTTP Parquet download',       'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_dest_folder', 'bronze/yellow_taxi',                                   'string',   'Destination folder in Lakehouse Files section', 'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_load_type',   'Full',                                                 'string',   'Full, Incremental, or CDC',                    'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_enabled',     'true',                                                 'bool',     'Set to false to skip this source',             'all');

-- Green Taxi monthly Parquet files
INSERT INTO dbo.pipeline_parameters 
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_MetaDriven_Bronze_Ingest', 'source_2_name',        'Green Taxi',                                           'string',   'Display name for logging',                     'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_2_type',        'HTTP',                                                 'string',   'Connector type',                               'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_2_base_url',    'https://d37ci6vzurychx.cloudfront.net/trip-data/',     'string',   'Base URL for TLC CDN',                         'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_2_path',        'green_tripdata_{month}.parquet',                       'string',   'File path template. {month} = yyyy_MM',        'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_2_format',      'Binary',                                               'string',   'Source format for HTTP Parquet download',       'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_2_dest_folder', 'bronze/green_taxi',                                    'string',   'Destination folder in Lakehouse Files section', 'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_2_load_type',   'Full',                                                 'string',   'Full, Incremental, or CDC',                    'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_2_enabled',     'true',                                                 'bool',     'Set to false to skip this source',             'all');

-- Taxi Zone Lookup CSV
INSERT INTO dbo.pipeline_parameters 
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_MetaDriven_Bronze_Ingest', 'source_3_name',        'Zone Lookup',                                          'string',   'Display name for logging',                     'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_3_type',        'HTTP',                                                 'string',   'Connector type',                               'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_3_base_url',    'https://d37ci6vzurychx.cloudfront.net/misc/',          'string',   'Base URL for TLC CDN misc files',              'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_3_path',        'taxi_zone_lookup.csv',                                 'string',   'Static file path, no month template needed',   'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_3_format',      'DelimitedText',                                        'string',   'CSV source format',                            'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_3_dest_table',  'taxi_zone_lookup',                                     'string',   'Destination Delta table in Lakehouse Tables',  'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_3_load_type',   'Full',                                                 'string',   'Full load on every run',                       'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_3_enabled',     'true',                                                 'bool',     'Set to false to skip this source',             'all');

-- Shared pipeline settings
INSERT INTO dbo.pipeline_parameters 
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_MetaDriven_Bronze_Ingest', 'target_lakehouse',     'NYCTaxi_Bronze_Silver',    'string',   'Target Lakehouse workspace item name',          'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'batch_count',          '4',                        'int',      'ForEach batch count (1-50, default 20)',        'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'enable_logging',       'true',                     'bool',     'Write to pipeline_logging table',               'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'log_level',            'INFO',                     'string',   'Minimum log level to write',                   'all');
```

---

## Step 3: Prompt the Agent

Open Copilot Chat in agent mode, select the **pipeline-builder** agent, and use this prompt:

```
Build me a metadata-driven pipeline called PL_MetaDriven_Bronze_Ingest that copies 
multiple NYC taxi data sources from HTTP endpoints to a Fabric Lakehouse. 

The pipeline should:
- Read all enabled sources for this pipeline from dbo.pipeline_parameters
- Use a ForEach activity with batch_count from the parameters table to iterate over sources
- For each source, run a Copy Job using the source_N_base_url, source_N_path, 
  source_N_format, and source_N_dest_folder values from the parameters table
- Replace {month} in the source path with the ProcessMonth pipeline parameter 
  formatted as yyyy_MM
- Log Start, Success, and Failure events to dbo.pipeline_logging including the 
  source_name and dest_folder custom columns
- Use a Script activity (not Execute Stored Procedure) for all logging calls

The target Lakehouse is NYCTaxi_Bronze_Silver. 
I have a Fabric SQL Database connection already configured.
```

---

## Step 4: What the Agent Builds

The agent will confirm the following pipeline design before creating anything:

```
[LookupParams] — reads all enabled rows for PL_MetaDriven_Bronze_Ingest
        ↓
[Log_Start] — Script activity → dbo.usp_log_pipeline_event
        ↓
[FE_Ingest_Sources] — ForEach, batch count from parameters
    └── [CJ_Ingest_Source] — Copy Job with dynamic source/dest from item()
        ↓ success          ↓ failure
[Log_Success]           [Log_Failure]
```

---

## Pipeline Expression Reference

These are the key dynamic expressions used inside the ForEach inner canvas:

```
// Full source URL
@concat(
    first(filter(activity('LookupParams').output.value, 
        item().parameter_name == concat('source_', variables('SourceIndex'), '_base_url')
    )).parameter_value,
    replace(
        first(filter(activity('LookupParams').output.value,
            item().parameter_name == concat('source_', variables('SourceIndex'), '_path')
        )).parameter_value,
        '{month}',
        replace(pipeline().parameters.ProcessMonth, '-', '_')
    )
)

// Destination folder with year/month partitioning
@concat(
    first(filter(activity('LookupParams').output.value,
        item().parameter_name == concat('source_', variables('SourceIndex'), '_dest_folder')
    )).parameter_value,
    '/',
    formatDateTime(pipeline().parameters.ProcessMonth, 'yyyy'),
    '/',
    formatDateTime(pipeline().parameters.ProcessMonth, 'MM'),
    '/'
)
```

---

## Disabling a Source Without Deleting It

To temporarily skip the green taxi source without removing its configuration:

```sql
UPDATE dbo.pipeline_parameters
SET    is_enabled = 0
WHERE  pipeline_name   = 'PL_MetaDriven_Bronze_Ingest'
AND    parameter_name  = 'source_2_enabled';
```

Set `is_enabled` back to 1 to re-enable it on the next run.

---

## Verifying the Run

After the pipeline runs, query `dbo.pipeline_logging` to confirm all three sources were processed:

```sql
SELECT  pipeline_name,
        activity_name,
        status,
        source_name,
        dest_folder,
        rows_copied,
        logged_at
FROM    dbo.pipeline_logging
WHERE   pipeline_name    = 'PL_MetaDriven_Bronze_Ingest'
AND     pipeline_run_id  = '<your-run-id>'
ORDER BY logged_at;
```

A successful run will show one Log_Start row, one Log_Success row per source, and a final Log_Success row for the pipeline.

---

## Related Examples

- [incremental-watermark.md](incremental-watermark.md) — adds watermark tracking to this pattern for incremental load
- [stored-proc-sequence.md](stored-proc-sequence.md) — runs post-load stored procedures in configurable order
