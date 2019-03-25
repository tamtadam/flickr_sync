package FlickrSync;

use strict;

use Flickr::Upload;
use Flickr::API;
use Data::Dumper;
use File::Find;
use FindBin ;
use Thread::Pool::Simple;
use Thread::Semaphore;

use lib $FindBin::RealBin;
use lib $FindBin::RealBin . "../../../common/cgi-bin/" ;
use lib $FindBin::RealBin . "../../cgi-bin/" ;

use DBConnHandler;
use DBH;

use parent qw(
              Flickr::API 
              DBH
);

use Log::Log4perl qw(:easy);
Log::Log4perl::init('../conf/log4perl.conf');
my $log = Log::Log4perl->get_logger();

use utf8;
use threads;
use threads::shared;

$ENV{HOME} = "";
$ENV{XML_SIMPLE_PREFERRED_PARSER }="XML::Parser";
my $s = Thread::Semaphore->new();
 
sub new {
    my $instance = shift;
    my $class    = ref $instance || $instance;
    my $self     = {};

    bless $self, $class;
    
    return $self->init( @_ );
}

sub init {
    my $self = shift;
    
    $self->{ user_id }   = $_[ 0 ]->{ user_id };
    $self->{ api }       = Flickr::API->import_storable_config( $_[ 0 ]->{ auth } );
    $self->{ DB_HANDLE } = $_[ 0 ]->{ DB_HANDLE };
    $self->{ pool }      = Thread::Pool::Simple->new(
        min => 1,
        max => 1,
        do  => [ sub {
            $self->do_handle( @_ )    
        } ]
    );
    return $self;
}

sub call {
    my $self = shift;
    my $method = shift || 'flickr.test.echo';
    my $params = shift || {};

    return $self->{ api }->execute_method( $method, $params);
}

sub get_photosets {
    my $self = shift;
    my $params = shift;

    $params->{ user_id } ||= $self->{ user_id };
    
    $log->info( "flickr.photosets.getList called" );
    my $response = $self->call( 'flickr.photosets.getList', $params );
    $log->info( "flickr.photosets.getList finished" );
    return $response->{hash}->{photosets}->{photoset};
}

sub get_photosets_key_folder {
    my $self = shift;
    
    return { map { $_->{ title } => $_->{ id } } @{ $self->get_photosets() || [] } };

}

sub get_photos_by_set {
    my $self = shift;
    my $params = shift;
    my @photos;

    $params->{ user_id } ||= $self->{ user_id };
    
    $log->info( "flickr.photosets.getPhotos called" );
    my $response = $self->call( 'flickr.photosets.getPhotos', $params );
    $log->info( "flickr.photosets.getPhotost finished" );
    push @photos, @{ $response->{hash}->{photoset}->{photo} };

    if ( $response->{hash}->{photoset}->{pages} !=
         $response->{hash}->{photoset}->{page} ) {
        
        $log->info( "page: " . $response->{hash}->{photoset}->{page} + 1  . " called from " . $response->{hash}->{photoset}->{pages} );
        $params->{ page } = ++$response->{hash}->{photoset}->{page }; 
        my @photos_of_page = @{ $self->get_photos_by_set( $params ) };
        push @photos, @photos_of_page;

    }
    
    return \@photos;

}

=pod
{
            'visibility_can_see_set' => '1',
            'date_create' => '1484598836',
            'id' => '72157675578574723',
            'farm' => '1',
            'primary' => '32313353466',
            'can_comment' => '1',
            'needs_interstitial' => '0',
            'description' => {},
            'server' => '279',
            'count_views' => '0',
            'count_comments' => '0',
            'title' => '2017_01_08_dtor',
            'videos' => '0',
            'secret' => '217d194c2d',
            'date_update' => '1541929009',
            'photos' => '83'
          }
=cut
sub sync_photoset_to_db {
    my $self = shift;
    my $params = shift;

    my $response = $self->get_photosets( $params ) || [];
    
    foreach my $set ( grep { $_->{ title } =~/$params->{filter}/} @{ $response } ) {
        $log->info( "Adding " . ( $set->{ title } || $set->{ description } ) . " set STARTED" );
        $set->{ SetID } = $self->my_select_insert( {
            'data' => {
                'ExternalID'     => $set->{id} ,
                'Title'          => $set->{title} ,
                'Status'         => 'SYNCED' ,
                'Photos'         => $set->{photos} ,
                'Description'    => ( ref $set->{description} ? "N/A" : $set->{description} ) ,
                'Videos'         => $set->{videos} ,
                'PrimaryPhotoID' => $set->{primary},
                'SecretID'       => $set->{secret}
            },
            'table'  => 'Sets',
            'selected_row' => 'SetID',
        } ) || undef ;
        $log->info( "Adding " . ( $set->{ title } || $set->{ description } ) . " set FINISHED, id:" . $set->{ SetID } );
    }

    return [ grep { $_->{ title } =~/$params->{filter}/} @{ $response } ];
}


