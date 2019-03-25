use strict;

use Flickr::Upload;
use Data::Dumper;
use File::Find;
use utf8;
use threads;
use threads::shared;
use FindBin ;

use lib $FindBin::RealBin;
use lib $FindBin::RealBin . "../../../common/cgi-bin/" ;
use lib $FindBin::RealBin . "../../cgi-bin/" ;

use DBConnHandler;
use FlickrSync;

use Log::Log4perl qw(:easy);
Log::Log4perl::init('../conf/log4perl.conf');
my $log = Log::Log4perl->get_logger();


$ENV{HOME} = "";
$ENV{XML_SIMPLE_PREFERRED_PARSER }="XML::Parser";

my $ua = Flickr::Upload->new(
        {
                'key' => "ed631024fc76d2d6a2c7bca46c763744",
                'secret' => "00af7ab1ccf4951b"
        });

my $config_file = "$ENV{HOME}.flickroauth.st";

my $ua = Flickr::Upload->import_storable_config($config_file);

my $flickr = FlickrSync->new( {
    DB_HANDLE => &DBConnHandler::init( 'server.cfg' ) , 
    auth      => '.flickroauth.st',
    user_id   => '138370151@N02',
} );

=pod
my $photoset_id = $ua->photosets_create( title => '2015_12_12',
                               description => 'description',
                               primary_photo_id => '31928217198',
                               'auth_token' => $ua );
                              
my $res = $ua->upload(
        'photo' => 'z:\2015\2015_07_11_Szofi\DSC01854.JPG',
        'auth_token' => $ua,
        'is_public' => 0,
        'is_friend' => 0,
        'is_family' => 0
) or die "Failed to upload /tmp/image.jpg";

=cut

# 2019_03_03_baboci_studio
# 2019_03_08_baboci_studio_var
# 2019_03_17_baboci_fuveszkert
# 2019_02_25_baboci_vajdahunyad


my $folders = $flickr->get_photosets_key_folder() || {};
my $root_folder = "z:\\2019\/2019_02_16_baboci_vece\/";
my $root_set = "__2019__";
my $skip = "xmp|NEF|arw";

$SIG{INT} = sub { 
    print Dumper $folders;
    die "Caught a sigint $!" 

};

$SIG{TERM} = sub { 
    print Dumper $folders;
    die "Caught a sigterm $!" 
};

find({ wanted => \&process, follow => 1, no_chdir=>0 }, $root_folder);

sub get_folders {
    my $path = shift;

    my @dir_list = split('\/', $path);
    shift @dir_list ;
    return \@dir_list
}

sub create_photoset {
    my $dir_list = shift;
    my $photo_id = shift;
    my $photoset_id;

    for my $set ( @{ $dir_list } ) {
        next if exists $folders->{ $set };
        $log->info( "Creating photoset ' $set '  primary_photo_id = $photo_id\n" );
        
        $photoset_id = $ua->photosets_create( title            => $set,
                                              description      => $set,
                                              primary_photo_id => $photo_id,
                                              auth_token       => $ua );
        $folders->{ $set } = $photoset_id;
        $log->info( "Created photoset, id = $photoset_id\n" );
    }

    return [ map{ $folders->{ $_ } } @{ $dir_list } ];
}

sub store_photo_in_set {
    my $path     = shift;
    my $photo_id = shift;

    my $dir_list = get_folders( $path );

    push @{ $dir_list }, $root_set;

    my $photo_set_ids = create_photoset( $dir_list, $photo_id );

    for my $photoset_id ( @{ $photo_set_ids } ) {
        $log->info( "Adding photoID $photo_id to photoset $photoset_id ...\n" );
        my $rc = $ua->photosets_addphoto (
            photoset_id  => $photoset_id,
            photo_id     => $photo_id,
            'auth_token' => $ua );
        $log->info( "Adding photoID $photo_id failed...\n" ) unless $rc;
    }
}

sub process {
    my $path = $File::Find::name;
    my $file_name = $_;
    my $dir = $File::Find::dir;

    next if $path =~/xmp|NEF|ARW/i || !-f $path || $path =~/Thumbs.db/;
    
    $log->info( "\n" . 'Uploading ' . $path . '...' . "\n" );
    my $photo_id = $ua->upload(
        'photo'      => $path,
        'auth_token' => $ua,
        'is_public'  => 0,
        'is_friend'  => 0,
        'is_family'  => 0,
        'tags'       => 'script_upload',
        #'async'      => 1
    ) or $log->info( "Failed to upload $path - *******E R R O R" ) and next;
    $log->info( "\n" . 'Uploading ' . $path . ' FINISHED' . "\n");
    store_photo_in_set($dir, $photo_id);
    
    if ( -e "exit_from_flickr.txt" ) {
        $log->info( "WAITING FOR USER USER INPUT TO STOP PROCESSING: Y stop, Other continue");
        
        my $zzz = <>;
        $zzz =~/Y/ ? exit : 0;    
    }
}

