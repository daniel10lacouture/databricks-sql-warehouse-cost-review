-- Databricks notebook source

-- COMMAND ----------

-- MAGIC %md
-- MAGIC # SQL Warehouse Cost and Governance Review
-- MAGIC
-- MAGIC **Purpose:** check that your SQL warehouses are right-sized, have the right guardrails, and that you can tie cost back to each customer so you know the margin on every account.
-- MAGIC
-- MAGIC **How to run this notebook**
-- MAGIC - Run any cell on its own, top to bottom. There is nothing to configure: no widgets, no parameters.
-- MAGIC - Every query is plain SQL, so you can also paste any one of them into the SQL editor and run it there.
-- MAGIC - Every query looks back **30 days**. To change that, find and replace `30 DAYS` with `7 DAYS`, `90 DAYS`, and so on.
-- MAGIC - Costs are at **list price**. Apply your own discount to get real dollars.
-- MAGIC
-- MAGIC | Check | Question it answers |
-- MAGIC |---|---|
-- MAGIC | 0. Data check | Do I have access to the data this review needs? |
-- MAGIC | 1. Inventory | What warehouses do we run, and how are they set up? |
-- MAGIC | 2. Statement timeout | What stops a runaway query? |
-- MAGIC | 3. Cost | Where does the money go? |
-- MAGIC | 4. Size | Is each warehouse the right size? |
-- MAGIC | 5. Scaling | Are min and max clusters right for the load? |
-- MAGIC | 6. Auto-stop | How much do we pay for idle time? |
-- MAGIC | 7. Efficiency | Are we repeating work we could cache? |
-- MAGIC | 8. Wasted work | Are we paying for queries that fail or get cancelled? |
-- MAGIC | 9. Customer margin | What does each customer cost us to serve? |
-- MAGIC | 10. Governance | Who can change things, and who hears about a spike? |
-- MAGIC | 11. Scorecard | What do we change, and in what order? |

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## Before you run
-- MAGIC
-- MAGIC 1. **Compute:** attach this notebook to **Serverless** compute (the dropdown at the top right of the notebook), or to a **SQL warehouse**. Every cell is SQL except one short Python cell in check 2a, which reads the statement-timeout setting. A classic cluster also works but is slower and not needed. Use a Medium or larger warehouse if your query history is very large.
-- MAGIC 2. **Access:** you need `SELECT` on the system tables listed in check 0. Queries are read-only; nothing here changes your workspace.
-- MAGIC 3. **Run check 0 first.** If it reports `EMPTY` or errors, fix that before reading anything else. An empty result is almost always access or data timing, not a finding.
-- MAGIC 4. **Privacy:** a few result columns show the first characters of SQL text and user emails (checks 2d, 7b and 7c). Hide or remove those columns before sharing your screen.
-- MAGIC 5. **Scope:** system tables cover **every workspace attached to the same metastore**, not just this one. To focus on one workspace, add `AND workspace_id = '<your workspace id>'` to the `WHERE` clause of the query (find the id in the workspace URL after `?o=`).
-- MAGIC 6. **Time zone:** all dates and hours are UTC.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 0. Data check (run this first)
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | That the system tables this review reads contain data you can see. |
-- MAGIC | **Impact if it's off** | If a table is empty, every later query will also come back empty, and that is not a finding about your warehouses. |
-- MAGIC | **What good looks like** | Every row says `OK`. |

-- COMMAND ----------

SELECT 'system.compute.warehouses (inventory)' AS source, COUNT(*) AS rows_found,
       CAST(MAX(change_time) AS STRING) AS latest, IF(COUNT(*) = 0, 'EMPTY - see below', 'OK') AS status
FROM system.compute.warehouses
UNION ALL
SELECT 'system.compute.warehouse_events (last 30 days)', COUNT(*), CAST(MAX(event_time) AS STRING), IF(COUNT(*) = 0, 'EMPTY - see below', 'OK')
FROM system.compute.warehouse_events WHERE event_time >= current_date() - INTERVAL 30 DAYS
UNION ALL
SELECT 'system.query.history (last 30 days, warehouses)', COUNT(*), CAST(MAX(start_time) AS STRING), IF(COUNT(*) = 0, 'EMPTY - see below', 'OK')
FROM system.query.history WHERE start_time >= current_date() - INTERVAL 30 DAYS AND compute.warehouse_id IS NOT NULL
UNION ALL
SELECT 'system.billing.usage (last 30 days, SQL)', COUNT(*), CAST(MAX(usage_date) AS STRING), IF(COUNT(*) = 0, 'EMPTY - see below', 'OK')
FROM system.billing.usage WHERE usage_date >= current_date() - INTERVAL 30 DAYS AND billing_origin_product = 'SQL'

-- COMMAND ----------

-- MAGIC %md
-- MAGIC **If a row is empty or the query errors, the usual causes are:**
-- MAGIC 1. **No access.** Ask a metastore admin to grant `USE CATALOG` on `system`, and `USE SCHEMA` plus `SELECT` on the `billing`, `compute`, `query` and `access` schemas. Query history is visible to admins by default; everyone else needs a grant.
-- MAGIC 2. **Schema not enabled.** If a table does not exist, an account admin has to enable that system schema (`databricks system-schemas enable <metastore-id> <schema>`).
-- MAGIC 3. **Different metastore.** System tables only include workspaces attached to the metastore you are querying from. Run the notebook from a workspace on the same metastore as the warehouses.
-- MAGIC 4. **Recent data.** Query history usually lands within about an hour; billing can lag a few hours.
-- MAGIC
-- MAGIC ### Warehouses that ran queries but are missing from the inventory table
-- MAGIC The inventory table only records warehouses that were created or edited after it started recording, so an old, untouched warehouse can be missing from it. Queries in this notebook still include these warehouses; they just show the ID instead of a name and `NULL` for size.

-- COMMAND ----------

SELECT h.compute.warehouse_id AS warehouse_id, COUNT(*) AS queries_last_30d
FROM system.query.history h
LEFT JOIN (SELECT DISTINCT warehouse_id FROM system.compute.warehouses) w ON h.compute.warehouse_id = w.warehouse_id
WHERE h.start_time >= current_date() - INTERVAL 30 DAYS AND h.compute.warehouse_id IS NOT NULL AND w.warehouse_id IS NULL
GROUP BY ALL
ORDER BY queries_last_30d DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 1. Inventory
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | Each warehouse's type, size, scaling range, auto-stop, tags and owner, with red flags called out. |
-- MAGIC | **Impact if it's off** | Settings drive cost. The cheapest fixes are usually here: oversized warehouses, long auto-stop, no tags so cost cannot be assigned to anyone. |
-- MAGIC | **What good looks like** | Serverless where load is bursty, auto-stop short, a tag on every warehouse, a size you can justify (check 4). |

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
)
SELECT warehouse_name, warehouse_id, warehouse_type, warehouse_size,
       CASE warehouse_size WHEN '2X_SMALL' THEN 4 WHEN 'X_SMALL' THEN 6 WHEN 'SMALL' THEN 12 WHEN 'MEDIUM' THEN 24
       WHEN 'LARGE' THEN 40 WHEN 'X_LARGE' THEN 80 WHEN '2X_LARGE' THEN 144 WHEN '3X_LARGE' THEN 272
       WHEN '4X_LARGE' THEN 528 END AS approx_dbu_per_hour,
       min_clusters, max_clusters, auto_stop_minutes, warehouse_channel, created_by,
       cardinality(tags) AS tag_count, tags,
       concat_ws('; ',
         IF(auto_stop_minutes > 10, 'auto-stop over 10 min', NULL),
         IF(warehouse_type <> 'SERVERLESS', 'not serverless', NULL),
         IF(max_clusters > 1 AND min_clusters = max_clusters, 'min = max clusters (never scales down)', NULL),
         IF(cardinality(tags) = 0, 'no tags (cost cannot be attributed)', NULL),
         IF(warehouse_size IN ('X_LARGE','2X_LARGE','3X_LARGE','4X_LARGE','5X_LARGE'), 'large size, confirm it is needed', NULL),
         IF(warehouse_channel = 'PREVIEW', 'preview channel on a production warehouse', NULL)
       ) AS flags
