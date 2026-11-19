# 🚲 Bike-Sharing Services Analysis (SQL Case Study)

An end-to-end SQL analysis of a bike-sharing platform: data quality audit → cleaning → demand analysis → user segmentation → maintenance analysis. Built in **MySQL 8** on 7 related tables (50,000 trips, 5,000 users, 200 stations, 1,000 bikes).

> Case study source: Coding Ninjas – *Bike-Sharing Services Analysis*. All queries in this repo were written by me and tested on the provided dataset.

---

## 1. Business problem
A bike-sharing operator wants data-backed answers to:
- Is our data complete and trustworthy?
- When and where is demand highest? Which stations run out of bikes or fill up?
- How do casual and subscription riders behave differently?
- Which bike problems are most common, and does heavy use cause more breakdowns?

## 2. Dataset

| Table | Rows | What it holds |
|---|---:|---|
| `trips` | 50,000 | One row per ride (user, bike, start/end station, times, duration, distance, ride type) |
| `users` | 5,000 | Age, gender, subscription type, signup date, city |
| `stations` | 200 | Station name, location, city, capacity |
| `bikes` | 1,000 | Bike type (Electric/Standard), purchase and last-maintenance date |
| `maintenance` | 10,000 | Bike repairs: issue type, date, downtime hours |
| `weather` | 8,760 | Hourly weather for 2023 |
| `revenue` | 5,000 | Payments and fines |

Full column descriptions are in the case study `Metadata.docx`.

## 3. Tools & SQL skills used
**MySQL 8.0 · MySQL Workbench · Git/GitHub**

Joins (inner/left) · Aggregations · `CASE WHEN` · CTEs (`WITH`) · Window functions (`ROW_NUMBER`, `RANK`, `NTILE`, `AVG() OVER`) · Subqueries · Views · Date/time functions · `REGEXP_REPLACE` · Safe `UPDATE`/`DELETE` with a backup table · Manual Pearson correlation.

## 4. Project structure
```
bike-sharing-sql-analysis/
├── data/                       # the 7 source CSV files
├── sql/
│   ├── 01_schema_and_load.sql          # create tables + load CSVs
│   ├── 02_stage1_data_exploration.sql  # record counts, NULLs, integrity checks
│   ├── 03_stage2_data_cleaning.sql     # duplicates, missing IDs, durations, names
│   ├── 04_stage3_demand_analysis.sql   # hourly/weekday demand, station net usage
│   ├── 05_stage4_user_behavior.sql     # ride types, top users, time-of-day
│   └── 06_stage5_maintenance.sql       # issues, fleet affected, wear analysis
├── results/                    # every query's output as CSV
├── docs/
│   ├── Bike_Sharing_SQL_Project_Guide.pdf   # full step-by-step explanation
│   └── charts/                 # charts used in the write-up
├── run_all.py                  # optional: runs all scripts and refreshes results/
└── README.md
```

## 5. How to run it
1. Install MySQL 8.0+ and Workbench.
2. Open `sql/01_schema_and_load.sql`. Replace the relative `data/...` paths with the full path to your `data` folder (Workbench does not resolve relative paths), then run it.
3. Run `02` → `06` **in order** (the cleaning script in `03` changes tables, so run it once; re-run `01` to reset).

## 6. Approach, stage by stage

| Stage | What I did | Why |
|---|---|---|
| **1. Exploration** | Compared row counts with expected volumes; measured % missing per column; checked missing `User_ID` by ride type; ran 13 integrity checks | A trusted analysis starts with trusted data |
| **2. Cleaning** | Backed up tables; looked for duplicates with `ROW_NUMBER()`; labelled missing casual IDs in a *new* column; repaired/removed negative durations by rule; standardised station names with regex | Fix only what is wrong, change as little as possible, keep an audit trail |
| **3. Demand** | Trips per hour (peak = above hourly average); weekday vs weekend (also per day); station arrivals − departures; peak vs commute-hour trips; stations whose busiest hour is not a commute hour | Plan fleet size and bike redistribution |
| **4. Users** | Duration/distance/volume per ride type; top riders; high-frequency decile with `NTILE`; hourly pattern per ride type | Target marketing and retention |
| **5. Maintenance** | Built a bike→station bridge view; issue × season × station; % of fleet affected; per-bike wear table; Electric vs Standard; correlation of usage with repairs | Plan servicing before breakdowns |

## 7. Key findings

**Data quality**
- The dataset is very clean: **0** NULLs, **0** duplicate trips, **0** negative durations, **0** broken foreign keys, 0 non-standard station names. Cleaning scripts therefore changed 0 rows, which was verified with before/after counts.
- Two real issues were found and flagged (not silently "fixed"):
  - **148 pairs of overlapping trips on the *same bike*** — physically impossible, listed for review.
  - **Trip `Ride_Type` differs from the user's `Subscription_Type` in 31,901 trips (63.8%)**, and 4,063 of 4,999 users appear under all three ride types, so ride type behaves like a *trip* label, not a *user* label.

**Demand**
- Trips per hour range only **2,030 – 2,145** (average 2,083). Weekday vs weekend is **136.5 vs 138.2 rides per day**. A chi-square test cannot distinguish hourly demand from perfectly even demand (p = 0.995).
- Under the "above hourly average = peak" rule, 12 of 24 hours are labelled peak, but the gap to off-peak hours is about 3%, which is not operationally meaningful.
- Station imbalance: Station 1 gains the most bikes (**+65**), Station 148 loses the most (**−63**). 90 stations are in surplus and 103 in deficit. These extremes are in line with what random trips would produce (simulated ≈ +62 / −61).

**Users**
- Casual rides are 50.1% of trips, Monthly 30.0%, Yearly 19.9%. Average duration (~32 min) and distance (~5.3 km) are practically identical across ride types.
- The busiest 10% of users ride ~10 times each regardless of subscription type.

**Maintenance**
- Flat Tire is the most common issue (2,586 of 10,000 records) but all four issue types are within 6% of each other; no issue shows a seasonal peak.
- Correlation between a bike's trips and its repairs is **0.04**; Electric and Standard bikes need the same repairs (10.1 vs 9.95 per bike).

### What this means
The analysis pipeline works and every number is reproducible, but **this dataset behaves like uniformly generated (synthetic) data**: hourly, weekly, user-type and maintenance patterns are flat. I report that openly rather than inventing commute/leisure stories. On real data, the same queries would surface genuine peaks and risk bikes.

## 8. Assumptions & limitations
- "Expected" row-count thresholds and impact buckets (<1% low, 1–5% medium, >5% high) are my own assumptions.
- The maintenance table has no station column and its dates (2022) do not overlap trips (2023). I link bikes to stations through the trips they started or ended at.
- "Currently in maintenance" has no status flag in the data; I use bikes with a repair in the last 7 days of the log as a proxy.
- The weather table has one city per hour, so it cannot be reliably joined to trips. `revenue` and `weather` are loaded but not required by the five stages.
- The PDF's sample outputs for Stage 5 Q1/Q2 could not be reproduced with any natural join; those samples are format references only.

## 9. Possible next steps
Power BI dashboard on top of `results/`; revenue and churn analysis using `revenue`; weather impact on rides; automated servicing alerts for bikes above the 90th-percentile repair count.

---
**Author:** `<Your Name>` ·  [LinkedIn](https://www.linkedin.com/in/abhishak-khandelwal/) · MBA (Manipal University Jaipur) · Data Analyst
