-- Task 1: Data cleaning

-- Checkear que el inventario inicial de un lote no puede ser mayor al que recibiste
-- 1. potential receiving / induction error
SELECT 
    b.lot_id,
    l.sku_id,
    b.facility,
    b.boh_qty,
    l.qty_received,
    b.boh_qty - l.qty_received AS diff
FROM inv_boh_snapshot b
JOIN inv_lots l ON b.lot_id = l.lot_id
WHERE b.boh_qty > l.qty_received;


-- 2. Check nulls in excursion flag excursion_temp_f
select 
    lot_id,
    sku_id,
    facility,
    excursion_flag,
    excursion_temp_f
from inv_lots
where excursion_flag IS NULL 
or excursion_temp_f IS NULL;


-- 3. Check for order lines partial fulfillment or scan failure.
select 
    order_line_id,
    lot_id,
    facility,
    qty_ordered,
    qty_fulfilled,
    qty_ordered - qty_fulfilled AS diferencia,
    lifecycle_status,
    notes
from inv_order_lines 
where qty_fulfilled <> qty_ordered;



-- 4. Verify that all lot_id  exist in the lots master table

SELECT 'order_lines' AS origen, lot_id 
FROM inv_order_lines
WHERE lot_id NOT IN (SELECT lot_id FROM inv_lots)
UNION ALL
SELECT 'boh_snapshot', lot_id 
FROM inv_boh_snapshot
WHERE lot_id NOT IN (SELECT lot_id FROM inv_lots);


---#####---------------------------------------------------------##########
---#####---------------------------------------------------------##########
--  Task 2: EOW Inventory Reconciliation

select * from inv_boh_snapshot;

select * from inv_order_lines;


SELECT 
    l.lot_id,
    l.sku_id,
    l.facility,
    b.boh_qty,
    NVL(SUM(o.qty_fulfilled), 0)                        AS total_despachado,
    b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)            AS expected_eow,
    c.physical_qty,
    (b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) - c.physical_qty AS varianza_unidades,
    ROUND(
        ((b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) - c.physical_qty) 
        / NULLIF(b.boh_qty, 0) * 100, 2)               AS varianza_pct,    
    CASE 
        WHEN ABS((b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) - c.physical_qty) > 5
          OR ABS(ROUND(((b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) - c.physical_qty) 
             / NULLIF(b.boh_qty, 0) * 100, 2)) > 3
        THEN 'REQUIERE INVESTIGACION'
        ELSE 'OK'
    END AS flag_varianza
FROM inv_lots l
JOIN inv_boh_snapshot b ON l.lot_id = b.lot_id AND l.facility = b.facility
JOIN inv_cycle_counts c ON l.lot_id = c.lot_id AND l.facility = c.facility
LEFT JOIN inv_order_lines o ON l.lot_id = o.lot_id AND l.facility = o.facility
WHERE
    b.boh_qty > 0
GROUP BY 
    l.lot_id, l.sku_id, l.facility, 
    b.boh_qty, c.physical_qty
ORDER BY 
    ABS((b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) - c.physical_qty) DESC;
    
    
---#####---------------------------------------------------------##########
---#####---------------------------------------------------------##########
--  Task 3: FEFO Compliance Analysis


select * 
from inv_lots l
join inv_boh_snapshot b on l.lot_id = b.lot_id 
join inv_order_lines ol on l.lot_id = ol.lot_id
where b.boh_qty > 0;

-- CTE 1: Orders dispatched during the week with their expiration date
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
    JOIN inv_lots l 
        ON o.lot_id = l.lot_id
),
-- CTE 2: Lots available in the warehouse with BOH > 0
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
ORDER BY s.facility, s.sku_id;





---#####---------------------------------------------------------##########
---#####---------------------------------------------------------##########
--  Task 4: Temperature Excursion Impact Assessment

WITH excursion_goods AS (
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
    SELECT 
        sku_id,
        SUM(qty_fulfilled)                                  AS total_dispatched
    FROM inv_order_lines
    GROUP BY sku_id
),
cycle_variance AS (
    SELECT 
        b.lot_id,
        b.facility,
        b.boh_qty,
        NVL(SUM(o.qty_fulfilled), 0)                        AS total_dispatched,
        b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)            AS expected_eow,
        c.physical_qty,
        (b.boh_qty - NVL(SUM(o.qty_fulfilled), 0)) - c.physical_qty       AS variance_units
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
LEFT JOIN cycle_variance cv ON u.lot_id = cv.lot_id AND u.facility = cv.facility
ORDER BY pct_units_at_risk DESC;



---#####---------------------------------------------------------##########
---#####---------------------------------------------------------##########
--  Task 5: Stalled Order & Fulfillment Analysist

WITH date_stalled AS (
    SELECT 
        order_line_id,
        order_id,
        facility,
        lot_id,
        lifecycle_status,
        order_date,
        TO_DATE('17/03/2026', 'DD/MM/YYYY') - order_date  AS days_open
    FROM inv_order_lines
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


-- RESULTADO 2: Breakdown por facility y lifecycle status
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




---#####---------------------------------------------------------##########
---#####---------------------------------------------------------##########