FROM wh
WHERE delete_time IS NULL
ORDER BY approx_dbu_per_hour DESC NULLS LAST, warehouse_name

-- COMMAND ----------

-- MAGIC %md
-- MAGIC `approx_dbu_per_hour` is a reference rate for the size and roughly doubles with each step up; confirm against the current pricing page before quoting it.
-- MAGIC
-- MAGIC **In the UI:** *Compute → SQL Warehouses*, then a warehouse → **Edit**. Size, auto stop, scaling and tags (under *Advanced options*) are all there.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 2. Statement timeout
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | Whether anything caps how long a single query can run, and whether any queries have already run for a very long time. |
-- MAGIC | **Impact if it's off** | With no timeout, one bad query (a missing join condition, a dashboard scanning all history) can run for up to **two days** on a warehouse that bills by the second. |
-- MAGIC | **What good looks like** | A timeout on every interactive or customer-facing warehouse, set in minutes, not hours. |

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 2a. What is the timeout today?
-- MAGIC Run the next cell first. It reads the **workspace-level** `STATEMENT_TIMEOUT` and any per-warehouse value straight from the Databricks API, so it works on serverless notebook compute. It needs workspace admin rights; if it reports an error, use the alternatives below.

-- COMMAND ----------

-- MAGIC %python
-- MAGIC from databricks.sdk import WorkspaceClient
-- MAGIC
-- MAGIC w = WorkspaceClient()
-- MAGIC rows = []
-- MAGIC try:
-- MAGIC     cfg = w.api_client.do("GET", "/api/2.0/sql/config/warehouses")
-- MAGIC     pairs = (cfg.get("sql_configuration_parameters") or {}).get("configuration_pairs", [])
-- MAGIC     ws_val = next((p.get("value") for p in pairs if p.get("key", "").upper() == "STATEMENT_TIMEOUT"), None)
-- MAGIC     rows.append(("Workspace default (all SQL warehouses)", "", ws_val or "not set", "seconds" if ws_val else "no timeout set, the 172800 s (2 day) default applies"))
-- MAGIC     for wh in w.api_client.do("GET", "/api/2.0/sql/warehouses").get("warehouses", []):
-- MAGIC         v = wh.get("statement_timeout")
-- MAGIC         rows.append(("Warehouse", wh.get("name"), str(v) if v is not None else "not returned", "per-warehouse override (Beta)" if v is not None else "inherits the workspace value"))
-- MAGIC except Exception as e:
-- MAGIC     rows.append(("ERROR: needs workspace admin, or use the SQL editor / Settings UI below", type(e).__name__, str(e)[:200], ""))
-- MAGIC display(spark.createDataFrame(rows, "scope string, warehouse string, statement_timeout_seconds string, meaning string"))

-- COMMAND ----------

-- MAGIC %md
-- MAGIC | Value | Meaning |
-- MAGIC |---|---|
-- MAGIC | `not set` at workspace level | **No timeout is configured.** The system default of **172,800 seconds (2 days)** applies. |
-- MAGIC | A number | Seconds. That timeout is in place. A per-warehouse value, if present, overrides the workspace value. |
-- MAGIC
-- MAGIC **Other ways to check, if the cell above errors**
-- MAGIC - **Settings UI:** *Settings → Compute → Manage* next to **SQL warehouses and serverless compute**, then read **SQL Configuration Parameters**. A `STATEMENT_TIMEOUT` line means one is set; no line means the 2-day default.
-- MAGIC - **SQL editor on a warehouse:** open the *SQL editor*, select the warehouse at the top, and run `SET STATEMENT_TIMEOUT;`. It returns the effective value for that warehouse. This only works on a SQL warehouse. On a serverless notebook it fails with `Configuration STATEMENT_TIMEOUT is not available`, which is why it is not a notebook cell.
-- MAGIC - **CLI:** `databricks api get /api/2.0/sql/config/warehouses`
-- MAGIC
-- MAGIC ### 2b. Do the logs show runaway queries?
-- MAGIC The evidence matters more than the setting. If queries have run for hours, nothing is stopping them.

-- COMMAND ----------

WITH q AS (
  SELECT compute.warehouse_id AS warehouse_id, total_duration_ms, total_task_duration_ms, execution_status
  FROM system.query.history
  WHERE start_time >= current_date() - INTERVAL 30 DAYS AND compute.warehouse_id IS NOT NULL AND total_duration_ms IS NOT NULL
)
SELECT COALESCE(w.warehouse_name, q.warehouse_id) AS warehouse_name,
       COUNT(*) AS queries,
       ROUND(MAX(q.total_duration_ms) / 3.6e6, 2) AS longest_query_hours,
       COUNT_IF(q.total_duration_ms > 1800000) AS queries_over_30_min,
       COUNT_IF(q.total_duration_ms > 3600000) AS queries_over_1_hour,
       ROUND(100 * SUM(CASE WHEN q.total_duration_ms > 600000 THEN q.total_task_duration_ms END) / SUM(q.total_task_duration_ms), 1) AS pct_compute_in_queries_over_10_min,
       CASE WHEN MAX(q.total_duration_ms) > 3600000 THEN 'RISK: queries ran over 1 hour, set a timeout'
            WHEN MAX(q.total_duration_ms) > 1800000 THEN 'WATCH: queries ran over 30 minutes'
            ELSE 'OK: nothing long-running' END AS verdict
FROM q
LEFT JOIN (SELECT warehouse_id, warehouse_name FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY warehouse_id ORDER BY change_time DESC) rn FROM system.compute.warehouses) WHERE rn = 1) w
  ON q.warehouse_id = w.warehouse_id
GROUP BY ALL
ORDER BY longest_query_hours DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 2c. What would a timeout have cut? (pick the number)
-- MAGIC For each candidate limit: how many queries would have been stopped, and how many hours of wall-clock time that would have saved.

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
)
SELECT COALESCE(w.warehouse_name, q.warehouse_id) AS warehouse_name, t.timeout_s,
       COUNT_IF(q.total_duration_ms > t.timeout_s * 1000) AS queries_that_would_be_stopped,
       ROUND(100 * COUNT_IF(q.total_duration_ms > t.timeout_s * 1000) / COUNT(*), 3) AS pct_of_queries,
       ROUND(SUM(CASE WHEN q.total_duration_ms > t.timeout_s * 1000
                      THEN (q.total_duration_ms - t.timeout_s * 1000) END) / 3.6e6, 1) AS wall_clock_hours_saved
