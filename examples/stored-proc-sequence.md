# Example: Stored Procedure Sequence for Post-Load Transformation

This example shows how to use the metadata-driven pipeline agent to run a configurable sequence of stored procedures after bronze ingestion completes. The list of procedures, their execution order, and their parameters all live in `dbo.pipeline_parameters`. This is the pattern for running post-load data quality checks, silver layer transformations, and gold layer aggregations as a coordinated, ordered sequence without hard-coding any procedure names or parameters in the pipeline itself.

---

## Scenario

After the NYC yellow taxi bronze ingestion runs each month, we need to execute three post-load steps in a specific order:

| Step | Procedure | Purpose |
|------|-----------|---------|
| 1 | `dbo.usp_validate_bronze_taxi` | Data quality checks on the freshly landed bronze data |
| 2 | `dbo.usp_transform_silver_taxi` | Transform bronze to silver: filters, derived columns, zone lookup join |
| 3 | `dbo.usp_refresh_gold_aggregates` | Rebuild gold layer aggregation tables from the updated silver data |

If any step fails, subsequent steps should not run. The pipeline logs each step's start, success, or failure to `dbo.pipeline_logging`.

---

## Step 1: Create the Post-Load Stored Procedures

These are the three stored procedures the pipeline will call. Deploy them to your Fabric SQL Database or Fabric Warehouse depending on where your transformation logic lives.

```sql
-- Step 1: Bronze data quality validation
CREATE OR ALTER PROCEDURE dbo.usp_validate_bronze_taxi
    @process_month  NVARCHAR(10),   -- format: yyyy-MM
    @min_row_count  INT = 100000    -- fail if fewer rows than this
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @row_count INT;

    -- Count rows for the process month in the bronze table
    -- Adjust the table name and filter to match your bronze schema
    SELECT @row_count = COUNT(*)
    FROM   dbo.yellow_tripdata
    WHERE  FORMAT(tpep_pickup_datetime, 'yyyy-MM') = @process_month;

    IF @row_count < @min_row_count
    BEGIN
        RAISERROR(
            'Bronze validation failed for %s: found %d rows, expected at least %d.',
            16, 1,
            @process_month, @row_count, @min_row_count
        );
        RETURN;
    END

    PRINT CONCAT('Bronze validation passed for ', @process_month, ': ', @row_count, ' rows.');
END;
GO

-- Step 2: Silver layer transformation
CREATE OR ALTER PROCEDURE dbo.usp_transform_silver_taxi
    @process_month  NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    -- Merge bronze data into the silver table with quality filters and derived columns.
    -- This is a simplified example — adapt to your actual silver schema.
    MERGE dbo.silver_yellow_taxi_trips AS target
    USING (
        SELECT
            VendorID,
            tpep_pickup_datetime,
            tpep_dropoff_datetime,
            passenger_count,
            trip_distance,
            PULocationID,
            DOLocationID,
            fare_amount,
            tip_amount,
            total_amount,
            DATEDIFF(minute, tpep_pickup_datetime, tpep_dropoff_datetime) AS trip_duration_minutes,
            CASE WHEN fare_amount > 0
                 THEN tip_amount / fare_amount * 100.0
                 ELSE 0 END                                               AS tip_pct,
            zpu.Borough AS pickup_borough,
            zpu.Zone    AS pickup_zone,
            zdo.Borough AS dropoff_borough,
            zdo.Zone    AS dropoff_zone
        FROM  dbo.yellow_tripdata        b
        LEFT JOIN dbo.taxi_zone_lookup   zpu ON b.PULocationID = zpu.LocationID
        LEFT JOIN dbo.taxi_zone_lookup   zdo ON b.DOLocationID = zdo.LocationID
        WHERE fare_amount   > 0
          AND trip_distance > 0
          AND tpep_pickup_datetime < tpep_dropoff_datetime
          AND FORMAT(tpep_pickup_datetime, 'yyyy-MM') = @process_month
    ) AS source
    ON  target.VendorID              = source.VendorID
    AND target.tpep_pickup_datetime  = source.tpep_pickup_datetime
    WHEN MATCHED THEN UPDATE SET
        target.trip_duration_minutes = source.trip_duration_minutes,
        target.tip_pct               = source.tip_pct,
        target.pickup_borough        = source.pickup_borough,
        target.pickup_zone           = source.pickup_zone,
        target.dropoff_borough       = source.dropoff_borough,
        target.dropoff_zone          = source.dropoff_zone
    WHEN NOT MATCHED THEN INSERT (
        VendorID, tpep_pickup_datetime, tpep_dropoff_datetime,
        passenger_count, trip_distance, PULocationID, DOLocationID,
        fare_amount, tip_amount, total_amount,
        trip_duration_minutes, tip_pct,
        pickup_borough, pickup_zone, dropoff_borough, dropoff_zone
    )
    VALUES (
        source.VendorID, source.tpep_pickup_datetime, source.tpep_dropoff_datetime,
        source.passenger_count, source.trip_distance, source.PULocationID, source.DOLocationID,
        source.fare_amount, source.tip_amount, source.total_amount,
        source.trip_duration_minutes, source.tip_pct,
        source.pickup_borough, source.pickup_zone, source.dropoff_borough, source.dropoff_zone
    );

    PRINT CONCAT('Silver transformation complete for ', @process_month, ': ', @@ROWCOUNT, ' rows merged.');
END;
GO

-- Step 3: Gold layer aggregation refresh
CREATE OR ALTER PROCEDURE dbo.usp_refresh_gold_aggregates
    @process_month  NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    -- Refresh average fare and tip by pickup borough and hour of day.
    -- Truncate and reload the affected month's partition.
    DELETE FROM dbo.gold_fare_by_borough_hour
    WHERE  process_month = @process_month;

    INSERT INTO dbo.gold_fare_by_borough_hour
        (process_month, pickup_borough, hour_of_day, avg_fare, avg_tip_pct, trip_count)
    SELECT
        FORMAT(tpep_pickup_datetime, 'yyyy-MM')     AS process_month,
        pickup_borough,
        DATEPART(hour, tpep_pickup_datetime)        AS hour_of_day,
        AVG(fare_amount)                            AS avg_fare,
        AVG(tip_pct)                                AS avg_tip_pct,
        COUNT(*)                                    AS trip_count
    FROM  dbo.silver_yellow_taxi_trips
    WHERE FORMAT(tpep_pickup_datetime, 'yyyy-MM') = @process_month
      AND pickup_borough IS NOT NULL
    GROUP BY
        FORMAT(tpep_pickup_datetime, 'yyyy-MM'),
        pickup_borough,
        DATEPART(hour, tpep_pickup_datetime);

    PRINT CONCAT('Gold aggregates refreshed for ', @process_month, ': ', @@ROWCOUNT, ' rows.');
END;
GO
```

