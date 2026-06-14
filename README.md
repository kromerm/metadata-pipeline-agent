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
3. A **`SqlServerStoredProcedure` activity** writes Start, Success, and Failure events to `dbo.pipeline_logging` by calling `dbo.usp_log_pipeline_event`.

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
- The Lookup `typeProperties` must include `datasetSettings` with `connectionSettings` pointing to the SQL connection (see pattern below)

**Lookup / SqlServerStoredProcedure fails — connection not found**
- Lookup requires `datasetSettings.connectionSettings` inside `typeProperties` (not `externalReferences` at the activity level)
- `SqlServerStoredProcedure` requires `connectionSettings` at the activity level with `externalReferences` inside it
- See the confirmed JSON patterns in `.github/copilot-instructions.md`

**Can't see notebook output from the Fabric REST API**
- The jobs status endpoint returns lifecycle state only. Verify runs by querying `dbo.pipeline_logging` directly.

---

## Local Verification & Manual Database Connection

After running a pipeline, query `dbo.pipeline_logging` directly from your local machine to confirm rows were written. This is the most reliable verification method — the Fabric REST API returns only lifecycle metadata, not cell output.

### Authentication

Fabric SQL Database uses **Azure Active Directory token authentication only** — username/password and SQL auth are not supported. Use `pyodbc` with a bearer token from the Azure CLI.

### Prerequisites

- Python 3.12+ with `pyodbc` installed: `pip install pyodbc`
  - Note: As of May 2026, `pyodbc` 5.x does not install cleanly on Python 3.14. Use 3.12.
- [ODBC Driver 18 for SQL Server](https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server)
- Azure CLI authenticated: `az login`

### Connection String Format

Your Fabric SQL Database endpoint follows this pattern:
```
<encoded-workspace-id>.msit-database.fabric.microsoft.com,1433
```
This is **different from Azure SQL** (`*.database.windows.net`). Find your endpoint in the Fabric portal → SQL Database item → Settings → Connection strings.

### Local Verification Script

```python
import pyodbc, struct, subprocess, json

# On Windows, Python subprocess cannot resolve 'az' via PATH.
# Always use the full path to az.cmd.
AZ_CMD = r'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'

result = subprocess.run(
    [AZ_CMD, 'account', 'get-access-token', '--resource', 'https://database.windows.net/'],
    capture_output=True, text=True, shell=False
)
access_token = json.loads(result.stdout)['accessToken']

# Package token in the format pyodbc expects for SQL_COPT_SS_ACCESS_TOKEN
token_bytes = access_token.encode('utf-16-le')
token_struct = struct.pack(f'<I{len(token_bytes)}s', len(token_bytes), token_bytes)
SQL_COPT_SS_ACCESS_TOKEN = 1256

SERVER   = '<your-workspace-endpoint>.msit-database.fabric.microsoft.com,1433'
DATABASE = 'YourDatabaseName-<guid>'

conn_str = (
    f'DRIVER={{ODBC Driver 18 for SQL Server}};'
    f'SERVER={SERVER};DATABASE={DATABASE};'
    'Encrypt=yes;TrustServerCertificate=yes'
)
conn = pyodbc.connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct})

cursor = conn.cursor()
cursor.execute('''
    SELECT pipeline_name, pipeline_run_id, log_level, status, message, logged_at
    FROM dbo.pipeline_logging
    ORDER BY logged_at DESC
''')
for row in cursor.fetchall():
    print(row)
cursor.close()
conn.close()
```

A ready-to-run version of this script is included in this repo as [`local_verify.py`](local_verify.py).

### Inside Fabric Notebooks

When running inside a Fabric Notebook activity, use `notebookutils` to get the token — no `az` CLI required:

```python
access_token = notebookutils.credentials.getToken('https://database.windows.net/')
```

The rest of the pyodbc pattern is identical to the local script above.

---

## Contributing

Issues and pull requests welcome. See [`sql/schema.sql`](sql/schema.sql) for the full schema — if you extend the tables, update the stored procedure and the agent instructions accordingly.

---

## License

MIT