FROM q
LEFT JOIN wh w ON q.warehouse_id = w.warehouse_id AND q.workspace_id = w.workspace_id
CROSS JOIN (VALUES (60), (300), (600), (1800), (3600), (7200)) AS t(timeout_s)
WHERE q.total_duration_ms IS NOT NULL
GROUP BY ALL
ORDER BY COALESCE(w.warehouse_name, q.warehouse_id), t.timeout_s

-- COMMAND ----------

-- MAGIC %md
-- MAGIC **How to choose:** pick the lowest limit where `pct_of_queries` is close to zero but `wall_clock_hours_saved` is meaningful. Interactive, customer-facing warehouses are often in the minutes range; batch and ETL need much more, which is a reason to keep them on a separate warehouse.
-- MAGIC
-- MAGIC ### 2d. Which queries ran longest, and who ran them?

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
)
SELECT q.statement_id, COALESCE(w.warehouse_name, q.warehouse_id) AS warehouse_name, q.executed_by, q.client_application, q.execution_status,
       ROUND(q.total_duration_ms / 60000, 1) AS minutes,
       ROUND(q.read_bytes / 1e9, 1) AS read_gb,
       q.query_source.dashboard_id, q.query_source.alert_id, q.query_source.notebook_id, q.query_source.genie_space_id,
       LEFT(regexp_replace(q.statement_text, '\\s+', ' '), 160) AS statement_preview
FROM q
LEFT JOIN wh w ON q.warehouse_id = w.warehouse_id AND q.workspace_id = w.workspace_id
ORDER BY q.total_duration_ms DESC
LIMIT 20

-- COMMAND ----------

-- MAGIC %md
-- MAGIC **How to set it**
-- MAGIC - **All warehouses in the workspace (simplest):** *Settings → Compute → Manage* next to **SQL warehouses and serverless compute** → in **SQL Configuration Parameters** add `STATEMENT_TIMEOUT 1800` (seconds) → **Save**. Saving restarts running warehouses, so do it in a quiet window.
-- MAGIC - **One warehouse (Beta):** set the `statement_timeout` field on the warehouse through the SQL Warehouses API.
-- MAGIC - **One application or session:** run `SET STATEMENT_TIMEOUT = 120;` when the connection opens.
-- MAGIC
-- MAGIC Priority, highest first: session, warehouse, workspace, system default (2 days). Valid range is 0 to 172,800 seconds.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 3. Cost
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | Where the spend goes by warehouse, by day, and per query. |
-- MAGIC | **Impact if it's off** | You cannot decide what to resize or what to charge a customer until you know what each warehouse costs. |
-- MAGIC | **What good looks like** | A flat or predictable daily trend, and a cost per 1,000 queries you can compare to what you charge. |

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 3a. Cost by warehouse

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
usage AS (
  -- SQL warehouse billing records priced at list price (swap in your discount if you have one)
  SELECT u.usage_date, u.workspace_id, u.usage_metadata.warehouse_id AS warehouse_id, u.sku_name,
         u.custom_tags, u.usage_quantity AS dbus,
         u.usage_quantity * CAST(COALESCE(p.pricing.effective_list.default, p.pricing.default) AS DOUBLE) AS list_cost_usd
  FROM system.billing.usage u
  LEFT JOIN system.billing.list_prices p
    ON u.account_id = p.account_id AND u.sku_name = p.sku_name AND u.cloud = p.cloud
   AND p.currency_code = 'USD' AND u.usage_start_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
  WHERE u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
    AND u.usage_date >= current_date() - INTERVAL 30 DAYS
)
SELECT COALESCE(w.warehouse_name, u.warehouse_id) AS warehouse_name, u.warehouse_id, w.warehouse_type, w.warehouse_size,
       ROUND(SUM(u.dbus), 1) AS dbus,
       ROUND(SUM(u.list_cost_usd), 2) AS list_cost_usd,
       ROUND(100 * SUM(u.list_cost_usd) / SUM(SUM(u.list_cost_usd)) OVER (), 1) AS pct_of_total,
       ROUND(SUM(u.list_cost_usd) / COUNT(DISTINCT u.usage_date), 2) AS avg_usd_per_day
FROM usage u
LEFT JOIN wh w ON u.warehouse_id = w.warehouse_id AND u.workspace_id = w.workspace_id
GROUP BY ALL
ORDER BY list_cost_usd DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 3b. Daily trend
-- MAGIC Run it, then add a bar chart: x = `usage_date`, y = `list_cost_usd`, grouped by `warehouse_name`. Spikes stand out immediately.

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
usage AS (
  -- SQL warehouse billing records priced at list price (swap in your discount if you have one)
  SELECT u.usage_date, u.workspace_id, u.usage_metadata.warehouse_id AS warehouse_id, u.sku_name,
         u.custom_tags, u.usage_quantity AS dbus,
         u.usage_quantity * CAST(COALESCE(p.pricing.effective_list.default, p.pricing.default) AS DOUBLE) AS list_cost_usd
  FROM system.billing.usage u
  LEFT JOIN system.billing.list_prices p
    ON u.account_id = p.account_id AND u.sku_name = p.sku_name AND u.cloud = p.cloud
   AND p.currency_code = 'USD' AND u.usage_start_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
  WHERE u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
    AND u.usage_date >= current_date() - INTERVAL 30 DAYS
)
SELECT u.usage_date, COALESCE(w.warehouse_name, u.warehouse_id) AS warehouse_name, ROUND(SUM(u.list_cost_usd), 2) AS list_cost_usd
FROM usage u
LEFT JOIN wh w ON u.warehouse_id = w.warehouse_id AND u.workspace_id = w.workspace_id
GROUP BY ALL
ORDER BY u.usage_date, COALESCE(w.warehouse_name, u.warehouse_id)

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 3c. Cost per 1,000 queries and per compute-hour
-- MAGIC This is the number to compare against what you charge.

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
usage AS (
  -- SQL warehouse billing records priced at list price (swap in your discount if you have one)
  SELECT u.usage_date, u.workspace_id, u.usage_metadata.warehouse_id AS warehouse_id, u.sku_name,
         u.custom_tags, u.usage_quantity AS dbus,
         u.usage_quantity * CAST(COALESCE(p.pricing.effective_list.default, p.pricing.default) AS DOUBLE) AS list_cost_usd
  FROM system.billing.usage u
  LEFT JOIN system.billing.list_prices p
    ON u.account_id = p.account_id AND u.sku_name = p.sku_name AND u.cloud = p.cloud
   AND p.currency_code = 'USD' AND u.usage_start_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
  WHERE u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
    AND u.usage_date >= current_date() - INTERVAL 30 DAYS
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
),
cost AS (SELECT workspace_id, warehouse_id, SUM(list_cost_usd) AS cost_usd FROM usage GROUP BY ALL),
work AS (
  SELECT workspace_id, warehouse_id, COUNT(*) AS queries, SUM(total_task_duration_ms) / 3.6e6 AS task_hours
  FROM q WHERE execution_status = 'FINISHED' GROUP BY ALL
)
SELECT COALESCE(w.warehouse_name, c.warehouse_id) AS warehouse_name, ROUND(c.cost_usd, 2) AS list_cost_usd, k.queries,
       ROUND(1000 * c.cost_usd / NULLIF(k.queries, 0), 3) AS usd_per_1k_queries,
       ROUND(k.task_hours, 1) AS task_hours,
       ROUND(c.cost_usd / NULLIF(k.task_hours, 0), 3) AS usd_per_task_hour
