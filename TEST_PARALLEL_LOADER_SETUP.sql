-- ============================================================================
-- TEST ENVIRONMENT SETUP
-- CELLSTS_4G Test için Hazırlık ve Test Aggregate Procedure'leri
-- ============================================================================

-- ============================================================================
-- PART 1: CELLSTS_4G_TMP'ye Manuel DTYPE=1 Data Kopyalama
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1.1: Belirli bir saat için kopyalama
-- ----------------------------------------------------------------------------
DECLARE
    l_data_date     DATE := TO_DATE('2025-12-16 14:00', 'YYYY-MM-DD HH24:MI');
    l_row_count     NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('========================================');
    DBMS_OUTPUT.PUT_LINE('CELLSTS_4G → CELLSTS_4G_TMP Kopyalama');
    DBMS_OUTPUT.PUT_LINE('Tarih: ' || TO_CHAR(l_data_date, 'YYYY-MM-DD HH24:MI'));
    DBMS_OUTPUT.PUT_LINE('========================================');

    -- Önce TMP'den o saati temizle (varsa)
    DELETE FROM NORTHI_DATA.CELLSTS_4G_TMP
    WHERE FRAGMENT_DATE = l_data_date
      AND DTYPE = 1;

    l_row_count := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('Eski kayıtlar silindi: ' || l_row_count);
    COMMIT;

    -- DTYPE=1 datayı kopyala
    INSERT /*+ APPEND PARALLEL(8) */ INTO NORTHI_DATA.CELLSTS_4G_TMP
    SELECT /*+ PARALLEL(8) */ *
    FROM NORTHI_DATA.CELLSTS_4G
    WHERE FRAGMENT_DATE = l_data_date
      AND DTYPE = 1;

    l_row_count := SQL%ROWCOUNT;
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('Yeni kayıtlar kopyalandı: ' || l_row_count);
    DBMS_OUTPUT.PUT_LINE('========================================');
    DBMS_OUTPUT.PUT_LINE('✅ Kopyalama tamamlandı!');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('❌ HATA: ' || SQLERRM);
        RAISE;
END;
/

-- ----------------------------------------------------------------------------
-- 1.2: Saat aralığı için kopyalama
-- ----------------------------------------------------------------------------
DECLARE
    l_start_date    DATE := TO_DATE('2025-12-16 00:00', 'YYYY-MM-DD HH24:MI');
    l_end_date      DATE := TO_DATE('2025-12-16 23:00', 'YYYY-MM-DD HH24:MI');
    l_current_date  DATE;
    l_total_rows    NUMBER := 0;
    l_row_count     NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('========================================');
    DBMS_OUTPUT.PUT_LINE('Toplu Kopyalama Başladı');
    DBMS_OUTPUT.PUT_LINE('Başlangıç: ' || TO_CHAR(l_start_date, 'YYYY-MM-DD HH24:MI'));
    DBMS_OUTPUT.PUT_LINE('Bitiş: ' || TO_CHAR(l_end_date, 'YYYY-MM-DD HH24:MI'));
    DBMS_OUTPUT.PUT_LINE('========================================');

    l_current_date := l_start_date;

    WHILE l_current_date <= l_end_date LOOP
        -- Her saat için
        DELETE FROM NORTHI_DATA.CELLSTS_4G_TMP
        WHERE FRAGMENT_DATE = l_current_date AND DTYPE = 1;

        INSERT /*+ APPEND */ INTO NORTHI_DATA.CELLSTS_4G_TMP
        SELECT * FROM NORTHI_DATA.CELLSTS_4G
        WHERE FRAGMENT_DATE = l_current_date AND DTYPE = 1;

        l_row_count := SQL%ROWCOUNT;
        l_total_rows := l_total_rows + l_row_count;

        COMMIT;

        DBMS_OUTPUT.PUT_LINE(TO_CHAR(l_current_date, 'HH24:MI') || ' → ' ||
                             l_row_count || ' satır kopyalandı');

        -- Bir sonraki saat
        l_current_date := l_current_date + 1/24;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('========================================');
    DBMS_OUTPUT.PUT_LINE('✅ Toplam ' || l_total_rows || ' satır kopyalandı');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('❌ HATA: ' || SQLERRM);
        RAISE;
END;
/

