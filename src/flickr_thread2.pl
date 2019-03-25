use strict;
use Flickr::Upload;
use Data::Dumper;
use File::Find;
use utf8;
use Thread::Pool::Simple;
my $s = Thread::Semaphore->new();

my %val : shared;
my @vall;

@vall = (0..200);

my $pool = Thread::Pool::Simple->new(
   min => 1,           # at least 3 workers
   max => 4,           # at most 5 workers
   do => [\&do_handle]     # job handler for each worker
 );
 
 

sub do_handle {
    my $thread = shift;
    print $thread . "\n";
}

sub sub2 {
    my $data = shift;
#    $s->down();
#    lock %val;
#    if ( defined $val{ $thread } ) {
#        $val{ $thread }++;
#    } else {
#        $val{ $thread } = 1;
#    }    
    print $data . "\n";
#    $s->up();
}

foreach my $val ( @vall ){
    $pool->add( $val );
}

foreach my $val ( @vall ){
    $pool->add( $val );
}

$pool->join();
#print Dumper \%val;
