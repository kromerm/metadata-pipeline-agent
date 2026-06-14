This folder contains samples that you can use with the NYC Taxi data.

## Contents

| File | What it is |
|------|------------|
| [`PL_MetaDriven_Bronze_Ingest.json`](PL_MetaDriven_Bronze_Ingest.json) | **Complete, deployable pipeline definition.** A reference artifact showing the full metadata-driven pattern (Lookup params → Log_Start → GetMetadata → ForEach Copy → Log_Success / Log_Failure) using only the confirmed-working activity JSON formats. Replace the `<...-guid>` / `<...-display-name>` placeholders before deploying. |
| [`multi-table-copy.md`](multi-table-copy.md) | Walkthrough: copy multiple NYC taxi sources into a Lakehouse bronze layer, all driven from `dbo.pipeline_parameters`. |
| [`incremental-watermark.md`](incremental-watermark.md) | Walkthrough: add watermark tracking for incremental loads. |
| [`stored-proc-sequence.md`](stored-proc-sequence.md) | Walkthrough: run post-load stored procedures in a configurable order. |