FROM cost c
LEFT JOIN wh w ON c.warehouse_id = w.warehouse_id AND c.workspace_id = w.workspace_id
LEFT JOIN work k ON c.warehouse_id = k.warehouse_id AND c.workspace_id = k.workspace_id
ORDER BY c.cost_usd DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 3d. Which kind of compute are we paying for?

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
usage AS (
  -- SQL warehouse billing records priced at list price (swap in your discount if you have one)
  SELECT u.usage_date, u.workspace_id, u.usage_metadata.warehouse_id AS warehouse_id, u.sku_name,
         u.custom_tags, u.usage_quantity AS dbus,
         u.usage_quantity * CAST(COALESCE(p.pricing.effective_list.default, p.pricing.default) AS DOUBLE) AS list_cost_usd
  FROM system.billing.usage u
  LEFT JOIN system.billing.list_prices p
    ON u.account_id = p.account_id AND u.sku_name = p.sku_name AND u.cloud = p.cloud
   AND p.currency_code = 'USD' AND u.usage_start_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
  WHERE u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
    AND u.usage_date >= current_date() - INTERVAL 30 DAYS
)
SELECT u.sku_name, COUNT(DISTINCT u.warehouse_id) AS warehouses,
       ROUND(SUM(u.dbus), 1) AS dbus, ROUND(SUM(u.list_cost_usd), 2) AS list_cost_usd
FROM usage u
LEFT JOIN wh w ON u.warehouse_id = w.warehouse_id AND u.workspace_id = w.workspace_id
GROUP BY ALL
ORDER BY list_cost_usd DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC **In the UI:** *Account console → Usage* shows spend by product, SKU and tag. Use it to cross-check these numbers.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 4. Warehouse size
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | Whether each warehouse's size matches its queries: spilling and long runs argue for bigger, tiny queries on a big warehouse argue for smaller. |
-- MAGIC | **Impact if it's off** | Each step up in size roughly doubles the hourly cost. An oversized warehouse wastes money; an undersized one makes users wait. |
-- MAGIC | **What good looks like** | No spilling, little queueing, and queries that are not tiny relative to the size. |

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
),
s AS (
  SELECT COALESCE(w.warehouse_name, q.warehouse_id) AS warehouse_name, w.warehouse_size, w.warehouse_type,
         COUNT(*) AS queries,
         ROUND(percentile_approx(q.execution_duration_ms, 0.5) / 1000, 2) AS p50_exec_s,
         ROUND(percentile_approx(q.execution_duration_ms, 0.95) / 1000, 2) AS p95_exec_s,
         ROUND(percentile_approx(q.waiting_at_capacity_duration_ms, 0.95) / 1000, 2) AS p95_queue_s,
         ROUND(percentile_approx(q.waiting_for_compute_duration_ms, 0.95) / 1000, 2) AS p95_wait_for_compute_s,
         ROUND(100 * AVG(CASE WHEN q.spilled_local_bytes > 0 THEN 1 ELSE 0 END), 1) AS pct_queries_spilled,
         ROUND(percentile_approx(q.read_bytes, 0.95) / 1e9, 3) AS p95_read_gb,
         ROUND(MAX(q.read_bytes) / 1e9, 2) AS max_read_gb
  FROM q
  LEFT JOIN wh w ON q.warehouse_id = w.warehouse_id AND q.workspace_id = w.workspace_id
  WHERE q.execution_status = 'FINISHED'
  GROUP BY ALL
)
SELECT *,
  CASE
    WHEN pct_queries_spilled >= 5 THEN 'Spilling: test one size UP'
    WHEN p95_queue_s > 5 THEN 'Queuing: look at max clusters (section 4) before size'
    WHEN p95_exec_s < 5 AND p95_read_gb < 1 AND warehouse_size NOT IN ('2X_SMALL','X_SMALL') THEN 'Short, small queries: test one size DOWN'
    ELSE 'No clear signal'
  END AS first_hypothesis
FROM s
ORDER BY queries DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC **How to read it**
-- MAGIC - `pct_queries_spilled` above a few percent: queries ran out of memory and wrote to disk. A larger size often fixes it.
-- MAGIC - `p95_queue_s` high: that is a **concurrency** problem, not a size problem. Go to check 5.
-- MAGIC - `p95_exec_s` under about 5 seconds and `p95_read_gb` under 1 on a Large or bigger warehouse: a candidate to step down.
-- MAGIC - `first_hypothesis` is a starting point. Prove it with the test below.
-- MAGIC
-- MAGIC **Prove it in the UI**
-- MAGIC 1. *SQL Editor* → run a representative slow query on the current warehouse.
-- MAGIC 2. *Query History* → click it → **See query profile**. Note total time, spilled data and bytes read.
-- MAGIC 3. Run the same query on a warehouse one size up or down. Use `SET use_cached_result = false;` first so the cache does not skew it.
-- MAGIC 4. If doubling the size cut the time by about half or more, the bigger size costs the same or less and users wait less. If the time barely moved, keep the smaller size.
-- MAGIC
-- MAGIC ### Where the time goes in the slowest queries

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
)
SELECT q.statement_id, COALESCE(w.warehouse_name, q.warehouse_id) AS warehouse_name, q.executed_by, q.client_application,
       ROUND(q.total_duration_ms / 1000, 1) AS total_s,
       ROUND(q.waiting_for_compute_duration_ms / 1000, 1) AS wait_for_compute_s,
       ROUND(q.waiting_at_capacity_duration_ms / 1000, 1) AS queued_s,
       ROUND(q.compilation_duration_ms / 1000, 1) AS compile_s,
       ROUND(q.execution_duration_ms / 1000, 1) AS exec_s,
       ROUND(q.read_bytes / 1e9, 2) AS read_gb,
       ROUND(q.spilled_local_bytes / 1e9, 2) AS spilled_gb
FROM q
LEFT JOIN wh w ON q.warehouse_id = w.warehouse_id AND q.workspace_id = w.workspace_id
WHERE q.execution_status = 'FINISHED'
ORDER BY q.total_duration_ms DESC
LIMIT 25

-- COMMAND ----------

