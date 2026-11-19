-- =====================================================================
-- 03_stage2_data_cleaning.sql
-- STAGE 2: Data Cleaning & Integrity Management
-- GOAL   : Fix what is wrong, and change as little as possible.
-- IMPORTANT: this script modifies tables. It was written to be run ONCE
--            after 01_schema_and_load.sql. To start again, re-run 01.
-- =====================================================================
USE bike_sharing;

-- MySQL Workbench blocks UPDATE/DELETE without a key in WHERE ("Safe
-- Update Mode"). The PDF asks us to switch it off for this stage.
SET SQL_SAFE_UPDATES = 0;

-- ---------------------------------------------------------------------
-- SAFETY NET: take a backup copy before we change anything.
-- If a cleaning step goes wrong we can compare with / restore from this.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS trips_backup;
CREATE TABLE trips_backup AS SELECT * FROM trips;

DROP TABLE IF EXISTS stations_backup;
CREATE TABLE stations_backup AS SELECT * FROM stations;

-- =====================================================================
-- Q1. Duplicate trip records
-- =====================================================================
-- Step 1: FIND duplicates. ROW_NUMBER() numbers the rows inside each
--         group of identical (Trip_ID, Start_Time, User_ID, Bike_ID).
--         Row 1 = the original, row 2+ = duplicates.
-- @export s2q1_duplicate_check
SELECT COUNT(*) AS Duplicate_Rows_Found
FROM (
    SELECT ROW_NUMBER() OVER (
               PARTITION BY Trip_ID, Start_Time, User_ID, Bike_ID
               ORDER BY Trip_ID) AS rn
    FROM trips
) AS numbered
WHERE rn > 1;

-- Step 2: DELETE only the extra copies (rn > 1), keep the first one.
--         We delete by joining to the numbered list - a plain
--         "DELETE ... WHERE (subquery on same table)" is not allowed in MySQL.
--         On this dataset it removes 0 rows because none exist.
DELETE t
FROM trips t
JOIN (
    SELECT Trip_ID, Start_Time, User_ID, Bike_ID,
           ROW_NUMBER() OVER (
               PARTITION BY Trip_ID, Start_Time, User_ID, Bike_ID
               ORDER BY Trip_ID) AS rn
    FROM trips
) AS d
  ON  d.Trip_ID = t.Trip_ID AND d.Start_Time = t.Start_Time
  AND d.User_ID = t.User_ID AND d.Bike_ID    = t.Bike_ID
WHERE d.rn > 1;

-- Step 3: PROVE we did not destroy valid multi-bike rentals.
--         Same user, overlapping time, DIFFERENT bikes = a real
--         multi-bike rental (e.g. a family). These must stay.
-- @export s2q1_valid_multibike_rentals
SELECT COUNT(*) AS Multi_Bike_Overlap_Pairs_Kept
FROM trips a
JOIN trips b ON a.User_ID = b.User_ID
            AND a.Bike_ID <> b.Bike_ID
            AND a.Trip_ID < b.Trip_ID
            AND a.Start_Time < b.End_Time AND b.Start_Time < a.End_Time;

-- Step 4: FLAG (do not delete) the same BIKE used in two trips at the
--         same time. A bike cannot be in two places, so one of the two
--         records is wrong - but we cannot know which one, so we list
--         them for review instead of guessing.
-- @export s2q1_same_bike_overlap_review
SELECT a.Bike_ID,
       a.Trip_ID AS Trip_A, a.Start_Time AS A_Start, a.End_Time AS A_End,
       b.Trip_ID AS Trip_B, b.Start_Time AS B_Start, b.End_Time AS B_End
FROM trips a
JOIN trips b ON a.Bike_ID = b.Bike_ID
            AND a.Trip_ID < b.Trip_ID
            AND a.Start_Time < b.End_Time AND b.Start_Time < a.End_Time
ORDER BY a.Bike_ID, a.Start_Time;

-- =====================================================================
-- Q2. Missing User IDs
-- =====================================================================
-- Step 1: Do missing IDs cluster at certain stations / hours?
--         (Returns no rows here because there are no missing IDs.)
-- @export s2q2_missing_userid_clusters
SELECT Start_Station_ID, HOUR(Start_Time) AS Start_Hour, COUNT(*) AS Missing_Count
FROM trips
WHERE User_ID IS NULL
GROUP BY Start_Station_ID, HOUR(Start_Time)
ORDER BY Missing_Count DESC;

-- Step 2: Label missing IDs as 'CASUAL_UNKNOWN' - casual rides ONLY.
--         User_ID is a number (INT), so we cannot store text in it.
--         Instead we add a NEW text column User_Key and leave User_ID
--         untouched. That way joins to the users table still work and
--         counts like COUNT(DISTINCT User_ID) are not disturbed.
ALTER TABLE trips ADD COLUMN User_Key VARCHAR(20);

UPDATE trips
SET User_Key = CASE
                   WHEN User_ID IS NOT NULL    THEN CAST(User_ID AS CHAR)
                   WHEN Ride_Type = 'Casual'   THEN 'CASUAL_UNKNOWN'
                   ELSE NULL                   -- non-casual with no ID stays NULL (would be a real error)
               END;

-- Step 3: Verify. Non-casual rides must never get the label.
-- @export s2q2_verify_user_key
SELECT Ride_Type,
       CAST(SUM(User_Key = 'CASUAL_UNKNOWN') AS UNSIGNED) AS Labelled_Casual_Unknown,
       CAST(SUM(User_Key IS NULL) AS UNSIGNED)            AS Still_Null,
       COUNT(*)                                           AS Total_Trips
FROM trips
GROUP BY Ride_Type
ORDER BY Ride_Type;

-- Step 4: "No overlap between casual and subscription riders"?
--         We check how many users appear under more than one Ride_Type.
-- @export s2q2_users_with_multiple_ride_types
SELECT Ride_Types_Used AS Ride_Types_Per_User,
       COUNT(*)        AS Users
FROM (
    SELECT User_ID, COUNT(DISTINCT Ride_Type) AS Ride_Types_Used
    FROM trips
    WHERE User_ID IS NOT NULL
    GROUP BY User_ID
) AS u
GROUP BY Ride_Types_Used
ORDER BY Ride_Types_Per_User;

-- =====================================================================
-- Q3. Negative trip durations
-- =====================================================================
-- Step 1: Find them. We check BOTH the stored duration AND the duration
--         recalculated from the timestamps.
-- @export s2q3_negative_duration_check
SELECT
    CAST(SUM(Trip_Duration_Min < 0) AS UNSIGNED)                              AS Negative_Stored_Duration,
    CAST(SUM(TIMESTAMPDIFF(MINUTE, Start_Time, End_Time) < 0) AS UNSIGNED)    AS Negative_From_Timestamps,
    CAST(SUM(Trip_Duration_Min BETWEEN -5 AND -1) AS UNSIGNED)                AS Minor_Errors_To_Fix,
    CAST(SUM(Trip_Duration_Min < -5) AS UNSIGNED)                             AS Large_Errors_To_Delete
FROM trips;

-- Step 2: Do certain stations have more of these errors?
--         (Empty here - no negative durations.)
-- @export s2q3_negative_by_station
SELECT Start_Station_ID, COUNT(*) AS Negative_Duration_Trips
FROM trips
WHERE Trip_Duration_Min < 0
GROUP BY Start_Station_ID
ORDER BY Negative_Duration_Trips DESC;

-- Step 3: MINOR errors (-5 to -1 min): repair, do not delete.
--         Replace with that station's average valid duration and rebuild
--         End_Time so timestamps and duration agree again.
UPDATE trips t
JOIN (
    SELECT Start_Station_ID, ROUND(AVG(Trip_Duration_Min)) AS Avg_Duration
    FROM trips
    WHERE Trip_Duration_Min > 0
    GROUP BY Start_Station_ID
) AS s ON s.Start_Station_ID = t.Start_Station_ID
SET t.Trip_Duration_Min = s.Avg_Duration,
    t.End_Time          = DATE_ADD(t.Start_Time, INTERVAL s.Avg_Duration MINUTE)
WHERE t.Trip_Duration_Min BETWEEN -5 AND -1;

-- Step 4: LARGE errors (below -5 min): delete, they would distort demand.
DELETE FROM trips WHERE Trip_Duration_Min < -5;

-- =====================================================================
-- Q4. Station name standardisation
-- =====================================================================
-- Step 1: Look for abbreviations, stray spaces or other oddities.
-- @export s2q4_station_name_issues
SELECT Station_ID, Station_Name
FROM stations
WHERE Station_Name <> TRIM(Station_Name)
   OR Station_Name REGEXP '(?i)\\b(st|ave|rd|blvd)\\b\\.?'
   OR Station_Name NOT REGEXP '^Station [0-9]+$';

-- Step 2: Standardise. \b means "whole word only", so 'st' inside the
--         word "Station" is NOT touched. (?i) = ignore upper/lower case.
UPDATE stations
SET Station_Name = TRIM(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
        REGEXP_REPLACE(Station_Name,
            '(?i)\\bst\\b\\.?',   'Street'),
            '(?i)\\bave\\b\\.?',  'Avenue'),
            '(?i)\\brd\\b\\.?',   'Road'),
            '(?i)\\bblvd\\b\\.?', 'Boulevard'));

-- Why "all past and future trips are aligned": trips store only the
-- Station_ID. The NAME lives in ONE place (stations). Fix it there once
-- and every trip - old or new - shows the corrected name via the join.

-- =====================================================================
-- FINAL CHECK: before vs after cleaning
-- =====================================================================
-- @export s2_before_after_summary
SELECT 'trips'    AS Table_Name,
       (SELECT COUNT(*) FROM trips_backup)    AS Rows_Before,
       (SELECT COUNT(*) FROM trips)           AS Rows_After,
       (SELECT COUNT(*) FROM trips_backup) - (SELECT COUNT(*) FROM trips) AS Rows_Removed
UNION ALL
SELECT 'stations',
       (SELECT COUNT(*) FROM stations_backup),
       (SELECT COUNT(*) FROM stations),
       (SELECT COUNT(*) FROM stations_backup) - (SELECT COUNT(*) FROM stations);

SET SQL_SAFE_UPDATES = 1;