-- ============================================================================
-- PART 2: Test Aggregate Procedure'leri Oluşturma (_X suffix)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 2.1: Tek bir DTYPE için _X procedure oluşturma
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CREATE_TEST_AGG_PROCEDURE_X(
    P_TABLE_NAME        VARCHAR2,
    P_DTYPE             NUMBER,
    P_PARTITION_VALUE   VARCHAR2
) AS
    l_proc_name         VARCHAR2(100);
    l_test_proc_name    VARCHAR2(100);
    l_proc_ddl          CLOB;
    l_new_ddl           CLOB;
BEGIN
    l_proc_name := 'P_' || P_TABLE_NAME || '_' || P_PARTITION_VALUE;
    l_test_proc_name := l_proc_name || '_X';

    DBMS_OUTPUT.PUT_LINE('Creating ' || l_test_proc_name || ' (DTYPE=' || P_DTYPE || ')...');

    -- Orjinal procedure DDL'ini al
    BEGIN
        SELECT DBMS_METADATA.GET_DDL('PROCEDURE', l_proc_name, 'NORTHI_LOADER')
        INTO l_proc_ddl
        FROM DUAL;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('⚠️  Procedure bulunamadı: ' || l_proc_name);
            RETURN;
    END;

    -- Procedure ismini _X ile değiştir
    l_new_ddl := REPLACE(l_proc_ddl,
                         'PROCEDURE "' || l_proc_name || '"',
                         'PROCEDURE "' || l_test_proc_name || '"');

    -- Oluştur
    EXECUTE IMMEDIATE l_new_ddl;

    DBMS_OUTPUT.PUT_LINE('✅ ' || l_test_proc_name || ' oluşturuldu');

EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ Hata: ' || l_test_proc_name || ' - ' || SQLERRM);
END;
/

-- ----------------------------------------------------------------------------
-- 2.2: DTYPE 2-14 için toplu _X procedure'leri oluşturma
-- ----------------------------------------------------------------------------
DECLARE
    l_table_name    VARCHAR2(50) := 'CELLSTS_4G';
    l_dtype         NUMBER;
    l_partition_val VARCHAR2(50);
    l_created       NUMBER := 0;
    l_failed        NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('========================================');
    DBMS_OUTPUT.PUT_LINE('Test Aggregate Procedure Oluşturma (_X)');
    DBMS_OUTPUT.PUT_LINE('Table: ' || l_table_name);
    DBMS_OUTPUT.PUT_LINE('========================================');

    -- DTYPE 2-14 için döngü
    FOR rec IN (
        SELECT DTYPE, PARTITION_VALUE
        FROM NORTHI_PARTITION_TYPE
        WHERE PARTITION_ID = (
            SELECT PARTITION_ID
            FROM NORTHI_LOADER_SETTINGS
            WHERE TABLE_NAME = l_table_name
            AND ROWNUM = 1
        )
        AND DTYPE BETWEEN 2 AND 14
        ORDER BY DTYPE
    ) LOOP
        BEGIN
            CREATE_TEST_AGG_PROCEDURE_X(
                P_TABLE_NAME      => l_table_name,
                P_DTYPE           => rec.DTYPE,
                P_PARTITION_VALUE => rec.PARTITION_VALUE
            );
            l_created := l_created + 1;
        EXCEPTION
            WHEN OTHERS THEN
                l_failed := l_failed + 1;
        END;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('========================================');
    DBMS_OUTPUT.PUT_LINE('✅ Başarılı: ' || l_created);
    DBMS_OUTPUT.PUT_LINE('❌ Hatalı: ' || l_failed);
    DBMS_OUTPUT.PUT_LINE('========================================');
END;
/

-- ============================================================================
-- PART 3: Test Procedure'lerinin Manuel Kontrolü
-- ============================================================================

-- Oluşturulan test procedure'leri listele
SELECT
    object_name,
    object_type,
    status,
    TO_CHAR(created, 'YYYY-MM-DD HH24:MI') AS created_date
FROM USER_OBJECTS
WHERE object_name LIKE 'P_CELLSTS_4G_%_X'
ORDER BY object_name;

-- ============================================================================
-- PART 4: Test Parallel Loader (BEGIN_LOADER_TRANSFER_TEST)
-- ============================================================================

