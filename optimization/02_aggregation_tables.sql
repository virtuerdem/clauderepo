-- ================================================================
-- AGGREGATION TABLES FOR REPORT PERFORMANCE OPTIMIZATION
-- ================================================================
-- Purpose: Pre-calculate common aggregations to reduce query load
-- Strategy: Incremental daily/hourly aggregation
-- Data Retention: 90 days (configurable)
-- ================================================================

-- ================================================================
-- 1. AGG_CELL_AVAILABILITY_DAILY_4G
-- ================================================================
-- Pre-aggregated daily availability metrics for 4G cells
-- Eliminates need for complex availability calculations in queries
-- ================================================================

CREATE TABLE AGG_CELL_AVAILABILITY_DAILY_4G
(
    AGGREGATION_DATE    DATE NOT NULL,
    SUB_REGION_ID       NUMBER,
    SUB_REGION_NAME     VARCHAR2(100),
    ENODEB_ID           NUMBER,
    ENODEB_NAME         VARCHAR2(200),
    CELL_ID             NUMBER,
    CELL_NAME           VARCHAR2(200),
    -- Availability Metrics
    AVAILABILITY_PCT    NUMBER(10,2),
    AVAILABILITY_SYS    NUMBER(10,2),
    -- Aggregated values for recalculation if needed
    TOTAL_PARTIAL_AVAIL NUMBER,
    TOTAL_UNAVAIL_MANUAL NUMBER,
    TOTAL_UNAVAIL_ENERGYSAVING NUMBER,
    MAX_HOUR            NUMBER,
    TOTAL_REC_CNT       NUMBER,
    -- Metadata
    LOAD_TIMESTAMP      TIMESTAMP DEFAULT SYSTIMESTAMP,
    SOURCE_RECORD_COUNT NUMBER,
    -- Constraints
    CONSTRAINT pk_agg_avail_daily_4g PRIMARY KEY (AGGREGATION_DATE, CELL_ID)
)
PARTITION BY RANGE (AGGREGATION_DATE)
INTERVAL(NUMTODSINTERVAL(1, 'DAY'))
(
    PARTITION p_initial VALUES LESS THAN (TO_DATE('2024-01-01', 'YYYY-MM-DD'))
)
COMPRESS FOR QUERY HIGH
PARALLEL 4;

-- Indexes
CREATE INDEX idx_agg_avail_4g_sub ON AGG_CELL_AVAILABILITY_DAILY_4G(SUB_REGION_ID, AGGREGATION_DATE);
CREATE INDEX idx_agg_avail_4g_enodeb ON AGG_CELL_AVAILABILITY_DAILY_4G(ENODEB_ID, AGGREGATION_DATE);
CREATE BITMAP INDEX bidx_agg_avail_4g_date ON AGG_CELL_AVAILABILITY_DAILY_4G(AGGREGATION_DATE);

-- ================================================================
-- 2. AGG_CELL_AVAILABILITY_DAILY_2G
-- ================================================================

CREATE TABLE AGG_CELL_AVAILABILITY_DAILY_2G
(
    AGGREGATION_DATE    DATE NOT NULL,
    SUB_REGION_ID       NUMBER,
    SUB_REGION_NAME     VARCHAR2(100),
    BSC_ID              NUMBER,
    BSC_NAME            VARCHAR2(200),
    BTS_ID              NUMBER,
    BTS_NAME            VARCHAR2(200),
    CELL_ID             NUMBER,
    CELL_NAME           VARCHAR2(200),
    AVAILABILITY_PCT    NUMBER(10,2),
    TOTAL_CELL_AVAIL    NUMBER,
    MAX_HOUR            NUMBER,
    TOTAL_REC_CNT       NUMBER,
    LOAD_TIMESTAMP      TIMESTAMP DEFAULT SYSTIMESTAMP,
    SOURCE_RECORD_COUNT NUMBER,
    CONSTRAINT pk_agg_avail_daily_2g PRIMARY KEY (AGGREGATION_DATE, CELL_ID)
)
PARTITION BY RANGE (AGGREGATION_DATE)
INTERVAL(NUMTODSINTERVAL(1, 'DAY'))
(
    PARTITION p_initial VALUES LESS THAN (TO_DATE('2024-01-01', 'YYYY-MM-DD'))
)
COMPRESS FOR QUERY HIGH
PARALLEL 4;

