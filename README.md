# Inventory Analysis — Perishable Frozen Goods
**Analysis Period:** March 11–17, 2026  
**Facilities:** Facility A (East Coast) · Facility B (West Coast)  
**Products:** FrozenBerryMix-1lb · SalmonFillet-6oz · AvocadoChunks-2lb · OrganicSmoothiePack-12ct · IceCreamSandwich-8ct

---

## Overview

This project analyzes one week of operational data from two cold-chain fulfillment centers shipping frozen perishable goods. The goal was to identify root causes behind inventory discrepancies and rising product losses.

The analysis was done entirely in **Oracle SQL** and covers five areas:
1. Data Cleaning & Validation
2. End of Week Inventory Reconciliation
3. FEFO Compliance (First Expired, First Out)
4. Temperature Breach Impact
5. Stalled Order Analysis

---

## Database Structure

| Table | Description | Key Fields |
|---|---|---|
| `INV_SKUS` | Product reference — storage temps & shelf life | `sku_id`, `storage_temp_f`, `shelf_life_days` |
| `INV_LOTS` | Lot master — manufacture, expiry, receipt, breach data | `lot_id`, `expiration_date`, `excursion_flag`, `excursion_temp_f` |
| `INV_BOH_SNAPSHOT` | Beginning-of-week inventory per lot (Mar 11) | `lot_id`, `boh_qty` |
| `INV_ORDER_LINES` | All orders picked during the week | `lot_id`, `qty_fulfilled`, `lifecycle_status` |
| `INV_CYCLE_COUNTS` | Physical inventory count taken end of week (Mar 17) | `lot_id`, `physical_qty` |

---

## Task 1 — Data Quality Issues Found

| Issue | Lot | Detail | Action Taken |
|---|---|---|---|
| BOH exceeds qty received | LOT-B-SAL-001 | 620 on hand, only 500 received — 120 unit discrepancy | Flagged for recount and receiving log audit |
| NULL excursion flag | LOT-B-ICS-002 | No temperature record — product integrity unknown | Treated as unknown, not as safe |
| Partial fulfillment | OL-A-005 | Ordered 30, shipped 25 | Accounted for in reconciliation |
| Partial fulfillment | OL-B-007 | Ordered 70, shipped 50 | Accounted for in reconciliation |
| Referential integrity | All tables | No orphan lot_ids found | ✅ No action needed |

---

## Task 2 — End of Week Inventory Reconciliation

**Formula:**
```
Expected EOW = BOH - Units Dispatched
Variance = Expected EOW - Physical Count
```

**Flagging Criteria:** Variance > 5 units OR > 3%

| Lot | SKU | Facility | BOH | Dispatched | Expected EOW | Physical | Variance Units | Variance % | Flag |
|---|---|---|---|---|---|---|---|---|---|
| LOT-A-ICS-001 | IceCreamSandwich-8ct | A | 460 | 180 | 280 | 195 | 85 | 18.48% | 🔴 |
| LOT-B-OSP-001 | OrganicSmoothiePack-12ct | B | 360 | 115 | 245 | 185 | 60 | 16.67% | 🔴 |
| LOT-B-SAL-001 | SalmonFillet-6oz | B | 620 | 260 | 360 | 310 | 50 | 8.06% | 🔴 |
| LOT-A-SAL-001 | SalmonFillet-6oz | A | 380 | 230 | 150 | 120 | 30 | 7.89% | 🔴 |
| LOT-A-BRY-001 | FrozenBerryMix-1lb | A | 310 | 205 | 105 | 90 | 15 | 4.84% | 🔴 |

---

## Task 3 — FEFO Compliance Analysis

**FEFO (First Expired, First Out):** Pickers must always ship the lot that expires soonest. Picking a newer lot while an older one is available is a violation.

**Results — 5 violations found, one per SKU:**

| Facility | SKU | Violations | Units Violated | Total Dispatched | % of Total |
|---|---|---|---|---|---|
| A | FrozenBerryMix-1lb | 1 | 50 | 255 | 19.61% |
| A | IceCreamSandwich-8ct | 1 | 90 | 270 | 33.33% |
| A | SalmonFillet-6oz | 1 | 60 | 290 | 20.69% |
| B | OrganicSmoothiePack-12ct | 1 | 80 | 195 | **41.03%** |
| B | SalmonFillet-6oz | 1 | 100 | 360 | 27.78% |

> ⚠️ Pattern is systematic — violations occur across all SKUs in both facilities, not isolated incidents.

---

## Task 4 — Temperature Breach Impact

Lots that were stored above their required temperature are considered at risk. Units shipped from these lots may be compromised.

