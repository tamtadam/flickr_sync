use strict;
use warnings;
use Data::Dumper;

use FindBin ;
use lib $FindBin::RealBin;
use lib $FindBin::RealBin . "../../../common/cgi-bin/" ;
use lib $FindBin::RealBin . "../../cgi-bin/" ;
use lib $FindBin::RealBin . "/../src/" ;

use Test::More tests => 9;

use TestMock;
use DBH;
use DBConnHandler;
use Flickr::API;
use FlickrSync;

my $db;
my $DBH;

sub BEGIN {
    $ENV{ TEST_SQLITE } = q~../database/flickr_qa.sqlite~;
    TestMock::set_test_dependent_db();
    $db = DBConnHandler::init();
    $DBH = new DBH( { DB_HANDLE => $db, noparams => 1 } ) ;
}

sub END {
    DBConnHandler::disconnect();
    TestMock::remove_test_db();
}

my $flickr_api_mock = TestMock->new( 'Flickr::API' );
   $flickr_api_mock->mock( 'new' );
   $flickr_api_mock->mock( 'import_storable_config' );
   $flickr_api_mock->mock( 'execute_method' );
   $flickr_api_mock->import_storable_config( bless{}, 'Flickr::API' );

my $fs = FlickrSync->new( {
    DB_HANDLE => $db , 
    auth      => '.flickroauth.st',
    user_id   => 'ezenvagyok',
} );

subtest 'call' => sub {
    $flickr_api_mock->execute_method( "response" );
 
    my $r = $fs->call('method', { param => "val" }, user_id => "uid" );
    
    ok( $r eq "response", "response returned" );
    $flickr_api_mock->empty_buffers( 'execute_method' );
};

subtest 'get_photosets' => sub {
    $flickr_api_mock->execute_method( {
        hash => {
            photosets => {
                photoset => [
                ]
            }
        }
    } );
 
    my $r = $fs->get_photosets( { param => "val", user_id => "uid" } );
    
    my @call_params = $flickr_api_mock->execute_method();
    ok("flickr.photosets.getList"  eq $call_params[ 1 ]);
    is_deeply( {
        param => 'val',
        user_id => 'uid'
    }, $call_params[ 2 ] );
    is_deeply( $r, [], "response returned" );
    $flickr_api_mock->empty_buffers( 'execute_method' );
};

subtest 'get_photos_by_set' => sub {
    $flickr_api_mock->execute_method( {
        hash => {
            photoset => {
                photo => [
                    5
                ],
                pages => 3,
                page  => 1
            }
        }
    } );
    $flickr_api_mock->execute_method( {
        hash => {
            photoset => {
                photo => [
                    7
                ],
                pages => 3,
                page  => 2
            }
        }
    } );
    $flickr_api_mock->execute_method( {
        hash => {
            photoset => {
                photo => [
                    9
                ],
                pages => 3,
                page  => 3
            }
        }
    } );

    my $r = $fs->get_photos_by_set( { param => "val", user_id => "uid" } );
    is_deeply( $r, [5, 7, 9], "response returned" );

    $flickr_api_mock->empty_buffers( 'execute_method' );
};


