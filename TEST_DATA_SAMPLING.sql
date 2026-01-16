-- ============================================================================
-- TEST DATABASE ÖRNEK DATA AKTARIMI
-- Production DB'den Test DB'ye sample data export/import
-- ============================================================================

-- ============================================================================
-- PART 1: METADATA TABLOLARI (TAM KOPYA)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1.1: NORTHI_LOADER_SETTINGS (CELLSTS_4G için)
-- ----------------------------------------------------------------------------
SELECT *
FROM NORTHI_LOADER_SETTINGS
WHERE TABLE_NAME = 'CELLSTS_4G';

-- Export komutu:
-- exp user/pass@PROD file=loader_settings.dmp tables=NORTHI_LOADER_SETTINGS query=\"WHERE TABLE_NAME='CELLSTS_4G'\"

-- ----------------------------------------------------------------------------
-- 1.2: NORTHI_PARTITION_TYPE (CELLSTS_4G partition'ları)
-- ----------------------------------------------------------------------------
SELECT pt.*
FROM NORTHI_PARTITION_TYPE pt
WHERE pt.PARTITION_ID = (
    SELECT PARTITION_ID
    FROM NORTHI_LOADER_SETTINGS
    WHERE TABLE_NAME = 'CELLSTS_4G'
    AND ROWNUM = 1
)
ORDER BY pt.DTYPE;

-- Export örneği:
/*
PARTITION_ID=91 için DTYPE 1-14
*/

-- ----------------------------------------------------------------------------
-- 1.3: Loader Procedure'leri (Metadata)
-- ----------------------------------------------------------------------------
SELECT object_name, object_type, status
FROM USER_OBJECTS
WHERE object_name LIKE 'P_CELLSTS_4G_%'
  AND object_type = 'PROCEDURE'
ORDER BY object_name;

-- DDL Export:
/*
SELECT DBMS_METADATA.GET_DDL('PROCEDURE', 'P_CELLSTS_4G_CELL') FROM DUAL;
SELECT DBMS_METADATA.GET_DDL('PROCEDURE', 'P_CELLSTS_4G_ENODEB') FROM DUAL;
...
*/

-- ============================================================================
-- PART 2: REFERANS TABLOLARI
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 2.1: LIST_ENODEB_CELL (Örnek cell'ler)
-- ----------------------------------------------------------------------------

-- Tüm cell'ler yerine örnek seçim (100 ENODEB)
SELECT *
FROM LIST_ENODEB_CELL
WHERE ENODEB_ID IN (
    SELECT ENODEB_ID
    FROM (
        SELECT DISTINCT ENODEB_ID
        FROM LIST_ENODEB_CELL
        WHERE ROWNUM <= 100
    )
);

-- Veya belirli bölgeler:
SELECT *
FROM LIST_ENODEB_CELL
WHERE CITY_NAME IN ('İSTANBUL', 'ANKARA', 'İZMİR')
  AND ROWNUM <= 500;

-- ============================================================================
-- PART 3: CELLSTS_4G DATA (ÖRNEKLENMİŞ)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 3.1: Belirli tarih aralığı - TÜM DTYPE'lar
-- ----------------------------------------------------------------------------

-- Örnek: Son 2 günlük data
SELECT *
FROM CELLSTS_4G
WHERE FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE);

-- Kayıt sayısı kontrolü:
SELECT
    TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD') AS data_date,
    DTYPE,
    COUNT(*) AS row_count,
    ROUND(SUM(LENGTH(NETWORK_ID || NVL(TO_CHAR(CELL_ID),'')))/1024/1024, 2) AS approx_mb
FROM CELLSTS_4G
WHERE FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE)
GROUP BY TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD'), DTYPE
ORDER BY 1, 2;

-- ----------------------------------------------------------------------------
-- 3.2: Belirli saatler için örnekleme
-- ----------------------------------------------------------------------------

-- 2 gün, günde 4 saat (sabah, öğle, akşam, gece)
SELECT *
FROM CELLSTS_4G
WHERE FRAGMENT_DATE IN (
    -- Dün
    TRUNC(SYSDATE-1) + 6/24,   -- 06:00
    TRUNC(SYSDATE-1) + 12/24,  -- 12:00
    TRUNC(SYSDATE-1) + 18/24,  -- 18:00
    TRUNC(SYSDATE-1) + 23/24,  -- 23:00
    -- Bugün
    TRUNC(SYSDATE) + 6/24,     -- 06:00
    TRUNC(SYSDATE) + 12/24,    -- 12:00
    TRUNC(SYSDATE) + 18/24,    -- 18:00
    TRUNC(SYSDATE) + 23/24     -- 23:00
);

-- ----------------------------------------------------------------------------
-- 3.3: Belirli ENODEB'ler için örnekleme (küçük dataset)
-- ----------------------------------------------------------------------------

