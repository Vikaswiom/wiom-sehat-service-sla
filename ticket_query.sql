-- Per Track-B CSP: their still-open SERVICE tickets for "ये शिकायत समय से resolve करें".
-- Source: COMPLAINT_RESOLUTION_LEDGER (resolved_at IS NULL) + CONNECTIONS.service_address for area.
-- Locator = neighbourhood + city/pincode only (no house no / name / phone) -> no PII in the public file.
WITH cohort AS (   -- Track-B CSPs (OP>=75 at month start)
  SELECT csp_id FROM (
    SELECT csp_id, t1_oor_rate AS op0,
           ROW_NUMBER() OVER (PARTITION BY csp_id ORDER BY snapshot_date ASC) AS rn
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
    WHERE _fivetran_active = TRUE AND snapshot_date >= DATE_TRUNC('month', CURRENT_DATE)
  ) WHERE rn = 1 AND op0 >= 75
),
opn AS (   -- open SERVICE tickets, with a coarse area from the connection's service address
  SELECT c.csp_id, c.complaint_id,
         DATEDIFF(day, c.opened_at, CURRENT_TIMESTAMP) AS age_d,
         NULLIF(TRIM(SPLIT_PART(TRY_PARSE_JSON(cn.service_address):address::string, ',', 2)), '') AS locality,
         COALESCE(NULLIF(TRIM(TRY_PARSE_JSON(cn.service_address):city::string), ''),
                  TRY_PARSE_JSON(cn.service_address):pincode::string) AS place
  FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.COMPLAINT_RESOLUTION_LEDGER c
  JOIN cohort t ON t.csp_id = c.csp_id
  LEFT JOIN CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS cn
    ON cn.connection_id = c.connection_id AND cn._fivetran_active = TRUE
  WHERE c._fivetran_active = TRUE AND c.primary_class = 'SERVICE_ISSUE' AND c.resolved_at IS NULL
),
ranked AS (
  SELECT csp_id, age_d,
         -- null-safe join: drops NULL parts, so 'Kala Kunj' with no city/pincode still shows
         ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(locality, place), ' · ') AS area,
         ROW_NUMBER() OVER (PARTITION BY csp_id ORDER BY age_d DESC, complaint_id) AS rnk,  -- most overdue first, stable
         COUNT(*)     OVER (PARTITION BY csp_id)                    AS open_n
  FROM opn
)
SELECT csp_id,
       open_n,
       ARRAY_AGG(OBJECT_CONSTRUCT('a', area, 'g', age_d))
         WITHIN GROUP (ORDER BY rnk) AS tickets
FROM ranked
WHERE rnk <= 3
GROUP BY csp_id, open_n
ORDER BY csp_id
