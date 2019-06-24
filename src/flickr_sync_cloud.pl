use strict;
use FlickrSync;
use Data::Dumper;
use FindBin ;


use lib $FindBin::RealBin;
use lib $FindBin::RealBin . "../../../common/cgi-bin/" ;
use lib $FindBin::RealBin . "../../cgi-bin/" ;

use DBConnHandler;

#$ENV{ SQLITE } = "../database/flickr.sqlite";

my $flickr = FlickrSync->new( {
    DB_HANDLE => &DBConnHandler::init( 'server.cfg' ) , 
    auth      => '.flickroauth.st',
    user_id   => '138370151@N02',
} );


$flickr->sync_flickr_to_db( {
    user_id => '138370151@N02',
    filter  => '2019_06_17_baboci'
} );

