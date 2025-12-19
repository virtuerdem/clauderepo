-- ================================================================
-- DBMS_SCHEDULER SETUP FOR AUTOMATED REFRESH
-- ================================================================
-- Purpose: Automate incremental refresh of MVs and aggregation tables
-- Schedule: Daily at configured time (default: 04:00 AM)
-- Dependencies: PKG_REPORT_AGGREGATION must be compiled
-- ================================================================

-- ================================================================
-- 1. CREATE SCHEDULER JOB FOR DAILY REFRESH
-- ================================================================

BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'JOB_DAILY_AGGREGATION_REFRESH',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PKG_REPORT_AGGREGATION.refresh_all(TRUNC(SYSDATE-1)); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=DAILY; BYHOUR=4; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Daily refresh of all aggregation tables and materialized views'
    );
END;
/

-- ================================================================
-- 2. CREATE PROGRAM FOR FLEXIBLE EXECUTION
-- ================================================================
-- Allows parametrized execution

BEGIN
    DBMS_SCHEDULER.CREATE_PROGRAM (
        program_name    => 'PROG_AGGREGATION_REFRESH',
        program_type    => 'STORED_PROCEDURE',
        program_action  => 'PKG_REPORT_AGGREGATION.refresh_all',
        number_of_arguments => 2,
        enabled         => FALSE,
        comments        => 'Program for aggregation refresh with parameters'
    );

    -- Define arguments
    DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT (
        program_name        => 'PROG_AGGREGATION_REFRESH',
        argument_position   => 1,
        argument_name       => 'p_refresh_date',
        argument_type       => 'DATE',
        default_value       => 'TRUNC(SYSDATE-1)'
    );

    DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT (
        program_name        => 'PROG_AGGREGATION_REFRESH',
        argument_position   => 2,
        argument_name       => 'p_force_full',
        argument_type       => 'BOOLEAN',
        default_value       => 'FALSE'
    );

    DBMS_SCHEDULER.ENABLE('PROG_AGGREGATION_REFRESH');
END;
/

-- ================================================================
-- 3. CREATE SCHEDULER JOB USING PROGRAM
-- ================================================================

BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'JOB_DAILY_AGGREGATION_PROGRAM',
        program_name    => 'PROG_AGGREGATION_REFRESH',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=DAILY; BYHOUR=4; BYMINUTE=0; BYSECOND=0',
        enabled         => FALSE,
        comments        => 'Daily aggregation refresh using program'
    );
END;
/

-- ================================================================
-- 4. CREATE JOB FOR HOURLY MV REFRESH (OPTIONAL)
-- ================================================================
-- For reports that need more frequent updates

BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'JOB_HOURLY_MV_REFRESH',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PKG_REPORT_AGGREGATION.refresh_materialized_views(); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=HOURLY; INTERVAL=1',
        enabled         => FALSE,  -- Enable if needed
        comments        => 'Hourly refresh of materialized views only'
    );
END;
/

-- ================================================================
-- 5. CREATE JOB CHAIN FOR SEQUENTIAL EXECUTION
-- ================================================================
-- Use if you need to control execution order and dependencies

