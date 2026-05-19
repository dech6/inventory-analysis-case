-- ============================================================
-- INVENTORY ANALYSIS — PERISHABLE FROZEN GOODS
-- Analysis Period: March 11-17, 2026
-- Facilities: A (East Coast) | B (West Coast)
-- Tool: Oracle SQL Developer
-- ============================================================


-- ============================================================
-- TASK 1 — DATA CLEANING & VALIDATION
-- ============================================================

-- CHECK 1: NULL values in excursion_flag and excursion_temp_f
SELECT 
    lot_id,
    sku_id,
    facility,
    excursion_flag,
    excursion_temp_f
FROM inv_lots
WHERE excursion_flag IS NULL 
   OR excursion_temp_f IS NULL;

-- Findings:
-- LOT-B-ICS-002: excursion_flag = NULL — product integrity unknown
-- All lots with excursion_flag = FALSE have excursion_temp_f = NULL — expected behavior
-- Handling assumption: NULL excursion_flag treated as UNKNOWN, not as FALSE


-- CHECK 2: BOH exceeds qty_received (receiving/induction error)
SELECT 
    b.lot_id,
    l.sku_id,
    b.facility,
    b.boh_qty,
    l.qty_received,
    b.boh_qty - l.qty_received AS diferencia
FROM inv_boh_snapshot b
JOIN inv_lots l ON b.lot_id = l.lot_id
WHERE b.boh_qty > l.qty_received;

-- Findings:
-- LOT-B-SAL-001 (SalmonFillet-6oz, Facility B): BOH=620, received=500, diff=+120 units
-- Impossible to have more inventory than received — receiving or system error


-- CHECK 3: Partial fulfillment or scan failures
SELECT 
    order_line_id,
    lot_id,
    facility,
    qty_ordered,
    qty_fulfilled,
    qty_ordered - qty_fulfilled AS diferencia,
    lifecycle_status,
    notes
FROM inv_order_lines
WHERE qty_fulfilled <> qty_ordered
   OR qty_fulfilled IS NULL;

-- Findings:
-- OL-A-005: FrozenBerryMix-1lb, ordered 30, fulfilled 25 — partial fulfillment
-- OL-B-007: SalmonFillet-6oz, ordered 70, fulfilled 50 — partial fulfillment
-- Both in Carrier Hand-Off status — accounted for in reconciliation


-- CHECK 4: Referential integrity (orphan lot_ids)
SELECT 'order_lines' AS origen, lot_id 
FROM inv_order_lines
WHERE lot_id NOT IN (SELECT lot_id FROM inv_lots)
UNION ALL
SELECT 'boh_snapshot', lot_id 
FROM inv_boh_snapshot
WHERE lot_id NOT IN (SELECT lot_id FROM inv_lots);

-- Findings: 0 rows returned — no orphan lot_ids found, referential integrity intact


-- ============================================================
-- TASK 2 — EOW INVENTORY RECONCILIATION
-- ============================================================

-- Formula: Expected EOW = BOH - Units Dispatched
-- Variance = Expected EOW - Physical Count
-- Flag criteria: Variance > 5 units OR > 3%

SELECT 
    l.lot_id,
    l.sku_id,
    l.facility,
    b.boh_qty,
    NVL(SUM(o.qty_fulfilled), 0)                        AS total_dispatched,
    b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)            AS expected_eow,
    c.physical_qty,
    (b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) 
        - c.physical_qty                                AS variance_units,
    ROUND(
        ((b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) 
            - c.physical_qty) 
        / NULLIF(b.boh_qty, 0) * 100, 2)               AS variance_pct,
    CASE 
        WHEN ABS((b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) - c.physical_qty) > 5
          OR ABS(ROUND(((b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) - c.physical_qty) 
             / NULLIF(b.boh_qty, 0) * 100, 2)) > 3
        THEN 'REQUIRES INVESTIGATION'
        ELSE 'OK'
    END AS variance_flag
FROM inv_lots l
JOIN inv_boh_snapshot b 
    ON l.lot_id = b.lot_id AND l.facility = b.facility
JOIN inv_cycle_counts c 
    ON l.lot_id = c.lot_id AND l.facility = c.facility
LEFT JOIN inv_order_lines o 
    ON l.lot_id = o.lot_id AND l.facility = o.facility
