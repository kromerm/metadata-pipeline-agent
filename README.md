# Fabric Metadata-Driven Pipeline Agent

A GitHub Copilot agent that helps you build **metadata-driven Microsoft Fabric Data Factory pipelines** — pipelines that read runtime configuration from a Fabric SQL Database table and write structured logs to a second table.

Drop this repo into your GitHub project and Copilot will help you design, create, and operate pipelines without hard-coding any parameter values inside the pipeline itself.

---

## How It Works

The agent builds every pipeline around two SQL tables in your Fabric SQL Database:

| Table | Purpose |
|-------|---------|
| `dbo.pipeline_parameters` | Controls pipeline behavior — batch sizes, source tables, thresholds, flags, etc. |
| `dbo.pipeline_logging` | Captures a structured log of every pipeline run and activity |

**Pattern:**

1. A **Lookup activity** reads all enabled parameters for the current pipeline from `dbo.pipeline_parameters`.
2. Your business logic activities use those values via dynamic expressions — no hard-coded config.
3. A **Script / Execute SP activity** writes Start, Success, and Failure events to `dbo.pipeline_logging` by calling `dbo.usp_log_pipeline_event`.

Change pipeline behavior by updating rows in SQL — no pipeline edits, no redeployments.

---

## Prerequisites

- **VS Code** with the [GitHub Copilot](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot) and [GitHub Copilot Chat](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot-chat) extensions
- **Copilot agent mode** enabled (VS Code 1.99+ / Copilot Chat 0.26+)
- **.NET 10 SDK** (for the MCP server)
- A **Microsoft Fabric workspace** with:
  - Data Factory enabled
  - A **Fabric SQL Database** provisioned

---

## Setup

### 1 — Install the Fabric Data Factory MCP Server

```bash
dotnet tool install --global microsoft.fabric.mcp
```

Verify:

```bash
fabmcp --version
```

### 2 — Configure the MCP Server in VS Code

Create or update `.vscode/mcp.json` in your project:

```json
{
  "mcp": {
    "servers": {
      "datafactory": {
        "command": "fabmcp"
      }
    }
  }
}
```

Restart VS Code after saving.

### 3 — Deploy the SQL Schema

Connect to your **Fabric SQL Database** (not Azure SQL DB — this is the native Fabric SQL Database item) and execute [`sql/schema.sql`](sql/schema.sql). This creates:

- `dbo.pipeline_parameters` — runtime configuration table
- `dbo.pipeline_logging` — structured log table
- `dbo.usp_log_pipeline_event` — stored procedure used by pipelines to write logs
- Sample seed data for a demo pipeline named `pl_metadata_demo`

### 4 — (Optional) Add Custom Log Columns

If your pipelines need to log extra context (source table names, batch IDs, file paths, etc.), add columns to `dbo.pipeline_logging` now:

```sql
ALTER TABLE dbo.pipeline_logging ADD source_table NVARCHAR(200) NULL;
ALTER TABLE dbo.pipeline_logging ADD batch_id     NVARCHAR(100) NULL;
-- Add as many as you need
```

Tell the agent about these columns when you start building a pipeline and it will wire them into every log activity automatically.

---

## Usage

Open Copilot Chat in agent mode and select the **pipeline-builder** agent (defined in `agents/pipeline-builder.agent.md`).

Then describe your orchestration pattern in plain English:

```
Build me a pipeline that copies data from 10 source tables to a Lakehouse delta table.
I want to control which tables are included, the watermark column name, and whether to
do a full or incremental load — all from the parameters table.
```

The agent will:

1. Confirm the pipeline design with you before building anything
2. Generate `INSERT` statements to seed `dbo.pipeline_parameters` for your pipeline
3. Create the pipeline in your Fabric workspace via the MCP tools
4. Wire the Lookup activity (param read) and SP activities (logging) automatically
5. Offer a test run and show you the results from `dbo.pipeline_logging`

---

## Repository Structure

```
.github/
  copilot-instructions.md   # Global Copilot behavior for this repo
agents/
  pipeline-builder.agent.md # Copilot agent mode definition
sql/
  schema.sql                # DDL for both tables + stored procedure + sample data
examples/                   # (optional) Example pipeline patterns
README.md
```

---

## SQL Schema Quick Reference

### `dbo.pipeline_parameters`

| Column | Type | Description |
|--------|------|-------------|
| `pipeline_name` | NVARCHAR(200) | Pipeline this row belongs to |
| `parameter_name` | NVARCHAR(200) | Parameter key |
| `parameter_value` | NVARCHAR(MAX) | Parameter value (always stored as string) |
| `data_type` | VARCHAR(20) | `string`, `int`, `bool`, `float`, `datetime` |
| `is_enabled` | BIT | Set to 0 to disable without deleting |
| `environment` | VARCHAR(20) | `dev`, `test`, `prod`, or `all` |

### `dbo.pipeline_logging`

| Column | Type | Description |
|--------|------|-------------|
| `pipeline_run_id` | NVARCHAR(100) | Fabric pipeline run ID |
| `activity_name` | NVARCHAR(200) | Which activity logged this event |
| `log_level` | VARCHAR(10) | `DEBUG`, `INFO`, `WARN`, `ERROR` |
| `status` | VARCHAR(20) | `Started`, `Succeeded`, `Failed`, `Skipped` |
| `message` | NVARCHAR(MAX) | Human-readable log message |
| `rows_read` / `rows_written` | BIGINT | Row counts (optional) |
| `logged_at` | DATETIME2 | Auto-set by the stored procedure |
| *(your custom columns)* | — | Add with `ALTER TABLE` |

---

## Troubleshooting

**MCP server not found**
- Confirm `dotnet tool install --global Microsoft.DataFactory.MCP` completed successfully
- Ensure `%USERPROFILE%\.dotnet\tools` is on your `PATH`

**Authentication errors**
- The agent will call `mcp_datafactorymc_authenticate_interactive` — complete the browser auth flow when prompted

**"Pipeline already exists" error**
- Use `mcp_datafactorymc_list_pipelines` to check, or rename your pipeline

**Lookup activity returns no rows**
- Check that `pipeline_name` in `dbo.pipeline_parameters` exactly matches `@pipeline().Pipeline` (case-sensitive)
- Confirm `is_enabled = 1` and `environment` matches your target environment

---

## Contributing

Issues and pull requests welcome. See [`sql/schema.sql`](sql/schema.sql) for the full schema — if you extend the tables, update the stored procedure and the agent instructions accordingly.

---

## License

MIT
