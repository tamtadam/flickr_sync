use strict;
use FlickrSync;
use Data::Dumper;
use FindBin ;

use Thread::Pool::Simple;
use lib $FindBin::RealBin;
use lib $FindBin::RealBin . "../../../common/cgi-bin/" ;
use lib $FindBin::RealBin . "../../cgi-bin/" ;

use DBConnHandler;
use ImageData;

my $id = new ImageData();

#$ENV{ SQLITE } = "../database/flickr.sqlite";

my $flickr = FlickrSync->new( {
    DB_HANDLE => &DBConnHandler::init( 'server.cfg' ) , 
    auth      => '.flickroauth.st',
    user_id   => '138370151@N02',
    image_data => $id
} );

$flickr->remove_tags( {
    user_id => '138370151@N02',
    filter  => '2018_MALDIV_vizalatti' ,
    tags    => [
        'mm'
    ]
} );