WHERE b.boh_qty > 0
GROUP BY 
    l.lot_id, l.sku_id, l.facility, 
    b.boh_qty, c.physical_qty
ORDER BY 
    ABS((b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) 
        - c.physical_qty) DESC;

-- Findings (flagged lots):
-- LOT-A-ICS-001: 85 units variance, 18.48% — highest discrepancy
-- LOT-B-OSP-001: 60 units variance, 16.67%
-- LOT-B-SAL-001: 50 units variance, 8.06% — also has receiving error from Task 1
-- LOT-A-SAL-001: 30 units variance, 7.89%
-- LOT-A-BRY-001: 15 units variance, 4.84%


-- ============================================================
-- TASK 3 — FEFO COMPLIANCE ANALYSIS
-- ============================================================

-- FEFO = First Expired First Out
-- Rule: always ship the lot that expires soonest
-- Violation: a lot was picked while another available lot expired earlier

-- PART 1: Detail of FEFO violations
WITH dispatched_lots AS (
    -- Orders dispatched during the week with their expiration date
    SELECT 
        o.order_line_id,
        o.order_id,
        o.facility,
        o.sku_id,
        o.lot_id,
        o.qty_fulfilled,
        l.expiration_date
    FROM inv_order_lines o
    JOIN inv_lots l 
        ON o.lot_id = l.lot_id
),

available_lots AS (
    -- Lots available in the warehouse with BOH > 0
    SELECT 
        l.lot_id,
        l.sku_id,
        l.facility,
        l.expiration_date,
        b.boh_qty
    FROM inv_lots l
    JOIN inv_boh_snapshot b 
        ON l.lot_id = b.lot_id 
        AND l.facility = b.facility
    WHERE b.boh_qty > 0
),

fefo_violations AS (
    -- Cross dispatched vs available to find violations
    SELECT 
        d.order_line_id,
        d.order_id,
        d.facility,
        d.sku_id,
        d.lot_id                        AS dispatched_lot,
        d.expiration_date               AS dispatched_lot_expiry,
        a.lot_id                        AS lot_that_should_have_been_picked,
        a.expiration_date               AS correct_lot_expiry,
        a.expiration_date 
            - d.expiration_date         AS days_difference,
        d.qty_fulfilled                 AS units_in_violation
    FROM dispatched_lots d
    JOIN available_lots a
        ON d.sku_id = a.sku_id
        AND d.facility = a.facility
        AND d.lot_id <> a.lot_id
        AND a.expiration_date < d.expiration_date
)

SELECT *
FROM fefo_violations
ORDER BY facility, sku_id;


-- PART 2: Summary of FEFO violations by facility and SKU
WITH dispatched_lots AS (
    SELECT 
        o.order_line_id,
        o.order_id,
        o.facility,
        o.sku_id,
        o.lot_id,
        o.qty_fulfilled,
        l.expiration_date
    FROM inv_order_lines o
    JOIN inv_lots l ON o.lot_id = l.lot_id
),

available_lots AS (
    SELECT 
        l.lot_id,
        l.sku_id,
        l.facility,
        l.expiration_date,
        b.boh_qty
    FROM inv_lots l
    JOIN inv_boh_snapshot b 
        ON l.lot_id = b.lot_id 
        AND l.facility = b.facility
    WHERE b.boh_qty > 0
),

fefo_violations AS (
    SELECT 
        d.facility,
        d.sku_id,
        d.qty_fulfilled                 AS units_in_violation
    FROM dispatched_lots d
    JOIN available_lots a
        ON d.sku_id = a.sku_id
        AND d.facility = a.facility
        AND d.lot_id <> a.lot_id
        AND a.expiration_date < d.expiration_date
),

fefo_summary AS (
    SELECT 
        facility,
        sku_id,
        COUNT(*)                        AS total_violations,
        SUM(units_in_violation)         AS total_units_violated
    FROM fefo_violations
    GROUP BY facility, sku_id
),

total_dispatched AS (
    SELECT 
        facility,
        sku_id,
        SUM(qty_fulfilled)              AS total_dispatched
    FROM inv_order_lines
    GROUP BY facility, sku_id
)

SELECT 
    s.facility,
    s.sku_id,
    s.total_violations,
    s.total_units_violated,
    t.total_dispatched,
    ROUND(s.total_units_violated / t.total_dispatched * 100, 2) AS pct_of_total_dispatched