CREATE INDEX idx_agg_avail_2g_sub ON AGG_CELL_AVAILABILITY_DAILY_2G(SUB_REGION_ID, AGGREGATION_DATE);
CREATE INDEX idx_agg_avail_2g_bts ON AGG_CELL_AVAILABILITY_DAILY_2G(BTS_ID, AGGREGATION_DATE);

-- ================================================================
-- 3. AGG_TRAFFIC_DAILY_4G
-- ================================================================
-- Pre-aggregated traffic volumes by cell/enodeb
-- ================================================================

CREATE TABLE AGG_TRAFFIC_DAILY_4G
(
    AGGREGATION_DATE        DATE NOT NULL,
    AGGREGATION_LEVEL       VARCHAR2(20) NOT NULL, -- 'CELL' or 'ENODEB'
    SUB_REGION_ID           NUMBER,
    SUB_REGION_NAME         VARCHAR2(100),
    ENODEB_ID               NUMBER,
    ENODEB_NAME             VARCHAR2(200),
    CELL_ID                 NUMBER,
    CELL_NAME               VARCHAR2(200),
    -- Traffic Metrics
    DL_TRAFFIC_VOL          NUMBER,
    UL_TRAFFIC_VOL          NUMBER,
    TOTAL_TRAFFIC_VOL       NUMBER,
    TRAFFIC_VOL_MB          NUMBER(15,2),
    TRAFFIC_VOL_GB          NUMBER(15,3),
    -- Additional Metrics
    CELL_UNAVAIL_DUR_ENERGYSAVING NUMBER(10,2),
    AVG_THROUGHPUT_DL       NUMBER(15,2),
    AVG_THROUGHPUT_UL       NUMBER(15,2),
    -- Metadata
    LOAD_TIMESTAMP          TIMESTAMP DEFAULT SYSTIMESTAMP,
    SOURCE_RECORD_COUNT     NUMBER,
    CONSTRAINT pk_agg_traffic_daily_4g PRIMARY KEY (AGGREGATION_DATE, AGGREGATION_LEVEL, CELL_ID)
)
PARTITION BY RANGE (AGGREGATION_DATE)
INTERVAL(NUMTODSINTERVAL(1, 'DAY'))
(
    PARTITION p_initial VALUES LESS THAN (TO_DATE('2024-01-01', 'YYYY-MM-DD'))
)
COMPRESS FOR QUERY HIGH
PARALLEL 4;

CREATE INDEX idx_agg_traffic_4g_sub ON AGG_TRAFFIC_DAILY_4G(SUB_REGION_ID, AGGREGATION_DATE);
CREATE INDEX idx_agg_traffic_4g_enodeb ON AGG_TRAFFIC_DAILY_4G(ENODEB_ID, AGGREGATION_DATE);
CREATE BITMAP INDEX bidx_agg_traffic_4g_level ON AGG_TRAFFIC_DAILY_4G(AGGREGATION_LEVEL);

-- ================================================================
-- 4. AGG_REGIONAL_SUMMARY_DAILY
-- ================================================================
-- Regional level aggregations (SUB_REGION and NW level)
-- Used for high-level dashboards and reports
-- ================================================================

CREATE TABLE AGG_REGIONAL_SUMMARY_DAILY
(
    AGGREGATION_DATE        DATE NOT NULL,
    NETWORK_TYPE            VARCHAR2(10) NOT NULL, -- '2G', '3G', '4G'
    SUB_REGION_ID           NUMBER,
    SUB_REGION_NAME         VARCHAR2(100) NOT NULL,
    -- Availability Metrics
    AVG_AVAILABILITY_PCT    NUMBER(10,2),
    MIN_AVAILABILITY_PCT    NUMBER(10,2),
    MAX_AVAILABILITY_PCT    NUMBER(10,2),
    -- Traffic Metrics (4G only)
    TOTAL_TRAFFIC_GB        NUMBER(15,2),
    AVG_TRAFFIC_PER_CELL_MB NUMBER(15,2),
    -- Cell Counts
    TOTAL_CELLS             NUMBER,
    ACTIVE_CELLS            NUMBER,
    ZERO_TRAFFIC_CELLS      NUMBER,
    -- Metadata
    LOAD_TIMESTAMP          TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_agg_regional_daily PRIMARY KEY (AGGREGATION_DATE, NETWORK_TYPE, SUB_REGION_NAME)
)
PARTITION BY RANGE (AGGREGATION_DATE)
INTERVAL(NUMTODSINTERVAL(1, 'DAY'))
(
    PARTITION p_initial VALUES LESS THAN (TO_DATE('2024-01-01', 'YYYY-MM-DD'))
)
COMPRESS FOR QUERY HIGH
PARALLEL 4;

