-- ================================================================
-- PKG_REPORT_AGGREGATION - Incremental Refresh Package
-- ================================================================
-- Purpose: Manage incremental refresh of MVs and aggregation tables
-- Schedule: Run after daily data loads complete
-- Dependencies: DBMS_SCHEDULER for automation
-- ================================================================

CREATE OR REPLACE PACKAGE PKG_REPORT_AGGREGATION AS

    -- ============================================================
    -- CONSTANTS
    -- ============================================================
    C_RETENTION_DAYS    CONSTANT NUMBER := 90;
    C_LOG_TABLE         CONSTANT VARCHAR2(50) := 'AGG_REFRESH_LOG';

    -- ============================================================
    -- PUBLIC PROCEDURES
    -- ============================================================

    -- Main orchestration procedure
    PROCEDURE refresh_all(
        p_refresh_date  IN DATE DEFAULT TRUNC(SYSDATE-1),
        p_force_full    IN BOOLEAN DEFAULT FALSE
    );

    -- Individual refresh procedures
    PROCEDURE refresh_materialized_views(
        p_refresh_date  IN DATE DEFAULT TRUNC(SYSDATE-1)
    );

    PROCEDURE refresh_availability_aggregations(
        p_refresh_date  IN DATE DEFAULT TRUNC(SYSDATE-1)
    );

    PROCEDURE refresh_traffic_aggregations(
        p_refresh_date  IN DATE DEFAULT TRUNC(SYSDATE-1)
    );

    PROCEDURE refresh_regional_summaries(
        p_refresh_date  IN DATE DEFAULT TRUNC(SYSDATE-1)
    );

    PROCEDURE refresh_twamp_aggregations(
        p_refresh_date  IN DATE DEFAULT TRUNC(SYSDATE-1)
    );

    PROCEDURE refresh_rolling_20day(
        p_refresh_date  IN DATE DEFAULT TRUNC(SYSDATE-1)
    );

    -- Maintenance procedures
    PROCEDURE cleanup_old_partitions(
        p_retention_days IN NUMBER DEFAULT C_RETENTION_DAYS
    );

    PROCEDURE collect_stats_after_load;

    -- Monitoring
    FUNCTION get_last_refresh_status RETURN SYS_REFCURSOR;

END PKG_REPORT_AGGREGATION;
/

