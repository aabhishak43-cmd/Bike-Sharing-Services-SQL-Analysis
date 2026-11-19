-- =====================================================================
-- 04_stage3_demand_analysis.sql
-- STAGE 3: Demand Insights & Peak Usage Analysis
-- GOAL   : When, where and how much are bikes used?
-- =====================================================================
USE bike_sharing;

-- ---------------------------------------------------------------------
-- Q1. How does usage change through the day? Which hours are peak?
-- DEFINITION: an hour is "Peak" if its trips are ABOVE the average
--             number of trips per hour (50,000 / 24 = 2,083).
-- ---------------------------------------------------------------------
-- @export s3q1_hourly_demand
WITH hourly AS (
    SELECT HOUR(Start_Time) AS Hour_of_Day,
           COUNT(*)         AS Total_Trips
    FROM trips
    GROUP BY HOUR(Start_Time)
)
SELECT Hour_of_Day,
       Total_Trips,
       CASE WHEN Total_Trips > (SELECT AVG(Total_Trips) FROM hourly)
            THEN 'Peak' ELSE 'Off-Peak' END AS Peak_Off_Peak
FROM hourly
ORDER BY Hour_of_Day;

-- Are some time blocks under-used? Group the 24 hours into 4 blocks.
-- @export s3q1b_time_blocks
SELECT CASE WHEN HOUR(Start_Time) BETWEEN 0  AND 5  THEN '1. Night (00-05)'
            WHEN HOUR(Start_Time) BETWEEN 6  AND 11 THEN '2. Morning (06-11)'
            WHEN HOUR(Start_Time) BETWEEN 12 AND 17 THEN '3. Afternoon (12-17)'
            ELSE '4. Evening (18-23)' END                    AS Time_Block,
       COUNT(*)                                              AS Total_Trips,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM trips), 2) AS Share_Pct,
       ROUND(COUNT(*) / COUNT(DISTINCT HOUR(Start_Time)), 0)     AS Avg_Trips_Per_Hour
FROM trips
GROUP BY 1
ORDER BY 1;

-- How does peak-hour demand vary ACROSS USER TYPES?
-- Share of each ride type's trips that start in commute hours (7-9, 17-19).
-- @export s3q1c_commute_share_by_ride_type
SELECT Ride_Type,
       COUNT(*) AS Total_Trips,
       CAST(SUM(HOUR(Start_Time) BETWEEN 7 AND 9 OR HOUR(Start_Time) BETWEEN 17 AND 19) AS UNSIGNED)
            AS Commute_Hour_Trips,
       ROUND(SUM(HOUR(Start_Time) BETWEEN 7 AND 9 OR HOUR(Start_Time) BETWEEN 17 AND 19)
             * 100.0 / COUNT(*), 2) AS Commute_Hour_Share_Pct
FROM trips
GROUP BY Ride_Type
ORDER BY Ride_Type;

