-- =====================================================================
-- 06_stage5_maintenance.sql
-- STAGE 5: Predictive Maintenance & Bike Longevity
-- GOAL   : Which problems are most common, where and when do they
--          happen, and does heavy riding lead to more breakdowns?
--
-- THE KEY PROBLEM: the maintenance table has NO station column.
--   It only knows Bike_ID. And we cannot match by date either:
--   all maintenance is dated 2022, all trips are in 2023.
-- OUR SOLUTION: build a "bridge" between bikes and stations using the
--   trips table: a bike is linked to every station it has started a
--   trip from OR ended a trip at ("engaged" bikes - this is exactly the
--   wording of the PDF hint for Q2).
-- =====================================================================
USE bike_sharing;

CREATE OR REPLACE VIEW bike_station_bridge AS
SELECT Bike_ID, Start_Station_ID AS Station_ID FROM trips
UNION                                    -- UNION (not UNION ALL) removes repeated pairs
SELECT Bike_ID, End_Station_ID  AS Station_ID FROM trips;

-- ---------------------------------------------------------------------
-- Q1. Most common issues; most affected station; peak season.
-- Seasons (Northern hemisphere, all cities are in the USA):
--   Dec-Feb Winter | Mar-May Spring | Jun-Aug Summer | Sep-Nov Autumn
-- ---------------------------------------------------------------------
-- @export s5q1_issue_summary
WITH m AS (
    SELECT Issue_Reported, Bike_ID,
           CASE WHEN MONTH(Maintenance_Date) IN (12, 1, 2) THEN 'Winter'
                WHEN MONTH(Maintenance_Date) IN (3, 4, 5)  THEN 'Spring'
                WHEN MONTH(Maintenance_Date) IN (6, 7, 8)  THEN 'Summer'
                ELSE 'Autumn' END AS Season
    FROM maintenance
),
totals AS (
    SELECT Issue_Reported, COUNT(*) AS Total_Occurrences
    FROM m GROUP BY Issue_Reported
),
by_station AS (
    SELECT m.Issue_Reported, b.Station_ID, COUNT(*) AS Issue_Count,
           ROW_NUMBER() OVER (PARTITION BY m.Issue_Reported
                              ORDER BY COUNT(*) DESC, b.Station_ID) AS rn
    FROM m
    JOIN bike_station_bridge b ON b.Bike_ID = m.Bike_ID
    GROUP BY m.Issue_Reported, b.Station_ID
),
by_season AS (
    SELECT Issue_Reported, Season, COUNT(*) AS Season_Count,
           ROW_NUMBER() OVER (PARTITION BY Issue_Reported ORDER BY COUNT(*) DESC, Season) AS rn
    FROM m
    GROUP BY Issue_Reported, Season
)
SELECT t.Issue_Reported,
       t.Total_Occurrences,
       s.Station_Name   AS Most_Affected_Station,
       bs.Issue_Count   AS Records_At_That_Station,
       se.Season        AS Peak_Season,
       se.Season_Count  AS Records_In_Peak_Season
FROM totals t
JOIN by_station bs ON bs.Issue_Reported = t.Issue_Reported AND bs.rn = 1
JOIN stations s    ON s.Station_ID = bs.Station_ID
JOIN by_season se  ON se.Issue_Reported = t.Issue_Reported AND se.rn = 1
ORDER BY t.Total_Occurrences DESC;

-- Full issue x season table (shows whether any issue is truly seasonal)
-- @export s5q1b_issue_by_season
SELECT Issue_Reported,
       CAST(SUM(MONTH(Maintenance_Date) IN (12, 1, 2)) AS UNSIGNED) AS Winter,
       CAST(SUM(MONTH(Maintenance_Date) IN (3, 4, 5))  AS UNSIGNED) AS Spring,
       CAST(SUM(MONTH(Maintenance_Date) IN (6, 7, 8))  AS UNSIGNED) AS Summer,
       CAST(SUM(MONTH(Maintenance_Date) IN (9, 10, 11)) AS UNSIGNED) AS Autumn,
       COUNT(*) AS Total
FROM maintenance
GROUP BY Issue_Reported
ORDER BY Total DESC;

-- Which stations are linked to the most maintenance records overall?
-- @export s5q1c_top_stations_by_issues
SELECT s.Station_Name,
       s.City,
       COUNT(*)                       AS Maintenance_Records,
       COUNT(DISTINCT m.Bike_ID)      AS Distinct_Bikes
