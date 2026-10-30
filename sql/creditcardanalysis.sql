--#1. Check the table and row count

SELECT
    TABLE_SCHEMA,
    TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;

SELECT
    s.name AS SchemaName,
    t.name AS TableName,
    SUM(p.rows) AS TotalRows
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
    ON t.schema_id = s.schema_id
INNER JOIN sys.partitions AS p
    ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
GROUP BY
    s.name,
    t.name
ORDER BY
    t.name;

--#2. Create a typed view

USE [credit card analysis];
GO

CREATE OR ALTER VIEW dbo.v_credit_card_transactions_clean
AS
SELECT
    TRY_CONVERT(bigint, NULLIF(transaction_id, '')) AS transaction_id,
    TRY_CONVERT(datetime2, NULLIF(transaction_datetime, '')) AS transaction_datetime,
    NULLIF(LTRIM(RTRIM(merchant)), '') AS merchant,
    NULLIF(LTRIM(RTRIM(category)), '') AS category,
    TRY_CONVERT(decimal(18,2), NULLIF(amount, '')) AS amount,
    NULLIF(LTRIM(RTRIM(gender)), '') AS gender,
    NULLIF(LTRIM(RTRIM(city)), '') AS city,
    NULLIF(LTRIM(RTRIM(state)), '') AS state,
    TRY_CONVERT(int, NULLIF(zip_code, '')) AS zip_code,
    TRY_CONVERT(float, NULLIF(customer_latitude, '')) AS customer_latitude,
    TRY_CONVERT(float, NULLIF(customer_longitude, '')) AS customer_longitude,
    TRY_CONVERT(bigint, NULLIF(city_population, '')) AS city_population,
    NULLIF(LTRIM(RTRIM(job)), '') AS job,
    TRY_CONVERT(int, NULLIF(customer_age, '')) AS customer_age,
    TRY_CONVERT(bigint, NULLIF(transaction_unix_time, '')) AS transaction_unix_time,
    TRY_CONVERT(float, NULLIF(merchant_latitude, '')) AS merchant_latitude,
    TRY_CONVERT(float, NULLIF(merchant_longitude, '')) AS merchant_longitude,
    TRY_CONVERT(int, NULLIF(merchant_zip_code, '')) AS merchant_zip_code,
    TRY_CONVERT(int, NULLIF(is_fraud, '')) AS is_fraud
FROM dbo.credit_card_transactions_clean;
GO

--#3. Overall metrics and data quality

SELECT
    COUNT_BIG(*) AS transaction_count,
    SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_labeled_count,
    CAST(
        100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT_BIG(*), 0) AS decimal(8,3)
    ) AS fraud_rate_pct,
    CAST(AVG(amount) AS decimal(18,2)) AS average_transaction_amount,
    CAST(SUM(amount) AS decimal(20,2)) AS total_amount,
    MIN(transaction_datetime) AS first_transaction,
    MAX(transaction_datetime) AS last_transaction,
    SUM(CASE WHEN transaction_datetime IS NULL THEN 1 ELSE 0 END) AS invalid_or_missing_datetime,
    SUM(CASE WHEN amount IS NULL THEN 1 ELSE 0 END) AS invalid_or_missing_amount,
    SUM(CASE WHEN is_fraud IS NULL THEN 1 ELSE 0 END) AS invalid_or_missing_fraud_label
FROM dbo.v_credit_card_transactions_clean;
GO

--#4. Monthly transactions and spending trends

WITH monthly AS (
    SELECT
        DATEFROMPARTS(YEAR(transaction_datetime), MONTH(transaction_datetime), 1) AS month_start,
        COUNT_BIG(*) AS transaction_count,
        SUM(amount) AS total_spending,
        AVG(amount) AS average_transaction
    FROM dbo.v_credit_card_transactions_clean
    WHERE transaction_datetime IS NOT NULL
    GROUP BY YEAR(transaction_datetime), MONTH(transaction_datetime)
),
changes AS (
    SELECT *,
        LAG(transaction_count) OVER (ORDER BY month_start) AS previous_count,
        LAG(total_spending) OVER (ORDER BY month_start) AS previous_spending
    FROM monthly
)
SELECT
    CONVERT(char(7), month_start, 120) AS [month],
    transaction_count,
    CAST(total_spending AS decimal(20,2)) AS total_spending,
    CAST(average_transaction AS decimal(18,2)) AS average_transaction,
    CAST(100.0 * (transaction_count - previous_count)
         / NULLIF(previous_count, 0) AS decimal(10,2)) AS transaction_growth_pct,
    CAST(100.0 * (total_spending - previous_spending)
         / NULLIF(previous_spending, 0) AS decimal(10,2)) AS spending_growth_pct
