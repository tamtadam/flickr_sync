package FlickrSync;

use strict;

use POSIX qw(strftime);

use Flickr::Upload;
use Flickr::API;
use Data::Dumper;
use File::Find;
use FindBin ;
use Thread::Pool::Simple;
use Thread::Semaphore;
use List::MoreUtils qw(first_value last_value uniq);

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
    $self->{ image_data } = $_[ 0 ]->{ image_data };
    
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
    
    my $method = "flickr.photosets.getList";
    $params->{ user_id } ||= $self->{ user_id };
    
    $log->info( "$method called" );
    my $response = $self->call( $method, $params );
    $log->info( "$method finished" );
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
    
    $log->info( "flickr.photosets.getPhotos called" . Dumper $params );
    my $response = $self->call( 'flickr.photosets.getPhotos', $params );
    $log->info( "flickr.photosets.getPhotost finished" );

    next unless ref $response->{hash}->{photoset}->{photo} eq 'ARRAY' ;
    push @photos, @{ $response->{hash}->{photoset}->{photo} };

    if ( $response->{hash}->{photoset}->{pages} !=
         $response->{hash}->{photoset}->{page} ) {
        
        $log->info( "page: " . $response->{hash}->{photoset}->{page} + 1  . " called from " . $response->{hash}->{photoset}->{pages} );
        $params->{ page } = ++$response->{hash}->{photoset}->{page }; 
        my @photos_of_page = @{ $self->get_photos_by_set( $params ) };
        push @photos, @photos_of_page;

    }

    delete $params->{ page } ;

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

    $params->{ filter } ||= '' ;

    my $response = $self->get_photosets( $params ) || [];
    
    foreach my $set ( grep { $_->{ title } =~/$params->{filter}/} @{ $response } ) {
        $set->{ SetID } = $self->add_set_to_db( $set ) || undef ;

    }

    return [ grep { $_->{ title } =~/$params->{filter}/} @{ $response } ];
}

sub add_set_to_db {
    my $self = shift ;
    my $set  = shift || return undef ;
    
    $log->info( "Adding " . ( $set->{ title } || $set->{ description } ) . " set STARTED" );
    my $res = $self->my_select_insert( {
        'data' => {
            'ExternalID'     => $set->{id} ,
            'Title'          => $set->{title} ,
            'Status'         => 'SYNCED' ,
            'Photos'         => $set->{photos} || $set->{ count_videos } ,
            'Description'    => ( ref $set->{description} ? "N/A" : $set->{description} ) ,
            'Videos'         => $set->{videos} || $set->{ count_photos } ,
            'PrimaryPhotoID' => $set->{primary},
            'SecretID'       => $set->{secret}
        },
        'table'  => 'Sets',
        'selected_row' => 'SetID',
    } );
    $log->info( "Adding " . ( $set->{ title } || $set->{ description } ) . " set FINISHED, id:" . $set->{ SetID } );
    
    return $res;
}

