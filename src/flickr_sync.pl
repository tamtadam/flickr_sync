use strict;
use FlickrSync;
use Data::Dumper;
use FindBin ;


use lib $FindBin::RealBin;
use lib $FindBin::RealBin . "../../../common/cgi-bin/" ;
use lib $FindBin::RealBin . "../../cgi-bin/" ;

use DBConnHandler;

$ENV{ SQLITE } = "../database/flickr.sqlite";

my $flickr = FlickrSync->new( {
    DB_HANDLE => &DBConnHandler::init() , 
    auth      => '.flickroauth.st',
    user_id   => '138370151@N02',
} );



=pod
my $response = $flickr->get_photos_by_set( {
    user_id => '138370151@N02',
    photoset_id => '72157700284049242',
});

print Dumper scalar @{ $response };



my $response = $flickr->call('flickr.photosets.getList', {
    user_id => '138370151@N02'
});

print Dumper $response->{hash}->{photosets}->{photoset};


$response = $flickr->call('flickr.photosets.getPhotos', {
    user_id => '138370151@N02',
    photoset_id => '72157699960640202'
});

print Dumper $response->{hash}->{photoset}->{photo};


$flickr->sync_flickr_to_db( {
    user_id => '138370151@N02'
} );
=cut

$flickr->sync_nas_to_db( "z:\\2017\\" );