-- DTYPE=1 (raw) için örnek 50 ENODEB
WITH sample_enodebs AS (
    SELECT DISTINCT ENODEB_ID
    FROM CELLSTS_4G
    WHERE DTYPE = 1
      AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
      AND ROWNUM <= 50
)
SELECT c.*
FROM CELLSTS_4G c
WHERE c.ENODEB_ID IN (SELECT ENODEB_ID FROM sample_enodebs)
  AND c.FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND c.FRAGMENT_DATE < TRUNC(SYSDATE);

-- Veri miktarı tahmini:
WITH sample_enodebs AS (
    SELECT DISTINCT ENODEB_ID
    FROM CELLSTS_4G
    WHERE DTYPE = 1
      AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
      AND ROWNUM <= 50
)
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT ENODEB_ID) AS enodeb_count,
    COUNT(DISTINCT FRAGMENT_DATE) AS hour_count,
    COUNT(DISTINCT DTYPE) AS dtype_count
FROM CELLSTS_4G c
WHERE c.ENODEB_ID IN (SELECT ENODEB_ID FROM sample_enodebs)
  AND c.FRAGMENT_DATE >= TRUNC(SYSDATE - 2);

-- ----------------------------------------------------------------------------
-- 3.4: Sadece DTYPE=1 (Raw data) - Aggregate'leri test'te üretiriz
-- ----------------------------------------------------------------------------

-- Sadece DTYPE=1 (en optimize seçenek)
SELECT *
FROM CELLSTS_4G
WHERE DTYPE = 1
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE);

-- Boyut kontrolü:
SELECT
    TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD HH24') AS data_hour,
    COUNT(*) AS cell_count,
    COUNT(DISTINCT ENODEB_ID) AS enodeb_count
FROM CELLSTS_4G
WHERE DTYPE = 1
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE)
GROUP BY TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD HH24')
ORDER BY 1;

-- ============================================================================
-- PART 4: PARSER_SQLLDR_LOGS (İlgili kayıtlar)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 4.1: CELLSTS_4G için parser logları
-- ----------------------------------------------------------------------------

SELECT *
FROM PARSER_SQLLDR_LOGS
WHERE TABLE_NAME = 'CELLSTS_4G'
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE);

-- Detaylı kontrol:
SELECT
    TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD HH24') AS data_hour,
    PARSER_STATE,
    LOADER_STATE,
    COUNT(*) AS log_count
FROM PARSER_SQLLDR_LOGS
WHERE TABLE_NAME = 'CELLSTS_4G'
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
GROUP BY TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD HH24'), PARSER_STATE, LOADER_STATE
ORDER BY 1, 2, 3;

-- ============================================================================
-- PART 5: NORTHI_LOADER_PROCESS (İş kayıtları)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 5.1: CELLSTS_4G için işlem kayıtları
-- ----------------------------------------------------------------------------

SELECT *
FROM NORTHI_LOADER_PROCESS
WHERE TABLE_NAME = 'CELLSTS_4G'
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE)
ORDER BY FRAGMENT_DATE, DTYPE;

-- DTYPE bazında özet:
SELECT
    TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD') AS data_date,
    DTYPE,
    STATE,
    COUNT(*) AS process_count,
    MIN(START_DATE) AS first_start,
    MAX(END_DATE) AS last_end
FROM NORTHI_LOADER_PROCESS
WHERE TABLE_NAME = 'CELLSTS_4G'
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
GROUP BY TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD'), DTYPE, STATE
ORDER BY 1, 2, 3;

-- ============================================================================
-- PART 6: EXPORT/IMPORT KOMPLİT SCRIPT
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 6.1: Oracle Data Pump Export (FULL)
-- ----------------------------------------------------------------------------

/*
-- Komut satırından çalıştır:

expdp user/pass@PROD directory=DATA_PUMP_DIR dumpfile=cellsts_test_%U.dmp \
  logfile=cellsts_test_export.log \
  schemas=NORTHI_DATA,NORTHI_LOADER \
  tables=NORTHI_DATA.CELLSTS_4G,NORTHI_DATA.LIST_ENODEB_CELL \
  query=NORTHI_DATA.CELLSTS_4G:\"WHERE FRAGMENT_DATE >= TRUNC\(SYSDATE - 2\) AND FRAGMENT_DATE < TRUNC\(SYSDATE\)\" \
  query=NORTHI_DATA.LIST_ENODEB_CELL:\"WHERE ROWNUM <= 500\" \
  parallel=4 \
  compression=ALL
*/

