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

#$flickr->add_tag( $flickr->mark_for_delete( '2015_' ) );

$flickr->add_tag( $flickr->mark_for_delete( '2016_' ) );

#$flickr->add_tag( $flickr->mark_for_delete( '2017_' ) );



