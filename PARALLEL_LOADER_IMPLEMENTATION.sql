-- ============================================================================
-- PARALLEL LOADER IMPLEMENTATION
-- CELLSTS_4G için güvenli paralel DTYPE işleme
-- ============================================================================

-- ============================================================================
-- 1. HELPER TYPES ve CONSTANTS
-- ============================================================================

CREATE OR REPLACE PACKAGE LOADER_PARALLEL_PKG AS

    -- Job bilgisi için type
    TYPE t_job_info IS RECORD (
        job_name        VARCHAR2(100),
        dtype           NUMBER,
        partition_value VARCHAR2(50),
        start_time      TIMESTAMP,
        status          VARCHAR2(20)  -- CREATED, RUNNING, COMPLETED, FAILED
    );

    TYPE t_job_list IS TABLE OF t_job_info INDEX BY PLS_INTEGER;

    -- Constants
    c_max_wait_seconds  CONSTANT NUMBER := 3600;  -- 1 saat max bekleme
    c_poll_interval     CONSTANT NUMBER := 5;     -- 5 saniye poll interval
    c_job_prefix        CONSTANT VARCHAR2(20) := 'LDR_DTYPE_';

    -- Main procedures
    PROCEDURE BEGIN_LOADER_TRANSFER_SAFE(
        P_SYSTEM_ID     IN NUMBER,
        P_TABLE_NAME    IN VARCHAR2 DEFAULT 'CELLSTS_4G',
        P_DATA_DATE     IN DATE DEFAULT SYSDATE
    );

    PROCEDURE START_PARALLEL_JOBS(
        P_TABLE_NAME    IN VARCHAR2,
        P_DATA_DATE     IN DATE,
        P_DTYPE_LIST    IN VARCHAR2,  -- Comma-separated: '2,3,4'
        P_WAIT          IN BOOLEAN DEFAULT TRUE
    );

    PROCEDURE WAIT_JOBS(
        P_TIMEOUT_SECONDS IN NUMBER DEFAULT 3600
    );

    -- Cleanup utilities
    PROCEDURE CLEANUP_OLD_JOBS(P_DAYS_OLD IN NUMBER DEFAULT 1);
    PROCEDURE STOP_ALL_JOBS;

END LOADER_PARALLEL_PKG;
/

-- ============================================================================
-- 2. PACKAGE BODY
-- ============================================================================

