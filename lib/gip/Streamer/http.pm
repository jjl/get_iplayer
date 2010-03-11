package gip::Streamer::http;

# Inherit from Streamer class
use base 'Streamer';

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use HTML::Entities;
use HTTP::Cookies;
use HTTP::Headers;
use IO::Seekable;
use IO::Socket;
use LWP::ConnCache;
use LWP::UserAgent;
use POSIX qw(mkfifo);
use strict;
use Time::Local;
use URI;

# Generic
# Actually do the http streaming
sub get {
	my ( $stream, $ua, $url, $prog ) = @_;
	my $start_time = time();

	# Set user agent
	$ua->agent('get_iplayer');

	main::logger "INFO: URL = $url\n" if $opt->{verbose};

	# Resume partial recording?
	my $start = 0;
	if ( -f $prog->{filepart} ) {
		$start = stat($prog->{filepart})->size;
		main::logger "INFO: Resuming recording from $start\n";
	}

	my $fh = main::open_file_append($prog->{filepart});

	if ( main::download_block($prog->{filepart}, $url, $ua, $start, undef, undef, $fh) != 0 ) {
		main::logger "\rERROR: Recording failed\n";
		close $fh;
		return 'next';
	} else {
		close $fh;
		# end marker
		my $end_time = time() + 0.0001;
		# Final file size
		my $size = stat($prog->{filepart})->size;
		# Calculate average speed, duration and total bytes downloaded
		main::logger sprintf("\rINFO: Recorded %.2fMB in %s at %5.0fkbps to %s\n", 
			($size - $start) / (1024.0 * 1024.0),
			sprintf("%02d:%02d:%02d", ( gmtime($end_time - $start_time))[2,1,0] ), 
			( $size - $start ) / ($end_time - $start_time) / 1024.0 * 8.0, 
			$prog->{filename} );
		move $prog->{filepart}, $prog->{filename} if $prog->{filepart} ne $prog->{filename};
		# re-symlink file
		$prog->create_symlink( $prog->{symlink}, $prog->{filename} ) if $opt->{symlink};
	}

	return 0;
}