subtest 'sync_photoset_to_db' => sub {
    my $fs_mock = TestMock->new( 'FlickrSync' );
    $fs_mock->mock( 'get_photosets' );

    my $in = [
        {
            id => 10,
            title => '__2016__',
            photos => 10,
            description => '__2016__',
            videos => 10,
            primary => 10,
            secret => 10,
        },
        {
            id => 11,
            title => '2015_dec_23_',
            photos => 11,
            description => '2015_dec_23_',
            videos => 11,
            primary => 11,
            secret => 11,
        },
        {
            id => 11,
            title => '2017_dec_23_',
            photos => 11,
            description => '2016_dec_23_',
            videos => 11,
            primary => 11,
            secret => 11,
        }
    ];    
    $fs_mock->get_photosets( $in );

    my $res = $fs->sync_photoset_to_db( { param => "val", user_id => "uid" } );

    my $data = $DBH->my_select({
        from   => 'Sets',
        select => 'ALL',
    });
    ok( $res->[ 0 ]->{ SetID } == 1, 'id of the element' );
    
    is_deeply( [
          {
            'Photos' => '11',
            'Videos' => '11',
            'PrimaryPhotoID' => '11',
            'Status' => 'SYNCED',
            'ExternalID' => '11',
            'Title' => '2015_dec_23_',
            'SetID' => 1,
            'Description' => '2015_dec_23_',
            'SecretID' => '11',
          }
    ] , $data, "database is set properly for video");
    $flickr_api_mock->unmock( 'get_photosets' );
};

subtest 'sync_photos_to_db_by_set_id' => sub {
    my $fs_mock = TestMock->new( 'FlickrSync' );
    $fs_mock->mock( 'get_photos_by_set' );

    my $in = [
        {   
            map { $_ => $_ . "1" } qw(id title secret)
        },
        {
            map { $_ => $_ . "2" } qw(id title secret)
        },
        {
            map { $_ => $_ . "3" } qw(id title secret)
        }
    ];    
    $fs_mock->get_photos_by_set( $in );

    my $res = $fs->sync_photos_to_db_by_set_id( { SetID => 1, user_id => "uid" } );

    my $data = $DBH->my_select({
        from   => 'Photos',
        select => 'ALL',
    });
    
    is_deeply($data, [
          {
            'PhotoID' => 1,
            'Status' => 'SYNCED',
            'ExternalID' => 'id1',
            'Title' => 'title1',
            'SecretID' => 'secret1',
          },
          {
            'PhotoID' => 2,
            'Status' => 'SYNCED',
            'ExternalID' => 'id2',
            'Title' => 'title2',
            'SecretID' => 'secret2',
          },
          {
            'PhotoID' => 3,
            'Status' => 'SYNCED',
            'ExternalID' => 'id3',
            'Title' => 'title3',
            'SecretID' => 'secret3',
          }
    ], "database is set properly for photo");
    $flickr_api_mock->unmock( 'get_photosets' );
    $fs_mock->unmock( 'get_photos_by_set' );
};


subtest 'sync_flickr_to_db' => sub {
    my $fs_mock = TestMock->new( 'FlickrSync' );
    $fs_mock->mock( 'sync_photoset_to_db' );
    $fs_mock->mock( 'sync_photos_to_db_by_set_id' );
    $fs_mock->sync_photoset_to_db( [
        {
            id => 5,
            SetID => 1,
        },
        {
            id => 4,
            SetID => 2,
        },
        {
            id => 1,
            SetID => 3,
        }
    ] );

    $fs->sync_flickr_to_db( { user_id => 'ENVAGYOK' } );

    my @photos_to_db = $fs_mock->sync_photos_to_db_by_set_id();
    ok( $photos_to_db[ 1 ]->{ photoset_id } == 5);
    ok( $photos_to_db[ 3 ]->{ photoset_id } == 4);
    ok( $photos_to_db[ 5 ]->{ photoset_id } == 1);

};

subtest 'add_file_to_db' => sub {
    my $fs_mock = TestMock->new( 'FlickrSync' );
    $fs_mock->mock( 'get_file_data' );
    $fs_mock->mock( 'filter' );
    $fs_mock->get_file_data( [ 'asads/asdf/ketto.jpg', 'ketto', 'ketto.jpg', 'asads/asdf/', ['sss', '2015_dec_23_'] ] );
    $fs_mock->filter( [1] );

    $fs->add_file_to_db();

    my $data = $DBH->my_select({
        from   => 'photosinnas',
        select => 'ALL',
    });

    ok( $data->[ 0 ]->{ SetID } == 1, 'correct set was selected' );

};