FROM maintenance m
JOIN bike_station_bridge b ON b.Bike_ID = m.Bike_ID
JOIN stations s ON s.Station_ID = b.Station_ID
GROUP BY s.Station_ID, s.Station_Name, s.City
ORDER BY Maintenance_Records DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- Q2. How much of each station's fleet is affected by maintenance?
-- The data has no "status = under repair" flag, so we use a PROXY:
--   "currently in maintenance" = bikes with a maintenance record in the
--   LAST 7 DAYS of the log (log ends 2023-01-01).
-- Fleet_Affected_Pct = bikes in maintenance / all bikes engaged at the
--   station (arriving or departing) x 100   <- PDF hint
-- You can change the 7 to 14 or 30 to see a wider window.
-- ---------------------------------------------------------------------
-- @export s5q2_fleet_affected
WITH recent AS (
    SELECT DISTINCT Bike_ID
    FROM maintenance
    WHERE Maintenance_Date > DATE_SUB((SELECT MAX(Maintenance_Date) FROM maintenance), INTERVAL 7 DAY)
),
engaged AS (
    SELECT Station_ID, COUNT(*) AS Total_Bikes_Engaged
    FROM bike_station_bridge
    GROUP BY Station_ID
),
affected AS (
    SELECT b.Station_ID, COUNT(*) AS Bikes_in_Maintenance
    FROM bike_station_bridge b
    JOIN recent r ON r.Bike_ID = b.Bike_ID
    GROUP BY b.Station_ID
)
SELECT s.Station_Name,
       COALESCE(a.Bikes_in_Maintenance, 0)  AS Bikes_in_Maintenance,
       e.Total_Bikes_Engaged,
       ROUND(COALESCE(a.Bikes_in_Maintenance, 0) * 100.0 / e.Total_Bikes_Engaged, 2) AS Fleet_Affected_Pct
FROM engaged e
JOIN stations s ON s.Station_ID = e.Station_ID
LEFT JOIN affected a ON a.Station_ID = e.Station_ID
ORDER BY Fleet_Affected_Pct DESC, Bikes_in_Maintenance DESC
LIMIT 10;

-- Overall picture: how spread out is the "fleet affected" figure?
-- @export s5q2b_fleet_affected_spread
WITH recent AS (
    SELECT DISTINCT Bike_ID
    FROM maintenance
    WHERE Maintenance_Date > DATE_SUB((SELECT MAX(Maintenance_Date) FROM maintenance), INTERVAL 7 DAY)
),
per_station AS (
    SELECT b.Station_ID,
           COUNT(*) AS Engaged,
           SUM(r.Bike_ID IS NOT NULL) AS Affected
    FROM bike_station_bridge b
    LEFT JOIN recent r ON r.Bike_ID = b.Bike_ID
    GROUP BY b.Station_ID
)
SELECT (SELECT COUNT(*) FROM recent)                     AS Bikes_In_Maintenance_Fleetwide,
       (SELECT COUNT(*) FROM bikes)                      AS Total_Bikes,
       ROUND((SELECT COUNT(*) FROM recent) * 100.0 / (SELECT COUNT(*) FROM bikes), 2) AS Fleetwide_Pct,
       ROUND(MIN(Affected * 100.0 / Engaged), 2)         AS Min_Station_Pct,
       ROUND(AVG(Affected * 100.0 / Engaged), 2)         AS Avg_Station_Pct,
       ROUND(MAX(Affected * 100.0 / Engaged), 2)         AS Max_Station_Pct
FROM per_station;

-- ---------------------------------------------------------------------
-- Q3. Does heavy riding lead to more breakdowns?
-- IMPORTANT: aggregate trips and maintenance SEPARATELY first, then
--   join. Joining raw trips to raw maintenance would multiply rows
--   (each trip x each repair) and inflate the counts.
-- Risk flag: a bike is "At Risk" if BOTH its average trip distance and
--   its maintenance count are above the fleet average.
-- ---------------------------------------------------------------------
-- @export s5q3_bike_wear_top
WITH trip_stats AS (
    SELECT Bike_ID,
           COUNT(*)                  AS Total_Trips,
           ROUND(AVG(Distance_KM), 2)       AS Avg_Trip_Distance,
           ROUND(AVG(Trip_Duration_Min), 2) AS Avg_Ride_Duration
    FROM trips GROUP BY Bike_ID
),
maint_stats AS (
    SELECT Bike_ID, COUNT(*) AS Maintenance_Count, SUM(Downtime_Hours) AS Total_Downtime_Hours
    FROM maintenance GROUP BY Bike_ID
),
joined AS (
    SELECT b.Bike_ID, b.Bike_Type, ts.Total_Trips, ts.Avg_Trip_Distance, ts.Avg_Ride_Duration,
           COALESCE(ms.Maintenance_Count, 0)    AS Maintenance_Count,
           COALESCE(ms.Total_Downtime_Hours, 0) AS Total_Downtime_Hours
    FROM bikes b
    LEFT JOIN trip_stats  ts ON ts.Bike_ID = b.Bike_ID
    LEFT JOIN maint_stats ms ON ms.Bike_ID = b.Bike_ID
)
SELECT Bike_ID, Bike_Type, Total_Trips, Avg_Trip_Distance, Avg_Ride_Duration,
       Maintenance_Count, Total_Downtime_Hours,
       CASE WHEN Maintenance_Count   > AVG(Maintenance_Count) OVER ()
             AND Avg_Trip_Distance   > AVG(Avg_Trip_Distance) OVER ()
            THEN 'At Risk' ELSE 'Normal' END AS Risk_Flag