CREATE OR REPLACE PACKAGE BODY LOADER_PARALLEL_PKG AS

    -- Global job tracking
    g_jobs              t_job_list;
    g_job_count         NUMBER := 0;

    -- Logging helper
    PROCEDURE log_message(
        p_message       IN VARCHAR2,
        p_level         IN VARCHAR2 DEFAULT 'INFO'
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO NORTHI_DATA.TEST_ERROR (
            ADD_DATE,
            PROCEDURE_NAME,
            SQLTEXT,
            STATE
        ) VALUES (
            SYSDATE,
            'LOADER_PARALLEL',
            SUBSTR(p_message, 1, 4000),
            p_level
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            NULL;  -- Log hatası ana işlemi durdurmasın
    END log_message;

    -- ========================================================================
    -- START_PARALLEL_JOBS - Paralel job'ları başlatır
    -- ========================================================================
    PROCEDURE START_PARALLEL_JOBS(
        P_TABLE_NAME    IN VARCHAR2,
        P_DATA_DATE     IN DATE,
        P_DTYPE_LIST    IN VARCHAR2,
        P_WAIT          IN BOOLEAN DEFAULT TRUE
    ) IS
        l_dtype_array       DBMS_SQL.VARCHAR2_TABLE;
        l_dtype             NUMBER;
        l_partition_value   VARCHAR2(50);
        l_job_name          VARCHAR2(100);
        l_job_action        CLOB;
        l_dtype_count       NUMBER := 0;

    BEGIN
        log_message('START_PARALLEL_JOBS: Starting for ' || P_TABLE_NAME ||
                    ', DTYPE list: ' || P_DTYPE_LIST ||
                    ', Date: ' || TO_CHAR(P_DATA_DATE, 'YYYY-MM-DD HH24:MI'),
                    'INFO');

        -- Comma-separated string'i parse et
        FOR i IN (
            SELECT TRIM(REGEXP_SUBSTR(P_DTYPE_LIST, '[^,]+', 1, LEVEL)) AS dtype_str
            FROM DUAL
            CONNECT BY LEVEL <= LENGTH(P_DTYPE_LIST) - LENGTH(REPLACE(P_DTYPE_LIST, ',', '')) + 1
        ) LOOP
            l_dtype := TO_NUMBER(i.dtype_str);
            l_dtype_count := l_dtype_count + 1;

            -- PARTITION_VALUE'yu al
            BEGIN
                SELECT PARTITION_VALUE INTO l_partition_value
                FROM NORTHI_PARTITION_TYPE
                WHERE DTYPE = l_dtype
                  AND PARTITION_ID = (
                      SELECT PARTITION_ID
                      FROM NORTHI_LOADER_SETTINGS
                      WHERE TABLE_NAME = P_TABLE_NAME
                      AND ROWNUM = 1
                  )
                  AND ROWNUM = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    log_message('DTYPE ' || l_dtype || ' için partition value bulunamadı!', 'ERROR');
                    RAISE_APPLICATION_ERROR(-20001, 'Invalid DTYPE: ' || l_dtype);
            END;

            -- Unique job name oluştur
            l_job_name := c_job_prefix || l_dtype || '_' ||
                          TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF');

            -- Job action (procedure çağrısı)
            l_job_action :=
                'DECLARE ' || CHR(10) ||
                '    l_start_time TIMESTAMP := SYSTIMESTAMP; ' || CHR(10) ||
                '    l_error_msg VARCHAR2(4000); ' || CHR(10) ||
                'BEGIN ' || CHR(10) ||
                '    -- Log başlangıç ' || CHR(10) ||
                '    INSERT INTO NORTHI_DATA.TEST_ERROR (ADD_DATE, PROCEDURE_NAME, SQLTEXT, STATE) ' || CHR(10) ||
                '    VALUES (SYSDATE, ''' || l_job_name || ''', ''DTYPE=' || l_dtype || ' STARTED'', ''RUNNING''); ' || CHR(10) ||
                '    COMMIT; ' || CHR(10) ||
                '    ' || CHR(10) ||
                '    -- Ana procedure çağrısı ' || CHR(10) ||
                '    P_' || P_TABLE_NAME || '_' || l_partition_value ||
                '(TO_DATE(''' || TO_CHAR(P_DATA_DATE, 'DD.MM.YYYY HH24:MI') || ''', ''DD.MM.YYYY HH24:MI'')); ' || CHR(10) ||
                '    ' || CHR(10) ||
                '    -- Log başarı ' || CHR(10) ||
                '    INSERT INTO NORTHI_DATA.TEST_ERROR (ADD_DATE, PROCEDURE_NAME, SQLTEXT, STATE) ' || CHR(10) ||
                '    VALUES (SYSDATE, ''' || l_job_name || ''', ' || CHR(10) ||
                '            ''DTYPE=' || l_dtype || ' COMPLETED in '' || ' || CHR(10) ||
                '            ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)), 2) || ''s'', ''COMPLETED''); ' || CHR(10) ||
                '    COMMIT; ' || CHR(10) ||
                'EXCEPTION ' || CHR(10) ||
                '    WHEN OTHERS THEN ' || CHR(10) ||
                '        l_error_msg := SUBSTR(SQLERRM, 1, 4000); ' || CHR(10) ||
                '        INSERT INTO NORTHI_DATA.TEST_ERROR (ADD_DATE, PROCEDURE_NAME, SQLTEXT, STATE) ' || CHR(10) ||
                '        VALUES (SYSDATE, ''' || l_job_name || ''', ' || CHR(10) ||
                '                ''DTYPE=' || l_dtype || ' FAILED: '' || l_error_msg, ''FAILED''); ' || CHR(10) ||
                '        COMMIT; ' || CHR(10) ||
                '        RAISE; ' || CHR(10) ||
                'END;';

            -- DBMS_SCHEDULER ile job oluştur
            BEGIN
                DBMS_SCHEDULER.CREATE_JOB(
                    job_name        => l_job_name,
                    job_type        => 'PLSQL_BLOCK',
                    job_action      => l_job_action,
                    start_date      => SYSTIMESTAMP,
                    enabled         => FALSE,  -- Manuel başlatacağız
                    auto_drop       => TRUE,   -- Bitince otomatik sil
                    comments        => 'Parallel DTYPE=' || l_dtype || ' loader for ' || P_TABLE_NAME
                );

                -- Job bilgisini kaydet
                g_job_count := g_job_count + 1;
                g_jobs(g_job_count).job_name := l_job_name;
                g_jobs(g_job_count).dtype := l_dtype;
                g_jobs(g_job_count).partition_value := l_partition_value;
                g_jobs(g_job_count).start_time := SYSTIMESTAMP;
                g_jobs(g_job_count).status := 'CREATED';

                log_message('Job created: ' || l_job_name || ' (DTYPE=' || l_dtype || ')', 'INFO');

            EXCEPTION
                WHEN OTHERS THEN
                    log_message('Job creation failed for DTYPE ' || l_dtype || ': ' || SQLERRM, 'ERROR');
                    RAISE;
            END;

        END LOOP;

        -- Tüm job'ları başlat
        FOR i IN 1..g_job_count LOOP
            IF g_jobs(i).status = 'CREATED' THEN
                DBMS_SCHEDULER.ENABLE(g_jobs(i).job_name);
                g_jobs(i).status := 'RUNNING';
                log_message('Job started: ' || g_jobs(i).job_name, 'INFO');
            END IF;
        END LOOP;

        log_message('Started ' || l_dtype_count || ' parallel jobs', 'INFO');

        -- Bekle (eğer isteniyorsa)
        IF P_WAIT THEN
            WAIT_JOBS(c_max_wait_seconds);
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            log_message('START_PARALLEL_JOBS failed: ' || SQLERRM, 'ERROR');
            RAISE;
    END START_PARALLEL_JOBS;

    -- ========================================================================
    -- WAIT_JOBS - Job'ların bitmesini bekler
    -- ========================================================================
    PROCEDURE WAIT_JOBS(
        P_TIMEOUT_SECONDS IN NUMBER DEFAULT 3600
    ) IS
        l_running_count     NUMBER;
        l_elapsed_seconds   NUMBER := 0;
        l_job_state         VARCHAR2(50);
        l_failed_jobs       NUMBER := 0;
        l_completed_jobs    NUMBER := 0;

    BEGIN
        log_message('WAIT_JOBS: Waiting for ' || g_job_count || ' jobs to complete...', 'INFO');

        WHILE l_elapsed_seconds < P_TIMEOUT_SECONDS LOOP
            l_running_count := 0;
            l_failed_jobs := 0;
            l_completed_jobs := 0;

            -- Her job'ın durumunu kontrol et
            FOR i IN 1..g_job_count LOOP
                IF g_jobs(i).status IN ('CREATED', 'RUNNING') THEN
                    BEGIN
                        SELECT state INTO l_job_state
                        FROM USER_SCHEDULER_JOBS
                        WHERE job_name = g_jobs(i).job_name;

                        IF l_job_state = 'RUNNING' THEN
                            l_running_count := l_running_count + 1;
                            g_jobs(i).status := 'RUNNING';
                        ELSIF l_job_state = 'FAILED' THEN
                            g_jobs(i).status := 'FAILED';
                            l_failed_jobs := l_failed_jobs + 1;
                            log_message('Job FAILED: ' || g_jobs(i).job_name ||
                                        ' (DTYPE=' || g_jobs(i).dtype || ')', 'ERROR');
                        END IF;

                    EXCEPTION
                        WHEN NO_DATA_FOUND THEN
                            -- Job artık yok (tamamlanmış ve drop olmuş)
                            g_jobs(i).status := 'COMPLETED';
                            l_completed_jobs := l_completed_jobs + 1;
                    END;
                ELSIF g_jobs(i).status = 'COMPLETED' THEN
                    l_completed_jobs := l_completed_jobs + 1;
                ELSIF g_jobs(i).status = 'FAILED' THEN
                    l_failed_jobs := l_failed_jobs + 1;
                END IF;
            END LOOP;

            -- Tüm job'lar bitti mi?
            IF l_running_count = 0 THEN
                log_message('All jobs completed. Success: ' || l_completed_jobs ||
                            ', Failed: ' || l_failed_jobs, 'INFO');
                EXIT;
            END IF;

            -- Status log
            IF MOD(l_elapsed_seconds, 30) = 0 THEN  -- Her 30 saniyede bir log
                log_message('Still waiting... Running: ' || l_running_count ||
                            ', Completed: ' || l_completed_jobs ||
                            ', Failed: ' || l_failed_jobs, 'INFO');
            END IF;

            -- Bekle
            DBMS_LOCK.SLEEP(c_poll_interval);
            l_elapsed_seconds := l_elapsed_seconds + c_poll_interval;

        END LOOP;

        -- Timeout kontrolü
        IF l_running_count > 0 THEN
            log_message('TIMEOUT! ' || l_running_count || ' jobs still running after ' ||
                        P_TIMEOUT_SECONDS || ' seconds', 'ERROR');
            RAISE_APPLICATION_ERROR(-20002, 'Job timeout: ' || l_running_count || ' jobs still running');
        END IF;

        -- Hata varsa raise et
        IF l_failed_jobs > 0 THEN
            RAISE_APPLICATION_ERROR(-20003, l_failed_jobs || ' jobs failed!');
        END IF;

        -- Job listesini temizle
        g_jobs.DELETE;
        g_job_count := 0;

    EXCEPTION
        WHEN OTHERS THEN
            log_message('WAIT_JOBS failed: ' || SQLERRM, 'ERROR');
            RAISE;
    END WAIT_JOBS;

    -- ========================================================================
    -- BEGIN_LOADER_TRANSFER_SAFE - Ana paralel loader prosedürü
    -- ========================================================================
    PROCEDURE BEGIN_LOADER_TRANSFER_SAFE(
        P_SYSTEM_ID     IN NUMBER,
        P_TABLE_NAME    IN VARCHAR2 DEFAULT 'CELLSTS_4G',
        P_DATA_DATE     IN DATE DEFAULT SYSDATE
    ) IS
        l_start_time        TIMESTAMP := SYSTIMESTAMP;
        l_dtype1_duration   NUMBER;
        l_total_duration    NUMBER;

    BEGIN
        log_message('========================================', 'INFO');
        log_message('BEGIN_LOADER_TRANSFER_SAFE STARTED', 'INFO');
        log_message('Table: ' || P_TABLE_NAME || ', System_ID: ' || P_SYSTEM_ID ||
                    ', Date: ' || TO_CHAR(P_DATA_DATE, 'YYYY-MM-DD HH24:MI'), 'INFO');
        log_message('========================================', 'INFO');

        -- ====================================================================
        -- STEP 1: DTYPE=1 (Raw Cell Data) - SIRAYLA
        -- ====================================================================
        log_message('STEP 1: Starting DTYPE=1 (Raw Cell Data)...', 'INFO');

        BEGIN
            EXECUTE IMMEDIATE
                'BEGIN P_' || P_TABLE_NAME || '_CELL(TO_DATE(''' ||
                TO_CHAR(P_DATA_DATE, 'DD.MM.YYYY HH24:MI') ||
                ''', ''DD.MM.YYYY HH24:MI'')); END;';

            l_dtype1_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time));
            log_message('DTYPE=1 completed in ' || ROUND(l_dtype1_duration, 2) || ' seconds', 'INFO');

        EXCEPTION
            WHEN OTHERS THEN
                log_message('DTYPE=1 FAILED: ' || SQLERRM, 'ERROR');
                RAISE;
        END;

        -- ====================================================================
        -- STEP 2: GRUP 1 - DTYPE 2,3,4 (PARALEL)
        -- Bağımlılık: DTYPE=1
        -- ====================================================================
        log_message('STEP 2: Starting GROUP 1 (DTYPE 2,3,4) - PARALLEL...', 'INFO');

        BEGIN
            START_PARALLEL_JOBS(
                P_TABLE_NAME => P_TABLE_NAME,
                P_DATA_DATE  => P_DATA_DATE,
                P_DTYPE_LIST => '2,3,4',
                P_WAIT       => TRUE
            );
            log_message('GROUP 1 completed', 'INFO');
        EXCEPTION
            WHEN OTHERS THEN
                log_message('GROUP 1 FAILED: ' || SQLERRM, 'ERROR');
                RAISE;
        END;

        -- ====================================================================
        -- STEP 3: GRUP 2 - DTYPE 7,8,9 (PARALEL)
        -- Bağımlılık: DTYPE=1
        -- ====================================================================
        log_message('STEP 3: Starting GROUP 2 (DTYPE 7,8,9) - PARALLEL...', 'INFO');

        BEGIN
            START_PARALLEL_JOBS(
                P_TABLE_NAME => P_TABLE_NAME,
                P_DATA_DATE  => P_DATA_DATE,
                P_DTYPE_LIST => '7,8,9',
                P_WAIT       => TRUE
            );
            log_message('GROUP 2 completed', 'INFO');
        EXCEPTION
            WHEN OTHERS THEN
                log_message('GROUP 2 FAILED: ' || SQLERRM, 'ERROR');
                RAISE;
        END;

        -- ====================================================================
        -- STEP 4: GRUP 3 - DTYPE 10,11,12,13,14 (PARALEL)
        -- Bağımlılık: DTYPE=1
        -- ====================================================================
        log_message('STEP 4: Starting GROUP 3 (DTYPE 10,11,12,13,14) - PARALLEL...', 'INFO');

        BEGIN
            START_PARALLEL_JOBS(
                P_TABLE_NAME => P_TABLE_NAME,
                P_DATA_DATE  => P_DATA_DATE,
                P_DTYPE_LIST => '10,11,12,13,14',
                P_WAIT       => TRUE
            );
            log_message('GROUP 3 completed', 'INFO');
        EXCEPTION
            WHEN OTHERS THEN
                log_message('GROUP 3 FAILED: ' || SQLERRM, 'ERROR');
                RAISE;
        END;

        -- ====================================================================
        -- STEP 5: GRUP 4 - DTYPE 5,6 (PARALEL)
        -- Bağımlılık: DTYPE=2
        -- ====================================================================
        log_message('STEP 5: Starting GROUP 4 (DTYPE 5,6) - PARALLEL...', 'INFO');

        BEGIN
            START_PARALLEL_JOBS(
                P_TABLE_NAME => P_TABLE_NAME,
                P_DATA_DATE  => P_DATA_DATE,
                P_DTYPE_LIST => '5,6',
                P_WAIT       => TRUE
            );
            log_message('GROUP 4 completed', 'INFO');
        EXCEPTION
            WHEN OTHERS THEN
                log_message('GROUP 4 FAILED: ' || SQLERRM, 'ERROR');
                RAISE;
        END;

        -- ====================================================================
        -- STEP 6: TMP Kopyalama (Eğer T0-1 saati ise)
        -- ====================================================================
        IF P_DATA_DATE = TRUNC(SYSDATE,'HH24')-1/24 THEN
            log_message('STEP 6: Starting DATA_LOAD_TO_TMP (T0-1 detected)...', 'INFO');

            BEGIN
                NORTHI_LOADER.DATA_LOAD_TO_TMP(P_TABLE_NAME);
                log_message('TMP copy completed', 'INFO');
            EXCEPTION
                WHEN OTHERS THEN
                    log_message('TMP copy FAILED: ' || SQLERRM, 'ERROR');
                    -- TMP hatası kritik değil, devam et
            END;
        END IF;

        -- ====================================================================
        -- FINAL: Özet ve NORTHI_LOADER_PROCESS güncelleme
        -- ====================================================================
        l_total_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time));

        log_message('========================================', 'INFO');
        log_message('BEGIN_LOADER_TRANSFER_SAFE COMPLETED', 'INFO');
        log_message('Total duration: ' || ROUND(l_total_duration, 2) || ' seconds', 'INFO');
        log_message('========================================', 'INFO');

        -- LOADER_STATE'leri güncelle (tamamlandı olarak işaretle)
        UPDATE NORTHI_LOADER_PROCESS
        SET LOADER_STATE = 2,
            LOAD_DATE = SYSDATE
        WHERE SYSTEM_ID = P_SYSTEM_ID
          AND ORG_TABLE = P_TABLE_NAME
          AND DATA_DATE = P_DATA_DATE
          AND LOADER_STATE IN (0, 1);

        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            log_message('BEGIN_LOADER_TRANSFER_SAFE FAILED: ' || SQLERRM, 'ERROR');

            -- Hata durumunda LOADER_STATE=3 (error)
            UPDATE NORTHI_LOADER_PROCESS
            SET LOADER_STATE = 3
            WHERE SYSTEM_ID = P_SYSTEM_ID
              AND ORG_TABLE = P_TABLE_NAME
              AND DATA_DATE = P_DATA_DATE;

            COMMIT;
            RAISE;
    END BEGIN_LOADER_TRANSFER_SAFE;

    -- ========================================================================
    -- CLEANUP_OLD_JOBS - Eski job'ları temizle
    -- ========================================================================
    PROCEDURE CLEANUP_OLD_JOBS(P_DAYS_OLD IN NUMBER DEFAULT 1) IS
        l_dropped_count NUMBER := 0;
    BEGIN
        FOR old_job IN (
            SELECT job_name
            FROM USER_SCHEDULER_JOBS
            WHERE job_name LIKE c_job_prefix || '%'
              AND START_DATE < SYSDATE - P_DAYS_OLD
        ) LOOP
            BEGIN
                DBMS_SCHEDULER.DROP_JOB(old_job.job_name, TRUE);
                l_dropped_count := l_dropped_count + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;  -- Ignore errors
            END;
        END LOOP;

        log_message('Cleaned up ' || l_dropped_count || ' old jobs', 'INFO');
    END CLEANUP_OLD_JOBS;

    -- ========================================================================
    -- STOP_ALL_JOBS - Tüm çalışan job'ları durdur (emergency)
    -- ========================================================================
    PROCEDURE STOP_ALL_JOBS IS
        l_stopped_count NUMBER := 0;
    BEGIN
        FOR running_job IN (
            SELECT job_name
            FROM USER_SCHEDULER_RUNNING_JOBS
            WHERE job_name LIKE c_job_prefix || '%'
        ) LOOP
            BEGIN
                DBMS_SCHEDULER.STOP_JOB(running_job.job_name, TRUE);
                l_stopped_count := l_stopped_count + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END LOOP;

        log_message('Stopped ' || l_stopped_count || ' running jobs', 'WARNING');
    END STOP_ALL_JOBS;

END LOADER_PARALLEL_PKG;
/

-- ============================================================================
-- 3. ÖRNEK KULLANIM
-- ============================================================================

-- Basit kullanım (tüm işlem otomatik)
/*
BEGIN
    LOADER_PARALLEL_PKG.BEGIN_LOADER_TRANSFER_SAFE(
        P_SYSTEM_ID  => 21,
        P_TABLE_NAME => 'CELLSTS_4G',
        P_DATA_DATE  => TO_DATE('2025-12-10 14:00', 'YYYY-MM-DD HH24:MI')
    );
END;
*/

-- Manuel grup kontrolü
/*
DECLARE
    l_data_date DATE := TO_DATE('2025-12-10 14:00', 'YYYY-MM-DD HH24:MI');
BEGIN
    -- DTYPE=1 çalıştır
    P_CELLSTS_4G_CELL(l_data_date);

    -- Sadece GRUP 1'i paralel çalıştır
    LOADER_PARALLEL_PKG.START_PARALLEL_JOBS(
        P_TABLE_NAME => 'CELLSTS_4G',
        P_DATA_DATE  => l_data_date,
        P_DTYPE_LIST => '2,3,4',
        P_WAIT       => TRUE
    );

    -- İstersen diğer grupları...
END;
*/

-- Logları görüntüleme
/*
SELECT
    ADD_DATE,
    PROCEDURE_NAME,
    SQLTEXT,
    STATE
FROM NORTHI_DATA.TEST_ERROR
WHERE PROCEDURE_NAME LIKE '%LDR_DTYPE%'
   OR PROCEDURE_NAME = 'LOADER_PARALLEL'
ORDER BY ADD_DATE DESC;
*/

-- Çalışan job'ları görüntüleme
/*
SELECT
    job_name,
    state,
    TO_CHAR(start_date, 'YYYY-MM-DD HH24:MI:SS') AS start_time,
    ROUND((SYSDATE - start_date) * 24 * 60, 2) AS elapsed_minutes
FROM USER_SCHEDULER_JOBS
WHERE job_name LIKE 'LDR_DTYPE_%'
ORDER BY start_date DESC;
*/

-- Emergency: Tüm job'ları durdur
/*
BEGIN
    LOADER_PARALLEL_PKG.STOP_ALL_JOBS;
END;
*/

-- Eski job'ları temizle
/*
BEGIN
    LOADER_PARALLEL_PKG.CLEANUP_OLD_JOBS(P_DAYS_OLD => 7);
END;
*/