FROM fefo_summary s
JOIN total_dispatched t
    ON s.facility = t.facility
    AND s.sku_id = t.sku_id
ORDER BY pct_of_total_dispatched DESC;

-- Findings:
-- 5 violations found — one per SKU, both facilities
-- Worst case: OrganicSmoothiePack Facility B at 41.03%
-- Pattern is systematic — not isolated incidents


-- ============================================================
-- TASK 4 — TEMPERATURE BREACH IMPACT ASSESSMENT
-- ============================================================

WITH excursion_goods AS (
    -- Lots with confirmed temperature breach
    SELECT  
        l.lot_id,
        l.sku_id,
        l.facility,
        l.excursion_temp_f,
        s.storage_temp_f,
        ABS(l.excursion_temp_f) - ABS(s.storage_temp_f)    AS temperature_breach_f
    FROM inv_skus s
    JOIN inv_lots l ON l.sku_id = s.sku_id
    WHERE excursion_flag = 'true'
),

units_at_risk AS (
    -- Units shipped from excursion lots
    SELECT 
        eg.lot_id,
        eg.sku_id,
        eg.facility,
        eg.temperature_breach_f,
        SUM(ol.qty_fulfilled)                               AS units_at_risk
    FROM inv_order_lines ol
    JOIN excursion_goods eg ON ol.lot_id = eg.lot_id
    GROUP BY eg.lot_id, eg.sku_id, eg.facility, eg.temperature_breach_f
),

total_dispatched AS (
    -- Total dispatched per SKU for % calculation
    SELECT 
        sku_id,
        SUM(qty_fulfilled)                                  AS total_dispatched
    FROM inv_order_lines
    GROUP BY sku_id
),

cycle_variance AS (
    -- Inventory variance per lot for cross-reference
    SELECT 
        b.lot_id,
        b.facility,
        b.boh_qty,
        NVL(SUM(o.qty_fulfilled), 0)                        AS total_dispatched,
        b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)            AS expected_eow,
        c.physical_qty,
        (b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) 
            - c.physical_qty                                AS variance_units
    FROM inv_boh_snapshot b
    LEFT JOIN inv_order_lines o ON b.lot_id = o.lot_id
    JOIN inv_cycle_counts c 
        ON b.lot_id = c.lot_id 
        AND b.facility = c.facility
    GROUP BY b.lot_id, b.facility, b.boh_qty, c.physical_qty
)

SELECT 
    u.lot_id,
    u.sku_id,
    u.facility,
    u.temperature_breach_f,
    u.units_at_risk,
    t.total_dispatched,
    ROUND(u.units_at_risk / t.total_dispatched * 100, 2)   AS pct_units_at_risk,
    cv.variance_units
FROM units_at_risk u
JOIN total_dispatched t ON u.sku_id = t.sku_id
LEFT JOIN cycle_variance cv 
    ON u.lot_id = cv.lot_id 
    AND u.facility = cv.facility
ORDER BY pct_units_at_risk DESC;

-- Findings:
-- LOT-A-SAL-001: 28F breach, 230 units at risk (35.38%), 30 unit variance
-- LOT-A-ICS-001: 5F breach, 180 units at risk (31.03%), 85 unit variance
-- LOT-B-SAL-002: 22F breach, 100 units at risk (15.38%)
-- 2 of 3 breaches in Facility A — points to infrastructure issue
-- Excursion lots show higher inventory losses — breach likely caused unrecorded product discard


-- ============================================================
-- TASK 5 — STALLED ORDER & FULFILLMENT ANALYSIS
-- ============================================================

-- Stalled = open more than 2 days as of March 17
-- High Risk = stalled AND lot expires within 60 days
-- Dollar exposure assumption: $10/unit (unit price not provided in dataset)

-- PART 1: Order detail with risk flag
WITH date_stalled AS (
    SELECT 
        o.order_line_id,
        o.order_id,
        o.facility,
        o.lot_id,
        o.lifecycle_status,
        o.order_date,
        o.qty_fulfilled,
        TO_DATE('17/03/2026', 'DD/MM/YYYY') - o.order_date  AS days_open
    FROM inv_order_lines o
    WHERE lifecycle_status != 'Completed'
),