| Lot | SKU | Facility | Temp Breach (°F) | Units At Risk | Total Dispatched | % At Risk | Inventory Variance |
|---|---|---|---|---|---|---|---|
| LOT-A-SAL-001 | SalmonFillet-6oz | A | +28°F | 230 | 650 | 35.38% | 30 units |
| LOT-A-ICS-001 | IceCreamSandwich-8ct | A | +5°F | 180 | 580 | 31.03% | 85 units |
| LOT-B-SAL-002 | SalmonFillet-6oz | B | +22°F | 100 | 650 | 15.38% | N/A |

> ⚠️ 2 of 3 temperature breaches occurred in Facility A — points to a facility-level infrastructure issue.

---

## Task 5 — Stalled Order Analysis

An order is considered stalled if it has been open for more than 2 days as of March 17 without completing.  
**High Risk** = stalled AND lot expires within 60 days.

> 💰 Unit value not provided in dataset — assumed **$10/unit** for dollar exposure calculation.

**Order Detail:**

| Order | Facility | Lot | Status | Days Open | Days to Expiry | Risk |
|---|---|---|---|---|---|---|
| OL-B-012 | B | LOT-B-OSP-001 | Shipped | 4 | 41 days | 🔴 HIGH RISK |
| OL-B-006 | B | LOT-B-SAL-001 | Awaiting Shipment | 3 | 48 days | 🔴 HIGH RISK |
| OL-A-014 | A | LOT-A-OSP-001 | Shipped | 4 | 76 days | 🟡 Monitor |
| OL-A-008 | A | LOT-A-SAL-002 | Awaiting Shipment | 3 | 114 days | 🟡 Monitor |
| OL-A-017 | A | LOT-A-ICS-002 | Awaiting Shipment | 4 | 124 days | 🟡 Monitor |
| OL-A-004 | A | LOT-A-BRY-001 | Shipped | 3 | 198 days | 🟡 Monitor |
| OL-A-003 | A | LOT-A-BRY-002 | Awaiting Shipment | 4 | 243 days | 🟡 Monitor |

**Breakdown by Facility and Status:**

| Facility | Status | Orders | Units | $ Exposure | High Risk Orders |
|---|---|---|---|---|---|
| A | Awaiting Shipment | 3 | 200 | $2,000 | 0 |
| A | Shipped | 2 | 100 | $1,000 | 0 |
| B | Awaiting Shipment | 1 | 80 | $800 | 1 |
| B | Shipped | 1 | 60 | $600 | 1 |

---

## Task 6 — Root Cause Summary & Action Plan

### Top 3 Root Causes — Ranked by Unit Impact

| Rank | Root Cause | Unit Impact | Corrective Action |
|---|---|---|---|
| 🔴 #1 | Wrong lots being picked (FEFO violations) | 380 units | Implement system-enforced lot selection — remove manual picking decisions |
| 🔴 #2 | Temperature breaches | 510 units at risk | Put affected lots on hold — audit cold storage equipment in Facility A |
| 🟡 #3 | Stalled orders | 440 units / $4,400 exposure | Escalate Facility B HIGH RISK orders immediately |

---

### Facility Compliance Risk

**Facility B — Greater compliance risk:**
- 2 HIGH RISK stalled orders with lots expiring in 41 and 48 days
- LOT-B-SAL-001 has 120 unit receiving discrepancy — unresolved
- LOT-B-ICS-002 has no temperature record — integrity unknown

**Facility A — Greater operational risk:**
- 2 of 3 temperature breaches occurred here
- 5 of 7 stalled orders concentrated here
- Highest inventory variance — LOT-A-ICS-001 at 85 units (18.48%)

---

### Prioritized Lot Action List

| Priority | Lot | Action | Reason |
|---|---|---|---|
| 🔴 1 | LOT-B-OSP-001 | Ship immediately | Stalled 4 days, expires in 41 days |
| 🔴 2 | LOT-B-SAL-001 | Recount + receiving audit | 120 unit discrepancy, stalled in facility |
| 🔴 3 | LOT-A-SAL-001 | Put on hold | 28°F breach, 35% of SKU units at risk |
| 🔴 4 | LOT-A-ICS-001 | Put on hold | Temperature breach + 85 unit variance |
| 🟡 5 | LOT-B-SAL-002 | Put on hold | 22°F temperature breach |
| 🟡 6 | LOT-B-ICS-002 | Investigate | No temperature record on file |
| 🟡 7 | LOT-A-BRY-001 | Recount | 15 unit variance |

---

## Tools Used
- Oracle SQL / SQL Developer
- Oracle SQL — CTEs, Window Functions, NVL, NULLIF, CASE statements
