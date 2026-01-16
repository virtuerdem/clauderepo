-- ============================================================================
-- MISSING HOURS GENERATOR
-- 4 örnek saatten (00, 06, 12, 20) kalan 20 saati generate eder
-- ============================================================================

-- ============================================================================
-- PART 1: MEVCUT DATA ANALİZİ
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1.1: Yüklenen örnek saatleri kontrol et
-- ----------------------------------------------------------------------------
SELECT
    TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD') AS data_date,
    TO_CHAR(FRAGMENT_DATE, 'HH24') AS data_hour,
    DTYPE,
    COUNT(*) AS row_count,
    COUNT(DISTINCT ENODEB_ID) AS enodeb_count,
    COUNT(DISTINCT CELL_ID) AS cell_count
FROM CELLSTS_4G
WHERE DTYPE = 1
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
GROUP BY TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD'), TO_CHAR(FRAGMENT_DATE, 'HH24'), DTYPE
ORDER BY 1, 2;

-- Beklenen: 00:00, 06:00, 12:00, 20:00 saatleri görünmeli

-- ----------------------------------------------------------------------------
-- 1.2: Örnek bir saatin structure'ını incele
-- ----------------------------------------------------------------------------
SELECT *
FROM CELLSTS_4G
WHERE DTYPE = 1
  AND FRAGMENT_DATE = TRUNC(SYSDATE-1) + 6/24  -- 06:00 örneği
  AND ROWNUM <= 10;

-- ============================================================================
-- PART 2: SAATLERİ GENERATE ETME STRATEJİSİ
-- ============================================================================

/*
YAKLAŞIM:
---------
1. Her örnek saat (00, 06, 12, 20) kendine en yakın saatleri generate eder
2. FRAGMENT_DATE değiştirilerek yeni kayıtlar oluşturulur
3. KPI değerlerinde ±5-10% varyasyon eklenir (gerçekçilik için)
4. Aynı ENODEB_ID, CELL_ID, NETWORK_ID yapısı korunur

SAAT DAĞILIMI:
--------------
00:00 → 01, 02, 03, 04, 05 generate eder (6 saat)
06:00 → 07, 08, 09, 10, 11 generate eder (6 saat)
12:00 → 13, 14, 15, 16, 17 generate eder (6 saat)
20:00 → 18, 19, 21, 22, 23 generate eder (6 saat)

Toplam: 4 + 20 = 24 saat
*/

-- ============================================================================
-- PART 3: GENERATE PROCEDURE
-- ============================================================================

CREATE OR REPLACE PROCEDURE GENERATE_MISSING_HOURS(
    P_BASE_DATE     IN DATE DEFAULT TRUNC(SYSDATE-1),
    P_TABLE_NAME    IN VARCHAR2 DEFAULT 'CELLSTS_4G',
    P_ADD_VARIANCE  IN BOOLEAN DEFAULT TRUE
) AS
    l_row_count     NUMBER := 0;
    l_total_rows    NUMBER := 0;
    l_source_date   DATE;
    l_target_date   DATE;

    TYPE t_hour_map IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    l_source_hours  t_hour_map;
    l_target_hours  VARCHAR2(1000);

    PROCEDURE log_msg(p_msg VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSDATE, 'HH24:MI:SS') || ' - ' || p_msg);
    END;