BEGIN
    -- Create chain
    DBMS_SCHEDULER.CREATE_CHAIN (
        chain_name  => 'CHAIN_AGGREGATION_REFRESH',
        rule_set_name => NULL,
        evaluation_interval => NULL,
        comments => 'Chain for sequential aggregation refresh'
    );

    -- Add steps to chain
    DBMS_SCHEDULER.DEFINE_CHAIN_STEP (
        chain_name => 'CHAIN_AGGREGATION_REFRESH',
        step_name => 'STEP_REFRESH_MVS',
        program_name => NULL
    );

    DBMS_SCHEDULER.DEFINE_CHAIN_STEP (
        chain_name => 'CHAIN_AGGREGATION_REFRESH',
        step_name => 'STEP_REFRESH_AVAILABILITY',
        program_name => NULL
    );

    DBMS_SCHEDULER.DEFINE_CHAIN_STEP (
        chain_name => 'CHAIN_AGGREGATION_REFRESH',
        step_name => 'STEP_REFRESH_TRAFFIC',
        program_name => NULL
    );

    DBMS_SCHEDULER.DEFINE_CHAIN_STEP (
        chain_name => 'CHAIN_AGGREGATION_REFRESH',
        step_name => 'STEP_REFRESH_REGIONAL',
        program_name => NULL
    );

    -- Define rules
    DBMS_SCHEDULER.DEFINE_CHAIN_RULE (
        chain_name => 'CHAIN_AGGREGATION_REFRESH',
        condition => 'TRUE',
        action => 'START STEP_REFRESH_MVS',
        rule_name => 'RULE_START'
    );

    DBMS_SCHEDULER.DEFINE_CHAIN_RULE (
        chain_name => 'CHAIN_AGGREGATION_REFRESH',
        condition => 'STEP_REFRESH_MVS COMPLETED',
        action => 'START STEP_REFRESH_AVAILABILITY',
        rule_name => 'RULE_MVS_TO_AVAIL'
    );

    DBMS_SCHEDULER.DEFINE_CHAIN_RULE (
        chain_name => 'CHAIN_AGGREGATION_REFRESH',
        condition => 'STEP_REFRESH_AVAILABILITY COMPLETED',
        action => 'START STEP_REFRESH_TRAFFIC',
        rule_name => 'RULE_AVAIL_TO_TRAFFIC'
    );

    DBMS_SCHEDULER.DEFINE_CHAIN_RULE (
        chain_name => 'CHAIN_AGGREGATION_REFRESH',
        condition => 'STEP_REFRESH_TRAFFIC COMPLETED',
        action => 'START STEP_REFRESH_REGIONAL',
        rule_name => 'RULE_TRAFFIC_TO_REGIONAL'
    );

    DBMS_SCHEDULER.DEFINE_CHAIN_RULE (
        chain_name => 'CHAIN_AGGREGATION_REFRESH',
        condition => 'STEP_REFRESH_REGIONAL COMPLETED',
        action => 'END',
        rule_name => 'RULE_END'
    );

    -- Enable chain
    DBMS_SCHEDULER.ENABLE('CHAIN_AGGREGATION_REFRESH');
END;
/

-- ================================================================
-- 6. EMAIL NOTIFICATIONS ON FAILURE (OPTIONAL)
-- ================================================================
-- Configure email notifications for job failures

BEGIN
    -- Create notification
    DBMS_SCHEDULER.ADD_JOB_EMAIL_NOTIFICATION (
        job_name => 'JOB_DAILY_AGGREGATION_REFRESH',
        recipients => 'dba@company.com,reports@company.com',
        subject => 'Aggregation Refresh Job Failed - %job_name%',
        body => 'Job %job_name% failed at %event_timestamp% with error: %error_message%',
        events => 'JOB_FAILED,JOB_BROKEN',
        filter_condition => NULL
    );
END;
/

-- ================================================================
-- 7. MONITORING QUERIES
-- ================================================================

-- Check job status
SELECT job_name, enabled, state, last_start_date, next_run_date, failure_count
FROM USER_SCHEDULER_JOBS
WHERE job_name LIKE '%AGGREGATION%'
ORDER BY job_name;

-- Check job run details
SELECT log_id, log_date, job_name, status, error#, additional_info
FROM USER_SCHEDULER_JOB_LOG
WHERE job_name LIKE '%AGGREGATION%'
ORDER BY log_date DESC
FETCH FIRST 20 ROWS ONLY;

-- Check running jobs
SELECT job_name, session_id, running_instance, elapsed_time
FROM USER_SCHEDULER_RUNNING_JOBS
WHERE job_name LIKE '%AGGREGATION%';

-- Check aggregation refresh log
SELECT
    session_id,
    procedure_name,
    status,
    row_count,
    log_timestamp,
    error_message
FROM AGG_REFRESH_LOG
WHERE session_id = (SELECT MAX(session_id) FROM AGG_REFRESH_LOG)
ORDER BY log_timestamp;

-- ================================================================
-- 8. MANUAL EXECUTION EXAMPLES
-- ================================================================

-- Run full refresh for yesterday
BEGIN
    PKG_REPORT_AGGREGATION.refresh_all(TRUNC(SYSDATE-1));
END;
/

-- Run full refresh for specific date
BEGIN
    PKG_REPORT_AGGREGATION.refresh_all(TO_DATE('2024-01-15', 'YYYY-MM-DD'));
END;
/

