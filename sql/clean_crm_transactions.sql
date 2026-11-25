
/*****************************************************************************************
Author: Ismail Hachouni
Project: Messy CRM & E-Commerce Data Cleanup
Target Environment: Google BigQuery
Description: 
  This script executes an end-to-end data quality pipeline. It ingests raw,
  unstructured CRM transactions, audits integrity issues, standardizes regions,cleans and validates emails
  formats international phone numbers, and flags transaction anomalies.
****************************************************************************************/

-- ======================================================================================
-- STEP 1: INITIAL EXTRACTION & AUDIT
-- Purpose: Inspect row counts, columns, and Check for structural schema and column types
-- =======================================================================================
SELECT COUNT(*) AS total_rows
FROM `durable-boulder-507309-q2.customer_clean_staging.raw_crm_transactions` ;

SELECT column_name, data_type
FROM  `durable-boulder-507309-q2.customer_clean_staging.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'raw_crm_transactions';
  

-- =====================================================================
-- SAVE FINAL OUTPUT AS A PERMANENT TABLE
-- =====================================================================
CREATE OR REPLACE TABLE `durable-boulder-507309-q2.customer_clean_staging.cleaned_crm_transactions` AS

-- =====================================================================
-- STEP 2: MULTI-STAGE CLEANING & CROSS-VALIDATION PIPELINE
-- =====================================================================
WITH Cleaned_base AS (
-- Trim leading/trailing whitespace and standardize customer id to Proper Case
SELECT  
TRIM(customer_id) AS customer_id,
-- Standardize customer name: Handle 'N/A' null values, strip extra whitespace, and apply proper Title Case
COALESCE(INITCAP(NULLIF(UPPER(TRIM(full_name)),'N/A' )),'Unknown Customer')AS full_name,
email,
phone_number,
order_date,
region_state,
revenue_amount,
FROM `durable-boulder-507309-q2.customer_clean_staging.raw_crm_transactions`),
Transformed_Attributes AS (
SELECT 
customer_id,
full_name,
email AS raw_email,
-- Email validation logic: Categorize records into valid, missing format, or test/dummy entries
CASE
WHEN email IS NULL OR TRIM(email) = '' THEN 'Invalid: Missing'
WHEN LOWER(TRIM(email)) NOT LIKE '%@%.%' 
OR LOWER(TRIM(email)) LIKE '% %' THEN 'Invalid: Missing Format'
WHEN REGEXP_CONTAINS(
LOWER(TRIM(email)), 
r'(test|unknown|invalid|dummy|fake|noreply|@domain\.com|@example\.com|@sample\.com)'
) THEN 'Invalid: Test/Dummy'
ELSE 'Valid Email'
END AS email_validation_status,
--- Email sanitization and nullification: Replace invalid, dummy, or malformed emails with NULL to protect downstream analytical integrity
CASE 
WHEN email NOT LIKE '%@%'
OR email NOT LIKE '%.%'
OR  LOWER(TRIM(email)) LIKE '%test%' 
OR LOWER(TRIM(email)) LIKE  '%unknown%' 
OR  LOWER(TRIM(email)) LIKE '%invalid%'
THEN NULL 
ELSE LOWER(TRIM(email))
END AS Cleaned_email,
phone_number,
order_date,
region_state,
revenue_amount,

FROM Cleaned_base),

extracted_phone_digits_and_country_market AS(
SELECT
customer_id,
full_name,
raw_email,
email_validation_status,
Cleaned_email,
-- Robust multi-format date parser handling various layout styles
 COALESCE(
SAFE.PARSE_DATE('%Y-%m-%d', TRIM(order_date)),
SAFE.PARSE_DATE('%m/%d/%Y', TRIM(order_date)),
SAFE.PARSE_DATE('%Y/%m/%d', TRIM(order_date)),
SAFE.PARSE_DATE('%d-%m-%Y', TRIM(order_date)),
SAFE.PARSE_DATE('%d/%m/%Y', TRIM(order_date))
) AS parsed_order_date,
-- Preserve original phone number for audit tracking
phone_number AS original_phone_number,
 -- Extract clean digit string for phone validation
REGEXP_REPLACE(TRIM(phone_number), r'[^0-9]', '') AS digits_only,
  
-- Detect Country Market based on phone prefix and format patterns
 CASE 
 WHEN  phone_number LIKE '+212%' OR  phone_number LIKE '06%' OR  phone_number LIKE '07%' THEN 'Morocco'
 WHEN  phone_number LIKE '+1%' THEN 'North America'
 WHEN phone_number LIKE '+44%' THEN 'United Kingdom'
 ELSE 'Other / International'
 END AS country_market,

order_date,
-- Retain raw region input for regional auditing
region_state AS raw_region,
revenue_amount,
FROM Transformed_Attributes),




Standardized_Phones_And_Regions AS(
SELECT
customer_id,
full_name,
raw_email,
email_validation_status,
Cleaned_email,
original_phone_number,
parsed_order_date,
digits_only,
country_market,
-- Format standard international phone numbers
CASE
WHEN country_market = 'Morocco' AND digits_only LIKE '06%' THEN CONCAT('+212 ', SUBSTR(digits_only, 2, 9)) WHEN country_market = 'Morocco' AND digits_only LIKE '07%' THEN CONCAT('+212 ', SUBSTR(digits_only, 2, 9))
WHEN country_market = 'North America' THEN CONCAT('+1 ', REGEXP_REPLACE(digits_only, r'^1', ''))
WHEN country_market = 'United Kingdom' THEN CONCAT('+44 ', SUBSTR(digits_only, 3))
ELSE CONCAT('+', digits_only)
END AS standardized_phone,
-- Flag test numbers and invalid phone lengths
CASE
WHEN country_market = 'North America'
AND REGEXP_REPLACE(original_phone_number, r'[^0-9]', '') LIKE '%555%'
THEN 'Test_Or_Dummy_Number'
 WHEN (
(country_market = 'Morocco' AND (
 (LENGTH(REGEXP_REPLACE(original_phone_number, r'[^0-9]', '')) = 12 AND LEFT(REGEXP_REPLACE(original_phone_number, r'[^0-9]', ''), 4) IN ('2125', '2126', '2127'))
OR (LENGTH(REGEXP_REPLACE(original_phone_number, r'[^0-9]', '')) = 10 AND LEFT(REGEXP_REPLACE(original_phone_number, r'[^0-9]', ''), 2) IN ('05', '06', '07'))
OR (LENGTH(REGEXP_REPLACE(original_phone_number, r'[^0-9]', '')) = 9  AND LEFT(REGEXP_REPLACE(original_phone_number, r'[^0-9]', ''), 1) IN ('5', '6', '7'))
))
OR (country_market = 'North America' AND (
(LENGTH(REGEXP_REPLACE(original_phone_number, r'[^0-9]', '')) = 11 AND LEFT(REGEXP_REPLACE(original_phone_number, r'[^0-9]', ''), 1) = '1')
OR LENGTH(REGEXP_REPLACE(original_phone_number, r'[^0-9]', '')) = 10
))
OR (country_market = 'United Kingdom'
 AND LENGTH(REGEXP_REPLACE(original_phone_number, r'[^0-9]', '')) = 12
 AND LEFT(REGEXP_REPLACE(original_phone_number, r'[^0-9]', ''), 2) = '44')
  )
THEN 'VALID'
 ELSE 'Invalid_Prefix_Or_Format'
END AS phone_validation_status,
-- Standardize state and region text
CASE
WHEN LOWER(raw_region) IN ('ny', 'new york') THEN 'New York'
WHEN LOWER(raw_region) IN ('ca', 'calfornia', 'california') THEN 'California'
WHEN LOWER(raw_region) = 'texas' THEN 'Texas'
WHEN LOWER(raw_region) IN ('london') THEN 'Greater London'
WHEN LOWER(raw_region) IN ('paris') THEN 'Île-de-France'
WHEN LOWER(raw_region) LIKE'marrakesh'THEN 'Marrakech-Safi'
WHEN LOWER(raw_region) LIKE '%casablanca%' THEN 'Casablanca-Settat'
WHEN LOWER(raw_region) LIKE '%rabat%' THEN 'Rabat-Sale-Kenitra'
WHEN LOWER(raw_region) LIKE '%tangier%' THEN 'Tangier-Tetouan-Al Hoceima'
ELSE INITCAP(raw_region)
END AS standardized_region,
-- Retain raw revenue amount for financial auditing and transformation
revenue_amount AS raw_revenue
FROM extracted_phone_digits_and_country_market),

revenue_standardized AS (
SELECT
customer_id,
full_name,
raw_revenue,
raw_email,
email_validation_status,
Cleaned_email,
original_phone_number,
digits_only,
country_market,
standardized_phone,
phone_validation_status,
parsed_order_date,
standardized_region,
-- Clean numeric revenue, strip non-numeric symbols, convert currencies based on symbols or text codes, and handle defaults
ROUND(COALESCE(SAFE_CAST(REGEXP_REPLACE(raw_revenue, r'[^0-9.-]', '') AS FLOAT64) * CASE 
-- Check for Moroccan Dirham (MAD or Moroccan context)
WHEN UPPER(raw_revenue) LIKE '%MAD%' THEN 0.1018329938900204
-- Check for Euro symbols or EUR code
WHEN UPPER(raw_revenue) LIKE '%EUR%' OR raw_revenue LIKE '%€%' THEN 1.1177
-- Check for British Pound symbols or GBP code
WHEN UPPER(raw_revenue) LIKE '%GBP%' OR raw_revenue LIKE '%£%' THEN 1.2800
-- Check for Dollar symbols or USD code (defaults multiplier to 1.0)
WHEN UPPER(raw_revenue) LIKE '%USD%' OR raw_revenue LIKE '%$%' THEN 1.0
ELSE 1
END,
0.0), 2) AS revenue_amount_usd,

 -- Classify transaction type (detecting refunds/negative amounts)
CASE 
WHEN SAFE_CAST(REPLACE(REPLACE(REGEXP_REPLACE(raw_revenue, r'[^0-9.-]', ''), "$", ""), "USD", "")  AS FLOAT64) < 0 THEN 'Refund / Negative'
WHEN raw_revenue IS NULL OR UPPER(raw_revenue) IN ('N/A', 'NULL', '') THEN 'Missing Revenue'
ELSE 'Standard Sale'
END AS transaction_status
FROM Standardized_Phones_And_Regions),


-- Insert your targeted filter/quarantine CTE right here with a comma separating them:
 Target_Vector_Quarantine_And_Conflict AS (
SELECT *
FROM revenue_standardized
WHERE 
-- Sandbox & Test Vector Quarantine (CUST-004,CUST-006, CUST-007, CUST-016)
customer_id NOT IN ('CUST-004', 'CUST-007', 'CUST-016', 'CUST-006')
      
 -- Corrupted Payload Isolation (CUST-011)
AND NOT (customer_id = 'CUST-011' )),

--Assign row numbers to keep the latest transaction per customer/date/amount group
deduplicated_transactions AS (
SELECT *,
ROW_NUMBER() OVER (
-- Strict partition to force-collapse CUST-010 duplicates regardless of minor timestamp variations
PARTITION BY customer_id 
-- Order by the most recent date to keep the latest valid record
ORDER BY parsed_order_date ASC, revenue_amount_usd ASC
) AS row_num
 FROM Target_Vector_Quarantine_And_Conflict
)
-- =====================================================================
-- STEP 3: FINAL DEDUPLICATION AND CROSS-VALIDATION AUDIT SUMMARY
-- =====================================================================
SELECT 
customer_id,
full_name,
Cleaned_email,
email_validation_status,
standardized_phone,
country_market,
phone_validation_status,
parsed_order_date,
standardized_region,
revenue_amount_usd,
transaction_status,


  -- Cross-validation flag detecting market vs region contradictions
CASE
WHEN country_market = 'Morocco' AND standardized_region NOT IN ('Marrakech-Safi', 'Casablanca-Settat', 'Rabat-Sale-Kenitra', 'Tangier-Tetouan-Al Hoceima') THEN 'Warning: Moroccan Market with Non-Local Region'
WHEN country_market = 'North America' AND standardized_region NOT IN ('New York', 'California', 'Texas') THEN 'Warning: NA Market with Non-US Region'
WHEN country_market = 'United Kingdom' AND standardized_region NOT IN ('Greater London') 
THEN 'Warning: UK Market with Non-UK Region'
WHEN country_market = 'France' AND standardized_region NOT IN ('Île-de-France') 
THEN 'Warning: France Market with Non-French Region'
ELSE 'Aligned'
END AS market_region_cross_check
FROM  deduplicated_transactions WHERE row_num = 1
 ORDER BY customer_id asc;