CREATE INDEX idx_agg_regional_sub ON AGG_REGIONAL_SUMMARY_DAILY(SUB_REGION_ID, AGGREGATION_DATE);
CREATE BITMAP INDEX bidx_agg_regional_net ON AGG_REGIONAL_SUMMARY_DAILY(NETWORK_TYPE);

-- ================================================================
-- 5. AGG_TWAMP_JITTER_DAILY
-- ================================================================
-- Pre-aggregated TWAMP performance metrics
-- Used in queries like 122.800
-- ================================================================

CREATE TABLE AGG_TWAMP_JITTER_DAILY
(
    AGGREGATION_DATE    DATE NOT NULL,
    SUB_REGION_ID       NUMBER,
    SUB_REGION_NAME     VARCHAR2(100),
    CITY_ID             NUMBER,
    CITY_NAME           VARCHAR2(100),
    ENODEB_ID           NUMBER,
    ENODEB_NAME         VARCHAR2(200),
    -- TWAMP Metrics
    AVG_JITTER          NUMBER(10,3),
    MAX_JITTER          NUMBER(10,3),
    MIN_JITTER          NUMBER(10,3),
    AVG_DELAY           NUMBER(10,3),
    AVG_PACKET_LOSS     NUMBER(10,3),
    -- Metadata
    LOAD_TIMESTAMP      TIMESTAMP DEFAULT SYSTIMESTAMP,
    SAMPLE_COUNT        NUMBER,
    CONSTRAINT pk_agg_twamp_daily PRIMARY KEY (AGGREGATION_DATE, ENODEB_ID)
)
PARTITION BY RANGE (AGGREGATION_DATE)
INTERVAL(NUMTODSINTERVAL(1, 'DAY'))
(
    PARTITION p_initial VALUES LESS THAN (TO_DATE('2024-01-01', 'YYYY-MM-DD'))
)
COMPRESS FOR QUERY HIGH
PARALLEL 4;

CREATE INDEX idx_agg_twamp_sub ON AGG_TWAMP_JITTER_DAILY(SUB_REGION_ID, AGGREGATION_DATE);
CREATE INDEX idx_agg_twamp_city ON AGG_TWAMP_JITTER_DAILY(CITY_ID, AGGREGATION_DATE);

-- ================================================================
-- 6. AGG_AVAILABILITY_ROLLING_20DAY
-- ================================================================
-- Pre-pivoted 20-day rolling availability data
-- Eliminates need for 20 DECODE operations in queries
-- ================================================================

CREATE TABLE AGG_AVAILABILITY_ROLLING_20DAY
(
    BASE_DATE           DATE NOT NULL,
    NETWORK_TYPE        VARCHAR2(10) NOT NULL,
    SUB_REGION_ID       NUMBER,
    ENODEB_NAME         VARCHAR2(200),
    CELL_NAME           VARCHAR2(200),
    NETWORK_ID          NUMBER,
    -- 20 days of data (DAY_1 is most recent, DAY_20 is oldest)
    DAY_1_VALUE         NUMBER(10,2),
    DAY_2_VALUE         NUMBER(10,2),
    DAY_3_VALUE         NUMBER(10,2),
    DAY_4_VALUE         NUMBER(10,2),
    DAY_5_VALUE         NUMBER(10,2),
    DAY_6_VALUE         NUMBER(10,2),
    DAY_7_VALUE         NUMBER(10,2),
    DAY_8_VALUE         NUMBER(10,2),
    DAY_9_VALUE         NUMBER(10,2),
    DAY_10_VALUE        NUMBER(10,2),
    DAY_11_VALUE        NUMBER(10,2),
    DAY_12_VALUE        NUMBER(10,2),
    DAY_13_VALUE        NUMBER(10,2),
    DAY_14_VALUE        NUMBER(10,2),
    DAY_15_VALUE        NUMBER(10,2),
    DAY_16_VALUE        NUMBER(10,2),
    DAY_17_VALUE        NUMBER(10,2),
    DAY_18_VALUE        NUMBER(10,2),
    DAY_19_VALUE        NUMBER(10,2),
    DAY_20_VALUE        NUMBER(10,2),
    LOAD_TIMESTAMP      TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_agg_rolling_20day PRIMARY KEY (BASE_DATE, NETWORK_TYPE, NETWORK_ID)
)
PARTITION BY RANGE (BASE_DATE)
INTERVAL(NUMTODSINTERVAL(1, 'DAY'))
(
    PARTITION p_initial VALUES LESS THAN (TO_DATE('2024-01-01', 'YYYY-MM-DD'))
)
COMPRESS FOR QUERY HIGH
PARALLEL 4;