sub set_perms_for_set {
    my $self = shift;
    my $params = shift;

    my $pool = Thread::Pool::Simple->new(
       min => 1,           # at least 3 workers
       max => 8,           # at most 5 workers
       do => [\&do_handle_for_perm, $self]     # job handler for each worker
    );
     
    sub do_handle_for_perm {
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
    
    my $method = "flickr.photos.setPerms";
        
    $log->info( "$method called: " . Dumper $params );
    my $response = $self->call( $method, $params );
    $log->info( "$method finished: " . Dumper $params );
    return $response->{hash}->{photosets}->{photoset};

}

sub get_perms {
    my $self = shift;
    my $params = shift;
    
    my $method = "flickr.photos.getPerms";
        
    $log->info( "$method called: " . $params->{ photo_id } );
    my $response = $self->call( $method, $params );
    $log->info( "$method finished: " . $params->{ photo_id } );
    
    if ( $response->{ hash }->{ stat } eq 'ok') {
        return $response->{ hash }->{ perms };
 
    } else {
        return {};

    }
}

sub remove_tag {
    my $self = shift ;
    my $params = shift;
    
    my $method = "flickr.photos.removeTag";
        
    $log->info( "$method called: " . $params->{ tag_id } );
    my $response = $self->call( $method, $params );
    
    $log->info( "$method finished: " . $params->{ tag_id } );
}

sub get_exif {
    my $self = shift;
    my $params = shift;
    
    my $method = "flickr.photos.getPerms";
        
    $log->info( "flickr.photos.getExif called: " . $params->{ photo_id } );
    my $response = $self->call( 'flickr.photos.getExif', $params );
    $log->info( "flickr.photos.getExif finished: " . $params->{ photo_id } );
    return $response->{ hash }->{ photo }->{ exif };

}

sub get_set_info {
    my $self = shift;
    my $params = shift;
    
    my $method = "flickr.photosets.getInfo";
        
    $log->info( "$method called: " . $params->{ photoset_id } );
    my $response = $self->call( $method, $params );
    $log->info( "$method finished: " . $params->{ photoset_id } );

    if ( $response->{ hash }->{ stat } eq 'ok') {
        return $response->{ hash }->{ photoset };
 
    } else {
        return {};
    }
}

sub get_info {
    my $self = shift;
    my $params = shift;
    
    my $method = "flickr.photos.getInfo";
        
    $log->info( "$method called: " . $params->{ photo_id } );
    my $response = $self->call( $method, $params );
    $log->info( "$method finished: " . $params->{ photo_id } );
    
    if ( $response->{ hash }->{ stat } eq 'ok') {
        return $response->{ hash }->{ photo };
 
    } else {
        return {};
    }
}

sub get_tag_ids_from_info {
    my $self   = shift ;
    my $photo  = shift || {} ;
    my $tags   = shift || {} ;
    
    my @found;
    foreach my $tag ( grep { not defined $tags->{ $_ } } keys %{ $tags } ) {
        @found = grep { $_->{ raw } =~ /^$tag$/ } @{ $photo->{ tags }->{ tag } || [] } ;
        $tags->{ $tag } = $found[ 0 ]->{ id };
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

sub sync_flickr_tags_from_exif {
    my $self = shift;
    my $params = shift || return undef;

    my $pool = Thread::Pool::Simple->new(
       min => 1,           # at least 3 workers
       max => 8,           # at most 5 workers
       do => [\&do_handle, $self]     # job handler for each worker
    );

    sub do_handle {
        my $self     = shift ;
        my $photo_id = shift ;
        my $tags     = shift ;
        $self->add_tags( {
            photo_id => $photo_id,
            tags     => $tags
        } );
        return 1;
    }

    my $response = $self->get_photosets( $params ) || [];
    foreach my $set ( grep { $_->{ title } =~/^2019_02_24_baboci_vece*/} @{ $response } ) { # 201(9)_. 5|6|7|8|
        $log->info( "set: " . $set->{ title } );
        
        $params->{ photoset_id } = $set->{ id };
        
        my $photos = $self->get_photos_by_set( $params ) || [];
        my $photos_on_nas = $self->my_select(
                {
                    'from'   => 'photosinnas',
                    'select' => 'ALL',
                    'where'  => {
                        LastSet => $set->{ title },
                    }
                }
            ) ;
        

        $log->info( scalar @{ $photos_on_nas || [] } . " found on nas " . scalar @{ $photos || [] } . " found on flickr"  );
 
        next unless $photos_on_nas;
         
        foreach my $photo ( @{ $photos } ) {
            $log->info( $set->{ title } .": photo: " . $photo->{ title } );
            my $photo_to_tag = @{ [ grep { $_->{ FullFileName } =~/$photo->{ title }/ } @{ $photos_on_nas } ] || [] }[ 0 ];
            
            next unless $photo_to_tag ;
            
            $log->info( $set->{ title } .": path: " . $photo_to_tag->{ Path } );
            
            my $tags = $self->{ image_data }->get_image_data( $photo_to_tag->{ Path }, [ qw( LensID Lens LensModel Model FocalLength ) ] );
               $tags = $self->{ image_data }->add_new_tags( $tags );
               $tags = $self->{ image_data }->change_tags( $tags );
               $tags = [ uniq @{ $tags } ] ;
            $log->info( "    tags: " . join( ",", grep{ defined $_ and $_ ne "----" } @{ $tags } ) );


            $pool->add(  $photo->{ id }, join( ",", grep{ defined $_ and $_ ne "----" } @{ $tags } ) ) if $tags;

        }

    }
    $pool->join();
}

sub remove_tags {
    my $self = shift;
    my $params = shift || return undef;

    my $tags_hash = { map { $_ => undef } @{ $params->{ tags } } } ;
    
    my $pool = Thread::Pool::Simple->new(
       min => 1,           # at least 3 workers
       max => 8,           # at most 5 workers
       do => [\&do_handle, $self]     # job handler for each worker
    );

    sub do_handle {
        my $self     = shift ;
        my $photo_id = shift ;
        my $tags     = shift ;
        $self->add_tags( {
            photo_id => $photo_id,
            tags     => $tags
        } );
        return 1;
    }

    my $response = $self->get_photosets( $params ) || [];
    foreach my $set ( grep { $_->{ title } =~/^$params->{filter}.*/} @{ $response } ) { # 5|6|7|8|
        $log->info( "set: " . $set->{ title } );
        
        $params->{ photoset_id } = $set->{ id };
        
        my $photos = $self->get_photos_by_set( $params ) || [];
        my $photo_info ;
        PHOTO: foreach my $photo ( @{ $photos } ) {
            $log->info( $set->{ title } .": photo: " . $photo->{ title } );
            if ( scalar grep { not defined $tags_hash->{ $_ } } keys %{ $tags_hash } ) {
                $photo_info = $self->get_info( {
                    photo_id => $photo->{ id }
                } ) ;

                $self->get_tag_ids_from_info( $photo_info, $tags_hash ) ;
            } else {
                $self->remove_tag( { 
                    tag_id   => $_, 
                    user_id  => $params->{ user_id },
                    photo_id => $photo->{ id } } ) foreach values %{ $tags_hash } ;

            }
        }
        $self->remove_tag( { tag_id => $_, user_id => $params->{ user_id } } ) foreach values %{ $tags_hash } ;
    }
    $pool->join();

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
    
    !-e $path || $path =~/LAGZI/ ? return undef : return 1;
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
    my $path = $File::Find::name || shift;

    return unless $self->filter( $path );

    my ( $path, $file_name, $full_file_name, $dir, $set ) = @{ $self->get_file_data( $path, $_, $File::Find::dir ) };

    my @stat = -e $path ? stat( $path ) : (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) ;
    
    my $calc_set_id = $self->my_select(
        {
          from   => 'Sets ',
          select => 'ALL',
          where => {
              Description => $set->[ -1 ]
          }
        }
    ) ;

    $log->info( "Add file from NAS to db: " . $path . " STARTED" );

    my $already_in_db = $self->is_image_already_in_db( $path ) ;

    if( $already_in_db ) {
        $log->info( "Add file from NAS to db: " . $path . " SKIPPED, already in DB" );  
        return ;
    }

    my $id = $self->my_select_insert( {
        data => {
            Path         => $path,
            Status       => 'SYNCED',
            FullFileName => $full_file_name,
            FileName     => $file_name,
            Dir          => $dir,
            LastSet      => $set->[ -1 ],
            SetID        => $calc_set_id->[0]->{ SetID },
            LastAccess   => $self->get_formatted_time( $stat[ 8 ] ),
            LastModified => $self->get_formatted_time( $stat[ 9 ] ),
            SizeInByte   => $stat[ 7 ],
        },
        table        => 'photosinnas',
        selected_row => 'PhotosInNASID',
    } );

    $log->info( "Add file from NAS to db: " . $path . " FINISHED" );

}

sub is_image_already_in_db {
    my $self = shift ;    
    my $path = shift ; 

    return undef unless -e $path ;

    my @stat = -e $path ? stat( $path ) : (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) ;

    my $res = $self->my_select( {
        where => {
            Path         => $path,
            LastModified => $self->get_formatted_time( $stat[ 9 ] ),
            SizeInByte   => $stat[ 7 ]
        },
        from     => 'photosinnas',
        relation => 'and',
        select   => 'ALL',
    } );
    return $res;
}

sub get_formatted_time {
    my $self = shift ;
    my $time = shift ;
    return POSIX::strftime( "%Y-%m-%d %H:%M:%S", localtime( $time ) ) ;
}

sub get_folders {
    my $self = shift;
    my $path = shift;

    my @dir_list = split('\/', $path);
    shift @dir_list ;
    return \@dir_list
}

sub mark_for_update_in_cloud {
    my $self = shift;
    my $path = $File::Find::name || shift;

    return unless $self->filter( $path );

    my ( $path, $file_name, $full_file_name, $dir, $set ) = @{ $self->get_file_data( $path, $_, $File::Find::dir ) };
    my @stat = -e $path ? stat( $path ) : (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) ;
    
    $log->info( "Check file in DB " . $path . " STARTED" );
    print Dumper [ ( $path, $file_name, $full_file_name, $dir, $set ) ];
#    LastAccess   => $self->get_formatted_time( $stat[ 8 ] ),
#    LastModified => $self->get_formatted_time( $stat[ 9 ] ),
    my $res = $self->my_select( {
        where => {
            Path         => $path,
            FullFileName => $full_file_name,
            FileName     => $file_name,
            Dir          => $dir,
            LastSet      => $set->[ -1 ],
        },
        from     => 'photosinnas',
        select   => 'ALL',
        relation => 'and'
    } );
    
    print Dumper $res ;

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

sub add_tags {
    my $self  = shift ;
    my $photo = shift ;

    my $method = "flickr.photos.addTags" ;
    $log->info( "$method called: " . $photo->{ photo_id } );
    my $response = $self->call( $method, { 
        photo_id => $photo->{ photo_id },
        tags     => $photo->{ tags }
    } );
    $log->info( "$method finished: " . $photo->{ photo_id } . " - " . $photo->{ tags } );
    return $response ;

}

sub add_delete_tag {
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