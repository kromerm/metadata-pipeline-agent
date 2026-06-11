# Example: Incremental Load with Per-Source Watermarks

This example extends the multi-table copy pattern to support incremental load. Instead of re-copying all data on every run, the pipeline reads a watermark value per source from `dbo.pipeline_parameters`, extracts only rows newer than that value, and updates the watermark after each successful copy. This is the production pattern for the NYC yellow taxi monthly ingestion workflow.

---

## Scenario

The NYC yellow taxi dataset grows by roughly 3 million rows per month. Re-copying the entire history on every daily pipeline run wastes time and capacity. With watermark-based incremental load:

- The first run copies all available data
- Each subsequent run copies only rows where `tpep_pickup_datetime` is greater than the last recorded watermark
- The watermark is updated in `dbo.pipeline_parameters` after each successful copy
- If a run fails, the watermark is not updated and the next run automatically retries the same window

---

## Step 1: Add Watermark Parameters

Extend the parameters seeded in `multi-table-copy.md` with watermark settings for the yellow taxi source. Run these INSERT statements against your Fabric SQL Database:

```sql
-- Watermark settings for Yellow Taxi incremental load
INSERT INTO dbo.pipeline_parameters 
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_load_type',       'Incremental',          'string',   'Switch from Full to Incremental',                      'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_watermark_col',   'tpep_pickup_datetime', 'string',   'Column used to filter new rows at the source',         'all'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_watermark_value', '1900-01-01T00:00:00',  'datetime', 'Last loaded watermark. Updated after each successful run', 'dev'),
    ('PL_MetaDriven_Bronze_Ingest', 'source_1_watermark_value', '2024-01-01T00:00:00',  'datetime', 'Last loaded watermark for production',                 'prod');
```

The `1900-01-01` sentinel value for dev means "no prior watermark — copy everything." The pipeline detects this and runs a full load on the first execution, then switches to incremental for all subsequent runs.

---

## Step 2: Add a Watermark Update Stored Procedure

The standard `dbo.usp_log_pipeline_event` handles logging. For the watermark update, add a dedicated stored procedure that updates the `parameter_value` for the watermark row after a successful copy:

```sql
CREATE OR ALTER PROCEDURE dbo.usp_update_watermark
    @pipeline_name      NVARCHAR(200),
    @parameter_name     NVARCHAR(200),
    @new_watermark      NVARCHAR(50),
    @environment        NVARCHAR(50) = 'all'
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.pipeline_parameters
    SET    parameter_value = @new_watermark,
           modified_at     = SYSUTCDATETIME()
    WHERE  pipeline_name   = @pipeline_name
    AND    parameter_name  = @parameter_name
    AND    environment     = @environment;
END;
GO
```

---

## Step 3: Prompt the Agent

Open Copilot Chat in agent mode, select the **pipeline-builder** agent, and use this prompt:

```
Update PL_MetaDriven_Bronze_Ingest to support incremental load for the yellow taxi source.

For sources where load_type = 'Incremental':
- Read source_N_watermark_col and source_N_watermark_value from the parameters table
- Add a source filter to the Copy Job that only extracts rows where the watermark 
  column is greater than the last watermark value
- After a successful copy, call dbo.usp_update_watermark via a Script activity to 
  update source_N_watermark_value with the new high watermark
- Use a Script activity (not Execute Stored Procedure) for the watermark update call
- Only update the watermark after the Copy Job has fully succeeded — 
  use an on-success edge to enforce this ordering

The watermark update Script activity should pass:
  @pipeline_name    = @pipeline().Pipeline
  @parameter_name   = the source_N_watermark_value parameter name for this source
  @new_watermark    = the MAX value of the watermark column from the data just copied
  @environment      = the environment parameter value
```

---

## Step 4: Pipeline Pattern with Watermark Update

The agent will design the following inner canvas pattern for incremental sources:

```
[CJ_Ingest_Source] — Copy Job with watermark filter on source
    ↓ on-success
[SCR_Update_Watermark] — Script activity → dbo.usp_update_watermark
    ↓ on-success
[Log_Success] — Script activity → dbo.usp_log_pipeline_event
    
[CJ_Ingest_Source]
    ↓ on-failure
[Log_Failure] — Script activity → dbo.usp_log_pipeline_event
    (watermark is NOT updated on failure — next run retries the same window)
```

The critical detail is the ordering: the watermark update only runs on the on-success edge from the Copy Job. If the Copy Job fails for any reason, the watermark stays at its previous value and the next scheduled run automatically re-attempts the same data window.

---

## Key Pipeline Expressions

These expressions drive the incremental filter and watermark update inside the ForEach inner canvas:

```
// Source filter expression for the Copy Job
// Reads the watermark column name and last value from parameters
@concat(
    first(filter(activity('LookupParams').output.value,
        item().parameter_name == concat('source_', variables('SourceIndex'), '_watermark_col')
    )).parameter_value,
    ' > ''',
    first(filter(activity('LookupParams').output.value,
        item().parameter_name == concat('source_', variables('SourceIndex'), '_watermark_value')
    )).parameter_value,
    ''''
)

// New watermark value passed to usp_update_watermark after successful copy
// Uses the Copy Job activity output to get the max watermark from the copied data
@activity('CJ_Ingest_Source').output.value[0].output.maxWatermark
```

---

## Checking Watermark State

After each pipeline run, verify that the watermark advanced correctly:

```sql
SELECT  pipeline_name,
        parameter_name,
        parameter_value     AS current_watermark,
        modified_at         AS last_updated
FROM    dbo.pipeline_parameters
WHERE   pipeline_name  = 'PL_MetaDriven_Bronze_Ingest'
AND     parameter_name LIKE '%watermark_value%'
ORDER BY parameter_name;
```

If the watermark did not advance after a run, check `dbo.pipeline_logging` for a failure event on the SCR_Update_Watermark activity.

---

## Resetting the Watermark

To force a full reload of a source — for example after a schema change or a known data gap — reset the watermark to the sentinel value:

```sql
UPDATE dbo.pipeline_parameters
SET    parameter_value = '1900-01-01T00:00:00',
       modified_at     = SYSUTCDATETIME()
WHERE  pipeline_name   = 'PL_MetaDriven_Bronze_Ingest'
AND    parameter_name  = 'source_1_watermark_value'
AND    environment     = 'prod';
```

The next pipeline run will detect the sentinel value and perform a full load, then resume incremental from the new high watermark going forward.

---

## Environment-Specific Watermarks

The `environment` column in `dbo.pipeline_parameters` lets dev and prod maintain independent watermark state. The dev environment starts from `1900-01-01` (full load every time for testing) while prod tracks the real watermark. This means you can test the incremental logic in dev without affecting the production watermark state.

---

## Related Examples

- [multi-table-copy.md](multi-table-copy.md) — base pattern this example extends
- [stored-proc-sequence.md](stored-proc-sequence.md) — running post-load transformations after incremental ingestion