-- ----------------------------------------------------------------------------
-- 6.2: Oracle Data Pump Import (TEST DB'ye)
-- ----------------------------------------------------------------------------

/*
-- Test DB'de çalıştır:

impdp user/pass@TEST directory=DATA_PUMP_DIR dumpfile=cellsts_test_%U.dmp \
  logfile=cellsts_test_import.log \
  table_exists_action=APPEND \
  parallel=4
*/

-- ----------------------------------------------------------------------------
-- 6.3: SQL*Loader Format (CSV Export)
-- ----------------------------------------------------------------------------

-- CSV dosyası oluşturma
SET COLSEP ','
SET PAGESIZE 0
SET TRIMSPOOL ON
SET HEADSEP OFF
SET LINESIZE 32000
SET FEEDBACK OFF

SPOOL cellsts_4g_dtype1.csv

SELECT
    FRAGMENT_DATE,
    DTYPE,
    ENODEB_ID,
    CELL_ID,
    NETWORK_ID,
    -- Diğer kolonlar...
    KPI_VALUE1,
    KPI_VALUE2
    -- vb.
FROM CELLSTS_4G
WHERE DTYPE = 1
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE);

SPOOL OFF

-- ============================================================================
-- PART 7: KÜÇÜK TEST DATASET (HIZLI TEST İÇİN)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 7.1: Minimal test seti - 1 saat, 10 ENODEB
-- ----------------------------------------------------------------------------

-- DTYPE=1 için minimal örnek
WITH sample_data AS (
    SELECT *
    FROM CELLSTS_4G
    WHERE DTYPE = 1
      AND FRAGMENT_DATE = TRUNC(SYSDATE-1) + 14/24  -- Dün saat 14:00
      AND ENODEB_ID IN (
          SELECT ENODEB_ID FROM (
              SELECT DISTINCT ENODEB_ID
              FROM CELLSTS_4G
              WHERE DTYPE = 1
                AND FRAGMENT_DATE = TRUNC(SYSDATE-1) + 14/24
              ORDER BY DBMS_RANDOM.VALUE
          ) WHERE ROWNUM <= 10
      )
)
SELECT * FROM sample_data;

-- Kayıt sayısı:
SELECT COUNT(*) AS row_count
FROM CELLSTS_4G
WHERE DTYPE = 1
  AND FRAGMENT_DATE = TRUNC(SYSDATE-1) + 14/24
  AND ENODEB_ID IN (
      SELECT ENODEB_ID FROM (
          SELECT DISTINCT ENODEB_ID
          FROM CELLSTS_4G
          WHERE DTYPE = 1
            AND FRAGMENT_DATE = TRUNC(SYSDATE-1) + 14/24
          ORDER BY DBMS_RANDOM.VALUE
      ) WHERE ROWNUM <= 10
  );

-- ============================================================================
-- PART 8: INSERT SCRIPTLERI (TEST DB için)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 8.1: Direct INSERT (küçük datalar için)
-- ----------------------------------------------------------------------------

-- PROD'dan çek, TEST'e insert et
INSERT /*+ APPEND */ INTO TEST_DB.CELLSTS_4G
SELECT *
FROM PROD_DB.CELLSTS_4G@PROD_LINK
WHERE DTYPE = 1
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE);

COMMIT;

-- ----------------------------------------------------------------------------
-- 8.2: Partition Exchange (hızlı yöntem)
-- ----------------------------------------------------------------------------

-- Geçici tablo oluştur
CREATE TABLE CELLSTS_4G_STAGING
AS SELECT * FROM CELLSTS_4G WHERE 1=0;

-- PROD'dan staging'e yükle
INSERT /*+ APPEND PARALLEL(8) */ INTO CELLSTS_4G_STAGING
SELECT *
FROM CELLSTS_4G@PROD_LINK
WHERE FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE);

-- Partition exchange (eğer partition yapısı uygunsa)
-- ALTER TABLE CELLSTS_4G
-- EXCHANGE PARTITION ... WITH TABLE CELLSTS_4G_STAGING;

-- ============================================================================
-- PART 9: DATA VALIDATION SCRIPTLERI
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 9.1: PROD vs TEST karşılaştırma
-- ----------------------------------------------------------------------------

-- PROD kayıt sayıları
SELECT
    'PROD' AS source,
    TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD HH24') AS data_hour,
    DTYPE,
    COUNT(*) AS row_count
FROM PROD_DB.CELLSTS_4G@PROD_LINK
WHERE FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE)
GROUP BY TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD HH24'), DTYPE

UNION ALL

-- TEST kayıt sayıları
SELECT
    'TEST' AS source,
    TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD HH24') AS data_hour,
    DTYPE,
    COUNT(*) AS row_count
FROM TEST_DB.CELLSTS_4G
WHERE FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE)
GROUP BY TO_CHAR(FRAGMENT_DATE, 'YYYY-MM-DD HH24'), DTYPE

ORDER BY 2, 3, 1;