CREATE OR REPLACE PROCEDURE BEGIN_LOADER_TRANSFER_TEST(
    P_DATA_DATE     IN DATE,
    P_TABLE_NAME    IN VARCHAR2 DEFAULT 'CELLSTS_4G'
) AS
    l_start_time        TIMESTAMP := SYSTIMESTAMP;
    l_total_duration    NUMBER;
    l_proc_name         VARCHAR2(100);
    l_row_count         NUMBER;

    -- Job tracking
    TYPE t_job_rec IS RECORD (
        job_name    VARCHAR2(100),
        dtype       NUMBER,
        status      VARCHAR2(20)
    );
    TYPE t_job_list IS TABLE OF t_job_rec INDEX BY PLS_INTEGER;
    l_jobs              t_job_list;
    l_job_count         NUMBER := 0;

    PROCEDURE log_msg(p_msg VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO NORTHI_DATA.TEST_ERROR (
            ADD_DATE, PROCEDURE_NAME, SQLTEXT, STATE
        ) VALUES (
            SYSDATE, 'LOADER_TEST', SUBSTR(p_msg, 1, 4000), 'INFO'
        );
        COMMIT;
        DBMS_OUTPUT.PUT_LINE(p_msg);
    END;

    PROCEDURE start_test_job(p_dtype NUMBER, p_partition_value VARCHAR2) IS
        l_job_name VARCHAR2(100);
        l_action   CLOB;
    BEGIN
        l_job_name := 'TEST_DTYPE_' || p_dtype || '_' ||
                      TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF');

        l_action :=
            'BEGIN ' ||
            '    P_' || P_TABLE_NAME || '_' || p_partition_value || '_X' ||
            '(TO_DATE(''' || TO_CHAR(P_DATA_DATE, 'DD.MM.YYYY HH24:MI') ||
            ''', ''DD.MM.YYYY HH24:MI'')); ' ||
            'END;';

        DBMS_SCHEDULER.CREATE_JOB(
            job_name    => l_job_name,
            job_type    => 'PLSQL_BLOCK',
            job_action  => l_action,
            enabled     => FALSE,
            auto_drop   => TRUE
        );

        l_job_count := l_job_count + 1;
        l_jobs(l_job_count).job_name := l_job_name;
        l_jobs(l_job_count).dtype := p_dtype;
        l_jobs(l_job_count).status := 'CREATED';

        DBMS_SCHEDULER.ENABLE(l_job_name);

        log_msg('  ├─ Job started: DTYPE=' || p_dtype);
    END;

    PROCEDURE wait_all_jobs IS
        l_running NUMBER;
        l_elapsed NUMBER := 0;
    BEGIN
        log_msg('  └─ Waiting for jobs to complete...');

        LOOP
            l_running := 0;

            FOR i IN 1..l_job_count LOOP
                BEGIN
                    SELECT 1 INTO l_running
                    FROM USER_SCHEDULER_JOBS
                    WHERE job_name = l_jobs(i).job_name
                      AND state = 'RUNNING';

                    l_running := l_running + 1;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        NULL;
                END;
            END LOOP;

            EXIT WHEN l_running = 0;

            DBMS_LOCK.SLEEP(5);
            l_elapsed := l_elapsed + 5;

            IF MOD(l_elapsed, 30) = 0 THEN
                log_msg('    Still waiting... (' || l_running || ' jobs running)');
            END IF;
        END LOOP;

        log_msg('  ✅ All jobs completed');
        l_job_count := 0;
        l_jobs.DELETE;
    END;

BEGIN
    log_msg('========================================');
    log_msg('TEST LOADER BAŞLADI');
    log_msg('Table: ' || P_TABLE_NAME);
    log_msg('Date: ' || TO_CHAR(P_DATA_DATE, 'YYYY-MM-DD HH24:MI'));
    log_msg('========================================');

    -- GRUP 1: DTYPE 2,3,4
    log_msg('GROUP 1: DTYPE 2,3,4 (PARALLEL)');
    start_test_job(2, 'ENODEB');
    start_test_job(3, 'NW');
    start_test_job(4, 'MAIN_REGION');
    wait_all_jobs;

    -- GRUP 2: DTYPE 7,8,9
    log_msg('GROUP 2: DTYPE 7,8,9 (PARALLEL)');
    start_test_job(7, 'FBAND');
    start_test_job(8, 'RBAND');
    start_test_job(9, 'CBAND');
    wait_all_jobs;

    -- GRUP 3: DTYPE 10-14
    log_msg('GROUP 3: DTYPE 10,11,12,13,14 (PARALLEL)');
    start_test_job(10, 'ILCE');
    start_test_job(11, 'MAHALLE');
    start_test_job(12, 'NFBAND');
    start_test_job(13, 'SRCITY');
    start_test_job(14, 'OEMANN');
    wait_all_jobs;

    -- GRUP 4: DTYPE 5,6
    log_msg('GROUP 4: DTYPE 5,6 (PARALLEL)');
    start_test_job(5, 'SUB_REGION');
    start_test_job(6, 'CITY');
    wait_all_jobs;

    l_total_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time));

    log_msg('========================================');
    log_msg('✅ TEST LOADER TAMAMLANDI');
    log_msg('Total duration: ' || ROUND(l_total_duration, 2) || ' seconds');
    log_msg('========================================');

EXCEPTION
    WHEN OTHERS THEN
        log_msg('❌ TEST FAILED: ' || SQLERRM);
        RAISE;
END;
/

-- ============================================================================
-- PART 5: Hızlı Test Scripti
-- ============================================================================

-- Tek komutla test ortamını hazırla ve çalıştır
DECLARE
    l_test_date DATE := TO_DATE('2025-12-16 14:00', 'YYYY-MM-DD HH24:MI');
BEGIN
    DBMS_OUTPUT.PUT_LINE('🚀 TEST BAŞLIYOR...');
    DBMS_OUTPUT.PUT_LINE('');

    -- 1. TMP'ye DTYPE=1 kopyala
    DBMS_OUTPUT.PUT_LINE('STEP 1: TMP tablosuna DTYPE=1 kopyalama...');
    DELETE FROM NORTHI_DATA.CELLSTS_4G_TMP
    WHERE FRAGMENT_DATE = l_test_date AND DTYPE = 1;

    INSERT /*+ APPEND */ INTO NORTHI_DATA.CELLSTS_4G_TMP
    SELECT * FROM NORTHI_DATA.CELLSTS_4G
    WHERE FRAGMENT_DATE = l_test_date AND DTYPE = 1;
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('✅ ' || SQL%ROWCOUNT || ' satır kopyalandı');
    DBMS_OUTPUT.PUT_LINE('');

    -- 2. Test aggregate'leri çalıştır
    DBMS_OUTPUT.PUT_LINE('STEP 2: Test aggregate procedure çalıştırılıyor...');
    BEGIN_LOADER_TRANSFER_TEST(P_DATA_DATE => l_test_date);

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('🎉 TEST TAMAMLANDI!');

EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('❌ TEST HATASI: ' || SQLERRM);
        RAISE;
END;
/

-- ============================================================================
-- PART 6: Temizlik ve Doğrulama Scriptleri
-- ============================================================================

-- Test sonuçlarını kontrol et
SELECT
    DTYPE,
    COUNT(*) AS row_count,
    MIN(FRAGMENT_DATE) AS min_date,
    MAX(FRAGMENT_DATE) AS max_date
FROM NORTHI_DATA.CELLSTS_4G
WHERE FRAGMENT_DATE = TO_DATE('2025-12-16 14:00', 'YYYY-MM-DD HH24:MI')
GROUP BY DTYPE
ORDER BY DTYPE;

-- Test procedure'lerini sil (cleanup)
BEGIN
    FOR proc IN (
        SELECT object_name
        FROM USER_OBJECTS
        WHERE object_name LIKE 'P_CELLSTS_4G_%_X'
          AND object_type = 'PROCEDURE'
    ) LOOP
        EXECUTE IMMEDIATE 'DROP PROCEDURE ' || proc.object_name;
        DBMS_OUTPUT.PUT_LINE('Dropped: ' || proc.object_name);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('✅ Test procedure''leri temizlendi');
END;
/

-- TMP tablosundan test datayı sil
DELETE FROM NORTHI_DATA.CELLSTS_4G_TMP
WHERE FRAGMENT_DATE = TO_DATE('2025-12-16 14:00', 'YYYY-MM-DD HH24:MI');
COMMIT;

-- Test job'ları sil
BEGIN
    FOR job IN (
        SELECT job_name
        FROM USER_SCHEDULER_JOBS
        WHERE job_name LIKE 'TEST_DTYPE_%'
    ) LOOP
        DBMS_SCHEDULER.DROP_JOB(job.job_name, TRUE);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('✅ Test job''ları temizlendi');
END;
/