sub set_perms_for_set {
    my $self = shift;
    my $params = shift;

    my $pool = Thread::Pool::Simple->new(
       min => 1,           # at least 3 workers
       max => 8,           # at most 5 workers
       do => [\&do_handle, $self]     # job handler for each worker
    );
     
    sub do_handle {
        my $self  = shift ;
        my $photo = shift ;
        my $params   = shift ;
        $self->set_perms_comment( {
            photo_id  => $photo->{ id },
            is_public => 0,
            is_friend => 0,
            is_family => $params->{ is_family },
            perm_comment => 0
        } ) ;
    }

    my $photo_sets = $self->get_photosets( $params ) || [];
    my $cnt = 0;

    foreach my $set ( grep { $_->{ title } =~/^$params->{filter}$/} @{ $photo_sets } ) {
        $log->info(( $set->{ title } || $set->{ description } ) . " start to update photos:" . $set->{ SetID } );
        
        $params->{ photoset_id } = $set->{ id };
        my $response = $self->get_photos_by_set( $params ) || [];
        
        foreach my $photo ( @{ $response } ) {
            $params->{ photo_id } = $photo->{ id };
            $log->info( scalar @{ $response } . "/" . $cnt++ );
            my $perms = $self->get_perms( $params ) ;
            next if $perms->{ ispublic } == 1;
            next if $perms->{ isfamily } == $params->{ is_family };
            
            $pool->add( $photo, $params );

        }
        $log->info( ( $set->{ title } || $set->{ description } ) . " start to update photos: FINISHED" );
    }
    $pool->join();
    return [ grep { $_->{ title } =~/$params->{filter}/} @{ $photo_sets } ];
}


sub set_perms_comment {
    my $self = shift;
    my $params = shift;
    
    $log->info( "flickr.photosets.setPerms called: " . $params->{ photo_id } );
    my $response = $self->call( 'flickr.photos.setPerms', $params );
    $log->info( "flickr.photosets.setPerms finished: " . $params->{ photo_id } );
    return $response->{hash}->{photosets}->{photoset};

}

sub get_perms {
    my $self = shift;
    my $params = shift;
    
    $log->info( "flickr.photosets.getPerms called: " . $params->{ photo_id } );
    my $response = $self->call( 'flickr.photos.getPerms', $params );
    $log->info( "flickr.photosets.getPerms finished: " . $params->{ photo_id } );
    
    if ( $response->{ hash }->{ stat } eq 'ok') {
        return $response->{ hash }->{ perms };
 
    } else {
        return {};
        
    }
}


=pod

{
    'secret' => 'a324355bf6',
    'isfriend' => '0',
    'server' => '1933',
    'isfamily' => '0',
    'ispublic' => '0',
    'title' => 'conv_DSC_9388',
    'isprimary' => '0',
    'id' => '31855468728',
    'farm' => '2'
  }

=cut
sub sync_photos_to_db_by_set_id {
    my $self = shift;
    my $params = shift;

    my $response = $self->get_photos_by_set( $params ) || [];
    my $PhotoID;
    my $cnt = 0;
    foreach my $photo ( @{ $response } ) {
        $log->info( "Adding " . $photo->{ title } . " photo to " . $params->{ SetID } . " set STARTED" );
        $PhotoID = $self->my_select_insert( {
            'data' => {
                'ExternalID' => $photo->{id} ,
                'Title'      => $photo->{title} ,
                'Status'     => 'SYNCED' ,
                'SecretID'   => $photo->{secret}
            },
            'table'  => 'Photos',
            'selected_row' => 'PhotoID',
        } );

        $log->info( "Adding " . $photo->{ title } . " photo to " . $params->{ SetID } . " set FINISHED" );
        if( $PhotoID && $params->{ SetID } ) {
            my $PhotosInSetID = $self->my_select_insert( {
                'table'        => 'PhotosInSet',
                'selected_row' => 'PhotosInSetID',
                'data' => {
                    'PhotoID' => $PhotoID ,
                    'SetID'   => $params->{ SetID } ,
                    'PhotoTitle' => $photo->{ title }
                },
            } );
            $cnt++ if $PhotosInSetID;
        }
    }
    return $cnt;

}


sub sync_flickr_to_db {
    my $self = shift;
    my $params = shift || return undef;

    my $photosets = $self->sync_photoset_to_db( $params );
    my $processed_photo_cnt = 0;
    foreach my $set ( @{ $photosets } ) {
        my %photo_data = %{ $params };
        $photo_data{ photoset_id } = $set->{ id };
        $photo_data{ SetID } = $set->{ SetID };

        $log->info( "Reading photos from " . ( $set->{ title } || $set->{ description } ) . " set STARTED" );

        $processed_photo_cnt = $self->sync_photos_to_db_by_set_id( \%photo_data );

        $log->info( "Reading photos from " . ( $set->{ title } || $set->{ description } ) . " set FINISHED" );
        $log->info( $processed_photo_cnt . " photo processed from " . $set->{ photos } );

        if ( -e "exit_from_flickr.txt" ) {
            $log->info( "WAITING FOR USER USER INPUT TO STOP PROCESSING: Y stop, Other continue");

            my $zzz = <>;
            $zzz =~/Y/ ? exit : 0;    
        }
    }
}

