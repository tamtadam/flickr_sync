DROP TABLE IF EXISTS photoids_to_delete;
CREATE TEMPORARY TABLE photoids_to_delete
	SELECT PhotoID FROM flickr.v_photosinset where PhotoStatus ="DELETEIT" AND SetTitle LIKE "2016_%";


UPDATE photos SET Status = "DELETED" where PhotoID IN(
	SELECT PhotoID FROM photoids_to_delete
);
