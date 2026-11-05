# Databricks SQL Warehouse Cost and Governance Review

A ready-to-run notebook that reviews your Databricks SQL warehouses for **right-sizing, scaling, idle cost, query timeouts, efficiency and governance**, and that ties cost back to each of your customers so you can see the margin per account.

It is **read-only**. Every cell is SQL against Databricks system tables. Nothing is created, changed or deleted.

## What you get

| File | Use it for |
|---|---|
| `notebooks/SQL_Warehouse_Cost_Review.sql` | Databricks notebook (source format). Import this one into a workspace. |
| `notebooks/SQL_Warehouse_Cost_Review.ipynb` | The same notebook as Jupyter, for viewing on GitHub or importing as `.ipynb`. |

## What it checks

| Check | Question it answers |
|---|---|
| 0. Data check | Do I have access to the data this review needs? |
| 1. Inventory | What warehouses do we run, and how are they set up? |
| 2. Statement timeout | What stops a runaway query? |
| 3. Cost | Where does the money go, and what does a query cost? |
| 4. Size | Is each warehouse the right size? |
| 5. Scaling | Are min and max clusters right for the load? |
| 6. Auto-stop | How much do we pay for idle time? |
| 7. Efficiency | Are we repeating work we could cache? |
| 8. Wasted work | Are we paying for queries that fail or get cancelled? |
| 9. Customer margin | What does each customer cost us to serve? |
| 10. Governance | Who can change warehouses, and who hears about a spike? |
| 11. Scorecard | What do we change, and in what order? |

Each check starts with **what we're checking**, **the impact if it's off**, and **what good looks like**, then gives the query and how to read it.

## Before you run (read this first)

### 1. Pick the right compute
- In the notebook, open the compute dropdown (top right) and select **Serverless**. A **SQL warehouse** also works.
- Every cell is SQL except **one short Python cell in check 2a**, which reads your statement-timeout setting through the Databricks API. It runs on serverless notebook compute (the Databricks SDK is built in) and needs **workspace admin** rights. If it errors, the notebook lists three alternatives (Settings UI, SQL editor, CLI).
- Use a **Medium or larger** SQL warehouse if your query history is very large; the queries scan system tables.
- **Do not add `SET STATEMENT_TIMEOUT` as a notebook cell.** On serverless notebook compute it fails with `Configuration STATEMENT_TIMEOUT is not available`. It only works in the **SQL editor with a SQL warehouse selected**.

### 2. Make sure you can read the system tables
You need `SELECT` on these tables. A metastore admin can grant it:

```sql
GRANT USE CATALOG ON CATALOG system TO `<group-or-user>`;
GRANT USE SCHEMA, SELECT ON SCHEMA system.billing TO `<group-or-user>`;
GRANT USE SCHEMA, SELECT ON SCHEMA system.compute TO `<group-or-user>`;
GRANT USE SCHEMA, SELECT ON SCHEMA system.query   TO `<group-or-user>`;
GRANT USE SCHEMA, SELECT ON SCHEMA system.access  TO `<group-or-user>`;
```

Tables used: `system.compute.warehouses`, `system.compute.warehouse_events`, `system.query.history`, `system.billing.usage`, `system.billing.list_prices`, `system.access.audit`.

### 3. Make sure the system schemas are enabled
If a table does not exist, an account or metastore admin must enable that schema:

```bash
databricks system-schemas list   <metastore-id>
databricks system-schemas enable <metastore-id> <schema-name>   # e.g. compute, query, access, billing
```

### 4. Run check 0 first
Check 0 counts rows in each table and says `OK` or `EMPTY`. If anything is empty, fix that first. **An empty result is almost always access, scope or data timing, not a finding about your warehouses.**

## How to run

**Option A, UI:** *Workspace → Import* → choose `notebooks/SQL_Warehouse_Cost_Review.sql` (or the `.ipynb`) → open it → select compute → run cells top to bottom.