---

## Step 2: Seed the Parameters Table

Run these INSERT statements to configure the three-step sequence for the pipeline named `PL_PostLoad_Transform`:

```sql
-- Step 1: Bronze validation
INSERT INTO dbo.pipeline_parameters
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_PostLoad_Transform', 'step_1_proc',           'dbo.usp_validate_bronze_taxi',     'string',   'Stored procedure to call for step 1',          'all'),
    ('PL_PostLoad_Transform', 'step_1_name',           'Bronze Validation',                'string',   'Display name for logging',                     'all'),
    ('PL_PostLoad_Transform', 'step_1_order',          '1',                                'int',      'Execution order — lower numbers run first',    'all'),
    ('PL_PostLoad_Transform', 'step_1_enabled',        'true',                             'bool',     'Set to false to skip this step',               'all'),
    ('PL_PostLoad_Transform', 'step_1_min_row_count',  '100000',                           'int',      'Minimum row count threshold for validation',   'all');

-- Step 2: Silver transformation
INSERT INTO dbo.pipeline_parameters
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_PostLoad_Transform', 'step_2_proc',           'dbo.usp_transform_silver_taxi',    'string',   'Stored procedure to call for step 2',          'all'),
    ('PL_PostLoad_Transform', 'step_2_name',           'Silver Transformation',            'string',   'Display name for logging',                     'all'),
    ('PL_PostLoad_Transform', 'step_2_order',          '2',                                'int',      'Execution order',                              'all'),
    ('PL_PostLoad_Transform', 'step_2_enabled',        'true',                             'bool',     'Set to false to skip this step',               'all');

-- Step 3: Gold aggregates
INSERT INTO dbo.pipeline_parameters
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_PostLoad_Transform', 'step_3_proc',           'dbo.usp_refresh_gold_aggregates',  'string',   'Stored procedure to call for step 3',          'all'),
    ('PL_PostLoad_Transform', 'step_3_name',           'Gold Aggregates',                  'string',   'Display name for logging',                     'all'),
    ('PL_PostLoad_Transform', 'step_3_order',          '3',                                'int',      'Execution order',                              'all'),
    ('PL_PostLoad_Transform', 'step_3_enabled',        'true',                             'bool',     'Set to false to skip this step',               'all');

-- Shared pipeline settings
INSERT INTO dbo.pipeline_parameters
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_PostLoad_Transform', 'enable_logging',        'true',                             'bool',     'Write to pipeline_logging table',              'all'),
    ('PL_PostLoad_Transform', 'log_level',             'INFO',                             'string',   'Minimum log level',                            'all'),
    ('PL_PostLoad_Transform', 'fail_on_step_failure',  'true',                             'bool',     'Stop the sequence if any step fails',          'all');
```