-- MAGIC %md
-- MAGIC If most of `total_s` is `queued_s` or `wait_for_compute_s`, resizing will not help; fix scaling or auto-stop. If it is `exec_s` with spill, size is the lever.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 5. Scaling and concurrency
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | How many queries run at once at peak, and how many clusters the warehouse actually used. |
-- MAGIC | **Impact if it's off** | Extra clusters protect users at peak but also multiply the bill. Too few means queueing; too many means paying for headroom you never use. |
-- MAGIC | **What good looks like** | Queueing near zero with the lowest `max_clusters` that achieves it. |

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 5a. Peak load vs configured capacity
-- MAGIC Average concurrent queries per hour is estimated as total execution time in the hour divided by one hour.

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
),
hourly AS (
  SELECT q.workspace_id, q.warehouse_id, date_trunc('hour', q.start_time) AS hr,
         COUNT(*) AS queries,
         SUM(q.execution_duration_ms) / 3.6e6 AS avg_concurrent,
         percentile_approx(q.waiting_at_capacity_duration_ms, 0.95) / 1000 AS p95_queue_s
  FROM q GROUP BY ALL
)
SELECT COALESCE(w.warehouse_name, h.warehouse_id) AS warehouse_name, w.warehouse_size, w.min_clusters, w.max_clusters,
       ROUND(MAX(h.avg_concurrent), 1) AS peak_hour_avg_concurrency,
       ROUND(percentile_approx(h.avg_concurrent, 0.95), 1) AS p95_hour_avg_concurrency,
       MAX(h.queries) AS busiest_hour_queries,
       ROUND(MAX(h.p95_queue_s), 1) AS worst_hour_p95_queue_s,
       SUM(CASE WHEN h.p95_queue_s > 5 THEN 1 ELSE 0 END) AS hours_with_queueing
FROM hourly h
LEFT JOIN wh w ON h.warehouse_id = w.warehouse_id AND h.workspace_id = w.workspace_id
GROUP BY ALL
ORDER BY peak_hour_avg_concurrency DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC - `hours_with_queueing = 0` and `max_clusters` far above the peak: you are paying for headroom. Try a lower max.
-- MAGIC - Queueing in many hours with `max_clusters = 1`: the warehouse needs to scale out.
-- MAGIC
-- MAGIC ### 5b. What the clusters actually did

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
ev AS (
  SELECT e.workspace_id, e.warehouse_id, e.event_type, e.cluster_count, e.event_time,
         LEAD(e.event_time) OVER (PARTITION BY e.workspace_id, e.warehouse_id ORDER BY e.event_time) AS next_time
  FROM system.compute.warehouse_events e
  WHERE e.event_time >= current_date() - INTERVAL 30 DAYS
),
span AS (
  SELECT *, (unix_timestamp(COALESCE(next_time, current_timestamp())) - unix_timestamp(event_time)) / 3600 AS hrs
  FROM ev
)
SELECT COALESCE(w.warehouse_name, s.warehouse_id) AS warehouse_name, w.min_clusters, w.max_clusters,
       ROUND(SUM(CASE WHEN s.cluster_count > 0 THEN s.hrs END), 1) AS hours_running,
       ROUND(SUM(s.cluster_count * s.hrs) / NULLIF(SUM(CASE WHEN s.cluster_count > 0 THEN s.hrs END), 0), 2) AS avg_clusters_while_running,
       MAX(s.cluster_count) AS peak_clusters,
       COUNT_IF(s.event_type = 'SCALED_UP') AS scale_ups,
       COUNT_IF(s.event_type = 'SCALED_DOWN') AS scale_downs,
       COUNT_IF(s.event_type = 'STARTING') AS cold_starts
FROM span s
LEFT JOIN wh w ON s.warehouse_id = w.warehouse_id AND s.workspace_id = w.workspace_id
GROUP BY ALL
ORDER BY hours_running DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC `avg_clusters_while_running` near `max_clusters` means the ceiling is being hit; near `min_clusters` means the extra capacity is rarely used. Many scale-ups and downs in a short window means spiky demand, which serverless handles well.
-- MAGIC
-- MAGIC **In the UI (best for real peaks):** *Compute → SQL Warehouses → a warehouse → **Monitoring** tab* charts running clusters, queued queries and peak concurrency for up to 30 days.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 6. Auto-stop and idle time
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | How long each warehouse stays on after its last query, and what that idle time costs. |
-- MAGIC | **Impact if it's off** | A running warehouse bills whether or not queries are running. Too long wastes money; too short on a slow-starting warehouse causes cold starts users feel. |
-- MAGIC | **What good looks like** | Auto-stop matched to the warehouse type: short on serverless, around 10 minutes on Pro or Classic. |

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
),
ordered AS (
  SELECT q.workspace_id, q.warehouse_id, q.start_time,
         MAX(q.end_time) OVER (PARTITION BY q.workspace_id, q.warehouse_id ORDER BY q.start_time
                               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_end
  FROM q WHERE q.end_time IS NOT NULL
),
gaps AS (
  SELECT workspace_id, warehouse_id,
         (unix_timestamp(start_time) - unix_timestamp(prev_end)) / 60 AS gap_min
  FROM ordered WHERE prev_end IS NOT NULL AND start_time > prev_end
)
SELECT COALESCE(w.warehouse_name, g.warehouse_id) AS warehouse_name, w.warehouse_type, w.warehouse_size, w.auto_stop_minutes,
       COUNT(*) AS gaps_between_queries,
       ROUND(SUM(LEAST(g.gap_min, w.auto_stop_minutes)) / 60, 1) AS idle_hours_at_current,
       ROUND(SUM(LEAST(g.gap_min, 5)) / 60, 1) AS idle_hours_at_5_min,
       ROUND(SUM(LEAST(g.gap_min, 1)) / 60, 1) AS idle_hours_at_1_min,
       ROUND((CASE warehouse_size WHEN '2X_SMALL' THEN 4 WHEN 'X_SMALL' THEN 6 WHEN 'SMALL' THEN 12 WHEN 'MEDIUM' THEN 24
       WHEN 'LARGE' THEN 40 WHEN 'X_LARGE' THEN 80 WHEN '2X_LARGE' THEN 144 WHEN '3X_LARGE' THEN 272
       WHEN '4X_LARGE' THEN 528 END) * (SUM(LEAST(g.gap_min, w.auto_stop_minutes)) - SUM(LEAST(g.gap_min, 5))) / 60, 1) AS dbus_saved_going_to_5_min,
       COUNT_IF(g.gap_min > 5 AND g.gap_min <= w.auto_stop_minutes) AS gaps_that_would_become_cold_starts_at_5_min
FROM gaps g
LEFT JOIN wh w ON g.warehouse_id = w.warehouse_id AND g.workspace_id = w.workspace_id
WHERE w.auto_stop_minutes IS NOT NULL
GROUP BY ALL
ORDER BY dbus_saved_going_to_5_min DESC NULLS LAST

-- COMMAND ----------

-- MAGIC %md
-- MAGIC - `dbus_saved_going_to_5_min` is the headroom from shortening auto-stop. Multiply by your price per DBU.
-- MAGIC - `gaps_that_would_become_cold_starts_at_5_min` is the cost side: each one is a user whose first query waits for a start. On **serverless** that wait is seconds; on Pro or Classic it can be minutes.
-- MAGIC - This is an estimate from query timing, not a billing record. Use it to rank, change one warehouse, and watch the next week's cost.
-- MAGIC
-- MAGIC **In the UI:** *Compute → SQL Warehouses → a warehouse → Edit → Auto stop*. The minimum allowed value depends on the warehouse type.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 7. Query efficiency
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | Cache and file-pruning effectiveness, repeated queries, and which dashboards or users consume the most compute. |
-- MAGIC | **Impact if it's off** | The cheapest query is the one that does not run. Caching and removing repeated work cut cost without changing warehouse settings. |
-- MAGIC | **What good looks like** | High result-cache use on dashboard traffic, high file pruning, and no single dashboard or user dominating compute. |

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 7a. Cache and pruning

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
)
SELECT COALESCE(w.warehouse_name, q.warehouse_id) AS warehouse_name, COUNT(*) AS queries,
       ROUND(100 * AVG(CASE WHEN q.from_result_cache THEN 1 ELSE 0 END), 1) AS pct_served_from_result_cache,
       ROUND(AVG(q.read_io_cache_percent), 1) AS avg_disk_cache_hit_pct,
       ROUND(100 * SUM(q.pruned_files) / NULLIF(SUM(q.pruned_files) + SUM(q.read_files), 0), 1) AS pct_files_pruned,
       ROUND(SUM(q.read_bytes) / 1e12, 3) AS tb_read
