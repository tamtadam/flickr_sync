package ImageData;

use strict          ;
use Image::ExifTool ;
use Data::Dumper    ;
use List::MoreUtils qw(first_value last_value uniq);
use feature qw( state );
use parent qw( Image::ExifTool ) ;

sub new {
    my $instance = shift;
    my $class    = ref $instance || $instance;
    my $self     = new Image::ExifTool;

    bless $self, $class;
    
    return $self->init( @_ );

}


sub init {
    my $self   = shift ;
    my @params = @_    ;
    
    return $self ;
}

sub get_image_data {
    my $self  = shift ;
    my $file  = shift ;
    my $param = shift || "";
    
    if ( -e $file ) {
        my $extract_info_status = $self->ExtractInfo( $file ) ;
        
        if ( $extract_info_status ) {
            my $info = $self->GetInfo();
            return [ uniq map { $info->{ $_ } } @{ $param } ] ;
            
        } else {
            print "Extract info failed: $file\n";
            return undef ;
    
        }
    } else {
        print $file . " not found\n";
        return undef ;
    }

    
}

sub add_new_tags {
    state $tag = {
        'Super-Multi-Coated Takumar f/1.4' => [ 'SMC Takumar 50mm f1.4' ],
        'ILCE-7M2'                         => [ 'Sony A7II'],
        'FE 85mm F1.8'                     => [ 'Sony 85mm f1.8', 'SEL85F18' ],
        'ILCE-6000'                        => [ 'Sony A6000' ],
        'Pentacon auto f2.8'               => [],
        'Tokina f2.8'                      => [],
        'Nikon 35/1.8G'                    => [ 'Nikon 35mm/1.8G' ],
    };
    
    my $self = shift ;
    my $tags = shift || [] ;

    my @new_tags = @{ $tags };

    push @new_tags, ( map { @{ $tag->{ $_ } } } grep { defined $tag->{ $_ } } @{ $tags } ) ; 

    return \@new_tags ;
}

sub change_tags {
    my $self = shift ;
    my $tags = shift || [] ;
    
    my @new_tags = map { 
        my $act = $_ ;

        if ( $act =~/(\d+).\d\smm/ ) {
            $1. " mm" ;
        } else {
            $act ;
        }

    } @{ $tags } ; 

    return \@new_tags ;

}

1;