FROM changes
ORDER BY month_start;
GO

--#5. Fraud label rate by category

SELECT
    DATEPART(hour, transaction_datetime) AS transaction_hour,
    COUNT_BIG(*) AS transaction_count,
    SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_labeled_count,
    CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END)
         / NULLIF(COUNT_BIG(*), 0) AS decimal(10,3)) AS fraud_rate_pct
FROM dbo.v_credit_card_transactions_clean
WHERE transaction_datetime IS NOT NULL
GROUP BY DATEPART(hour, transaction_datetime)
ORDER BY transaction_hour;
GO

--#6. Fraud-label rate by hour

SELECT
    DATEPART(hour, transaction_datetime) AS transaction_hour,
    COUNT_BIG(*) AS transaction_count,
    SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_labeled_count,
    CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END)
         / NULLIF(COUNT_BIG(*), 0) AS decimal(10,3)) AS fraud_rate_pct
FROM dbo.credit_card_transactions_clean
WHERE transaction_datetime IS NOT NULL
GROUP BY DATEPART(hour, transaction_datetime)
ORDER BY transaction_hour;
GO

--#7. Fraud-label rate by state

SELECT
    state,
    COUNT_BIG(*) AS transaction_count,
    SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_labeled_count,
    CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END)
         / NULLIF(COUNT_BIG(*), 0) AS decimal(10,3)) AS fraud_rate_pct
FROM dbo.v_credit_card_transactions_clean
GROUP BY state
HAVING COUNT_BIG(*) >= 1000
ORDER BY fraud_rate_pct DESC;
GO

--#8 Which categories generate the most spending

SELECT
    category,
    COUNT_BIG(*) AS transaction_count,
    CAST(SUM(TRY_CONVERT(decimal(18,2), amount)) AS decimal(20,2)) AS total_spending,
    CAST(AVG(TRY_CONVERT(decimal(18,2), amount)) AS decimal(18,2)) AS average_transaction
FROM dbo.credit_card_transactions_clean
GROUP BY category
ORDER BY total_spending DESC;

--#9. Which merchants have the most transactions and fraud labels

SELECT
    merchant,
    COUNT_BIG(*) AS transaction_count,
    CAST(SUM(TRY_CONVERT(decimal(18,2), amount)) AS decimal(20,2)) AS total_spending,
    SUM(CASE WHEN TRY_CONVERT(int, is_fraud) = 1 THEN 1 ELSE 0 END) AS fraud_labeled_count,
    CAST(
        100.0 * SUM(CASE WHEN TRY_CONVERT(int, is_fraud) = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT_BIG(*), 0) AS decimal(10,3)
    ) AS fraud_rate_pct
FROM dbo.credit_card_transactions_clean
GROUP BY merchant
HAVING COUNT_BIG(*) >= 100
ORDER BY fraud_rate_pct DESC;

--#10. What hours have the most activity and highest fraud-label rates? 

WITH transaction_hours AS (
    SELECT
        DATEPART(hour, TRY_CONVERT(datetime2, transaction_datetime)) AS transaction_hour,
        TRY_CONVERT(int, is_fraud) AS is_fraud
    FROM dbo.credit_card_transactions_clean
    WHERE TRY_CONVERT(datetime2, transaction_datetime) IS NOT NULL
)
SELECT
    transaction_hour,
    COUNT_BIG(*) AS transaction_count,
    SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_labeled_count,
    CAST(
        100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT_BIG(*), 0) AS decimal(10,3)
    ) AS fraud_rate_pct
FROM transaction_hours
GROUP BY transaction_hour
ORDER BY transaction_hour;

--#11. How do transaction volume and fraud labels vary by age group?

WITH age_groups AS (
    SELECT
        CASE
            WHEN TRY_CONVERT(int, customer_age) < 18 THEN 'Under 18'
            WHEN TRY_CONVERT(int, customer_age) BETWEEN 18 AND 25 THEN '18-25'
            WHEN TRY_CONVERT(int, customer_age) BETWEEN 26 AND 35 THEN '26-35'
            WHEN TRY_CONVERT(int, customer_age) BETWEEN 36 AND 45 THEN '36-45'
            WHEN TRY_CONVERT(int, customer_age) BETWEEN 46 AND 55 THEN '46-55'
            WHEN TRY_CONVERT(int, customer_age) BETWEEN 56 AND 65 THEN '56-65'
            WHEN TRY_CONVERT(int, customer_age) >= 66 THEN '66+'
            ELSE 'Unknown'
        END AS age_group,
        TRY_CONVERT(int, is_fraud) AS is_fraud
    FROM dbo.credit_card_transactions_clean
)
SELECT
    age_group,
    COUNT_BIG(*) AS transaction_count,
    SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_labeled_count,
    CAST(
        100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT_BIG(*), 0) AS decimal(10,3)
    ) AS fraud_rate_pct