---

## Step 3: Prompt the Agent

Open Copilot Chat in agent mode, select the **pipeline-builder** agent, and use this prompt:

```
Build me a pipeline called PL_PostLoad_Transform that runs a sequence of stored 
procedures in order after the bronze ingestion completes.

The pipeline should:
- Read all enabled steps for this pipeline from dbo.pipeline_parameters, 
  ordered by step_N_order
- For each enabled step, call the stored procedure named in step_N_proc 
  using a Script activity, passing @process_month from the pipeline parameter
- Stop the sequence immediately if any step fails (do not run later steps)
- Log Start, Success, and Failure events for each step to dbo.pipeline_logging 
  using the step_N_name value as the activity_name
- Use a Script activity (not Execute Stored Procedure) for all stored procedure 
  calls and all logging calls

The pipeline accepts a single parameter: ProcessMonth (string, format yyyy-MM).
```

---

## Step 4: Pipeline Pattern

The agent will design the following sequential pattern:

```
[LookupParams] — reads all enabled steps ordered by step_N_order
        ↓
[Log_Start]
        ↓
[ForEach_Steps] — iterates over steps in order, batch count = 1 (sequential)
    └── [SCR_Execute_Step] — Script activity calls step_N_proc
        ↓ success          ↓ failure
    [Log_Step_Success]  [Log_Step_Failure]
                            ↓
                        [Fail_Activity] — stops the ForEach and fails the pipeline
        ↓
[Log_Pipeline_Success]
```

The ForEach batch count is set to 1 here because the steps must run in strict order: bronze validation must pass before silver transformation runs, and silver must complete before gold aggregates are refreshed. Setting batch count to 1 ensures sequential execution.

---

## Skipping a Step Without Removing It

To skip the gold aggregates refresh without removing its configuration — for example during a maintenance window:

```sql
UPDATE dbo.pipeline_parameters
SET    is_enabled = 0
WHERE  pipeline_name   = 'PL_PostLoad_Transform'
AND    parameter_name  = 'step_3_enabled';
```

The pipeline will read the updated parameters on the next run and skip step 3 automatically.

---

## Adding a New Step

To add a fourth step — for example a semantic model refresh — without touching the pipeline:

```sql
INSERT INTO dbo.pipeline_parameters
    (pipeline_name, parameter_name, parameter_value, data_type, description, environment)
VALUES
    ('PL_PostLoad_Transform', 'step_4_proc',    'dbo.usp_refresh_semantic_model',   'string', 'Refresh Power BI semantic model',  'all'),
    ('PL_PostLoad_Transform', 'step_4_name',    'Semantic Model Refresh',           'string', 'Display name for logging',         'all'),
    ('PL_PostLoad_Transform', 'step_4_order',   '4',                                'int',    'Runs after gold aggregates',       'all'),
    ('PL_PostLoad_Transform', 'step_4_enabled', 'true',                             'bool',   'Enabled by default',               'all');
```

No pipeline changes required. The ForEach loop will pick up the new row on the next run.

---

## Verifying the Sequence

After the pipeline runs, check the execution log to confirm all steps ran in order:

```sql
SELECT  activity_name,
        status,
        message,
        duration_seconds,
        logged_at
FROM    dbo.pipeline_logging
WHERE   pipeline_name   = 'PL_PostLoad_Transform'
AND     pipeline_run_id = '<your-run-id>'
ORDER BY logged_at;
```

A successful run will show Log_Start, then one success row per enabled step in order, then Log_Pipeline_Success.

---

## Chaining with the Bronze Ingestion Pipeline

To run the post-load transformation automatically after bronze ingestion, add an Invoke Pipeline activity to `PL_MetaDriven_Bronze_Ingest` on the on-success edge after the ForEach ingestion loop:

```
[FE_Ingest_Sources]
        ↓ on-success
[Invoke PL_PostLoad_Transform]
    parameter: ProcessMonth = @variables('ProcessMonth')
        ↓ on-success          ↓ on-failure
[Log_Success]             [Log_Failure + Teams notification]
```

This gives you a single scheduled pipeline that handles the full bronze-to-gold flow for the NYC taxi medallion architecture.

---

## Related Examples

- [multi-table-copy.md](multi-table-copy.md) — bronze ingestion pattern this example chains with
- [incremental-watermark.md](incremental-watermark.md) — incremental load pattern to run before this sequence