FROM joined
ORDER BY Maintenance_Count DESC, Avg_Trip_Distance DESC
LIMIT 15;

-- Electric vs Standard bikes
-- @export s5q3b_electric_vs_standard
WITH trip_stats AS (
    SELECT Bike_ID, COUNT(*) AS Trips, AVG(Distance_KM) AS Avg_Km, AVG(Trip_Duration_Min) AS Avg_Min
    FROM trips GROUP BY Bike_ID
),
maint_stats AS (
    SELECT Bike_ID, COUNT(*) AS Repairs, SUM(Downtime_Hours) AS Downtime
    FROM maintenance GROUP BY Bike_ID
)
SELECT b.Bike_Type,
       COUNT(*)                          AS Bikes,
       ROUND(AVG(ts.Trips), 1)           AS Avg_Trips_Per_Bike,
       ROUND(AVG(ts.Avg_Km), 2)          AS Avg_Trip_Distance,
       ROUND(AVG(ts.Avg_Min), 2)         AS Avg_Ride_Duration,
       ROUND(AVG(ms.Repairs), 2)         AS Avg_Repairs_Per_Bike,
       ROUND(AVG(ms.Downtime), 1)        AS Avg_Downtime_Hours_Per_Bike
FROM bikes b
LEFT JOIN trip_stats  ts ON ts.Bike_ID = b.Bike_ID
LEFT JOIN maint_stats ms ON ms.Bike_ID = b.Bike_ID
GROUP BY b.Bike_Type;

-- Is there a statistical link? Pearson correlation (-1 to +1) computed
-- by hand because MySQL has no CORR() function.
--   near 0 = no relationship | near +1 = more riding -> more repairs
-- @export s5q3c_correlation
WITH trip_stats AS (
    SELECT Bike_ID, COUNT(*) AS Trips, SUM(Distance_KM) AS Total_Km, AVG(Distance_KM) AS Avg_Km
    FROM trips GROUP BY Bike_ID
),
maint_stats AS (
    SELECT Bike_ID, COUNT(*) AS Repairs FROM maintenance GROUP BY Bike_ID
),
j AS (
    SELECT ts.Trips, ts.Total_Km, ts.Avg_Km, ms.Repairs
    FROM trip_stats ts JOIN maint_stats ms ON ms.Bike_ID = ts.Bike_ID
)
SELECT 'Total trips vs repairs' AS Compared,
       ROUND((COUNT(*) * SUM(Trips * Repairs) - SUM(Trips) * SUM(Repairs)) /
        SQRT((COUNT(*) * SUM(Trips * Trips) - SUM(Trips) * SUM(Trips)) *
             (COUNT(*) * SUM(Repairs * Repairs) - SUM(Repairs) * SUM(Repairs))), 4) AS Correlation
FROM j
UNION ALL
SELECT 'Total km vs repairs',
       ROUND((COUNT(*) * SUM(Total_Km * Repairs) - SUM(Total_Km) * SUM(Repairs)) /
        SQRT((COUNT(*) * SUM(Total_Km * Total_Km) - SUM(Total_Km) * SUM(Total_Km)) *
             (COUNT(*) * SUM(Repairs * Repairs) - SUM(Repairs) * SUM(Repairs))), 4)
FROM j
UNION ALL
SELECT 'Avg trip distance vs repairs',
       ROUND((COUNT(*) * SUM(Avg_Km * Repairs) - SUM(Avg_Km) * SUM(Repairs)) /
        SQRT((COUNT(*) * SUM(Avg_Km * Avg_Km) - SUM(Avg_Km) * SUM(Avg_Km)) *
             (COUNT(*) * SUM(Repairs * Repairs) - SUM(Repairs) * SUM(Repairs))), 4)
FROM j;