-- ----------------------------------------------------------------------------
-- 9.2: Referans tablo kontrolü
-- ----------------------------------------------------------------------------

-- LIST_ENODEB_CELL kontrolü
SELECT
    'PROD' AS source,
    COUNT(*) AS total_cells,
    COUNT(DISTINCT ENODEB_ID) AS enodeb_count,
    COUNT(DISTINCT CITY_NAME) AS city_count
FROM PROD_DB.LIST_ENODEB_CELL@PROD_LINK

UNION ALL

SELECT
    'TEST' AS source,
    COUNT(*) AS total_cells,
    COUNT(DISTINCT ENODEB_ID) AS enodeb_count,
    COUNT(DISTINCT CITY_NAME) AS city_count
FROM TEST_DB.LIST_ENODEB_CELL;

-- ============================================================================
-- PART 10: ÖNERİLEN EXPORT STRATEJİSİ
-- ============================================================================

/*
SENARYO 1: TAM FONKSİYONEL TEST (Önerilen)
==========================================
- DTYPE=1 datası: Son 2 gün, tüm ENODEB'ler
- DTYPE 2-14: Test ortamında üretilecek
- Boyut: ~2-5 GB (saatlik data boyutuna göre)
- Süre: Export ~30 dk, Import ~20 dk

Adımlar:
1. NORTHI_LOADER_SETTINGS → Tam kopya (CELLSTS_4G)
2. NORTHI_PARTITION_TYPE → Tam kopya (PARTITION_ID=91)
3. LIST_ENODEB_CELL → Tam kopya
4. CELLSTS_4G → Sadece DTYPE=1, son 2 gün
5. PARSER_SQLLDR_LOGS → İlgili kayıtlar
6. Procedure'ler → DDL export


SENARYO 2: HIZLI TEST (Minimal)
================================
- DTYPE=1 datası: 1 gün, 4 saat örnek
- Boyut: ~500 MB - 1 GB
- Süre: Export ~10 dk, Import ~5 dk

Adımlar:
1. Metadata tabloları (aynı)
2. CELLSTS_4G → DTYPE=1, belirli 4 saat
3. LIST_ENODEB_CELL → İlgili ENODEB'ler


SENARYO 3: PERFORMANS TESTI (Örneklenmiş)
=========================================
- DTYPE=1 datası: 50 ENODEB, son 2 gün
- Küçük ama gerçekçi dataset
- Boyut: ~100-200 MB
- Süre: Export ~5 dk, Import ~3 dk

Adımlar:
1. Metadata tabloları (aynı)
2. 50 ENODEB seç (random veya belirli bölgeler)
3. CELLSTS_4G → Sadece bu 50 ENODEB, DTYPE=1
4. LIST_ENODEB_CELL → Sadece bu 50 ENODEB
*/

-- ============================================================================
-- ÖRNEK: TAM EXPORT SCRIPTI (SENARYO 1)
-- ============================================================================

-- Step 1: Boyut tahmini
SELECT
    'CELLSTS_4G DTYPE=1' AS table_name,
    COUNT(*) AS row_count,
    ROUND(SUM(VSIZE(NETWORK_ID))/1024/1024, 2) AS approx_mb
FROM CELLSTS_4G
WHERE DTYPE = 1
  AND FRAGMENT_DATE >= TRUNC(SYSDATE - 2)
  AND FRAGMENT_DATE < TRUNC(SYSDATE);

-- Step 2: Export query dosyası oluştur
SPOOL export_queries.par
SET PAGESIZE 0
SET FEEDBACK OFF

SELECT 'directory=DATA_PUMP_DIR' FROM DUAL;
SELECT 'dumpfile=cellsts_test_%U.dmp' FROM DUAL;
SELECT 'logfile=cellsts_test.log' FROM DUAL;
SELECT 'parallel=4' FROM DUAL;
SELECT 'compression=ALL' FROM DUAL;
SELECT 'tables=NORTHI_DATA.CELLSTS_4G,NORTHI_DATA.LIST_ENODEB_CELL,NORTHI_LOADER_SETTINGS,NORTHI_PARTITION_TYPE,PARSER_SQLLDR_LOGS' FROM DUAL;
SELECT 'query=NORTHI_DATA.CELLSTS_4G:"WHERE DTYPE=1 AND FRAGMENT_DATE>=TRUNC(SYSDATE-2) AND FRAGMENT_DATE<TRUNC(SYSDATE)"' FROM DUAL;
SELECT 'query=PARSER_SQLLDR_LOGS:"WHERE TABLE_NAME=''CELLSTS_4G'' AND FRAGMENT_DATE>=TRUNC(SYSDATE-2)"' FROM DUAL;

SPOOL OFF

-- Step 3: Export komutunu çalıştır
-- expdp user/pass@PROD parfile=export_queries.par