BEGIN
    log_msg('========================================');
    log_msg('MISSING HOURS GENERATOR BAŞLADI');
    log_msg('Base Date: ' || TO_CHAR(P_BASE_DATE, 'YYYY-MM-DD'));
    log_msg('========================================');

    -- Örnek saatler: 00, 06, 12, 20
    l_source_hours(1) := 0;
    l_source_hours(2) := 6;
    l_source_hours(3) := 12;
    l_source_hours(4) := 20;

    -- ========================================================================
    -- 00:00 → 01, 02, 03, 04, 05 generate et
    -- ========================================================================
    log_msg('');
    log_msg('GROUP 1: 00:00 → 01-05 saatleri');
    log_msg('----------------------------------------');

    FOR target_hour IN 1..5 LOOP
        l_source_date := TRUNC(P_BASE_DATE) + 0/24;   -- 00:00
        l_target_date := TRUNC(P_BASE_DATE) + target_hour/24;

        IF P_ADD_VARIANCE THEN
            -- KPI değerlerinde ±8% varyasyon ekle
            INSERT /*+ APPEND */ INTO CELLSTS_4G
            SELECT
                l_target_date AS FRAGMENT_DATE,  -- Yeni saat
                DTYPE,
                ENODEB_ID,
                CELL_ID,
                NETWORK_ID,
                -- Numerik kolonlarda varyasyon (örnek - gerçek kolon isimlerini kullan)
                ROUND(KPI_VALUE_1 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) AS KPI_VALUE_1,  -- ±8%
                ROUND(KPI_VALUE_2 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) AS KPI_VALUE_2,
                -- Diğer tüm kolonları kopyala (gerçek kolon isimlerini kullan)
                CITY_ID,
                REGION_ID,
                BAND_TYPE
                -- ... diğer kolonlar
            FROM CELLSTS_4G
            WHERE FRAGMENT_DATE = l_source_date
              AND DTYPE = 1;
        ELSE
            -- Varyasyon olmadan direkt kopya
            INSERT /*+ APPEND */ INTO CELLSTS_4G
            SELECT
                l_target_date AS FRAGMENT_DATE,  -- Sadece FRAGMENT_DATE değişir
                DTYPE,
                ENODEB_ID,
                CELL_ID,
                NETWORK_ID,
                KPI_VALUE_1,
                KPI_VALUE_2,
                CITY_ID,
                REGION_ID,
                BAND_TYPE
                -- ... diğer kolonlar
            FROM CELLSTS_4G
            WHERE FRAGMENT_DATE = l_source_date
              AND DTYPE = 1;
        END IF;

        l_row_count := SQL%ROWCOUNT;
        l_total_rows := l_total_rows + l_row_count;
        COMMIT;

        log_msg('  ' || TO_CHAR(target_hour, 'FM00') || ':00 oluşturuldu → ' || l_row_count || ' satır');
    END LOOP;

    -- ========================================================================
    -- 06:00 → 07, 08, 09, 10, 11 generate et
    -- ========================================================================
    log_msg('');
    log_msg('GROUP 2: 06:00 → 07-11 saatleri');
    log_msg('----------------------------------------');

    FOR target_hour IN 7..11 LOOP
        l_source_date := TRUNC(P_BASE_DATE) + 6/24;   -- 06:00
        l_target_date := TRUNC(P_BASE_DATE) + target_hour/24;

        INSERT /*+ APPEND */ INTO CELLSTS_4G
        SELECT
            l_target_date,
            DTYPE,
            ENODEB_ID,
            CELL_ID,
            NETWORK_ID,
            CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_1 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_1 END,
            CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_2 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_2 END,
            CITY_ID,
            REGION_ID,
            BAND_TYPE
            -- ... diğer kolonlar
        FROM CELLSTS_4G
        WHERE FRAGMENT_DATE = l_source_date
          AND DTYPE = 1;

        l_row_count := SQL%ROWCOUNT;
        l_total_rows := l_total_rows + l_row_count;
        COMMIT;

        log_msg('  ' || TO_CHAR(target_hour, 'FM00') || ':00 oluşturuldu → ' || l_row_count || ' satır');
    END LOOP;

    -- ========================================================================
    -- 12:00 → 13, 14, 15, 16, 17 generate et
    -- ========================================================================
    log_msg('');
    log_msg('GROUP 3: 12:00 → 13-17 saatleri');
    log_msg('----------------------------------------');

    FOR target_hour IN 13..17 LOOP
        l_source_date := TRUNC(P_BASE_DATE) + 12/24;  -- 12:00
        l_target_date := TRUNC(P_BASE_DATE) + target_hour/24;

        INSERT /*+ APPEND */ INTO CELLSTS_4G
        SELECT
            l_target_date,
            DTYPE,
            ENODEB_ID,
            CELL_ID,
            NETWORK_ID,
            CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_1 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_1 END,
            CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_2 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_2 END,
            CITY_ID,
            REGION_ID,
            BAND_TYPE
            -- ... diğer kolonlar
        FROM CELLSTS_4G
        WHERE FRAGMENT_DATE = l_source_date
          AND DTYPE = 1;

        l_row_count := SQL%ROWCOUNT;
        l_total_rows := l_total_rows + l_row_count;
        COMMIT;

        log_msg('  ' || TO_CHAR(target_hour, 'FM00') || ':00 oluşturuldu → ' || l_row_count || ' satır');
    END LOOP;

    -- ========================================================================
    -- 20:00 → 18, 19, 21, 22, 23 generate et
    -- ========================================================================
    log_msg('');
    log_msg('GROUP 4: 20:00 → 18, 19, 21-23 saatleri');
    log_msg('----------------------------------------');

    -- 18:00
    l_source_date := TRUNC(P_BASE_DATE) + 20/24;
    l_target_date := TRUNC(P_BASE_DATE) + 18/24;

    INSERT /*+ APPEND */ INTO CELLSTS_4G
    SELECT
        l_target_date,
        DTYPE,
        ENODEB_ID,
        CELL_ID,
        NETWORK_ID,
        CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_1 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_1 END,
        CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_2 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_2 END,
        CITY_ID,
        REGION_ID,
        BAND_TYPE
        -- ... diğer kolonlar
    FROM CELLSTS_4G
    WHERE FRAGMENT_DATE = l_source_date
      AND DTYPE = 1;

    l_row_count := SQL%ROWCOUNT;
    l_total_rows := l_total_rows + l_row_count;
    COMMIT;
    log_msg('  18:00 oluşturuldu → ' || l_row_count || ' satır');

    -- 19:00
    l_target_date := TRUNC(P_BASE_DATE) + 19/24;

    INSERT /*+ APPEND */ INTO CELLSTS_4G
    SELECT
        l_target_date,
        DTYPE,
        ENODEB_ID,
        CELL_ID,
        NETWORK_ID,
        CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_1 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_1 END,
        CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_2 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_2 END,
        CITY_ID,
        REGION_ID,
        BAND_TYPE
        -- ... diğer kolonlar
    FROM CELLSTS_4G
    WHERE FRAGMENT_DATE = l_source_date
      AND DTYPE = 1;

    l_row_count := SQL%ROWCOUNT;
    l_total_rows := l_total_rows + l_row_count;
    COMMIT;
    log_msg('  19:00 oluşturuldu → ' || l_row_count || ' satır');

    -- 21-23:00
    FOR target_hour IN 21..23 LOOP
        l_target_date := TRUNC(P_BASE_DATE) + target_hour/24;

        INSERT /*+ APPEND */ INTO CELLSTS_4G
        SELECT
            l_target_date,
            DTYPE,
            ENODEB_ID,
            CELL_ID,
            NETWORK_ID,
            CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_1 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_1 END,
            CASE WHEN P_ADD_VARIANCE THEN ROUND(KPI_VALUE_2 * (0.92 + DBMS_RANDOM.VALUE * 0.16), 2) ELSE KPI_VALUE_2 END,
            CITY_ID,
            REGION_ID,
            BAND_TYPE
            -- ... diğer kolonlar
        FROM CELLSTS_4G
        WHERE FRAGMENT_DATE = l_source_date
          AND DTYPE = 1;

        l_row_count := SQL%ROWCOUNT;
        l_total_rows := l_total_rows + l_row_count;
        COMMIT;

        log_msg('  ' || TO_CHAR(target_hour, 'FM00') || ':00 oluşturuldu → ' || l_row_count || ' satır');
    END LOOP;

    -- ========================================================================
    -- ÖZET
    -- ========================================================================
    log_msg('');
    log_msg('========================================');
    log_msg('✅ GENERATION TAMAMLANDI');
    log_msg('Toplam oluşturulan satır: ' || l_total_rows);
    log_msg('Variance: ' || CASE WHEN P_ADD_VARIANCE THEN 'Aktif (±8%)' ELSE 'Pasif (exact copy)' END);
    log_msg('========================================');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        log_msg('❌ HATA: ' || SQLERRM);
        RAISE;