sub sync_nas_to_db {
    my $self = shift;
    my $root_folder = shift;
    
    find(
        { 
            wanted => sub {
                $self->add_file_to_db( @_ );
            }, 
            follow   => 1, 
            no_chdir => 0
    }, $root_folder);

}

sub filter {
    my $self = shift;
    my $path = shift;
    
    !-f $path || $path =~/LAGZI/ ? return undef : return 1;
}

sub get_file_data {
    my $self = shift;
    my $path = shift;
    my $file_name = shift;
    my $dir = shift;
    
    $file_name =~/(.*?)\..*$/; 
    my $set = $self->get_folders( $dir );
    
    return [ $path, $1, $file_name, $dir, $set ] ;

}


sub add_file_to_db {
    my $self = shift;
    my $path = $File::Find::name;

    return unless $self->filter( $path );

    my ( $path, $file_name, $full_file_name, $dir, $set ) = @{ $self->get_file_data( $File::Find::name, $_, $File::Find::dir ) };

    my $calc_set_id = $self->my_select(
        {
          'from'   => 'Sets ',
          'select' => 'ALL',
          "where" => {
              'Description' => $set->[ -1 ]
          }
        }
    ) ;

    $log->info( "Add file from NAS to db: " . $path . " STARTED" );
    my $id = $self->my_insert( {
        'insert' => {
            'Path'     => $path,
            'Status'   => 'SYNCED',
            'FullFileName' => $file_name,
            'FileName' => $file_name,
            'Dir'      => $dir,
            'LastSet'  => $set->[ -1 ],
            'SetID'    => $calc_set_id->[0]->{ SetID }
        },
        'table'  => 'photosinnas',
        'select' => 'PhotosInNASID',
    } );

    $log->info( "Add file from NAS to db: " . $path . " FINISHED" );

}


sub get_folders {
    my $self = shift;
    my $path = shift;

    my @dir_list = split('\/', $path);
    shift @dir_list ;
    return \@dir_list
}


sub mark_for_delete {
    my $self = shift;
    my $filter = shift;
    
    my $photos_from_flickr = $self->my_select(
        {
            'from'   => 'v_photosinset',
            'select' => 'ALL',
            'where'  => {
                PhotoStatus => "SYNCED"                
            }
        }
    ) ;
    $photos_from_flickr = [ grep { $_->{ SetTitle } eq $_->{ SetDescription } and $_->{ SetTitle } =~/^$filter/ } @{ $photos_from_flickr } ];
    $log->info( "Number of photos found in flickr: " . scalar @{ $photos_from_flickr } );

    my $nas = $self->my_select(
        {
          'from'   => 'photosinnas',
          'select' => [
              qw( Path Status FileName Dir )
          ]
        }
    ) ;

    $nas = [ grep { $_->{ Dir } =~/$filter/ } @{ $nas } ];
    $log->info( "Number of photos found in nas: " . scalar @{ $nas } );

    my %photos_to_delete;

    my @val = grep { defined $_ } map {
        my $flickr = $_ ;
        my $res = scalar grep {
            $_->{ Path } =~/$flickr->{SetTitle}/ && $_->{ Path } =~/$flickr->{PhotoTitle}/
        } @{ $nas } ;
        $res ? undef : $flickr;
    } @{ $photos_from_flickr };

    $log->info( "Number of photos marked for deletion: " . scalar @val );

    for my $flickr ( @val ) {
        if ( !defined $photos_to_delete{ $flickr->{ SetTitle } } ) {
            $photos_to_delete{ $flickr->{ SetTitle } } = [ $flickr ];

        } else {
            push @{ $photos_to_delete{ $flickr->{ SetTitle } } }, $flickr;

        }
    }
    my $photo_list = [];

    foreach my $set ( keys %photos_to_delete ) {
        $log->info( $set . ": " . scalar @{ $photos_to_delete{ $set } } );
        foreach my $photo ( @{ $photos_to_delete{ $set } } ) {
            $self->my_update({
                table  => "Photos",
                update => {
                    Status => "DELETEIT"
                },
                where => {
                    PhotoID => $photo->{ 'PhotoID' },
                }
            });
            push @{ $photo_list }, $photo; 
        }
    }
    
    return $photo_list;
}

sub add_tag {
    my $self = shift;
    my $photos = shift || [];   

    for my $photo ( @{ $photos } ) {
        $log->info( "Mark photo for deletion: " . $photo->{ PhotoID } . " - " . $photo->{ SetDescription } . " - " . $photo->{ PhotoTitle } );
        $self->call( 'flickr.photos.addTags', { 
            photo_id => $photo->{ PhotoExternalID },
            tags     => 'DELETEIT'
        } );
        
        $self->my_update({
            table  => "Photos",
            update => {
                Status => "DELETED"
            },
            where => {
                PhotoID => $photo->{ 'PhotoID' },
            }
        });
        $log->info( "Mark photo for deletion: FINISHED" );
    }
}





1;