-- Refresh only MVs
BEGIN
    PKG_REPORT_AGGREGATION.refresh_materialized_views(TRUNC(SYSDATE-1));
END;
/

-- Refresh only availability aggregations
BEGIN
    PKG_REPORT_AGGREGATION.refresh_availability_aggregations(TRUNC(SYSDATE-1));
END;
/

-- Get last refresh status
DECLARE
    v_cursor SYS_REFCURSOR;
    v_session_id NUMBER;
    v_procedure_name VARCHAR2(100);
    v_message VARCHAR2(4000);
    v_status VARCHAR2(20);
    v_row_count NUMBER;
    v_timestamp TIMESTAMP;
BEGIN
    v_cursor := PKG_REPORT_AGGREGATION.get_last_refresh_status();

    DBMS_OUTPUT.PUT_LINE('Last Refresh Status:');
    DBMS_OUTPUT.PUT_LINE('==========================================');

    LOOP
        FETCH v_cursor INTO v_session_id, v_procedure_name, v_message,
                           v_status, v_row_count, NULL, v_timestamp;
        EXIT WHEN v_cursor%NOTFOUND;

        DBMS_OUTPUT.PUT_LINE(
            TO_CHAR(v_timestamp, 'YYYY-MM-DD HH24:MI:SS') || ' | ' ||
            v_procedure_name || ' | ' ||
            v_status || ' | ' ||
            NVL(TO_CHAR(v_row_count), 'N/A') || ' rows'
        );
    END LOOP;

    CLOSE v_cursor;
END;
/

-- ================================================================
-- 9. DISABLE/ENABLE JOBS
-- ================================================================

-- Disable job for maintenance
BEGIN
    DBMS_SCHEDULER.DISABLE('JOB_DAILY_AGGREGATION_REFRESH');
END;
/

-- Enable job after maintenance
BEGIN
    DBMS_SCHEDULER.ENABLE('JOB_DAILY_AGGREGATION_REFRESH');
END;
/

-- Drop job if needed
BEGIN
    DBMS_SCHEDULER.DROP_JOB('JOB_DAILY_AGGREGATION_REFRESH', force => TRUE);
END;
/

-- ================================================================
-- 10. RESOURCE MANAGEMENT (OPTIONAL)
-- ================================================================
-- Assign job to specific resource consumer group

BEGIN
    DBMS_SCHEDULER.SET_ATTRIBUTE (
        name => 'JOB_DAILY_AGGREGATION_REFRESH',
        attribute => 'job_class',
        value => 'DEFAULT_JOB_CLASS'  -- or create custom class
    );
END;
/

-- Create custom job class for aggregation jobs
BEGIN
    DBMS_SCHEDULER.CREATE_JOB_CLASS (
        job_class_name => 'AGGREGATION_JOB_CLASS',
        resource_consumer_group => 'BATCH_GROUP',  -- Create this group in Resource Manager
        logging_level => DBMS_SCHEDULER.LOGGING_FULL,
        log_history => 30,
        comments => 'Job class for aggregation refresh jobs'
    );
END;
/

-- ================================================================
-- DEPLOYMENT CHECKLIST
-- ================================================================
/*
1. [ ] Compile PKG_REPORT_AGGREGATION package
2. [ ] Create materialized views (01_materialized_views.sql)
3. [ ] Create aggregation tables (02_aggregation_tables.sql)
4. [ ] Test manual execution of refresh procedures
5. [ ] Review and adjust scheduler timing
6. [ ] Enable scheduler job: JOB_DAILY_AGGREGATION_REFRESH
7. [ ] Configure email notifications (if needed)
8. [ ] Set up monitoring dashboard/alerts
9. [ ] Document SLA and monitoring procedures
10. [ ] Plan for initial backfill of historical data

INITIAL BACKFILL:
-- Run for past 30 days to populate aggregation tables
DECLARE
    v_date DATE;
BEGIN
    FOR i IN 1..30 LOOP
        v_date := TRUNC(SYSDATE) - i;
        DBMS_OUTPUT.PUT_LINE('Refreshing data for: ' || TO_CHAR(v_date, 'YYYY-MM-DD'));
        PKG_REPORT_AGGREGATION.refresh_all(v_date);
        COMMIT;
    END LOOP;
END;
/
*/