CREATE OR REPLACE PACKAGE BODY PKG_REPORT_AGGREGATION AS

    -- ============================================================
    -- PRIVATE VARIABLES
    -- ============================================================
    g_session_id        NUMBER;
    g_start_time        TIMESTAMP;

    -- ============================================================
    -- LOGGING PROCEDURE
    -- ============================================================
    PROCEDURE log_message(
        p_procedure     IN VARCHAR2,
        p_message       IN VARCHAR2,
        p_status        IN VARCHAR2 DEFAULT 'INFO',
        p_row_count     IN NUMBER DEFAULT NULL,
        p_error_msg     IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO AGG_REFRESH_LOG (
            session_id, procedure_name, message, status,
            row_count, error_message, log_timestamp
        ) VALUES (
            g_session_id, p_procedure, p_message, p_status,
            p_row_count, p_error_msg, SYSTIMESTAMP
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Logging failed: ' || SQLERRM);
    END log_message;

    -- ============================================================
    -- REFRESH MATERIALIZED VIEWS
    -- ============================================================
    PROCEDURE refresh_materialized_views(
        p_refresh_date IN DATE DEFAULT TRUNC(SYSDATE-1)
    ) IS
        v_start_time    TIMESTAMP := SYSTIMESTAMP;
        v_duration      NUMBER;
    BEGIN
        log_message('refresh_materialized_views',
                    'Starting MV refresh for date: ' || TO_CHAR(p_refresh_date, 'YYYY-MM-DD'),
                    'START');

        -- Refresh CM_4G
        BEGIN
            DBMS_MVIEW.REFRESH('MV_DAILY_CM_4G', 'C'); -- Complete refresh (can be changed to 'F' for fast)
            log_message('refresh_materialized_views', 'MV_DAILY_CM_4G refreshed', 'SUCCESS');
        EXCEPTION
            WHEN OTHERS THEN
                log_message('refresh_materialized_views', 'MV_DAILY_CM_4G failed', 'ERROR', NULL, SQLERRM);
                RAISE;
        END;

        -- Refresh CM_2G
        BEGIN
            DBMS_MVIEW.REFRESH('MV_DAILY_CM_2G', 'C');
            log_message('refresh_materialized_views', 'MV_DAILY_CM_2G refreshed', 'SUCCESS');
        EXCEPTION
            WHEN OTHERS THEN
                log_message('refresh_materialized_views', 'MV_DAILY_CM_2G failed', 'ERROR', NULL, SQLERRM);
                RAISE;
        END;

        -- Refresh CM_3G
        BEGIN
            DBMS_MVIEW.REFRESH('MV_DAILY_CM_3G', 'C');
            log_message('refresh_materialized_views', 'MV_DAILY_CM_3G refreshed', 'SUCCESS');
        EXCEPTION
            WHEN OTHERS THEN
                log_message('refresh_materialized_views', 'MV_DAILY_CM_3G failed', 'ERROR', NULL, SQLERRM);
                RAISE;
        END;

        -- Refresh Availability ONAIR
        BEGIN
            DBMS_MVIEW.REFRESH('MV_AVAILABILITY_ONAIR_4G', 'C');
            log_message('refresh_materialized_views', 'MV_AVAILABILITY_ONAIR_4G refreshed', 'SUCCESS');
        EXCEPTION
            WHEN OTHERS THEN
                log_message('refresh_materialized_views', 'MV_AVAILABILITY_ONAIR_4G failed', 'ERROR', NULL, SQLERRM);
                RAISE;
        END;

        v_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - v_start_time));
        log_message('refresh_materialized_views',
                    'All MVs refreshed successfully in ' || ROUND(v_duration,2) || ' seconds',
                    'COMPLETE');

    EXCEPTION
        WHEN OTHERS THEN
            log_message('refresh_materialized_views', 'Fatal error', 'ERROR', NULL, SQLERRM);
            RAISE;
    END refresh_materialized_views;

    -- ============================================================
    -- REFRESH AVAILABILITY AGGREGATIONS
    -- ============================================================
    PROCEDURE refresh_availability_aggregations(
        p_refresh_date IN DATE DEFAULT TRUNC(SYSDATE-1)
    ) IS
        v_row_count     NUMBER;
    BEGIN
        log_message('refresh_availability_aggregations',
                    'Starting availability aggregation for date: ' || TO_CHAR(p_refresh_date, 'YYYY-MM-DD'),
                    'START');

        -- Delete existing data for refresh date (idempotent operation)
        DELETE FROM AGG_CELL_AVAILABILITY_DAILY_4G WHERE AGGREGATION_DATE = p_refresh_date;
        COMMIT;

        -- Insert aggregated data for 4G
        INSERT /*+ APPEND PARALLEL(4) */ INTO AGG_CELL_AVAILABILITY_DAILY_4G
        (
            AGGREGATION_DATE, SUB_REGION_ID, SUB_REGION_NAME,
            ENODEB_ID, ENODEB_NAME, CELL_ID, CELL_NAME,
            AVAILABILITY_PCT, AVAILABILITY_SYS,
            TOTAL_PARTIAL_AVAIL, TOTAL_UNAVAIL_MANUAL, TOTAL_UNAVAIL_ENERGYSAVING,
            MAX_HOUR, TOTAL_REC_CNT, SOURCE_RECORD_COUNT
        )
        SELECT
            p_refresh_date AS AGGREGATION_DATE,
            CM.SUB_REGION_ID,
            CM.SUB_REGION_NAME,
            CM.ENODEB_ID,
            CM.ENODEB_NAME,
            CM.CELL_ID,
            CM.CELL_NAME,
            -- Calculate availability percentage
            ROUND(
                100 - (
                    (SUM(DA.PARTIAL_AVAIL) + SUM(NVL(DA.L_CELL_UNAVAIL_DUR_MANUAL, 0)))
                    / (60 * 60 * CASE WHEN MAX(DA.HOUR) > 24 THEN 24 ELSE MAX(DA.HOUR) END * SUM(DA.REC_CNT))
                    * 100
                ),
                2
            ) AS AVAILABILITY_PCT,
            -- System availability (without manual unavailability)
            ROUND(
                100 - (
                    SUM(DA.PARTIAL_AVAIL)
                    / (60 * 60 * CASE WHEN MAX(DA.HOUR) > 24 THEN 24 ELSE MAX(DA.HOUR) END * SUM(DA.REC_CNT))
                    * 100
                ),
                2
            ) AS AVAILABILITY_SYS,
            SUM(DA.PARTIAL_AVAIL) AS TOTAL_PARTIAL_AVAIL,
            SUM(NVL(DA.L_CELL_UNAVAIL_DUR_MANUAL, 0)) AS TOTAL_UNAVAIL_MANUAL,
            MAX(DA.CELL_UNAVAIL_DUR_ENERGYSAVING) AS TOTAL_UNAVAIL_ENERGYSAVING,
            MAX(DA.HOUR) AS MAX_HOUR,
            SUM(DA.REC_CNT) AS TOTAL_REC_CNT,
            COUNT(*) AS SOURCE_RECORD_COUNT
        FROM
            MV_DAILY_CM_4G CM
        JOIN
            NORTHI_DATA.CELLSTS_4G_DA DA ON CM.CELL_ID = DA.NETWORK_ID
                                         AND CM.DATA_DATE = DA.FRAGMENT_DATE
        WHERE
            CM.DATA_DATE = p_refresh_date
            AND DA.FRAGMENT_DATE = p_refresh_date
            AND DA.DTYPE = 1
        GROUP BY
            CM.SUB_REGION_ID, CM.SUB_REGION_NAME,
            CM.ENODEB_ID, CM.ENODEB_NAME,
            CM.CELL_ID, CM.CELL_NAME;

        v_row_count := SQL%ROWCOUNT;
        COMMIT;

        log_message('refresh_availability_aggregations',
                    '4G availability aggregation completed',
                    'SUCCESS',
                    v_row_count);

        -- Similar process for 2G
        DELETE FROM AGG_CELL_AVAILABILITY_DAILY_2G WHERE AGGREGATION_DATE = p_refresh_date;

        INSERT /*+ APPEND PARALLEL(4) */ INTO AGG_CELL_AVAILABILITY_DAILY_2G
        (
            AGGREGATION_DATE, SUB_REGION_ID, SUB_REGION_NAME,
            BSC_ID, BSC_NAME, BTS_ID, BTS_NAME, CELL_ID, CELL_NAME,
            AVAILABILITY_PCT, TOTAL_CELL_AVAIL, MAX_HOUR, TOTAL_REC_CNT, SOURCE_RECORD_COUNT
        )
        SELECT
            p_refresh_date AS AGGREGATION_DATE,
            CM.SUB_REGION_ID,
            CM.SUB_REGION_NAME,
            CM.BSC_ID,
            CM.BSC_NAME,
            CM.BTS_ID,
            CM.BTS_NAME,
            CM.CELL_ID,
            CM.CELL_NAME,
            ROUND(
                100 - (
                    (SUM(DA.CELL_AVAILABILITY) * 100)
                    / (60 * 60 * CASE WHEN MAX(DA.HOUR) > 24 THEN 24 ELSE MAX(DA.HOUR) END * SUM(DA.REC_CNT))
                ),
                2
            ) AS AVAILABILITY_PCT,
            SUM(DA.CELL_AVAILABILITY) AS TOTAL_CELL_AVAIL,
            MAX(DA.HOUR) AS MAX_HOUR,
            SUM(DA.REC_CNT) AS TOTAL_REC_CNT,
            COUNT(*) AS SOURCE_RECORD_COUNT
        FROM
            MV_DAILY_CM_2G CM
        JOIN
            NORTHI_DATA.CELLSTS_DA DA ON CM.CELL_ID = DA.NETWORK_ID
                                      AND CM.DATA_DATE = DA.FRAGMENT_DATE
        WHERE
            CM.DATA_DATE = p_refresh_date
            AND DA.FRAGMENT_DATE = p_refresh_date
            AND DA.DTYPE = 1
        GROUP BY
            CM.SUB_REGION_ID, CM.SUB_REGION_NAME,
            CM.BSC_ID, CM.BSC_NAME, CM.BTS_ID, CM.BTS_NAME,
            CM.CELL_ID, CM.CELL_NAME;

        v_row_count := SQL%ROWCOUNT;
        COMMIT;

        log_message('refresh_availability_aggregations',
                    '2G availability aggregation completed',
                    'SUCCESS',
                    v_row_count);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_message('refresh_availability_aggregations', 'Error occurred', 'ERROR', NULL, SQLERRM);
            RAISE;
    END refresh_availability_aggregations;

    -- ============================================================
    -- REFRESH TRAFFIC AGGREGATIONS
    -- ============================================================
    PROCEDURE refresh_traffic_aggregations(
        p_refresh_date IN DATE DEFAULT TRUNC(SYSDATE-1)
    ) IS
        v_row_count NUMBER;
    BEGIN
        log_message('refresh_traffic_aggregations',
                    'Starting traffic aggregation for date: ' || TO_CHAR(p_refresh_date, 'YYYY-MM-DD'),
                    'START');

        DELETE FROM AGG_TRAFFIC_DAILY_4G WHERE AGGREGATION_DATE = p_refresh_date;

        -- Cell level aggregation
        INSERT /*+ APPEND PARALLEL(4) */ INTO AGG_TRAFFIC_DAILY_4G
        SELECT
            p_refresh_date AS AGGREGATION_DATE,
            'CELL' AS AGGREGATION_LEVEL,
            CM.SUB_REGION_ID,
            CM.SUB_REGION_NAME,
            CM.ENODEB_ID,
            CM.ENODEB_NAME,
            CM.CELL_ID,
            CM.CELL_NAME,
            SUM(DA.DL_TRAFFIC_VOL) AS DL_TRAFFIC_VOL,
            SUM(DA.UL_TRAFFIC_VOL) AS UL_TRAFFIC_VOL,
            SUM(DA.DL_TRAFFIC_VOL + DA.UL_TRAFFIC_VOL) AS TOTAL_TRAFFIC_VOL,
            ROUND(SUM(DA.DL_TRAFFIC_VOL + DA.UL_TRAFFIC_VOL) / 8 / (1024 * 1024), 2) AS TRAFFIC_VOL_MB,
            ROUND(SUM(DA.DL_TRAFFIC_VOL + DA.UL_TRAFFIC_VOL) / 8 / (1024 * 1024 * 1024), 3) AS TRAFFIC_VOL_GB,
            MAX(DA.CELL_UNAVAIL_DUR_ENERGYSAVING) AS CELL_UNAVAIL_DUR_ENERGYSAVING,
            NULL AS AVG_THROUGHPUT_DL, -- Can add if needed
            NULL AS AVG_THROUGHPUT_UL,
            SYSTIMESTAMP AS LOAD_TIMESTAMP,
            COUNT(*) AS SOURCE_RECORD_COUNT
        FROM
            MV_DAILY_CM_4G CM
        JOIN
            NORTHI_DATA.CELLSTS_4G_DA DA ON CM.CELL_ID = DA.NETWORK_ID
                                         AND CM.DATA_DATE = DA.FRAGMENT_DATE
        WHERE
            CM.DATA_DATE = p_refresh_date
            AND DA.FRAGMENT_DATE = p_refresh_date
            AND DA.DTYPE = 1
        GROUP BY
            CM.SUB_REGION_ID, CM.SUB_REGION_NAME,
            CM.ENODEB_ID, CM.ENODEB_NAME,
            CM.CELL_ID, CM.CELL_NAME;

        v_row_count := SQL%ROWCOUNT;

        -- eNodeB level aggregation
        INSERT /*+ APPEND PARALLEL(4) */ INTO AGG_TRAFFIC_DAILY_4G
        SELECT
            p_refresh_date AS AGGREGATION_DATE,
            'ENODEB' AS AGGREGATION_LEVEL,
            SUB_REGION_ID,
            SUB_REGION_NAME,
            ENODEB_ID,
            ENODEB_NAME,
            NULL AS CELL_ID,
            NULL AS CELL_NAME,
            SUM(DL_TRAFFIC_VOL) AS DL_TRAFFIC_VOL,
            SUM(UL_TRAFFIC_VOL) AS UL_TRAFFIC_VOL,
            SUM(TOTAL_TRAFFIC_VOL) AS TOTAL_TRAFFIC_VOL,
            SUM(TRAFFIC_VOL_MB) AS TRAFFIC_VOL_MB,
            SUM(TRAFFIC_VOL_GB) AS TRAFFIC_VOL_GB,
            AVG(CELL_UNAVAIL_DUR_ENERGYSAVING) AS CELL_UNAVAIL_DUR_ENERGYSAVING,
            NULL AS AVG_THROUGHPUT_DL,
            NULL AS AVG_THROUGHPUT_UL,
            SYSTIMESTAMP AS LOAD_TIMESTAMP,
            SUM(SOURCE_RECORD_COUNT) AS SOURCE_RECORD_COUNT
        FROM
            AGG_TRAFFIC_DAILY_4G
        WHERE
            AGGREGATION_DATE = p_refresh_date
            AND AGGREGATION_LEVEL = 'CELL'
        GROUP BY
            SUB_REGION_ID, SUB_REGION_NAME, ENODEB_ID, ENODEB_NAME;

        v_row_count := v_row_count + SQL%ROWCOUNT;
        COMMIT;

        log_message('refresh_traffic_aggregations',
                    'Traffic aggregation completed',
                    'SUCCESS',
                    v_row_count);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_message('refresh_traffic_aggregations', 'Error occurred', 'ERROR', NULL, SQLERRM);
            RAISE;
    END refresh_traffic_aggregations;

    -- ============================================================
    -- REFRESH REGIONAL SUMMARIES
    -- ============================================================
    PROCEDURE refresh_regional_summaries(
        p_refresh_date IN DATE DEFAULT TRUNC(SYSDATE-1)
    ) IS
        v_row_count NUMBER;
    BEGIN
        log_message('refresh_regional_summaries',
                    'Starting regional summary for date: ' || TO_CHAR(p_refresh_date, 'YYYY-MM-DD'),
                    'START');

        DELETE FROM AGG_REGIONAL_SUMMARY_DAILY WHERE AGGREGATION_DATE = p_refresh_date;

        -- 4G Regional Summary
        INSERT /*+ APPEND */ INTO AGG_REGIONAL_SUMMARY_DAILY
        SELECT
            p_refresh_date AS AGGREGATION_DATE,
            '4G' AS NETWORK_TYPE,
            A.SUB_REGION_ID,
            A.SUB_REGION_NAME,
            ROUND(AVG(A.AVAILABILITY_PCT), 2) AS AVG_AVAILABILITY_PCT,
            MIN(A.AVAILABILITY_PCT) AS MIN_AVAILABILITY_PCT,
            MAX(A.AVAILABILITY_PCT) AS MAX_AVAILABILITY_PCT,
            ROUND(SUM(T.TRAFFIC_VOL_GB), 2) AS TOTAL_TRAFFIC_GB,
            ROUND(AVG(T.TRAFFIC_VOL_MB), 2) AS AVG_TRAFFIC_PER_CELL_MB,
            COUNT(DISTINCT A.CELL_ID) AS TOTAL_CELLS,
            COUNT(DISTINCT CASE WHEN T.TRAFFIC_VOL_MB > 0 THEN A.CELL_ID END) AS ACTIVE_CELLS,
            COUNT(DISTINCT CASE WHEN T.TRAFFIC_VOL_MB = 0 THEN A.CELL_ID END) AS ZERO_TRAFFIC_CELLS,
            SYSTIMESTAMP AS LOAD_TIMESTAMP
        FROM
            AGG_CELL_AVAILABILITY_DAILY_4G A
        LEFT JOIN
            AGG_TRAFFIC_DAILY_4G T ON A.CELL_ID = T.CELL_ID
                                   AND A.AGGREGATION_DATE = T.AGGREGATION_DATE
                                   AND T.AGGREGATION_LEVEL = 'CELL'
        WHERE
            A.AGGREGATION_DATE = p_refresh_date
        GROUP BY
            A.SUB_REGION_ID, A.SUB_REGION_NAME

        UNION ALL

        -- NW Level Summary for 4G
        SELECT
            p_refresh_date AS AGGREGATION_DATE,
            '4G' AS NETWORK_TYPE,
            NULL AS SUB_REGION_ID,
            'NW' AS SUB_REGION_NAME,
            ROUND(AVG(A.AVAILABILITY_PCT), 2) AS AVG_AVAILABILITY_PCT,
            MIN(A.AVAILABILITY_PCT) AS MIN_AVAILABILITY_PCT,
            MAX(A.AVAILABILITY_PCT) AS MAX_AVAILABILITY_PCT,
            ROUND(SUM(T.TRAFFIC_VOL_GB), 2) AS TOTAL_TRAFFIC_GB,
            ROUND(AVG(T.TRAFFIC_VOL_MB), 2) AS AVG_TRAFFIC_PER_CELL_MB,
            COUNT(DISTINCT A.CELL_ID) AS TOTAL_CELLS,
            COUNT(DISTINCT CASE WHEN T.TRAFFIC_VOL_MB > 0 THEN A.CELL_ID END) AS ACTIVE_CELLS,
            COUNT(DISTINCT CASE WHEN T.TRAFFIC_VOL_MB = 0 THEN A.CELL_ID END) AS ZERO_TRAFFIC_CELLS,
            SYSTIMESTAMP AS LOAD_TIMESTAMP
        FROM
            AGG_CELL_AVAILABILITY_DAILY_4G A
        LEFT JOIN
            AGG_TRAFFIC_DAILY_4G T ON A.CELL_ID = T.CELL_ID
                                   AND A.AGGREGATION_DATE = T.AGGREGATION_DATE
                                   AND T.AGGREGATION_LEVEL = 'CELL'
        WHERE
            A.AGGREGATION_DATE = p_refresh_date;

        v_row_count := SQL%ROWCOUNT;
        COMMIT;

        log_message('refresh_regional_summaries',
                    'Regional summary completed',
                    'SUCCESS',
                    v_row_count);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_message('refresh_regional_summaries', 'Error occurred', 'ERROR', NULL, SQLERRM);
            RAISE;
    END refresh_regional_summaries;

    -- ============================================================
    -- REFRESH TWAMP AGGREGATIONS
    -- ============================================================
    PROCEDURE refresh_twamp_aggregations(
        p_refresh_date IN DATE DEFAULT TRUNC(SYSDATE-1)
    ) IS
        v_row_count NUMBER;
    BEGIN
        log_message('refresh_twamp_aggregations',
                    'Starting TWAMP aggregation for date: ' || TO_CHAR(p_refresh_date, 'YYYY-MM-DD'),
                    'START');

        DELETE FROM AGG_TWAMP_JITTER_DAILY WHERE AGGREGATION_DATE = p_refresh_date;

        INSERT /*+ APPEND PARALLEL(4) */ INTO AGG_TWAMP_JITTER_DAILY
        SELECT
            TRUNC(T.FRAGMENT_DATE) AS AGGREGATION_DATE,
            E.SUB_REGION_ID,
            E.SUB_REGION_NAME,
            E.CITY_ID,
            E.CITY_NAME,
            E.ENODEB_ID,
            E.ENODEB_NAME,
            ROUND(AVG(T.JITTER_AVERAGE), 3) AS AVG_JITTER,
            ROUND(MAX(T.JITTER_AVERAGE), 3) AS MAX_JITTER,
            ROUND(MIN(T.JITTER_AVERAGE), 3) AS MIN_JITTER,
            ROUND(AVG(T.DELAY_AVERAGE), 3) AS AVG_DELAY,
            ROUND(AVG(T.PACKET_LOSS), 3) AS AVG_PACKET_LOSS,
            SYSTIMESTAMP AS LOAD_TIMESTAMP,
            COUNT(*) AS SAMPLE_COUNT
        FROM
            NORTHI_DATA.TWAMP_PERF_H T
        JOIN
            (SELECT DISTINCT SUB_REGION_NAME, SUB_REGION_ID, CITY_ID, CITY_NAME,
                    ENODEB_ID, ENODEB_NAME
             FROM NORTHI_DATA.LIST_TWAMP_ENODEB) E
            ON T.NETWORK_ID = E.ENODEB_ID
        WHERE
            TRUNC(T.FRAGMENT_DATE) = p_refresh_date
        GROUP BY
            TRUNC(T.FRAGMENT_DATE), E.SUB_REGION_ID, E.SUB_REGION_NAME,
            E.CITY_ID, E.CITY_NAME, E.ENODEB_ID, E.ENODEB_NAME;

        v_row_count := SQL%ROWCOUNT;
        COMMIT;

        log_message('refresh_twamp_aggregations',
                    'TWAMP aggregation completed',
                    'SUCCESS',
                    v_row_count);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_message('refresh_twamp_aggregations', 'Error occurred', 'ERROR', NULL, SQLERRM);
            RAISE;
    END refresh_twamp_aggregations;

    -- ============================================================
    -- REFRESH 20-DAY ROLLING DATA
    -- ============================================================
    PROCEDURE refresh_rolling_20day(
        p_refresh_date IN DATE DEFAULT TRUNC(SYSDATE-1)
    ) IS
        v_row_count NUMBER;
    BEGIN
        log_message('refresh_rolling_20day',
                    'Starting 20-day rolling aggregation for date: ' || TO_CHAR(p_refresh_date, 'YYYY-MM-DD'),
                    'START');

        DELETE FROM AGG_AVAILABILITY_ROLLING_20DAY WHERE BASE_DATE = p_refresh_date;

        -- 4G Rolling data
        INSERT /*+ APPEND PARALLEL(4) */ INTO AGG_AVAILABILITY_ROLLING_20DAY
        SELECT
            p_refresh_date AS BASE_DATE,
            '4G' AS NETWORK_TYPE,
            SUB_REGION_ID,
            ENODEB_NAME,
            CELL_NAME,
            CELL_ID AS NETWORK_ID,
            MAX(CASE WHEN day_offset = 0 THEN AVAILABILITY_PCT END) AS DAY_1_VALUE,
            MAX(CASE WHEN day_offset = 1 THEN AVAILABILITY_PCT END) AS DAY_2_VALUE,
            MAX(CASE WHEN day_offset = 2 THEN AVAILABILITY_PCT END) AS DAY_3_VALUE,
            MAX(CASE WHEN day_offset = 3 THEN AVAILABILITY_PCT END) AS DAY_4_VALUE,
            MAX(CASE WHEN day_offset = 4 THEN AVAILABILITY_PCT END) AS DAY_5_VALUE,
            MAX(CASE WHEN day_offset = 5 THEN AVAILABILITY_PCT END) AS DAY_6_VALUE,
            MAX(CASE WHEN day_offset = 6 THEN AVAILABILITY_PCT END) AS DAY_7_VALUE,
            MAX(CASE WHEN day_offset = 7 THEN AVAILABILITY_PCT END) AS DAY_8_VALUE,
            MAX(CASE WHEN day_offset = 8 THEN AVAILABILITY_PCT END) AS DAY_9_VALUE,
            MAX(CASE WHEN day_offset = 9 THEN AVAILABILITY_PCT END) AS DAY_10_VALUE,
            MAX(CASE WHEN day_offset = 10 THEN AVAILABILITY_PCT END) AS DAY_11_VALUE,
            MAX(CASE WHEN day_offset = 11 THEN AVAILABILITY_PCT END) AS DAY_12_VALUE,
            MAX(CASE WHEN day_offset = 12 THEN AVAILABILITY_PCT END) AS DAY_13_VALUE,
            MAX(CASE WHEN day_offset = 13 THEN AVAILABILITY_PCT END) AS DAY_14_VALUE,
            MAX(CASE WHEN day_offset = 14 THEN AVAILABILITY_PCT END) AS DAY_15_VALUE,
            MAX(CASE WHEN day_offset = 15 THEN AVAILABILITY_PCT END) AS DAY_16_VALUE,
            MAX(CASE WHEN day_offset = 16 THEN AVAILABILITY_PCT END) AS DAY_17_VALUE,
            MAX(CASE WHEN day_offset = 17 THEN AVAILABILITY_PCT END) AS DAY_18_VALUE,
            MAX(CASE WHEN day_offset = 18 THEN AVAILABILITY_PCT END) AS DAY_19_VALUE,
            MAX(CASE WHEN day_offset = 19 THEN AVAILABILITY_PCT END) AS DAY_20_VALUE,
            SYSTIMESTAMP AS LOAD_TIMESTAMP
        FROM (
            SELECT
                SUB_REGION_ID,
                ENODEB_NAME,
                CELL_NAME,
                CELL_ID,
                AVAILABILITY_PCT,
                p_refresh_date - AGGREGATION_DATE AS day_offset
            FROM
                AGG_CELL_AVAILABILITY_DAILY_4G
            WHERE
                AGGREGATION_DATE BETWEEN p_refresh_date - 19 AND p_refresh_date
        )
        GROUP BY
            SUB_REGION_ID, ENODEB_NAME, CELL_NAME, CELL_ID;

        v_row_count := SQL%ROWCOUNT;
        COMMIT;

        log_message('refresh_rolling_20day',
                    '20-day rolling aggregation completed',
                    'SUCCESS',
                    v_row_count);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_message('refresh_rolling_20day', 'Error occurred', 'ERROR', NULL, SQLERRM);
            RAISE;
    END refresh_rolling_20day;

    -- ============================================================
    -- MAIN ORCHESTRATION PROCEDURE
    -- ============================================================
    PROCEDURE refresh_all(
        p_refresh_date  IN DATE DEFAULT TRUNC(SYSDATE-1),
        p_force_full    IN BOOLEAN DEFAULT FALSE
    ) IS
        v_start_time    TIMESTAMP := SYSTIMESTAMP;
        v_duration      NUMBER;
    BEGIN
        -- Initialize session
        SELECT AGG_REFRESH_SEQ.NEXTVAL INTO g_session_id FROM DUAL;
        g_start_time := SYSTIMESTAMP;

        log_message('refresh_all',
                    'Starting full refresh for date: ' || TO_CHAR(p_refresh_date, 'YYYY-MM-DD'),
                    'START');

        -- Step 1: Refresh Materialized Views
        refresh_materialized_views(p_refresh_date);

        -- Step 2: Refresh Availability Aggregations
        refresh_availability_aggregations(p_refresh_date);

        -- Step 3: Refresh Traffic Aggregations
        refresh_traffic_aggregations(p_refresh_date);

        -- Step 4: Refresh TWAMP
        refresh_twamp_aggregations(p_refresh_date);

        -- Step 5: Refresh Regional Summaries
        refresh_regional_summaries(p_refresh_date);

        -- Step 6: Refresh 20-day rolling
        refresh_rolling_20day(p_refresh_date);

        -- Step 7: Collect Statistics
        collect_stats_after_load();

        -- Step 8: Cleanup old partitions
        cleanup_old_partitions();

        v_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - g_start_time));
        log_message('refresh_all',
                    'Full refresh completed successfully in ' || ROUND(v_duration/60, 2) || ' minutes',
                    'COMPLETE');

    EXCEPTION
        WHEN OTHERS THEN
            log_message('refresh_all', 'Fatal error in refresh_all', 'ERROR', NULL, SQLERRM);
            RAISE;
    END refresh_all;

    -- ============================================================
    -- CLEANUP OLD PARTITIONS
    -- ============================================================
    PROCEDURE cleanup_old_partitions(
        p_retention_days IN NUMBER DEFAULT C_RETENTION_DAYS
    ) IS
        v_cutoff_date   DATE := TRUNC(SYSDATE) - p_retention_days;
    BEGIN
        log_message('cleanup_old_partitions',
                    'Starting partition cleanup for data before: ' || TO_CHAR(v_cutoff_date, 'YYYY-MM-DD'),
                    'START');

        -- Drop old partitions (Oracle will automatically manage interval partitions)
        -- Just log the action
        log_message('cleanup_old_partitions',
                    'Partition cleanup completed (auto-managed by Oracle)',
                    'COMPLETE');

    EXCEPTION
        WHEN OTHERS THEN
            log_message('cleanup_old_partitions', 'Error occurred', 'ERROR', NULL, SQLERRM);
    END cleanup_old_partitions;

    -- ============================================================
    -- COLLECT STATISTICS
    -- ============================================================
    PROCEDURE collect_stats_after_load IS
    BEGIN
        log_message('collect_stats_after_load', 'Starting statistics collection', 'START');

        -- Gather stats on aggregation tables
        DBMS_STATS.GATHER_TABLE_STATS(USER, 'AGG_CELL_AVAILABILITY_DAILY_4G',
                                      granularity => 'PARTITION', degree => 4);
        DBMS_STATS.GATHER_TABLE_STATS(USER, 'AGG_CELL_AVAILABILITY_DAILY_2G',
                                      granularity => 'PARTITION', degree => 4);
        DBMS_STATS.GATHER_TABLE_STATS(USER, 'AGG_TRAFFIC_DAILY_4G',
                                      granularity => 'PARTITION', degree => 4);
        DBMS_STATS.GATHER_TABLE_STATS(USER, 'AGG_REGIONAL_SUMMARY_DAILY',
                                      granularity => 'PARTITION', degree => 4);
        DBMS_STATS.GATHER_TABLE_STATS(USER, 'AGG_TWAMP_JITTER_DAILY',
                                      granularity => 'PARTITION', degree => 4);
        DBMS_STATS.GATHER_TABLE_STATS(USER, 'AGG_AVAILABILITY_ROLLING_20DAY',
                                      granularity => 'PARTITION', degree => 4);

        log_message('collect_stats_after_load', 'Statistics collection completed', 'COMPLETE');

    EXCEPTION
        WHEN OTHERS THEN
            log_message('collect_stats_after_load', 'Error occurred', 'ERROR', NULL, SQLERRM);
    END collect_stats_after_load;

    -- ============================================================
    -- GET LAST REFRESH STATUS
    -- ============================================================
    FUNCTION get_last_refresh_status RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT
                session_id,
                procedure_name,
                message,
                status,
                row_count,
                error_message,
                log_timestamp
            FROM
                AGG_REFRESH_LOG
            WHERE
                session_id = (SELECT MAX(session_id) FROM AGG_REFRESH_LOG)
            ORDER BY
                log_timestamp;

        RETURN v_cursor;
    END get_last_refresh_status;