END;
/

-- ============================================================================
-- PART 4: KOLON İSİMLERİNİ OTOMATIK TESPIT EDEN VERSİYON
-- ============================================================================

CREATE OR REPLACE PROCEDURE GENERATE_MISSING_HOURS_AUTO(
    P_BASE_DATE     IN DATE DEFAULT TRUNC(SYSDATE-1),
    P_TABLE_NAME    IN VARCHAR2 DEFAULT 'CELLSTS_4G'
) AS
    l_columns       VARCHAR2(32000);
    l_sql           CLOB;
    l_row_count     NUMBER := 0;
    l_total_rows    NUMBER := 0;

    TYPE t_hour_mapping IS RECORD (
        source_hour NUMBER,
        target_hours VARCHAR2(100)
    );
    TYPE t_hour_mappings IS TABLE OF t_hour_mapping;

    l_mappings t_hour_mappings := t_hour_mappings(
        t_hour_mapping(0, '1,2,3,4,5'),
        t_hour_mapping(6, '7,8,9,10,11'),
        t_hour_mapping(12, '13,14,15,16,17'),
        t_hour_mapping(20, '18,19,21,22,23')
    );

    PROCEDURE log_msg(p_msg VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSDATE, 'HH24:MI:SS') || ' - ' || p_msg);
    END;

