-- =====================================================================
-- 02_stage1_data_exploration.sql
-- STAGE 1: Data Exploration & Quality Assessment
-- GOAL   : Before any analysis, check that the data is complete,
--          has no hidden gaps, and is safe to trust.
-- =====================================================================
USE bike_sharing;

-- ---------------------------------------------------------------------
-- Q1. How does the volume of records in each table compare to the
--     expected operational usage?
-- WHY : If a table has fewer rows than expected, data may have been lost
--       during logging or import. We compare actual vs expected minimum.
-- NOTE: "Expected" values are OUR assumptions (the PDF says to set our
--       own thresholds). Weather = 365 days x 24 hours = 8,760 rows.
-- ---------------------------------------------------------------------
-- @export s1q1_record_counts
SELECT Table_Name,
       Total_Records,
       Expected_Min_Records,
       CASE WHEN Total_Records >= Expected_Min_Records THEN 'Yes' ELSE 'No' END
           AS Expected_Volume_Verified
FROM (
    SELECT 'Bike Trips'  AS Table_Name, COUNT(*) AS Total_Records, 20000 AS Expected_Min_Records FROM trips
    UNION ALL SELECT 'Users',       COUNT(*), 1000 FROM users
    UNION ALL SELECT 'Stations',    COUNT(*), 100  FROM stations
    UNION ALL SELECT 'Bikes',       COUNT(*), 500  FROM bikes
    UNION ALL SELECT 'Weather',     COUNT(*), 8760 FROM weather
    UNION ALL SELECT 'Maintenance', COUNT(*), 5000 FROM maintenance
    UNION ALL SELECT 'Revenue',     COUNT(*), 1000 FROM revenue
) AS counts;

-- Extra coverage check: do we have trips in every month of the year?
-- @export s1q1b_trips_per_month
SELECT DATE_FORMAT(Start_Time, '%Y-%m') AS Trip_Month,
       COUNT(*)                         AS Total_Trips
FROM trips
GROUP BY DATE_FORMAT(Start_Time, '%Y-%m')
ORDER BY Trip_Month;

-- ---------------------------------------------------------------------
-- Q2. How do missing values in key fields affect trip analysis?
-- WHY : NULLs in timestamps / IDs / stations silently drop rows from
--       joins and averages. We measure how many and grade the impact.
-- BUCKETS (our own): < 1% = Low, 1-5% = Medium, > 5% = High
-- ---------------------------------------------------------------------
-- @export s1q2_missing_values
SELECT Column_Name,
       Missing_Values,
       ROUND(Missing_Values * 100.0 / Total_Rows, 3) AS Percentage_Missing,
       CASE WHEN Missing_Values * 100.0 / Total_Rows < 1 THEN 'Low'
            WHEN Missing_Values * 100.0 / Total_Rows < 5 THEN 'Medium'
            ELSE 'High' END                          AS Impact_Level
FROM (
    SELECT 'Trip_ID'           AS Column_Name, CAST(SUM(Trip_ID IS NULL) AS UNSIGNED)           AS Missing_Values, COUNT(*) AS Total_Rows FROM trips
    UNION ALL SELECT 'User_ID',           CAST(SUM(User_ID IS NULL) AS UNSIGNED),           COUNT(*) FROM trips
    UNION ALL SELECT 'Bike_ID',           CAST(SUM(Bike_ID IS NULL) AS UNSIGNED),           COUNT(*) FROM trips
    UNION ALL SELECT 'Start_Station_ID',  CAST(SUM(Start_Station_ID IS NULL) AS UNSIGNED),  COUNT(*) FROM trips
    UNION ALL SELECT 'End_Station_ID',    CAST(SUM(End_Station_ID IS NULL) AS UNSIGNED),    COUNT(*) FROM trips
    UNION ALL SELECT 'Start_Time',        CAST(SUM(Start_Time IS NULL) AS UNSIGNED),        COUNT(*) FROM trips
    UNION ALL SELECT 'End_Time',          CAST(SUM(End_Time IS NULL) AS UNSIGNED),          COUNT(*) FROM trips
    UNION ALL SELECT 'Trip_Duration_Min', CAST(SUM(Trip_Duration_Min IS NULL) AS UNSIGNED), COUNT(*) FROM trips
    UNION ALL SELECT 'Distance_KM',       CAST(SUM(Distance_KM IS NULL) AS UNSIGNED),       COUNT(*) FROM trips
    UNION ALL SELECT 'Ride_Type',         CAST(SUM(Ride_Type IS NULL) AS UNSIGNED),         COUNT(*) FROM trips
) AS m;

