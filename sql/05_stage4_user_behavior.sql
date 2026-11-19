-- =====================================================================
-- 05_stage4_user_behavior.sql
-- STAGE 4: User Behavior & Segmentation
-- GOAL   : How do different rider groups use the system?
-- NOTE   : "Ride_Type" comes from the TRIPS table (Casual / Monthly /
--          Yearly), exactly as the PDF's expected outputs do.
-- =====================================================================
USE bike_sharing;

-- ---------------------------------------------------------------------
-- Q1. How does ride behaviour differ across user types?
-- ---------------------------------------------------------------------
-- @export s4q1_ride_behavior_by_type
SELECT Ride_Type,
       ROUND(AVG(Trip_Duration_Min), 2) AS Avg_Duration,
       ROUND(AVG(Distance_KM), 2)       AS Avg_Distance,
       COUNT(*)                         AS Total_Trips,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM trips), 2) AS Share_Of_Trips_Pct,
       COUNT(DISTINCT User_ID)          AS Active_Users,
       ROUND(COUNT(*) / COUNT(DISTINCT User_ID), 2) AS Trips_Per_User
FROM trips
GROUP BY Ride_Type
ORDER BY Total_Trips DESC;

-- ---------------------------------------------------------------------
-- Q2. Who rides most often?  (trips per user + total distance)
-- ---------------------------------------------------------------------
-- (a) Top 10 by User + Ride_Type, the same grouping as the PDF sample.
-- @export s4q2_top_users
SELECT User_ID,
       Ride_Type,
       COUNT(*)                  AS Total_Trips,
       ROUND(SUM(Distance_KM), 1) AS Total_KM
FROM trips
GROUP BY User_ID, Ride_Type
ORDER BY Total_Trips DESC, Total_KM DESC
LIMIT 10;

-- (b) Top 10 per USER (all their rides together), with the plan they
--     signed up for in the users table.
-- @export s4q2b_top_users_overall
SELECT t.User_ID,
       u.Subscription_Type,
       COUNT(*)                   AS Total_Trips,
       ROUND(SUM(t.Distance_KM), 1) AS Total_KM
FROM trips t
JOIN users u ON u.User_ID = t.User_ID
GROUP BY t.User_ID, u.Subscription_Type
ORDER BY Total_Trips DESC, Total_KM DESC
LIMIT 10;

-- (c) Define "high-frequency" = the busiest 10% of users (NTILE splits
--     users into 10 equal groups; group 1 = top 10%). Which plan are
--     they on, and how much more do they ride?
-- @export s4q2c_high_frequency_segment
WITH per_user AS (
    SELECT t.User_ID, u.Subscription_Type,
           COUNT(*) AS Trips, SUM(t.Distance_KM) AS Km
    FROM trips t
    JOIN users u ON u.User_ID = t.User_ID
    GROUP BY t.User_ID, u.Subscription_Type
),
tiled AS (
    SELECT *, NTILE(10) OVER (ORDER BY Trips DESC, Km DESC) AS Decile
    FROM per_user
)
SELECT Subscription_Type,
       COUNT(*)                                          AS Users_Total,
       CAST(SUM(Decile = 1) AS UNSIGNED)                 AS High_Frequency_Users,
       ROUND(SUM(Decile = 1) * 100.0 / COUNT(*), 1)      AS Pct_High_Frequency,
       ROUND(AVG(Trips), 2)                              AS Avg_Trips_Per_User,
       ROUND(AVG(Km), 1)                                 AS Avg_KM_Per_User
FROM tiled
GROUP BY Subscription_Type
ORDER BY Subscription_Type;

-- ---------------------------------------------------------------------
-- Q3. Time-of-day preference by user type.
-- ---------------------------------------------------------------------
-- (a) Long format (hour x ride type) - exactly as the PDF sample.
-- @export s4q3_hourly_by_ride_type
SELECT HOUR(Start_Time) AS Hour_Of_Day,
       Ride_Type,
       COUNT(*)         AS Trip_Count
FROM trips
GROUP BY HOUR(Start_Time), Ride_Type
ORDER BY Hour_Of_Day, Ride_Type;

-- (b) Wide format (one row per hour, one column per type) - this is
--     the easiest shape to feed into a line chart in Power BI / Excel.
-- @export s4q3b_hourly_pivot
SELECT HOUR(Start_Time) AS Hour_Of_Day,
       CAST(SUM(Ride_Type = 'Casual')  AS UNSIGNED) AS Casual,
       CAST(SUM(Ride_Type = 'Monthly') AS UNSIGNED) AS Monthly,
       CAST(SUM(Ride_Type = 'Yearly')  AS UNSIGNED) AS Yearly,
       COUNT(*)                                     AS All_Rides
FROM trips
GROUP BY HOUR(Start_Time)
ORDER BY Hour_Of_Day;

-- (c) Each ride type's single busiest hour.
-- @export s4q3c_peak_hour_per_type
SELECT Ride_Type, Hour_Of_Day AS Busiest_Hour, Trip_Count
FROM (
    SELECT Ride_Type, HOUR(Start_Time) AS Hour_Of_Day, COUNT(*) AS Trip_Count,
           ROW_NUMBER() OVER (PARTITION BY Ride_Type ORDER BY COUNT(*) DESC, HOUR(Start_Time)) AS rn
    FROM trips
    GROUP BY Ride_Type, HOUR(Start_Time)
) AS x
WHERE rn = 1
ORDER BY Ride_Type;
