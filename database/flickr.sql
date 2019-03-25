DROP TABLE IF EXISTS Sets;
CREATE TABLE `Sets` (
	`SetID`	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	`ExternalID`	INTEGER NOT NULL UNIQUE,
	`SecretID`	INTEGER NOT NULL UNIQUE,
	`Title`	        TEXT NOT NULL,
	`Status`	TEXT NOT NULL,
	`Photos`	INTEGER,
	`Description`	TEXT,
	`Videos`	INTEGER,
	`PrimaryPhotoID`	INTEGER
);

DROP TABLE IF EXISTS Photos;
CREATE TABLE `Photos` (
	`PhotoID`	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	`Title`	INTEGER NOT NULL,
	`SecretID`	INTEGER NOT NULL UNIQUE,
	`Status`	TEXT NOT NULL,
	`ExternalID`	INTEGER NOT NULL
);

DROP TABLE IF EXISTS PhotosInSet;
CREATE TABLE `PhotosInSet` (
	`PhotosInSetID`	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	`PhotoID`	INTEGER NOT NULL,
	`PhotoTitle`	TEXT NOT NULL,
	`SetID`	INTEGER NOT NULL
);

DROP TABLE IF EXISTS PhotosInNAS;
CREATE TABLE `PhotosInNAS` (
	`PhotosInNASID`	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT UNIQUE,
	`Path`	TEXT NOT NULL,
	`Status`	TEXT NOT NULL,
	`FullFileName`	TEXT NOT NULL,
	`FileName`	TEXT NOT NULL,
	`LastSet`	TEXT NOT NULL,
	`Dir`	TEXT NOT NULL,
	`SetID`	INTEGER NOT NULL
	
);

DROP TABLE IF EXISTS photos_in_set;
CREATE TEMPORARY  TABLE photos_in_set AS
	SELECT 
	ph.ExternalID as PhotoExternalID,
	ph.Title as PhotoTitle,
	ph.PhotoID as PhotoID,
	se.ExternalID as SetExternalID,
	se.Title as SetTitle,
	se.Description as SetDescription,
	se.SetID as SetID,
	se.Title || "\\" || ph.Title as LastPartOfPath
	FROM PhotosInSet as pis 
	JOIN Photos as ph ON pis.PhotoID = ph.PhotoID
	JOIN Sets as se ON pis.SetID = se.SetID
	WHERE se.Title = se.Description;