FROM q
LEFT JOIN wh w ON q.warehouse_id = w.warehouse_id AND q.workspace_id = w.workspace_id
WHERE q.statement_type = 'SELECT' AND q.execution_status = 'FINISHED'
GROUP BY ALL
ORDER BY tb_read DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC Low `pct_files_pruned` on large tables means queries scan everything. Fix with liquid clustering on the filter columns or predictive optimization.
-- MAGIC
-- MAGIC ### 7b. Repeated work: the same query shape over and over
-- MAGIC Literals are stripped so `customer_id = 12` and `= 98` count as one pattern. Top results are candidates for a materialized view, a pre-aggregated table, or a cached dashboard.

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
),
shaped AS (
  SELECT q.*, regexp_replace(regexp_replace(regexp_replace(q.statement_text, '\\s+', ' '), "'[^']*'", '?'), '[0-9]+', '?') AS shape
  FROM q
  WHERE q.statement_type = 'SELECT' AND q.execution_status = 'FINISHED'
)
SELECT md5(s.shape) AS shape_id, COUNT(*) AS runs, COUNT(DISTINCT s.executed_by) AS distinct_users,
       ROUND(SUM(s.total_task_duration_ms) / 3.6e6, 2) AS compute_hours,
       ROUND(100 * AVG(CASE WHEN s.from_result_cache THEN 1 ELSE 0 END), 1) AS pct_result_cache,
       LEFT(MAX(s.shape), 200) AS shape_preview
FROM shaped s
LEFT JOIN wh w ON s.warehouse_id = w.warehouse_id AND s.workspace_id = w.workspace_id
GROUP BY s.shape
ORDER BY compute_hours DESC
LIMIT 20

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 7c. Biggest consumers by who and what ran them

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
)
SELECT COALESCE(q.executed_as, q.executed_by) AS run_as, q.client_application,
       CASE WHEN q.query_source.dashboard_id IS NOT NULL THEN 'dashboard'
            WHEN q.query_source.alert_id IS NOT NULL THEN 'alert'
            WHEN q.query_source.genie_space_id IS NOT NULL THEN 'genie'
            WHEN q.query_source.notebook_id IS NOT NULL THEN 'notebook'
            WHEN q.query_source.job_info.job_id IS NOT NULL THEN 'job'
            ELSE 'other' END AS source_type,
       COUNT(*) AS queries,
       ROUND(SUM(q.total_task_duration_ms) / 3.6e6, 1) AS compute_hours,
       ROUND(100 * SUM(q.total_task_duration_ms) / SUM(SUM(q.total_task_duration_ms)) OVER (), 1) AS pct_of_compute
FROM q
LEFT JOIN wh w ON q.warehouse_id = w.warehouse_id AND q.workspace_id = w.workspace_id
GROUP BY ALL
ORDER BY compute_hours DESC
LIMIT 25

-- COMMAND ----------

-- MAGIC %md
-- MAGIC One dashboard, alert or service account dominating compute is the usual finding. Refresh schedules faster than the data changes are the most common cause.
-- MAGIC
-- MAGIC **In the UI:** *Query History* → filter by warehouse, user, status and duration; click a query → **See query profile**.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 8. Wasted work
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | Compute spent on queries that fail or are cancelled. |
-- MAGIC | **Impact if it's off** | That compute produced nothing for a customer. A broken dashboard retrying every few minutes is a common silent cost. |
-- MAGIC | **What good looks like** | Failed and cancelled work under about 2% of compute, and no single error repeating. |

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
)
SELECT COALESCE(w.warehouse_name, q.warehouse_id) AS warehouse_name, q.execution_status, COUNT(*) AS queries,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY COALESCE(w.warehouse_name, q.warehouse_id)), 2) AS pct_of_queries,
       ROUND(SUM(q.total_task_duration_ms) / 3.6e6, 2) AS compute_hours,
       ROUND(100 * SUM(q.total_task_duration_ms) / SUM(SUM(q.total_task_duration_ms)) OVER (PARTITION BY COALESCE(w.warehouse_name, q.warehouse_id)), 2) AS pct_of_compute
FROM q
LEFT JOIN wh w ON q.warehouse_id = w.warehouse_id AND q.workspace_id = w.workspace_id
GROUP BY COALESCE(w.warehouse_name, q.warehouse_id), q.execution_status
ORDER BY warehouse_name, compute_hours DESC

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
)
SELECT LEFT(q.error_message, 140) AS error_prefix, COUNT(*) AS occurrences,
       COUNT(DISTINCT q.executed_by) AS users,
       ROUND(SUM(q.total_task_duration_ms) / 3.6e6, 2) AS wasted_compute_hours
FROM q
LEFT JOIN wh w ON q.warehouse_id = w.warehouse_id AND q.workspace_id = w.workspace_id
WHERE q.execution_status = 'FAILED'
GROUP BY ALL
ORDER BY wasted_compute_hours DESC
LIMIT 15

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 9. Customer attribution and margin
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | Whether cost can be tied to each customer, then what each customer costs to serve and the margin on the account. |
-- MAGIC | **Impact if it's off** | Billing stops at the warehouse. Without a way to identify the customer, you cannot price accurately or spot an unprofitable account. |
-- MAGIC | **What good looks like** | Every query carries a customer identifier, and every account shows a margin. |

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Ways to identify the customer (best first)
-- MAGIC | Approach | How | Trade-off |
-- MAGIC |---|---|---|
-- MAGIC | **Query tags** | The app runs `SET QUERY_TAGS['customer'] = 'customer_a';` at the start of each session. It lands in `system.query.history.query_tags`. | Cheapest to add and works on shared warehouses. Keys cannot contain `, : - / = .`; values are plain text, so use an ID. This notebook reads the key `customer`. |
-- MAGIC | **Service principal per customer** | Each customer's traffic runs as its own service principal. | Clean audit trail and permissions. More identities to manage. |
-- MAGIC | **Warehouse per customer or tier** | Tag each warehouse `customer=customer_a`; the tag flows into billing. | Exact cost with no allocation math, but less sharing can raise idle cost. |
-- MAGIC
-- MAGIC ### 9a. How much can we attribute today?

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
usage AS (
  -- SQL warehouse billing records priced at list price (swap in your discount if you have one)
  SELECT u.usage_date, u.workspace_id, u.usage_metadata.warehouse_id AS warehouse_id, u.sku_name,
         u.custom_tags, u.usage_quantity AS dbus,
         u.usage_quantity * CAST(COALESCE(p.pricing.effective_list.default, p.pricing.default) AS DOUBLE) AS list_cost_usd
  FROM system.billing.usage u
  LEFT JOIN system.billing.list_prices p
    ON u.account_id = p.account_id AND u.sku_name = p.sku_name AND u.cloud = p.cloud
   AND p.currency_code = 'USD' AND u.usage_start_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
  WHERE u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
    AND u.usage_date >= current_date() - INTERVAL 30 DAYS
)
SELECT COALESCE(u.custom_tags['customer'], '(untagged warehouse)') AS customer_from_warehouse_tag,
       COUNT(DISTINCT u.warehouse_id) AS warehouses,
       ROUND(SUM(u.list_cost_usd), 2) AS list_cost_usd,
       ROUND(100 * SUM(u.list_cost_usd) / SUM(SUM(u.list_cost_usd)) OVER (), 1) AS pct_of_cost