BEGIN
    log_msg('========================================');
    log_msg('AUTO MISSING HOURS GENERATOR');
    log_msg('Table: ' || P_TABLE_NAME);
    log_msg('Base Date: ' || TO_CHAR(P_BASE_DATE, 'YYYY-MM-DD'));
    log_msg('========================================');

    -- Tablo kolonlarını otomatik tespit et (FRAGMENT_DATE hariç)
    SELECT LISTAGG(column_name, ', ') WITHIN GROUP (ORDER BY column_id)
    INTO l_columns
    FROM USER_TAB_COLUMNS
    WHERE table_name = UPPER(P_TABLE_NAME)
      AND column_name != 'FRAGMENT_DATE';

    log_msg('Tespit edilen kolonlar: ' || SUBSTR(l_columns, 1, 100) || '...');
    log_msg('');

    -- Her source hour için target hour'ları oluştur
    FOR mapping IN 1..l_mappings.COUNT LOOP
        log_msg('GROUP ' || mapping || ': Hour ' ||
                TO_CHAR(l_mappings(mapping).source_hour, 'FM00') ||
                ' → Hours ' || l_mappings(mapping).target_hours);
        log_msg('----------------------------------------');

        -- Target hour'ları parse et
        FOR target_hour IN (
            SELECT TO_NUMBER(TRIM(COLUMN_VALUE)) AS hour_val
            FROM TABLE(
                CAST(
                    MULTISET(
                        SELECT REGEXP_SUBSTR(l_mappings(mapping).target_hours, '[^,]+', 1, LEVEL)
                        FROM DUAL
                        CONNECT BY LEVEL <= REGEXP_COUNT(l_mappings(mapping).target_hours, ',') + 1
                    ) AS SYS.ODCIVARCHAR2LIST
                )
            )
        ) LOOP
            -- Dynamic SQL ile insert
            l_sql :=
                'INSERT /*+ APPEND */ INTO ' || P_TABLE_NAME || ' ' ||
                'SELECT ' ||
                '    TO_DATE(''' || TO_CHAR(P_BASE_DATE, 'YYYY-MM-DD') ||
                ' ' || TO_CHAR(target_hour.hour_val, 'FM00') || ':00'', ''YYYY-MM-DD HH24:MI'') AS FRAGMENT_DATE, ' ||
                '    ' || l_columns || ' ' ||
                'FROM ' || P_TABLE_NAME || ' ' ||
                'WHERE FRAGMENT_DATE = TO_DATE(''' || TO_CHAR(P_BASE_DATE, 'YYYY-MM-DD') ||
                ' ' || TO_CHAR(l_mappings(mapping).source_hour, 'FM00') || ':00'', ''YYYY-MM-DD HH24:MI'') ' ||
                '  AND DTYPE = 1';

            EXECUTE IMMEDIATE l_sql;
            l_row_count := SQL%ROWCOUNT;
            l_total_rows := l_total_rows + l_row_count;
            COMMIT;

            log_msg('  ' || TO_CHAR(target_hour.hour_val, 'FM00') || ':00 oluşturuldu → ' || l_row_count || ' satır');
        END LOOP;

        log_msg('');
    END LOOP;

    log_msg('========================================');
    log_msg('✅ GENERATION TAMAMLANDI');
    log_msg('Toplam oluşturulan satır: ' || l_total_rows);
    log_msg('========================================');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        log_msg('❌ HATA: ' || SQLERRM);
        RAISE;
