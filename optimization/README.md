# ET_REPORT_FIXEDQUERY Optimization Strategy

## 📋 Executive Summary

This optimization project addresses performance issues in 225+ report queries that run daily and hourly against the database. The solution implements a three-tier optimization strategy:

1. **Materialized Views** - Eliminate repetitive CTE calculations
2. **Aggregation Tables** - Pre-calculate complex metrics
3. **Incremental Refresh** - Automated daily data updates

**Expected Performance Gain:** 70-95% reduction in query execution time and database load.

---

## 🎯 Problem Statement

### Current Issues

- **225 report queries** executing daily/hourly
- **Repetitive CTEs** calculated in every query (CM_4G, DS_OBJ_DATA, etc.)
- **Complex string operations** in every execution (SUBSTR, REVERSE, INSTR)
- **20-day pivots** using 20 DECODE operations per query
- **Redundant calculations** (availability, traffic aggregations)
- **High database CPU** and I/O utilization

### Analysis Results

| Metric | Count |
|--------|-------|
| Total Queries | 225 |
| Common CTE Usage | 39+ times |
| CELLSTS Table Scans | 110+ times |
| OBJECTS Table Joins | 100+ times |
| Repeated Aggregations | 200+ times |

---

## 🏗️ Solution Architecture

### Layer 1: Materialized Views (Base Data)

Pre-filtered and pre-joined configuration management data:

```
┌─────────────────────┐
│   OBJECTS_HW4G      │
│   OBJECTS_HW2G      │  Raw Data
│   OBJECTS_HW3G      │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  MV_DAILY_CM_4G     │
│  MV_DAILY_CM_2G     │  Materialized Views
│  MV_DAILY_CM_3G     │  (Pre-filtered, pre-joined)
└──────────┬──────────┘
           │
           ▼
        Queries
```

**Benefits:**
- Eliminates string parsing overhead
- Removes complex filtering logic
- Pre-joins dimension tables
- Enables query rewrite

### Layer 2: Aggregation Tables (Pre-calculated Metrics)

Pre-aggregated performance metrics:

```
┌─────────────────────────────┐
│      CELLSTS_4G_DA          │
│      CELLSTS_DA             │  Raw Performance Data
│      TWAMP_PERF_H           │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│ AGG_CELL_AVAILABILITY_*     │
│ AGG_TRAFFIC_DAILY_4G        │  Daily Aggregations
│ AGG_TWAMP_JITTER_DAILY      │
│ AGG_REGIONAL_SUMMARY_DAILY  │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│ AGG_AVAILABILITY_ROLLING_   │  Pre-pivoted
│      20DAY                  │  Rolling Data
└─────────────┬───────────────┘
              │
              ▼
          Queries
```

**Benefits:**
- Eliminates complex GROUP BY operations
- Removes 20-day pivot calculations
- Reduces data scanned by 95%+
- Instant query response time

### Layer 3: Incremental Refresh (Automation)

Automated daily refresh process:

```
04:00 AM Daily
     │
     ▼
┌──────────────────────┐
│  Refresh MVs         │ ← 5-10 minutes
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Calculate Daily     │ ← 10-15 minutes
│  Aggregations        │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Build Rolling       │ ← 5 minutes
│  Windows             │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Collect Stats       │ ← 5 minutes
└──────────────────────┘

Total: ~25-30 minutes daily
```

---

## 📂 File Structure