FROM usage u
LEFT JOIN wh w ON u.warehouse_id = w.warehouse_id AND u.workspace_id = w.workspace_id
GROUP BY ALL
ORDER BY list_cost_usd DESC

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
)
SELECT COALESCE(w.warehouse_name, q.warehouse_id) AS warehouse_name,
       COUNT(*) AS queries,
       ROUND(100 * AVG(CASE WHEN q.query_tags['customer'] IS NOT NULL THEN 1 ELSE 0 END), 1) AS pct_queries_with_customer_tag,
       COUNT(DISTINCT q.executed_as) AS distinct_run_as_identities,
       COUNT(DISTINCT q.query_tags['customer']) AS distinct_customers_tagged
FROM q
LEFT JOIN wh w ON q.warehouse_id = w.warehouse_id AND q.workspace_id = w.workspace_id
GROUP BY ALL
ORDER BY queries DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC If one identity runs everything (`distinct_run_as_identities` = 1) and `pct_queries_with_customer_tag` is low, the customer cannot be identified yet. Adding `SET QUERY_TAGS` in the app is the smallest change that fixes it.
-- MAGIC
-- MAGIC ### 9b. Allocated cost per customer
-- MAGIC Each warehouse's daily cost is split across customers in proportion to the compute time their queries used that day. Customer = the `customer` query tag if present, otherwise the identity that ran the query.

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
usage AS (
  -- SQL warehouse billing records priced at list price (swap in your discount if you have one)
  SELECT u.usage_date, u.workspace_id, u.usage_metadata.warehouse_id AS warehouse_id, u.sku_name,
         u.custom_tags, u.usage_quantity AS dbus,
         u.usage_quantity * CAST(COALESCE(p.pricing.effective_list.default, p.pricing.default) AS DOUBLE) AS list_cost_usd
  FROM system.billing.usage u
  LEFT JOIN system.billing.list_prices p
    ON u.account_id = p.account_id AND u.sku_name = p.sku_name AND u.cloud = p.cloud
   AND p.currency_code = 'USD' AND u.usage_start_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
  WHERE u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
    AND u.usage_date >= current_date() - INTERVAL 30 DAYS
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
),
daily_cost AS (
  SELECT workspace_id, warehouse_id, usage_date, SUM(list_cost_usd) AS cost_usd FROM usage GROUP BY ALL
),
daily_work AS (
  SELECT q.workspace_id, q.warehouse_id, CAST(q.start_time AS DATE) AS d,
         COALESCE(q.query_tags['customer'], q.executed_as, q.executed_by, 'unknown') AS customer,
         SUM(q.total_task_duration_ms) AS task_ms, COUNT(*) AS queries
  FROM q GROUP BY ALL
),
shared AS (
  SELECT *, task_ms / NULLIF(SUM(task_ms) OVER (PARTITION BY workspace_id, warehouse_id, d), 0) AS share
  FROM daily_work
)
SELECT s.customer,
       SUM(s.queries) AS queries,
       ROUND(SUM(s.task_ms) / 3.6e6, 1) AS compute_hours,
       ROUND(SUM(s.share * c.cost_usd), 2) AS allocated_cost_usd,
       ROUND(100 * SUM(s.share * c.cost_usd) / SUM(SUM(s.share * c.cost_usd)) OVER (), 1) AS pct_of_cost
FROM shared s
JOIN daily_cost c ON s.warehouse_id = c.warehouse_id AND s.workspace_id = c.workspace_id AND s.d = c.usage_date
LEFT JOIN wh w ON s.warehouse_id = w.warehouse_id AND s.workspace_id = w.workspace_id
GROUP BY s.customer
ORDER BY allocated_cost_usd DESC
LIMIT 50

-- COMMAND ----------

-- MAGIC %md
-- MAGIC Idle time and shared overhead are spread in proportion to usage, so a quiet customer carries a small share. If that is not how you want to price it, a dedicated warehouse for large customers is the alternative. Dates are UTC.
-- MAGIC
-- MAGIC ### 9c. Margin by customer
-- MAGIC Replace the three `VALUES` rows with each customer and what they paid for the same 30 days. The result is gross margin on warehouse compute only.

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
usage AS (
  -- SQL warehouse billing records priced at list price (swap in your discount if you have one)
  SELECT u.usage_date, u.workspace_id, u.usage_metadata.warehouse_id AS warehouse_id, u.sku_name,
         u.custom_tags, u.usage_quantity AS dbus,
         u.usage_quantity * CAST(COALESCE(p.pricing.effective_list.default, p.pricing.default) AS DOUBLE) AS list_cost_usd
  FROM system.billing.usage u
  LEFT JOIN system.billing.list_prices p
    ON u.account_id = p.account_id AND u.sku_name = p.sku_name AND u.cloud = p.cloud
   AND p.currency_code = 'USD' AND u.usage_start_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
  WHERE u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
    AND u.usage_date >= current_date() - INTERVAL 30 DAYS
),
q AS (
  -- query history for warehouses in scope
  SELECT h.*, h.compute.warehouse_id AS warehouse_id
  FROM system.query.history h
  WHERE h.start_time >= current_date() - INTERVAL 30 DAYS
    AND h.compute.warehouse_id IS NOT NULL
),
revenue(customer, revenue_usd) AS (
  -- replace with the real customers and what they paid for this period
  VALUES ('customer_a', 1500.00), ('customer_b', 900.00), ('customer_c', 400.00)
),
daily_cost AS (
  SELECT workspace_id, warehouse_id, usage_date, SUM(list_cost_usd) AS cost_usd FROM usage GROUP BY ALL
),
daily_work AS (
  SELECT q.workspace_id, q.warehouse_id, CAST(q.start_time AS DATE) AS d,
         COALESCE(q.query_tags['customer'], q.executed_as, q.executed_by, 'unknown') AS customer,
         SUM(q.total_task_duration_ms) AS task_ms
  FROM q GROUP BY ALL
),
shared AS (
  SELECT *, task_ms / NULLIF(SUM(task_ms) OVER (PARTITION BY workspace_id, warehouse_id, d), 0) AS share
  FROM daily_work
),
alloc AS (
  SELECT s.customer, SUM(s.share * c.cost_usd) AS cost_usd
  FROM shared s
  JOIN daily_cost c ON s.warehouse_id = c.warehouse_id AND s.workspace_id = c.workspace_id AND s.d = c.usage_date
  LEFT JOIN wh w ON s.warehouse_id = w.warehouse_id AND s.workspace_id = w.workspace_id
  GROUP BY s.customer
)
SELECT COALESCE(r.customer, a.customer) AS customer,
       r.revenue_usd, ROUND(a.cost_usd, 2) AS allocated_compute_cost_usd,
       ROUND(r.revenue_usd - a.cost_usd, 2) AS gross_margin_usd,
       ROUND(100 * (r.revenue_usd - a.cost_usd) / NULLIF(r.revenue_usd, 0), 1) AS gross_margin_pct