**Option B, CLI:**
```bash
databricks workspace import /Users/<you>/SQL_Warehouse_Cost_Review \
  --file notebooks/SQL_Warehouse_Cost_Review.sql --language SQL --format SOURCE
```

Every query is self-contained, so you can also paste any single one into the SQL editor, a dashboard, or a SQL alert.

## Gotchas

| Gotcha | What to know |
|---|---|
| **Scope is the whole metastore** | System tables include **every workspace attached to the same metastore**, not just the one you run in. To focus on one workspace, add `AND workspace_id = '<id>'` to a query's `WHERE` clause (the id is after `?o=` in the workspace URL). |
| **Query history access** | `system.query.history` is admin-visible by default. If you are not an admin you will see little or nothing until it is granted. |
| **Data lag** | Query history usually lands within about an hour; billing can lag a few hours. Brand-new warehouses will look empty. |
| **Old warehouses missing from inventory** | `system.compute.warehouses` only records warehouses created or edited after it started recording. Queries here use left joins, so those warehouses still appear, but with an ID instead of a name and blank size. A second query in check 0 lists them. |
| **List prices** | Dollar figures are at **list price**. Apply your own discount to get real dollars. |
| **Estimates** | Idle time, per-customer allocation and the `approx_dbu_per_hour` reference rates are estimates for ranking and direction, not invoice-level numbers. Confirm DBU rates on the current pricing page. |
| **Statements and emails in results** | Checks 2d, 7b and 7c show the first characters of SQL text and user emails. Hide those columns before sharing your screen. |
| **Customer margin needs a customer identifier** | Check 9 reads a `customer` **query tag** (`SET QUERY_TAGS['customer'] = '...'`), then falls back to the user or service principal that ran the query. If neither identifies the customer, attribution will be coarse. Check 9a shows how much can be attributed. |
| **Sample revenue rows** | Check 9c ships with three sample rows (`customer_a`, `customer_b`, `customer_c`). Replace them with your real customers and what each paid for the same 30 days. |
| **Changing a timeout restarts warehouses** | If you act on check 2 by setting a workspace-level `STATEMENT_TIMEOUT`, saving it restarts running SQL warehouses. Do it in a quiet window. |
| **Time zone** | All dates and hours are UTC. |

## Customizing

- **Look-back window:** every query uses `30 DAYS`. Find and replace `30 DAYS` with `7 DAYS`, `90 DAYS`, and so on.
- **Customer tag key:** the notebook reads the query tag `customer`. Find and replace `['customer']` to use another key.
- **Narrow to some warehouses:** add `AND h.compute.warehouse_id IN ('<id1>', '<id2>')` to the `q` CTE of a query.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Check 0 shows `EMPTY` | No grant, schema not enabled, a different metastore, or data not landed yet. See "Before you run". |
| `TABLE_OR_VIEW_NOT_FOUND` on a `system.*` table | That system schema is not enabled. See step 3. |
| `PERMISSION_DENIED` / `INSUFFICIENT_PERMISSIONS` | Missing `USE CATALOG` / `USE SCHEMA` / `SELECT`. See step 2. |
| Queries are slow | Use a larger warehouse, or shorten the look-back window. |
| Check 2a (Python cell) shows `ERROR` | It needs workspace admin rights. Use the alternatives under the cell: *Settings → Compute → Manage → SQL Configuration Parameters*, or `SET STATEMENT_TIMEOUT;` in the SQL editor with a warehouse selected. |
| Warehouse shows only an ID | It is missing from the inventory table (see gotchas). Look it up under *Compute → SQL Warehouses*. |

## Tested

Written and validated against Databricks system tables on **AWS** in October 2026 (all 26 SQL queries executed successfully, and the Python cell in check 2a ran successfully on serverless compute). The SQL uses standard system-table columns, but Azure and GCP were **not** tested. System table schemas can change; if a column is renamed, adjust the query.

## Disclaimer

Provided as-is, without warranty. Review the queries before running them in a production workspace. Findings are starting points for discussion and should be verified before you change any warehouse setting.