```
optimization/
│
├── 01_materialized_views.sql         # MV definitions
│   ├── MV_DAILY_CM_4G
│   ├── MV_DAILY_CM_2G
│   ├── MV_DAILY_CM_3G
│   └── MV_AVAILABILITY_ONAIR_4G
│
├── 02_aggregation_tables.sql         # Aggregation table schemas
│   ├── AGG_CELL_AVAILABILITY_DAILY_4G
│   ├── AGG_CELL_AVAILABILITY_DAILY_2G
│   ├── AGG_TRAFFIC_DAILY_4G
│   ├── AGG_REGIONAL_SUMMARY_DAILY
│   ├── AGG_TWAMP_JITTER_DAILY
│   └── AGG_AVAILABILITY_ROLLING_20DAY
│
├── 03_incremental_refresh_package.sql # PL/SQL refresh logic
│   └── PKG_REPORT_AGGREGATION
│       ├── refresh_all()
│       ├── refresh_materialized_views()
│       ├── refresh_availability_aggregations()
│       ├── refresh_traffic_aggregations()
│       ├── refresh_regional_summaries()
│       ├── refresh_twamp_aggregations()
│       └── refresh_rolling_20day()
│
├── 04_scheduler_setup.sql             # DBMS_SCHEDULER configuration
│   ├── JOB_DAILY_AGGREGATION_REFRESH
│   └── Monitoring queries
│
├── 05_optimized_query_examples.sql    # Before/After examples
│   ├── Query 122.800 optimization
│   ├── Query 100.358 optimization
│   ├── Query 100.643 optimization
│   └── General patterns
│
└── README.md                          # This file
```

---

## 🚀 Deployment Guide

### Prerequisites

- [x] Database indexes exist on FRAGMENT_DATE, NETWORK_ID, SUB_REGION_ID
- [x] Tables partitioned by date range
- [ ] Sufficient tablespace for aggregation tables (~10GB estimated)
- [ ] DBMS_SCHEDULER privileges
- [ ] Statistics collection scheduled

### Step 1: Create Materialized Views (30 minutes)

```sql
@01_materialized_views.sql
```

**Post-execution checks:**
```sql
-- Verify MVs created
SELECT mview_name, last_refresh_date, staleness
FROM USER_MVIEWS
WHERE mview_name LIKE 'MV_%';

-- Verify MV logs created
SELECT log_table, master FROM USER_MVIEW_LOGS;

-- Check initial row counts
SELECT 'MV_DAILY_CM_4G' AS mv_name, COUNT(*) FROM MV_DAILY_CM_4G
UNION ALL
SELECT 'MV_DAILY_CM_2G', COUNT(*) FROM MV_DAILY_CM_2G
UNION ALL
SELECT 'MV_DAILY_CM_3G', COUNT(*) FROM MV_DAILY_CM_3G;
```

### Step 2: Create Aggregation Tables (5 minutes)

```sql
@02_aggregation_tables.sql
```

**Post-execution checks:**
```sql
-- Verify tables created
SELECT table_name, partitioned, compression
FROM USER_TABLES
WHERE table_name LIKE 'AGG_%';

-- Verify partitioning
SELECT table_name, partition_name, high_value
FROM USER_TAB_PARTITIONS
WHERE table_name LIKE 'AGG_%'
ORDER BY table_name, partition_position DESC;

-- Verify indexes
SELECT table_name, index_name, uniqueness
FROM USER_INDEXES
WHERE table_name LIKE 'AGG_%';
```

### Step 3: Deploy Refresh Package (10 minutes)

```sql
@03_incremental_refresh_package.sql
```

**Post-execution checks:**
```sql
-- Verify package compiled
SELECT object_name, object_type, status
FROM USER_OBJECTS
WHERE object_name = 'PKG_REPORT_AGGREGATION';

-- Verify log table created
SELECT COUNT(*) FROM AGG_REFRESH_LOG;
```

### Step 4: Initial Data Load (Backfill) (2-4 hours)

```sql
-- Load past 30 days
DECLARE
    v_date DATE;
BEGIN
    FOR i IN 1..30 LOOP
        v_date := TRUNC(SYSDATE) - i;
        DBMS_OUTPUT.PUT_LINE('Processing: ' || TO_CHAR(v_date, 'YYYY-MM-DD'));

        PKG_REPORT_AGGREGATION.refresh_all(v_date);

        COMMIT;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('Backfill completed successfully');
END;
/
```

**Monitor progress:**
```sql
SELECT
    procedure_name,
    status,
    COUNT(*) AS count,
    MAX(log_timestamp) AS last_run
FROM AGG_REFRESH_LOG
GROUP BY procedure_name, status
ORDER BY procedure_name, status;
```

### Step 5: Setup Scheduler (5 minutes)

```sql
@04_scheduler_setup.sql

-- Enable the job
BEGIN
    DBMS_SCHEDULER.ENABLE('JOB_DAILY_AGGREGATION_REFRESH');
END;
/
```

