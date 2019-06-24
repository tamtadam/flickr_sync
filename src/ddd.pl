use strict;
use Data::Dumper;

use ImageData;

my $id = new ImageData();

print Dumper $id->get_image_data( 'z:\2019\2019_03_24_vece_mhagyma\conv_DSC01557.jpg', [ qw( LensID Lens LensModel Model FocalLength ) ] );
