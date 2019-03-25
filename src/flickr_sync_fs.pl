use strict;
use FlickrSync;
use Data::Dumper;
use FindBin ;

use Thread::Pool::Simple;
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

$flickr->sync_nas_to_db( "z:\\2015\\" );
$flickr->sync_nas_to_db( "z:\\2016\\" );
$flickr->sync_nas_to_db( "z:\\2017\\" );