stalled_orders AS (
    SELECT
        order_line_id,
        order_id,
        facility,
        lot_id,
        lifecycle_status,
        order_date,
        qty_fulfilled,
        days_open,
        CASE
            WHEN days_open > 2 THEN 'STALLED'
            ELSE 'OK'
        END AS stalled_flag
    FROM date_stalled
)

SELECT  
    so.order_line_id,
    so.order_id,
    so.facility,
    so.lot_id,
    so.lifecycle_status,
    so.order_date,
    so.days_open,
    so.stalled_flag,
    l.expiration_date,
    l.expiration_date - TO_DATE('17/03/2026', 'DD/MM/YYYY')    AS days_to_expiry,
    CASE 
        WHEN l.expiration_date - TO_DATE('17/03/2026', 'DD/MM/YYYY') <= 60 
        THEN 'HIGH RISK' 
        ELSE 'MONITOR' 
    END AS risk_flag
FROM stalled_orders so
JOIN inv_lots l ON so.lot_id = l.lot_id
WHERE so.stalled_flag = 'STALLED'
ORDER BY days_to_expiry ASC;


-- PART 2: Breakdown by facility and lifecycle status
WITH date_stalled AS (
    SELECT 
        o.order_line_id,
        o.order_id,
        o.facility,
        o.lot_id,
        o.lifecycle_status,
        o.order_date,
        o.qty_fulfilled,
        TO_DATE('17/03/2026', 'DD/MM/YYYY') - o.order_date  AS days_open
    FROM inv_order_lines o
    WHERE lifecycle_status != 'Completed'
),

stalled_orders AS (
    SELECT
        order_line_id,
        order_id,
        facility,
        lot_id,
        lifecycle_status,
        order_date,
        qty_fulfilled,
        days_open,
        CASE
            WHEN days_open > 2 THEN 'STALLED'
            ELSE 'OK'
        END AS stalled_flag
    FROM date_stalled
)

SELECT 
    so.facility,
    so.lifecycle_status,
    COUNT(*)                                            AS total_orders,
    SUM(so.qty_fulfilled)                               AS total_units,
    SUM(so.qty_fulfilled) * 10                          AS dollar_exposure,
    COUNT(CASE WHEN 
        l.expiration_date - TO_DATE('17/03/2026', 'DD/MM/YYYY') <= 60 
        THEN 1 END)                                     AS high_risk_orders
FROM stalled_orders so
JOIN inv_lots l ON so.lot_id = l.lot_id
WHERE so.stalled_flag = 'STALLED'
GROUP BY so.facility, so.lifecycle_status
ORDER BY so.facility, so.lifecycle_status;

-- Findings:
-- 7 stalled orders total: 5 in Facility A, 2 in Facility B
-- Facility B: 2 HIGH RISK — LOT-B-OSP-001 expires in 41 days, LOT-B-SAL-001 in 48 days
-- Facility A: 0 HIGH RISK but 5 orders stalled — throughput problem
-- Total exposure: 440 units / $4,400


-- ============================================================
-- TASK 6 — ROOT CAUSE SUMMARY
-- ============================================================

SELECT 
    rank_cause,
    root_cause,
    unit_impact,
    affected_lots,
    corrective_action
FROM (
    SELECT 
        1                                   AS rank_cause,
        'FEFO Violations'                   AS root_cause,
        380                                 AS unit_impact,
        'OL-A-005, OL-B-007, OL-A-014, OL-B-012, OL-B-006' AS affected_lots,
        'Implement system-enforced lot selection at picking — remove manual picking decisions' 
                                            AS corrective_action
    FROM dual
    UNION ALL
    SELECT 
        2,
        'Temperature Breaches',
        510,
        'LOT-A-SAL-001, LOT-A-ICS-001, LOT-B-SAL-002',
        'Put affected lots on hold immediately — audit cold storage equipment in Facility A'
    FROM dual
    UNION ALL
    SELECT 
        3,
        'Stalled Orders',
        440,
        'OL-B-012, OL-B-006, OL-A-014, OL-A-008, OL-A-017, OL-A-003, OL-A-004',
        'Escalate Facility B HIGH RISK orders immediately — LOT-B-OSP-001 expires in 41 days'
    FROM dual
)
ORDER BY rank_cause;
