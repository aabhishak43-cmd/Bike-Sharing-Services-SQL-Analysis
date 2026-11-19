-- =====================================================================
-- 01_schema_and_load.sql
-- Purpose : Create database, tables (with keys) and load the 7 CSV files
-- Engine  : MySQL 8.0+ (also runs on MariaDB 10.5+)
-- Run from: the project root folder so the relative 'data/' paths work
-- =====================================================================
DROP DATABASE IF EXISTS bike_sharing;
CREATE DATABASE bike_sharing;
USE bike_sharing;

CREATE TABLE users (
    User_ID           INT PRIMARY KEY,
    Age               INT,
    Gender            VARCHAR(10),
    Subscription_Type VARCHAR(10),
    Signup_Date       DATE,
    City              VARCHAR(50)
);

CREATE TABLE stations (
    Station_ID            INT PRIMARY KEY,
    Station_Name          VARCHAR(100),
    Latitude              DOUBLE,
    Longitude             DOUBLE,
    City                  VARCHAR(50),
    Bike_Capacity         INT,
    Total_Bikes_Available INT
);

CREATE TABLE bikes (
    Bike_ID               INT PRIMARY KEY,
    Bike_Type             VARCHAR(10),
    Purchase_Date         DATE,
    Last_Maintenance_Date DATE
);

CREATE TABLE trips (
    Trip_ID           INT PRIMARY KEY,
    User_ID           INT NULL,            -- NULL allowed: casual guests may have no ID
    Bike_ID           INT,
    Start_Station_ID  INT,
    End_Station_ID    INT,
    Start_Time        DATETIME,
    End_Time          DATETIME,
    Trip_Duration_Min INT,
    Distance_KM       DOUBLE,
    Ride_Type         VARCHAR(10)
);

CREATE TABLE weather (
    City           VARCHAR(50),
    Date           DATETIME,
    Temperature_C  DOUBLE,
    Rainfall_MM    DOUBLE,
    Wind_Speed_KMH DOUBLE,
    Humidity_PCT   DOUBLE
);

CREATE TABLE maintenance (
    Bike_ID          INT,
    Maintenance_Date DATE,
    Issue_Reported   VARCHAR(30),
    Downtime_Hours   INT
);

CREATE TABLE revenue (
    User_ID      INT,
    Date         DATE,
    Payment_Type VARCHAR(20),
    Total_Fare   DOUBLE,
    Fines        DOUBLE
);

-- ---------- LOAD DATA ----------
-- If you get a "local_infile" error, run:  SET GLOBAL local_infile = 1;
-- and connect with:  mysql --local-infile=1 -u root -p
-- (Alternative: Workbench -> right-click table -> Table Data Import Wizard)

LOAD DATA LOCAL INFILE 'data/Final_Users_Data.csv' INTO TABLE users
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'data/Final_Stations_Data.csv' INTO TABLE stations
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'data/Final_Bikes_Data.csv' INTO TABLE bikes
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'data/Final_Trips_Data.csv' INTO TABLE trips
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'data/Final_Weather_Data.csv' INTO TABLE weather
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'data/Final_Maintenance_Data.csv' INTO TABLE maintenance
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;

LOAD DATA LOCAL INFILE 'data/Final_Revenue_Data.csv' INTO TABLE revenue
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;

-- Indexes to speed up the join-heavy queries in Stages 3-5
CREATE INDEX idx_trips_user  ON trips(User_ID);
CREATE INDEX idx_trips_bike  ON trips(Bike_ID);
CREATE INDEX idx_trips_start ON trips(Start_Station_ID);
CREATE INDEX idx_trips_end   ON trips(End_Station_ID);
CREATE INDEX idx_maint_bike  ON maintenance(Bike_ID);