**Verify scheduler:**
```sql
SELECT job_name, enabled, state, next_run_date
FROM USER_SCHEDULER_JOBS
WHERE job_name = 'JOB_DAILY_AGGREGATION_REFRESH';
```

### Step 6: Test Optimized Queries (30 minutes)

```sql
-- Run comparison tests from 05_optimized_query_examples.sql

-- Before
SET TIMING ON
-- [Run original query]
SET TIMING OFF

-- After
SET TIMING ON
-- [Run optimized query]
SET TIMING OFF

-- Compare results and timing
```

---

## 📊 Performance Metrics

### Before Optimization

| Metric | Value |
|--------|-------|
| Average Query Time | 45-120 seconds |
| Peak CPU Usage | 80-95% |
| Buffer Gets (per query) | 500M - 2B |
| Disk Reads (per query) | 100K - 500K |
| Daily Execution Time | 8-12 hours total |

### After Optimization (Expected)

| Metric | Value | Improvement |
|--------|-------|-------------|
| Average Query Time | 2-8 seconds | **90-95%** |
| Peak CPU Usage | 20-40% | **50-75%** |
| Buffer Gets (per query) | 10M - 50M | **95%** |
| Disk Reads (per query) | 1K - 10K | **99%** |
| Daily Execution Time | 30-45 minutes | **94%** |

### Aggregation Refresh Overhead

| Operation | Time | Frequency |
|-----------|------|-----------|
| MV Refresh | 5-10 min | Daily |
| Aggregation Build | 10-15 min | Daily |
| Stats Collection | 5 min | Daily |
| **Total Overhead** | **20-30 min** | **Daily** |

**ROI:** 8-12 hours saved daily vs. 30 minutes overhead = **20-30x improvement**

---

## 🔍 Monitoring & Maintenance

### Daily Health Checks

```sql
-- Check last refresh status
SELECT
    session_id,
    procedure_name,
    status,
    row_count,
    log_timestamp
FROM AGG_REFRESH_LOG
WHERE session_id = (SELECT MAX(session_id) FROM AGG_REFRESH_LOG)
ORDER BY log_timestamp;

-- Check aggregation data completeness
SELECT
    'AGG_CELL_AVAILABILITY_DAILY_4G' AS table_name,
    MAX(AGGREGATION_DATE) AS latest_date,
    COUNT(DISTINCT AGGREGATION_DATE) AS days_available
FROM AGG_CELL_AVAILABILITY_DAILY_4G
UNION ALL
SELECT
    'AGG_TRAFFIC_DAILY_4G',
    MAX(AGGREGATION_DATE),
    COUNT(DISTINCT AGGREGATION_DATE)
FROM AGG_TRAFFIC_DAILY_4G;

-- Check MV staleness
SELECT
    mview_name,
    staleness,
    last_refresh_date
FROM USER_MVIEWS
WHERE mview_name LIKE 'MV_%';
```

### Weekly Maintenance

```sql
-- Check partition counts
SELECT
    table_name,
    COUNT(*) AS partition_count
FROM USER_TAB_PARTITIONS
WHERE table_name LIKE 'AGG_%'
GROUP BY table_name;

-- Check table sizes
SELECT
    segment_name,
    ROUND(SUM(bytes)/1024/1024/1024, 2) AS size_gb
FROM USER_SEGMENTS
WHERE segment_name LIKE 'AGG_%'
GROUP BY segment_name
ORDER BY 2 DESC;

-- Verify query performance improvement
SELECT
    sql_id,
    executions,
    ROUND(elapsed_time/executions/1000000, 2) AS avg_sec,
    ROUND(buffer_gets/executions, 0) AS avg_buffer_gets
FROM V$SQL
WHERE sql_text LIKE '%AGG_%'
ORDER BY avg_sec DESC;
```

### Alerts Configuration

Set up alerts for:
- ❌ Refresh job failures
- ⚠️ Refresh taking > 45 minutes
- ⚠️ MV staleness > 2 days
- ❌ Missing daily aggregation data
- ⚠️ Aggregation table growth > 15GB

---

## 🛠️ Troubleshooting

### Issue: MV Refresh Fails