-- ---------------------------------------------------------------------
-- Q2. Weekday vs weekend.
-- DAYOFWEEK(): 1 = Sunday ... 7 = Saturday, so 1 and 7 = weekend.
-- ---------------------------------------------------------------------
-- @export s3q2_weekday_weekend
SELECT CASE WHEN DAYOFWEEK(Start_Time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END AS Day_Type,
       COUNT(*)                            AS Total_Rides,
       ROUND(AVG(Trip_Duration_Min), 4)    AS Avg_Trip_Duration,
       CASE WHEN DAYOFWEEK(Start_Time) IN (1, 7) THEN 'Leisure trips' ELSE 'Work commute' END
                                           AS Main_Ride_Purpose
FROM trips
GROUP BY CASE WHEN DAYOFWEEK(Start_Time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END,
         CASE WHEN DAYOFWEEK(Start_Time) IN (1, 7) THEN 'Leisure trips' ELSE 'Work commute' END
ORDER BY Day_Type DESC;

-- Fair comparison: weekdays have 5 days, weekends only 2, so compare
-- the average rides PER DAY, not just the totals.
-- @export s3q2b_rides_per_day
SELECT Day_Type,
       COUNT(DISTINCT Trip_Date) AS Days_In_Data,
       SUM(Rides)                AS Total_Rides,
       ROUND(SUM(Rides) / COUNT(DISTINCT Trip_Date), 1) AS Avg_Rides_Per_Day
FROM (
    SELECT DATE(Start_Time) AS Trip_Date,
           CASE WHEN DAYOFWEEK(Start_Time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END AS Day_Type,
           COUNT(*) AS Rides
    FROM trips
    GROUP BY DATE(Start_Time),
             CASE WHEN DAYOFWEEK(Start_Time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END
) AS daily
GROUP BY Day_Type
ORDER BY Day_Type DESC;

-- "Across different locations": compare by city of the START station.
-- @export s3q2c_weekday_weekend_by_city
SELECT s.City,
       CASE WHEN DAYOFWEEK(t.Start_Time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END AS Day_Type,
       COUNT(*)                          AS Total_Rides,
       ROUND(AVG(t.Trip_Duration_Min), 2) AS Avg_Trip_Duration
FROM trips t
JOIN stations s ON s.Station_ID = t.Start_Station_ID
GROUP BY s.City,
         CASE WHEN DAYOFWEEK(t.Start_Time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END
ORDER BY s.City, Day_Type DESC;

-- Time-specific differences: top 3 busiest hours on weekdays vs weekends.
-- @export s3q2d_top_hours_by_day_type
SELECT Day_Type, Hour_of_Day, Total_Rides, Hour_Rank
FROM (
    SELECT CASE WHEN DAYOFWEEK(Start_Time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END AS Day_Type,
           HOUR(Start_Time) AS Hour_of_Day,
           COUNT(*)         AS Total_Rides,
           RANK() OVER (
               PARTITION BY CASE WHEN DAYOFWEEK(Start_Time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END
               ORDER BY COUNT(*) DESC) AS Hour_Rank
    FROM trips
    GROUP BY CASE WHEN DAYOFWEEK(Start_Time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END,
             HOUR(Start_Time)
) AS r
WHERE Hour_Rank <= 3
ORDER BY Day_Type DESC, Hour_Rank;

-- ---------------------------------------------------------------------
-- Q3. Net bike usage per station.
-- Net_Usage = Arrivals - Departures
--   positive -> station GAINS bikes (they pile up)   -> "Surplus"
--   negative -> station LOSES bikes (runs empty)     -> "Deficit"
-- Threshold = average net usage of all stations (as the PDF hint says).
-- ---------------------------------------------------------------------
-- @export s3q3_station_net_usage
WITH departures AS (
    SELECT Start_Station_ID AS Station_ID, COUNT(*) AS Total_Departures
    FROM trips GROUP BY Start_Station_ID
),
arrivals AS (
    SELECT End_Station_ID AS Station_ID, COUNT(*) AS Total_Arrivals
    FROM trips GROUP BY End_Station_ID
),
net AS (
    SELECT s.Station_ID, s.Station_Name,
           COALESCE(d.Total_Departures, 0) AS Total_Departures,
           COALESCE(a.Total_Arrivals, 0)   AS Total_Arrivals,
           COALESCE(a.Total_Arrivals, 0) - COALESCE(d.Total_Departures, 0) AS Net_Usage
    FROM stations s
    LEFT JOIN departures d ON d.Station_ID = s.Station_ID
    LEFT JOIN arrivals   a ON a.Station_ID = s.Station_ID
)
SELECT Station_Name, Total_Departures, Total_Arrivals, Net_Usage,
       CASE WHEN Net_Usage > (SELECT AVG(Net_Usage) FROM net) THEN 'Surplus'
            WHEN Net_Usage < (SELECT AVG(Net_Usage) FROM net) THEN 'Deficit'
            ELSE 'Balanced' END AS Station_Status,
       CASE WHEN Net_Usage > (SELECT AVG(Net_Usage) FROM net) THEN 'Remove bikes'
            WHEN Net_Usage < (SELECT AVG(Net_Usage) FROM net) THEN 'Restock bikes'
            ELSE 'No action' END AS Suggested_Action
FROM net
ORDER BY Net_Usage DESC, Station_ID;

-- ---------------------------------------------------------------------
-- Q4. Peak vs off-peak trips: duration and distance.
-- DEFINITION (different from Q1 on purpose): PEAK = commute rush hours
--   7:00-9:59 and 17:00-19:59, as given in the PDF note for Q5.
-- ---------------------------------------------------------------------
-- @export s3q4_peak_vs_offpeak
SELECT Time_Period,
       COUNT(*)                         AS Total_Trips,
       ROUND(AVG(Trip_Duration_Min), 2) AS Avg_Trip_Duration,
       ROUND(AVG(Distance_KM), 2)       AS Avg_Trip_Distance,
       CASE WHEN Time_Period = 'Peak Hours' THEN 'Commute' ELSE 'Leisure' END AS Primary_Ride_Type
FROM (
    SELECT Trip_Duration_Min, Distance_KM,
           CASE WHEN HOUR(Start_Time) BETWEEN 7 AND 9
                  OR HOUR(Start_Time) BETWEEN 17 AND 19 THEN 'Peak Hours' ELSE 'Off-Peak' END
               AS Time_Period
    FROM trips
) AS labelled
GROUP BY Time_Period
ORDER BY Time_Period DESC;

-- ---------------------------------------------------------------------
-- Q5. Stations whose BUSIEST hour is NOT a normal commute hour.
-- Method: count trips per (station, hour) -> rank hours inside each
--         station -> keep rank 1 -> flag if outside 7-9 / 17-19.
-- ROW_NUMBER (not RANK) so a tie gives exactly one row per station
-- (earliest hour wins).
-- ---------------------------------------------------------------------
-- @export s3q5_unusual_peak_stations
WITH station_hour AS (
    SELECT Start_Station_ID AS Station_ID,
           HOUR(Start_Time) AS Peak_Usage_Hour,
           COUNT(*)         AS Total_Ride_During_Peak
    FROM trips
    GROUP BY Start_Station_ID, HOUR(Start_Time)
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (
                  PARTITION BY Station_ID
                  ORDER BY Total_Ride_During_Peak DESC, Peak_Usage_Hour) AS rn
    FROM station_hour
)
SELECT s.Station_Name,
       r.Peak_Usage_Hour,
       r.Total_Ride_During_Peak,
       CASE WHEN r.Peak_Usage_Hour BETWEEN 7 AND 9
              OR r.Peak_Usage_Hour BETWEEN 17 AND 19 THEN 'No' ELSE 'Yes' END AS Unusual_Peak_Pattern,
       CASE WHEN r.Peak_Usage_Hour >= 22 OR r.Peak_Usage_Hour <= 4 THEN 'Night-peak zone'
            ELSE '-' END AS Night_Zone_Flag
FROM ranked r
JOIN stations s ON s.Station_ID = r.Station_ID
WHERE r.rn = 1
ORDER BY r.Total_Ride_During_Peak DESC, s.Station_ID
LIMIT 20;

-- How many stations are "unusual" in total?
-- @export s3q5b_unusual_summary
WITH station_hour AS (
    SELECT Start_Station_ID AS Station_ID, HOUR(Start_Time) AS h, COUNT(*) AS c
    FROM trips GROUP BY Start_Station_ID, HOUR(Start_Time)
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY Station_ID ORDER BY c DESC, h) AS rn
    FROM station_hour
),
labelled AS (
    SELECT Station_ID,
           CASE WHEN h BETWEEN 7 AND 9 OR h BETWEEN 17 AND 19
                THEN 'Commute-hour peak' ELSE 'Unusual peak' END AS Pattern
    FROM ranked
    WHERE rn = 1
)
SELECT Pattern,
       COUNT(*) AS Stations,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM stations), 1) AS Pct_Of_Stations
FROM labelled
GROUP BY Pattern
ORDER BY Pattern;
