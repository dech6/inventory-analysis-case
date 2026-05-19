-- first data check

select * from inv_skus;

select * from inv_lots;

select * from  inv_boh_snapshot;

select * from inv_cycle_counts;

select * from inv_order_lines;


-- Checkeamos que todas la tablas existan y tengan registros
SELECT 'INV_SKUS' AS tabla, COUNT(*) AS filas FROM INV_SKUS UNION ALL
SELECT 'INV_LOTS', COUNT(*) FROM INV_LOTS UNION ALL
SELECT 'INV_BOH_SNAPSHOT', COUNT(*) FROM INV_BOH_SNAPSHOT UNION ALL
SELECT 'INV_ORDER_LINES', COUNT(*) FROM INV_ORDER_LINES UNION ALL
SELECT 'INV_CYCLE_COUNTS', COUNT(*) FROM INV_CYCLE_COUNTS;



-- Checkeamos las estructuras de las tablas
SELECT column_name, data_type, nullable
FROM user_tab_columns
WHERE table_name IN ('INV_SKUS','INV_LOTS','INV_BOH_SNAPSHOT','INV_ORDER_LINES','INV_CYCLE_COUNTS')
ORDER BY table_name, column_id;