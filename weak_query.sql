-- Per Track-A CSP: the worst-first weak connections (out-of-range ONTs) for "आज ये ठीक करें".
-- Source: PROD_DB.PUBLIC.HOURLY_DEVICE_PING_INFLUX — the FRESH per-device optical feed
--   (has OPTICAL_AVG + DATE_IST, updated daily). The DBT copy we used before FROZE on
--   2026-07-03, which surfaced stale readings for churned/inactive ONTs (RCA: a CSP saw
--   SY053676, plan-expired + no data since Jul 2, shown as a live weak connection).
-- Weak      = 15-day avg device optical below -25 dBm.
-- ACTIVE    = device belongs to a current active customer (PUBLIC.ACTIVE_CUST) -- only show
--             the CSP connections for their active users, not churned/removed accounts.
-- Liveness  = device must also have reported in the last 3 days (HAVING MAX(date_ist)) -- so a
--             connection that has stopped sending (offline / dead) drops off automatically,
--             instead of showing its last historical reading as "live".
-- Identifier = DEVICE_ID (ONT serial on the router). No customer name/address -> no PII.
WITH cohort AS (   -- Track-A CSPs (OP<75 at month start) mapped to their partner_id
  SELECT s.csp_id, a.partner_id
  FROM (
    SELECT csp_id, t1_oor_rate AS op0,
           ROW_NUMBER() OVER (PARTITION BY csp_id ORDER BY snapshot_date ASC) AS rn
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
    WHERE _fivetran_active = TRUE AND snapshot_date >= DATE_TRUNC('month', CURRENT_DATE)
  ) s
  JOIN PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT a
    ON a.csp_id = s.csp_id AND a._fivetran_active = TRUE
  WHERE s.rn = 1 AND s.op0 < 75
),
dev AS (   -- 15-day avg optical per device: ACTIVE customers only + still reporting
  SELECT c.csp_id, p.device_id,
         AVG(p.optical_avg) AS opt
  FROM cohort c
  JOIN PROD_DB.PUBLIC.HOURLY_DEVICE_PING_INFLUX p
    ON p.partner_id = c.partner_id
   AND p.date_ist >= DATEADD(day, -15, CURRENT_DATE)
   AND p.optical_avg IS NOT NULL
  JOIN PROD_DB.PUBLIC.ACTIVE_CUST ac        -- active users only (not churned/removed)
    ON ac.device_id = p.device_id
  GROUP BY c.csp_id, p.device_id
  HAVING MAX(p.date_ist) >= DATEADD(day, -3, CURRENT_DATE)   -- and still pinging (live)
),
-- coarse locator per device: neighbourhood (2nd comma-segment) + pincode, most-recent row.
-- NO house number / name / phone -> keeps the public file free of identifying PII.
addr AS (
  SELECT device_id,
         NULLIF(TRIM(SPLIT_PART(TRY_PARSE_JSON(address):address::string, ',', 2)), '') AS locality,
         TRY_PARSE_JSON(address):pincode::string                                        AS pincode
  FROM PROD_DB.DBT.T_WG_CUSTOMER
  WHERE address IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY added_time DESC) = 1
),
ranked AS (
  SELECT d.csp_id, d.device_id, ROUND(d.opt, 0) AS dbm,
         -- null-safe join: locality shows even when pincode is missing (and vice-versa)
         ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(a.locality, a.pincode), ' · ') AS area,
         ROW_NUMBER() OVER (PARTITION BY d.csp_id ORDER BY d.opt ASC, d.device_id) AS rnk,
         COUNT_IF(d.opt < -25) OVER (PARTITION BY d.csp_id)           AS weak_n
  FROM dev d
  LEFT JOIN addr a ON a.device_id = d.device_id
)
SELECT csp_id,
       weak_n,
       ARRAY_AGG(OBJECT_CONSTRUCT('d', device_id, 'v', dbm, 'a', area))
         WITHIN GROUP (ORDER BY rnk) AS worst
FROM ranked
WHERE rnk <= 3 AND dbm < -25
GROUP BY csp_id, weak_n
ORDER BY csp_id