subtest "mark_for_delete" => sub {
    my $dbh_mock = TestMock->new( 'DBH' );
    $dbh_mock->mock( 'my_select' );
    $dbh_mock->mock( 'my_update' );

    $dbh_mock->my_select( [
        { SetTitle => 'Path1', SetDescription => 'Path2', PhotoTitle => 'photo1', PhotoID => 1 },
        { SetTitle => 'Path2', SetDescription => 'Path1', PhotoTitle => 'photo2', PhotoID => 2 },
        { SetTitle => 'Patha', SetDescription => 'Patha', PhotoTitle => 'photo1', PhotoID => 3 },  # selected
        { SetTitle => 'Pathb', SetDescription => 'Pathb', PhotoTitle => 'photo2', PhotoID => 4 },  # selected
        { SetTitle => 'Pathc', SetDescription => 'Pathc', PhotoTitle => 'photo3', PhotoID => 5 },  # selected
        { SetTitle => 'Path3', SetDescription => 'Path3', PhotoTitle => 'photo4', PhotoID => 6 },  # selected
        { SetTitle => 'Path2', SetDescription => 'b',     PhotoTitle => 'abb'   , PhotoID => 7 },
        { SetTitle => 'Path3', SetDescription => 'Path3', PhotoTitle => 'photo3', PhotoID => 8 }
    ] );
    $dbh_mock->my_select( [
        { Path => 'Path1/photo1.png', Status => 'SYNCED',  FileName => 'photo1', Dir => "Path1/"},
        { Path => 'Path2/photo2.png', Status => 'SYNCED',  FileName => 'photo2', Dir => "Path2/"},
        { Path => 'Path3/photo3.png', Status => 'SYNCED',  FileName => 'photo3', Dir => "Path3/"}
    ] );

    my $res = $fs->mark_for_delete( "Path" );

    is_deeply( [ sort { $a->{ PhotoTitle } cmp $b->{ PhotoTitle } } @{ $res } ], [ sort { $a->{ PhotoTitle } cmp $b->{ PhotoTitle } }
          {
            'SetTitle' => 'Path3',
            'SetDescription' => 'Path3',
            'PhotoTitle' => 'photo4',
            'PhotoID' => 6
          },
          {
            'PhotoTitle' => 'photo1',
            'PhotoID' => 3,
            'SetTitle' => 'Patha',
            'SetDescription' => 'Patha'
          },
          {
            'PhotoID' => 4,
            'PhotoTitle' => 'photo2',
            'SetDescription' => 'Pathb',
            'SetTitle' => 'Pathb'
          },
          {
            'PhotoTitle' => 'photo3',
            'PhotoID' => 5,
            'SetTitle' => 'Pathc',
            'SetDescription' => 'Pathc'
          }
     ], 'files are selected for deletion');
    
    my @my_update = $dbh_mock->my_update();
    is_deeply( [ sort map{ $my_update[ $_ ]->{ where }->{ PhotoID } } ( 1, 3, 5, 7 ) ], [ 3, 4, 5, 6 ]);
};


subtest 'add_tag' => sub {
    my $fs_mock = TestMock->new( 'FlickrSync' );
    $fs_mock->mock( 'call' );

    $fs->add_tag( [
        { PhotoExternalID => 1 },
        { PhotoExternalID => 2 },
        { PhotoExternalID => 3 }
    ] );

    my @res = $fs_mock->call();
    ok( $res[ 2 ]->{ photo_id } == 1, 'first item' );
    ok( $res[ 5 ]->{ photo_id } == 2, 'first item' );
    ok( $res[ 8 ]->{ photo_id } == 3, 'first item' );
    ok( $res[ 2 ]->{ tags } eq 'DELETEIT' , 'first item' );
    ok( $res[ 5 ]->{ tags } eq 'DELETEIT' , 'first item' );
    ok( $res[ 8 ]->{ tags } eq 'DELETEIT' , 'first item' );
};