FROM age_groups
GROUP BY age_group
ORDER BY age_group;

--#12. Which transactions are unusually large

SELECT TOP (20)
    transaction_id,
    transaction_datetime,
    merchant,
    category,
    amount,
    state,
    is_fraud
FROM dbo.credit_card_transactions_clean
WHERE TRY_CONVERT(decimal(18,2), amount) IS NOT NULL
ORDER BY TRY_CONVERT(decimal(18,2), amount) DESC;

--#13. Join each transaction to its category’s fraud rate(This shows each transaction alongside the fraud-label rate for its category).

WITH transactions AS (
    SELECT
        transaction_id,
        TRY_CONVERT(datetime2, transaction_datetime) AS transaction_datetime,
        merchant,
        category,
        TRY_CONVERT(decimal(18,2), amount) AS amount,
        TRY_CONVERT(int, is_fraud) AS is_fraud
    FROM dbo.credit_card_transactions_clean
),
category_summary AS (
    SELECT
        category,
        COUNT_BIG(*) AS category_transaction_count,
        SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS category_fraud_count,
        CAST(
            100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(10,3)
        ) AS category_fraud_rate_pct
    FROM transactions
    GROUP BY category
)
SELECT TOP (100)
    t.transaction_id,
    t.transaction_datetime,
    t.merchant,
    t.category,
    t.amount,
    t.is_fraud,
    c.category_transaction_count,
    c.category_fraud_rate_pct
FROM transactions AS t
LEFT JOIN category_summary AS c
    ON t.category = c.category
ORDER BY t.amount DESC;

--# 14. Join monthly spending to monthly fraud results(This combines two monthly summaries by matching their month).

WITH transactions AS (
    SELECT
        TRY_CONVERT(datetime2, transaction_datetime) AS transaction_datetime,
        TRY_CONVERT(decimal(18,2), amount) AS amount,
        TRY_CONVERT(int, is_fraud) AS is_fraud
    FROM dbo.credit_card_transactions_clean
),
monthly_spending AS (
    SELECT
        DATEFROMPARTS(YEAR(transaction_datetime), MONTH(transaction_datetime), 1) AS month_start,
        COUNT_BIG(*) AS transaction_count,
        SUM(amount) AS total_spending
    FROM transactions
    WHERE transaction_datetime IS NOT NULL
    GROUP BY DATEFROMPARTS(YEAR(transaction_datetime), MONTH(transaction_datetime), 1)
),
monthly_fraud AS (
    SELECT
        DATEFROMPARTS(YEAR(transaction_datetime), MONTH(transaction_datetime), 1) AS month_start,
        SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_labeled_count
    FROM transactions
    WHERE transaction_datetime IS NOT NULL
    GROUP BY DATEFROMPARTS(YEAR(transaction_datetime), MONTH(transaction_datetime), 1)
)
SELECT
    CONVERT(char(7), s.month_start, 120) AS [month],
    s.transaction_count,
    CAST(s.total_spending AS decimal(20,2)) AS total_spending,
    f.fraud_labeled_count,
    CAST(
        100.0 * f.fraud_labeled_count / NULLIF(s.transaction_count, 0)
        AS decimal(10,3)
    ) AS fraud_rate_pct
FROM monthly_spending AS s
INNER JOIN monthly_fraud AS f
    ON s.month_start = f.month_start
ORDER BY s.month_start;

--#15. Join transactions to merchant performance(This compares each high-value transaction with its merchant’s overall volume and fraud-label rate. The merchant summary excludes merchants with fewer than 100 transactions).

WITH transactions AS (
    SELECT
        transaction_id,
        transaction_datetime,
        merchant,
        category,
        TRY_CONVERT(decimal(18,2), amount) AS amount,
        TRY_CONVERT(int, is_fraud) AS is_fraud
    FROM dbo.credit_card_transactions_clean
),
merchant_summary AS (
    SELECT
        merchant,
        COUNT_BIG(*) AS merchant_transaction_count,
        SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS merchant_fraud_count,
        CAST(
            100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(10,3)
        ) AS merchant_fraud_rate_pct
    FROM transactions
    GROUP BY merchant
    HAVING COUNT_BIG(*) >= 100
)
SELECT TOP (100)
    t.transaction_id,
    t.transaction_datetime,
    t.merchant,
    t.category,
    t.amount,
    t.is_fraud,
    m.merchant_transaction_count,
    m.merchant_fraud_rate_pct
FROM transactions AS t
LEFT JOIN merchant_summary AS m
    ON t.merchant = m.merchant
ORDER BY t.amount DESC;