END;
/

-- ============================================================================
-- PART 5: HIZLI ÇALIŞTIRMA SCRİPTLERİ
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 5.1: Varsayılan parametrelerle çalıştır
-- ----------------------------------------------------------------------------

-- Otomatik versiyon (tüm kolonları otomatik tespit eder)
BEGIN
    GENERATE_MISSING_HOURS_AUTO(
        P_BASE_DATE => TRUNC(SYSDATE-1)  -- Dün için
    );
END;
/

-- Manuel versiyon (variance ile)
/*
BEGIN
    GENERATE_MISSING_HOURS(
        P_BASE_DATE => TRUNC(SYSDATE-1),
        P_ADD_VARIANCE => TRUE  -- KPI değerlerinde ±8% varyasyon
    );
END;
/
*/

-- ----------------------------------------------------------------------------
-- 5.2: Birden fazla gün için çalıştır
-- ----------------------------------------------------------------------------

DECLARE
    l_start_date DATE := TRUNC(SYSDATE - 3);  -- 3 gün önce
    l_end_date   DATE := TRUNC(SYSDATE - 1);  -- Dün
    l_current    DATE;
BEGIN
    DBMS_OUTPUT.PUT_LINE('========================================');
    DBMS_OUTPUT.PUT_LINE('ÇOKLU GÜN GENERATION');
    DBMS_OUTPUT.PUT_LINE('========================================');

    l_current := l_start_date;

    WHILE l_current <= l_end_date LOOP
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('>>> İşleniyor: ' || TO_CHAR(l_current, 'YYYY-MM-DD'));
        DBMS_OUTPUT.PUT_LINE('');

        GENERATE_MISSING_HOURS_AUTO(P_BASE_DATE => l_current);

        l_current := l_current + 1;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('========================================');
    DBMS_OUTPUT.PUT_LINE('✅ TÜM GÜNLER TAMAMLANDI');
    DBMS_OUTPUT.PUT_LINE('========================================');
END;
/

-- ============================================================================
-- PART 6: VALIDATION SCRİPTLERİ
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 6.1: Tüm saatlerin oluşturulduğunu kontrol et
-- ----------------------------------------------------------------------------

SELECT
    TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD') AS data_date,
    TO_CHAR(FRAGMENT_DATE, 'HH24') AS hour,
    DTYPE,
    COUNT(*) AS row_count,
    CASE
        WHEN TO_CHAR(FRAGMENT_DATE, 'HH24') IN ('00','06','12','20') THEN 'SOURCE'
        ELSE 'GENERATED'
    END AS data_type
FROM CELLSTS_4G
WHERE DTYPE = 1
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
GROUP BY TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD'), TO_CHAR(FRAGMENT_DATE, 'HH24'), DTYPE
ORDER BY 1, 2;

-- Beklenen: Her gün için 24 saat görünmeli (00-23)

-- ----------------------------------------------------------------------------
-- 6.2: Kayıp saat var mı kontrol et
-- ----------------------------------------------------------------------------

WITH all_hours AS (
    SELECT LEVEL-1 AS hour_num
    FROM DUAL
    CONNECT BY LEVEL <= 24
),
base_dates AS (
    SELECT DISTINCT TRUNC(FRAGMENT_DATE) AS data_date
    FROM CELLSTS_4G
    WHERE DTYPE = 1
      AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
),
expected_hours AS (
    SELECT
        d.data_date,
        d.data_date + h.hour_num/24 AS expected_datetime,
        h.hour_num
    FROM base_dates d
    CROSS JOIN all_hours h
)
SELECT
    e.data_date,
    e.hour_num,
    CASE WHEN c.FRAGMENT_DATE IS NULL THEN '❌ KAYIP' ELSE '✅ MEVCUT' END AS status