**Symptoms:** Stale MVs, refresh errors in log

**Diagnosis:**
```sql
SELECT * FROM AGG_REFRESH_LOG
WHERE status = 'ERROR'
ORDER BY log_timestamp DESC;
```

**Solutions:**
1. Check source table availability
2. Verify MV log integrity
3. Consider complete refresh: `DBMS_MVIEW.REFRESH('MV_NAME', 'C')`
4. Rebuild MV if corrupted

### Issue: Aggregation Data Missing

**Symptoms:** Queries return no rows for certain dates

**Diagnosis:**
```sql
-- Check for gaps in aggregation dates
WITH date_range AS (
    SELECT TRUNC(SYSDATE) - LEVEL AS check_date
    FROM DUAL
    CONNECT BY LEVEL <= 30
)
SELECT
    d.check_date,
    CASE WHEN a.AGGREGATION_DATE IS NULL THEN 'MISSING' ELSE 'OK' END AS status
FROM date_range d
LEFT JOIN AGG_CELL_AVAILABILITY_DAILY_4G a
    ON d.check_date = a.AGGREGATION_DATE
ORDER BY d.check_date DESC;
```

**Solutions:**
1. Manual refresh for missing date:
   ```sql
   BEGIN
       PKG_REPORT_AGGREGATION.refresh_all(TO_DATE('2024-01-15', 'YYYY-MM-DD'));
   END;
   /
   ```
2. Check source data availability
3. Verify scheduler ran successfully

### Issue: Slow Aggregation Build

**Symptoms:** Refresh taking > 1 hour

**Diagnosis:**
```sql
-- Check long-running operations
SELECT
    opname,
    target,
    ROUND(sofar/totalwork*100, 2) AS pct_complete,
    elapsed_seconds,
    time_remaining
FROM V$SESSION_LONGOPS
WHERE totalwork > 0;
```

**Solutions:**
1. Increase PARALLEL degree
2. Check for table/index statistics staleness
3. Verify partition pruning is working
4. Consider incremental statistics collection

---

## 📈 Future Enhancements

### Phase 2 Optimizations

1. **Real-time Aggregations**
   - Hourly aggregation updates
   - Stream processing for critical KPIs

2. **Advanced Caching**
   - Result cache for frequently accessed data
   - In-memory column store for hot partitions

3. **Predictive Analytics**
   - ML-based anomaly detection
   - Proactive alerting

4. **Multi-level Aggregations**
   - Hourly → Daily → Weekly → Monthly
   - Hierarchical rollups

### Query Rewrite Automation

Create a tool to automatically convert old queries to use new structures:

```sql
-- Example: Query rewrite procedure
CREATE OR REPLACE PROCEDURE REWRITE_QUERY(
    p_old_query IN CLOB,
    p_new_query OUT CLOB
) AS
BEGIN
    -- Pattern matching and replacement logic
    -- Replace CM_4G CTE with MV_DAILY_CM_4G
    -- Replace aggregation logic with AGG_* tables
    NULL; -- Implementation TBD
END;
/
```

---

## 👥 Roles & Responsibilities

| Role | Responsibility |
|------|----------------|
| DBA | Deploy objects, monitor performance, maintain scheduler |
| Developer | Rewrite queries, validate results, test performance |
| Report Owner | Verify business logic, validate output correctness |
| Ops Team | Monitor alerts, escalate issues, perform health checks |

---

## 📞 Support

For issues or questions:
1. Check troubleshooting section above
2. Review AGG_REFRESH_LOG for errors
3. Check scheduler job logs
4. Contact DBA team with specific error messages

---

## 📝 Change Log

| Date | Version | Changes |
|------|---------|---------|
| 2024-12-19 | 1.0 | Initial optimization strategy |

---

## ✅ Success Criteria

- [ ] All MVs refreshing successfully daily
- [ ] All aggregation tables populated for past 30 days
- [ ] Scheduler job running without failures
- [ ] Average query time < 10 seconds
- [ ] Database CPU usage reduced by > 50%
- [ ] All reports producing correct results
- [ ] Zero data quality issues
- [ ] Monitoring dashboards operational

---

**End of Documentation**