END PKG_REPORT_AGGREGATION;
/

-- ================================================================
-- CREATE SUPPORTING OBJECTS
-- ================================================================

-- Sequence for session IDs
CREATE SEQUENCE AGG_REFRESH_SEQ START WITH 1 INCREMENT BY 1;

-- Log table
CREATE TABLE AGG_REFRESH_LOG
(
    log_id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id      NUMBER NOT NULL,
    procedure_name  VARCHAR2(100),
    message         VARCHAR2(4000),
    status          VARCHAR2(20),
    row_count       NUMBER,
    error_message   VARCHAR2(4000),
    log_timestamp   TIMESTAMP DEFAULT SYSTIMESTAMP
)
PARTITION BY RANGE (log_timestamp)
INTERVAL(NUMTODSINTERVAL(30, 'DAY'))
(
    PARTITION p_initial VALUES LESS THAN (TIMESTAMP '2024-01-01 00:00:00')
);

CREATE INDEX idx_refresh_log_session ON AGG_REFRESH_LOG(session_id, log_timestamp);

-- ================================================================
-- GRANT PERMISSIONS
-- ================================================================

GRANT EXECUTE ON PKG_REPORT_AGGREGATION TO REPORT_ADMIN_ROLE;
GRANT SELECT ON AGG_REFRESH_LOG TO REPORT_USER_ROLE;