CREATE INDEX idx_agg_rolling_sub ON AGG_AVAILABILITY_ROLLING_20DAY(SUB_REGION_ID, BASE_DATE);
CREATE INDEX idx_agg_rolling_net ON AGG_AVAILABILITY_ROLLING_20DAY(NETWORK_ID, BASE_DATE);

-- ================================================================
-- DATA RETENTION POLICY
-- ================================================================
-- Keep 90 days of aggregated data
-- Older partitions can be dropped or archived
-- ================================================================

COMMENT ON TABLE AGG_CELL_AVAILABILITY_DAILY_4G IS 'Aggregated daily availability metrics for 4G cells. Retention: 90 days';
COMMENT ON TABLE AGG_TRAFFIC_DAILY_4G IS 'Aggregated daily traffic metrics for 4G cells. Retention: 90 days';
COMMENT ON TABLE AGG_REGIONAL_SUMMARY_DAILY IS 'Regional level daily summaries. Retention: 90 days';
COMMENT ON TABLE AGG_TWAMP_JITTER_DAILY IS 'Daily TWAMP performance metrics. Retention: 90 days';
COMMENT ON TABLE AGG_AVAILABILITY_ROLLING_20DAY IS 'Pre-pivoted 20-day rolling data. Retention: 30 days';

-- ================================================================
-- GRANTS
-- ================================================================

GRANT SELECT ON AGG_CELL_AVAILABILITY_DAILY_4G TO REPORT_USER_ROLE;
GRANT SELECT ON AGG_CELL_AVAILABILITY_DAILY_2G TO REPORT_USER_ROLE;
GRANT SELECT ON AGG_TRAFFIC_DAILY_4G TO REPORT_USER_ROLE;
GRANT SELECT ON AGG_REGIONAL_SUMMARY_DAILY TO REPORT_USER_ROLE;
GRANT SELECT ON AGG_TWAMP_JITTER_DAILY TO REPORT_USER_ROLE;
GRANT SELECT ON AGG_AVAILABILITY_ROLLING_20DAY TO REPORT_USER_ROLE;

-- ================================================================
-- STATISTICS COLLECTION
-- ================================================================

BEGIN
    DBMS_STATS.SET_TABLE_PREFS(USER, 'AGG_CELL_AVAILABILITY_DAILY_4G', 'INCREMENTAL', 'TRUE');
    DBMS_STATS.SET_TABLE_PREFS(USER, 'AGG_CELL_AVAILABILITY_DAILY_2G', 'INCREMENTAL', 'TRUE');
    DBMS_STATS.SET_TABLE_PREFS(USER, 'AGG_TRAFFIC_DAILY_4G', 'INCREMENTAL', 'TRUE');
    DBMS_STATS.SET_TABLE_PREFS(USER, 'AGG_REGIONAL_SUMMARY_DAILY', 'INCREMENTAL', 'TRUE');
    DBMS_STATS.SET_TABLE_PREFS(USER, 'AGG_TWAMP_JITTER_DAILY', 'INCREMENTAL', 'TRUE');
    DBMS_STATS.SET_TABLE_PREFS(USER, 'AGG_AVAILABILITY_ROLLING_20DAY', 'INCREMENTAL', 'TRUE');
END;
/