FROM revenue r
FULL OUTER JOIN alloc a ON r.customer = a.customer
ORDER BY gross_margin_pct ASC NULLS LAST

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 10. Governance
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **What we're checking** | Who changed warehouses recently, who can manage them, and whether a cost spike would be noticed. |
-- MAGIC | **Impact if it's off** | Right-sizing only sticks if settings cannot drift and surprises are caught early. |
-- MAGIC | **What good looks like** | Few people can edit warehouses, every warehouse is tagged, and a budget or spike alert is on. |

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### 10a. Who changed warehouses in the last 30 days?

-- COMMAND ----------

SELECT event_time, user_identity.email AS changed_by, action_name,
       request_params['id'] AS warehouse_id,
       LEFT(to_json(request_params), 300) AS request_summary
FROM system.access.audit
WHERE service_name = 'databrickssql'
  AND action_name IN ('createWarehouse', 'editWarehouse', 'deleteWarehouse')
  AND event_date >= current_date() - INTERVAL 30 DAYS
ORDER BY event_time DESC
LIMIT 50

-- COMMAND ----------

-- MAGIC %md
-- MAGIC Frequent size or scaling edits by many different people, or warehouses created by individuals, mean settings can drift.
-- MAGIC
-- MAGIC ### 10b. Who can use or manage each warehouse? (UI)
-- MAGIC *Compute → SQL Warehouses → a warehouse → ⋮ → Permissions*. `CAN_MANAGE` should sit with a small platform group, not individuals or all users. `CAN_USE` should go to groups or per-customer service principals. `CAN_MONITOR` is enough for people who only watch.
-- MAGIC
-- MAGIC ### 10c. Guardrails to turn on once
-- MAGIC | Control | Where | What it does |
-- MAGIC |---|---|---|
-- MAGIC | **Warehouse tags** | *Edit warehouse → Advanced options → Tags* | Flow into billing `custom_tags`; require `customer` or `team` on every warehouse |
-- MAGIC | **Budgets and alerts** | *Account console → Usage → Budgets* | Email alerts when spend passes a threshold |
-- MAGIC | **Budget policies (serverless)** | *Account console → Usage → Budget policies* | Tag serverless usage to a team or customer automatically |
-- MAGIC | **Statement timeout** | Check 2 | Caps a single runaway query |
-- MAGIC | **Warehouse permissions** | 10b | Stops ad-hoc resizing |
-- MAGIC | **Spike alert** | 10d | Daily check for cost jumps |
-- MAGIC
-- MAGIC Menu names vary slightly by release; search the console for "Budgets" if a path differs.
-- MAGIC
-- MAGIC ### 10d. Cost spike detector (save as a SQL Alert)
-- MAGIC Flags any warehouse whose recent day cost more than 1.5x its trailing 7-day average. In the SQL editor choose *Create alert*, condition *rows returned > 0*, daily schedule, and a Slack or email destination.

-- COMMAND ----------

WITH wh AS (
  -- latest known configuration per warehouse (a warehouse can be missing here; every query uses LEFT JOIN so nothing disappears)
  SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) AS rn
    FROM system.compute.warehouses
  ) WHERE rn = 1
),
usage AS (
  -- SQL warehouse billing records priced at list price (swap in your discount if you have one)
  SELECT u.usage_date, u.workspace_id, u.usage_metadata.warehouse_id AS warehouse_id, u.sku_name,
         u.custom_tags, u.usage_quantity AS dbus,
         u.usage_quantity * CAST(COALESCE(p.pricing.effective_list.default, p.pricing.default) AS DOUBLE) AS list_cost_usd
  FROM system.billing.usage u
  LEFT JOIN system.billing.list_prices p
    ON u.account_id = p.account_id AND u.sku_name = p.sku_name AND u.cloud = p.cloud
   AND p.currency_code = 'USD' AND u.usage_start_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
  WHERE u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
    AND u.usage_date >= current_date() - INTERVAL 30 DAYS
),
daily AS (
  SELECT u.warehouse_id, u.workspace_id, u.usage_date, SUM(u.list_cost_usd) AS cost_usd
  FROM usage u GROUP BY ALL
),
scored AS (
  SELECT *, AVG(cost_usd) OVER (PARTITION BY workspace_id, warehouse_id ORDER BY usage_date
                                ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING) AS trailing_7d_avg
  FROM daily
)
SELECT COALESCE(w.warehouse_name, s.warehouse_id) AS warehouse_name, s.usage_date, ROUND(s.cost_usd, 2) AS cost_usd, ROUND(s.trailing_7d_avg, 2) AS trailing_7d_avg,
       ROUND(s.cost_usd / NULLIF(s.trailing_7d_avg, 0), 2) AS ratio
FROM scored s
LEFT JOIN wh w ON s.warehouse_id = w.warehouse_id AND s.workspace_id = w.workspace_id
WHERE s.usage_date >= date_sub(current_date(), 3)
  AND s.cost_usd > 1.5 * s.trailing_7d_avg
ORDER BY ratio DESC

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ---
-- MAGIC ## 11. Scorecard
-- MAGIC
-- MAGIC Fill in as you go. The target column is what the data should say before you change anything.
-- MAGIC
-- MAGIC | Area | Finding | Target | Owner | Status |
-- MAGIC |---|---|---|---|---|
-- MAGIC | Inventory | Warehouses without a tag: ___ | 0 | | |
-- MAGIC | Statement timeout | Warehouses still on the 2-day default: ___ ; longest query: ___ h | A timeout on every interactive warehouse | | |
-- MAGIC | Size | Warehouses spilling above 5%: ___ ; tiny queries on Large or bigger: ___ | Each size justified by the test in check 4 | | |
-- MAGIC | Scaling | `max_clusters` far above peak concurrency: ___ | Queueing near zero at the lowest max | | |
-- MAGIC | Auto-stop | DBUs saved by a shorter auto-stop: ___ | Matched to warehouse type | | |
-- MAGIC | Efficiency | Top repeated query shapes: ___ | Materialized view or cache for the top few | | |
-- MAGIC | Wasted work | Failed + cancelled share of compute: ___ % | Under 2% | | |
-- MAGIC | Attribution | Share of cost tied to a customer: ___ % | 100% | | |
-- MAGIC | Margin | Customers below target margin: ___ | A pricing or isolation decision for each | | |
-- MAGIC | Governance | People with CAN_MANAGE: ___ ; budget or spike alert on: Y/N | A group manages; alert on | | |
-- MAGIC
-- MAGIC **Suggested order:** (1) set a statement timeout; (2) tag warehouses and add `SET QUERY_TAGS` in the app; (3) adjust auto-stop; (4) run the size test on the top two cost warehouses; (5) tune `max_clusters`; (6) turn on the spike alert and a budget; (7) revisit margin by customer after two weeks of clean data.
-- MAGIC
-- MAGIC **Caveats:** list prices only; query history can lag about an hour; idle-time and per-customer figures are estimates built from query timing, good for ranking and direction rather than invoice-level accuracy.