-- ---------------------------------------------------------------------
-- Q3. How are missing User_IDs distributed across ride types?
-- WHY : If NULL User_IDs were concentrated in Casual rides, it would
--       mean guests ride without an account (normal) and not a bug.
-- ---------------------------------------------------------------------
-- @export s1q3_missing_userid_by_ride_type
SELECT Ride_Type,
       CAST(SUM(User_ID IS NULL) AS UNSIGNED)                 AS Missing_User_ID_Count,
       COUNT(*)                                               AS Total_Trips,
       ROUND(SUM(User_ID IS NULL) * 100.0 / COUNT(*), 2)      AS Percentage
FROM trips
GROUP BY Ride_Type
ORDER BY Ride_Type;

-- ---------------------------------------------------------------------
-- EXTRA (Stage 1 text also asks for duplicates, negative durations and
-- "suspect entries"). One summary table of integrity checks.
-- Every check should be 0 if the data is clean - except the ones we
-- explain in the write-up (overlaps, ride-type mismatch).
-- ---------------------------------------------------------------------
-- @export s1_integrity_checks
SELECT 'Duplicate Trip_ID' AS Check_Name, COUNT(*) - COUNT(DISTINCT Trip_ID) AS Rows_Found FROM trips
UNION ALL
SELECT 'Duplicate on Trip_ID+Start_Time+User_ID+Bike_ID', COUNT(*) FROM (
    SELECT Trip_ID FROM trips GROUP BY Trip_ID, Start_Time, User_ID, Bike_ID HAVING COUNT(*) > 1) d
UNION ALL
SELECT 'Negative Trip_Duration_Min', COUNT(*) FROM trips WHERE Trip_Duration_Min < 0
UNION ALL
SELECT 'End_Time before Start_Time', COUNT(*) FROM trips WHERE End_Time < Start_Time
UNION ALL
SELECT 'Duration does not match timestamps', COUNT(*) FROM trips
 WHERE Trip_Duration_Min <> TIMESTAMPDIFF(MINUTE, Start_Time, End_Time)
UNION ALL
SELECT 'Distance <= 0 km', COUNT(*) FROM trips WHERE Distance_KM <= 0
UNION ALL
SELECT 'Trips pointing to a missing user', COUNT(*) FROM trips t
 LEFT JOIN users u ON u.User_ID = t.User_ID WHERE u.User_ID IS NULL
UNION ALL
SELECT 'Trips pointing to a missing bike', COUNT(*) FROM trips t
 LEFT JOIN bikes b ON b.Bike_ID = t.Bike_ID WHERE b.Bike_ID IS NULL
UNION ALL
SELECT 'Trips pointing to a missing start station', COUNT(*) FROM trips t
 LEFT JOIN stations s ON s.Station_ID = t.Start_Station_ID WHERE s.Station_ID IS NULL
UNION ALL
SELECT 'Trips pointing to a missing end station', COUNT(*) FROM trips t
 LEFT JOIN stations s ON s.Station_ID = t.End_Station_ID WHERE s.Station_ID IS NULL
UNION ALL
SELECT 'Same bike in two overlapping trips (pairs)', COUNT(*) FROM trips a
 JOIN trips b ON a.Bike_ID = b.Bike_ID AND a.Trip_ID < b.Trip_ID
             AND a.Start_Time < b.End_Time AND b.Start_Time < a.End_Time
UNION ALL
SELECT 'Same user in two overlapping trips (pairs)', COUNT(*) FROM trips a
 JOIN trips b ON a.User_ID = b.User_ID AND a.Trip_ID < b.Trip_ID
             AND a.Start_Time < b.End_Time AND b.Start_Time < a.End_Time
UNION ALL
SELECT 'Trip Ride_Type differs from user Subscription_Type', COUNT(*) FROM trips t
 JOIN users u ON u.User_ID = t.User_ID WHERE t.Ride_Type <> u.Subscription_Type;
