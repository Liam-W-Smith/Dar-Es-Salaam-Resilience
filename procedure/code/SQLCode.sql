/* (1) Prep Food!*/
/* a) Extract food sellers*/
CREATE TABLE foodpoints2 AS
SELECT name, amenity, shop, osm_id, way
FROM planet_osm_point
WHERE amenity = 'marketplace' OR shop IN ('convenience', 'supermarket', 'kiosk', 'bakery', 'butcher', 'greengrocer', 'pastry')

CREATE TABLE foodpolygons AS
SELECT name, amenity, shop, osm_id, way
FROM planet_osm_polygon
WHERE amenity = 'marketplace' OR shop IN ('convenience', 'supermarket', 'kiosk', 'bakery', 'butcher', 'greengrocer', 'pastry')

/* b) Union the points and polygon grocers while making the polygon grocers into points */
CREATE TABLE foodsources AS
SELECT name, osm_id, st_transform(way, 32737)::geometry(point, 32737) AS geom FROM foodpoints2
UNION
SELECT name, osm_id, st_transform(st_centroid(way), 32737)::geometry(point,32737) AS geom FROM foodpolygons

/* (2) Flood the Food! */
/* a) Fix the flood geometry*/
UPDATE flood
SET geom = st_makevalid(geom)

/* b) Dissolve the flood polygons into one feature */
CREATE TABLE flooddissolve AS
SELECT st_union(geom)::geometry(multipolygon,32737) as geom
FROM flood

/* c) Create table of foodsources that intersect the flood zones  */
CREATE TABLE foodflood AS
SELECT foodsources .*, st_multi(st_intersection(foodsources.geom, flooddissolve.geom))::geometry(multipoint, 32737) as geom2
FROM foodsources INNER JOIN flooddissolve
ON st_intersects(foodsources.geom, flooddissolve.geom)

/* d) Delete old geometry column*/
ALTER TABLE foodflood
DROP COLUMN geom

/* (3) Find Residences */
/* a) Extract residences*/
CREATE TABLE residencepoints2 AS
SELECT building, osm_id, way
FROM planet_osm_point
WHERE building IN ('residential', 'yes')

CREATE TABLE residencepolygons AS
SELECT building, osm_id, way
FROM planet_osm_polygon
WHERE building IN ('residential', 'yes')

/* b) Union the points and polygon residences while making the polygons into points. I also took some time here to create spatial indices for wards, residences, and foodsources! */
CREATE TABLE residences AS
SELECT osm_id, st_transform(way, 32737)::geometry(point, 32737) AS geom FROM residencepoints2
UNION
SELECT osm_id, st_transform(st_centroid(way), 32737)::geometry(point,32737) AS geom FROM residencepolygons

/* c) Join ward information to residences */
ALTER TABLE residences
ADD COLUMN ward text

UPDATE residences
SET ward = wards.ward_name
FROM wards
WHERE st_contains(wards.utmgeom, residences.geom)

/* (4) Share the Food */
/* a) calculate distance in normal times */
CREATE TABLE foodaccess AS
SELECT residences.*, st_distance(a.foodsourcesgeom, residences.geom) AS dist
FROM residences CROSS JOIN lateral (
	SELECT foodsources.geom AS foodsourcesgeom
	FROM foodsources
	ORDER BY foodsources.geom <-> residences.geom
	LIMIT 1) a

/* b) find stores that are not flooded (and then made spatial index) */
CREATE TABLE alt_foodnotflood AS
SELECT *
FROM foodsources
WHERE osm_id NOT IN (SELECT osm_id FROM foodflood)

/* c) calculate distance for flooded times  */
CREATE TABLE foodaccess_flood AS
SELECT residences.*, st_distance(a.alt_foodnotfloodgeom, residences.geom) AS dist
FROM residences CROSS JOIN lateral (
	SELECT alt_foodnotflood.geom AS alt_foodnotfloodgeom
	FROM alt_foodnotflood
	ORDER BY alt_foodnotflood.geom <-> residences.geom
	LIMIT 1) a

/* d) group the food access tables by ward*/
CREATE TABLE foodaccess_wards AS
SELECT ward, avg(dist)
FROM foodaccess
GROUP BY ward

CREATE TABLE foodaccess_flood_wards AS
SELECT ward, avg(dist)
FROM foodaccess_flood
GROUP BY ward

/*e) Finding the change in distance for each ward */

CREATE TABLE change_in_access_wards AS
SELECT foodaccess_flood_wards.ward, foodaccess_flood_wards.avg AS flood_avg_dist, foodaccess_wards.avg AS normal_avg_dist, foodaccess_flood_wards.avg - foodaccess_wards.avg AS change_avg_dist
FROM foodaccess_flood_wards LEFT JOIN foodaccess_wards
ON foodaccess_flood_wards.ward = foodaccess_wards.ward

/* f) Joining Ward geometry back to change_in_access_wards*/
ALTER TABLE wards
ADD COLUMN change_avg_dist REAL

UPDATE wards
SET change_avg_dist = change_in_access_wards.change_avg_dist
FROM change_in_access_wards
WHERE wards.ward_name = change_in_access_wards.ward

/* g) Turns out, my results might be better illustrated if I did not group by ward. Below, I calculate summary statistics NOT grouped by ward*/
CREATE TABLE change_in_access AS
SELECT foodaccess_flood.osm_id, foodaccess_flood.geom, foodaccess_flood.dist AS flood_dist, foodaccess.dist AS normal_dist, foodaccess_flood.dist - foodaccess.dist AS change_dist
FROM foodaccess_flood LEFT JOIN foodaccess
ON foodaccess_flood.osm_id = foodaccess.osm_id

/* h) Finding the residences where the distance to the nearest grocery store changed by over 500 meters*/
CREATE TABLE meters_500 AS
SELECT *
FROM change_in_access
WHERE change_dist > 500