FROM expected_hours e
LEFT JOIN (
    SELECT DISTINCT FRAGMENT_DATE
    FROM CELLSTS_4G
    WHERE DTYPE = 1
) c ON c.FRAGMENT_DATE = e.expected_datetime
WHERE e.data_date >= TRUNC(SYSDATE - 2)
ORDER BY e.data_date, e.hour_num;

-- ----------------------------------------------------------------------------
-- 6.3: Source vs Generated kayıt sayısı karşılaştırması
-- ----------------------------------------------------------------------------

SELECT
    'SOURCE (00,06,12,20)' AS data_type,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT ENODEB_ID) AS enodeb_count,
    ROUND(AVG(cell_count_per_hour), 0) AS avg_cells_per_hour
FROM (
    SELECT
        FRAGMENT_DATE,
        COUNT(DISTINCT CELL_ID) AS cell_count_per_hour
    FROM CELLSTS_4G
    WHERE DTYPE = 1
      AND TO_CHAR(FRAGMENT_DATE, 'HH24') IN ('00','06','12','20')
      AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
    GROUP BY FRAGMENT_DATE
)

UNION ALL

SELECT
    'GENERATED (diğer 20 saat)' AS data_type,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT ENODEB_ID) AS enodeb_count,
    ROUND(AVG(cell_count_per_hour), 0) AS avg_cells_per_hour
FROM (
    SELECT
        FRAGMENT_DATE,
        COUNT(DISTINCT CELL_ID) AS cell_count_per_hour
    FROM CELLSTS_4G
    WHERE DTYPE = 1
      AND TO_CHAR(FRAGMENT_DATE, 'HH24') NOT IN ('00','06','12','20')
      AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
    GROUP BY FRAGMENT_DATE
);

-- ============================================================================
-- PART 7: CLEANUP (Gerekirse)
-- ============================================================================

-- Generated saatleri sil (source'ları koru)
/*
DELETE FROM CELLSTS_4G
WHERE DTYPE = 1
  AND TO_CHAR(FRAGMENT_DATE, 'HH24') NOT IN ('00','06','12','20')
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2);

COMMIT;

DBMS_OUTPUT.PUT_LINE('Generated saatler silindi. Sadece source saatler (00,06,12,20) kaldı.');
*/

-- ============================================================================
-- PART 8: KULLANIM KILAVUZU
-- ============================================================================

/*
ADIM 1: 4 Saatlik Source Datayı Yükle
======================================
- Git'ten 00, 06, 12, 20 saatlerini çek
- Test DB'ye import et
- DTYPE=1 olduğundan emin ol

ADIM 2: Kolonları Kontrol Et
============================
SELECT * FROM CELLSTS_4G WHERE DTYPE=1 AND ROWNUM=1;

ADIM 3: Generate Procedure Çalıştır
===================================
-- Otomatik versiyon (önerilen):
BEGIN
    GENERATE_MISSING_HOURS_AUTO(
        P_BASE_DATE => TRUNC(SYSDATE-1)
    );
END;
/

ADIM 4: Validation
==================
-- Tüm saatlerin oluşturulduğunu kontrol et
SELECT TO_CHAR(FRAGMENT_DATE, 'HH24'), COUNT(*)
FROM CELLSTS_4G
WHERE DTYPE=1 AND FRAGMENT_DATE >= TRUNC(SYSDATE-1)
GROUP BY TO_CHAR(FRAGMENT_DATE, 'HH24')
ORDER BY 1;

Beklenen: 00-23 arası 24 satır

ADIM 5: Paralel Loader Test
============================
-- DTYPE 2-14'ü oluştur
BEGIN
    BEGIN_LOADER_TRANSFER_TEST(
        P_DATA_DATE => TRUNC(SYSDATE-1) + 14/24  -- 14:00
    );
END;
/
*/
