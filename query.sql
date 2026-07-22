-- Sehat MG — per-CSP raw inputs for the app screen.
-- Both metrics are recomputed FROM SOURCE (not read off the snapshot), so the screen can
-- show each CSP the same numerator / denominator that their Rs.10,000 is graded on.
--
-- FORMULA — the one thing to not get wrong:
--   % Optical Power = OPTICAL_NUMERATOR / OPTICAL_DENOMINATOR   (share of IN-RANGE pings)
-- T1_OOR_RATE is an OK-rate despite its name. Proof: the service's own T1_BAND assigns
-- VG at 95-100 and GOOD at 90-95 — banding identically to T2_SPEED_OK_RATE, whose
-- direction is unambiguous. Reading it as "out of range" (100 - rate) inverts every CSP
-- and wrongly dumps 986 of 1,053 into Track A.
WITH snap AS (
  SELECT csp_id, snapshot_date, lookback_start, lookback_end, active_connection_count,
         t1_oor_rate, m3_tat_pass_rate,
         ROW_NUMBER() OVER (PARTITION BY csp_id ORDER BY snapshot_date DESC) AS rn
  FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
  WHERE _fivetran_active = TRUE
),
latest AS (SELECT * FROM snap WHERE rn = 1),

-- Track locks at month start, off that morning's Optical Power.
month_start AS (
  SELECT csp_id, t1_oor_rate AS op0,
         ROW_NUMBER() OVER (PARTITION BY csp_id ORDER BY snapshot_date ASC) AS rn
  FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
  WHERE _fivetran_active = TRUE
    AND snapshot_date >= DATE_TRUNC('month', CURRENT_DATE)
),
bench AS (SELECT csp_id, op0 FROM month_start WHERE rn = 1),

-- T1 · Optical Power, rolling 15 telemetry days
tel AS (
  SELECT csp_id,
         SUM(optical_numerator)   AS ok_pings,
         SUM(optical_denominator) AS all_pings
  FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.TELEMETRY_ROLLUP_RECORDS
  WHERE _fivetran_active = TRUE
    AND signal_date >= DATEADD(day, -15, CURRENT_DATE)
  GROUP BY csp_id
),

-- M3 · % resolved within the 4-hour TAT, over each CSP's OWN 60-day snapshot lookback
sla AS (
  SELECT l.csp_id,
         COUNT_IF(c.resolved_within_tat) AS sla_ok,
         COUNT(*)                        AS sla_tot
  FROM latest l
  JOIN PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.COMPLAINT_RESOLUTION_LEDGER c
    ON c.csp_id = l.csp_id
   AND c._fivetran_active = TRUE
   AND c.primary_class = 'SERVICE_ISSUE'
   AND c.opened_at >= l.lookback_start
   AND c.opened_at <  l.lookback_end
  GROUP BY l.csp_id
)

SELECT
  l.csp_id                      AS csp_id,
  l.active_connection_count     AS conns,
  t.ok_pings                    AS ok_pings,
  t.all_pings                   AS all_pings,
  s.sla_ok                      AS sla_ok,
  s.sla_tot                     AS sla_tot,
  ROUND(b.op0, 2)               AS op_month_start,
  CASE
    WHEN b.op0 IS NULL THEN 'U'
    WHEN b.op0 < 75    THEN 'A'
    ELSE                    'B'
  END                           AS track
FROM latest l
LEFT JOIN tel   t ON t.csp_id = l.csp_id
LEFT JOIN sla   s ON s.csp_id = l.csp_id
LEFT JOIN bench b ON b.csp_id = l.csp_id
ORDER BY l.csp_id
