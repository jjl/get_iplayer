package gip::Streamer::filestreamonly;

# Inherit from Streamer class
use base 'Streamer';

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use strict;

# Generic
# Actually do the file streaming
sub get {
	my ( $stream, $ua, $url, $prog ) = @_;
	my $start_time = time();

	main::logger "INFO: URL = $url\n" if $opt->{verbose};

	# Just remove any existing file
	unlink $prog->{filepart};
	
	# Streaming
	if ( $opt->{stdout} && $opt->{nowrite} ) {
		main::logger "INFO: Streaming $url to STDOUT\n" if $opt->{verbose};
		if ( ! open(FH, "< $url") ) {
			main::logger "ERROR: Cannot open $url: $!\n";
			return 'next';
		}
		# Fix for binary - needed for Windows
		binmode STDOUT;

		# Read each char from command output and push to STDOUT
		my $char;
		my $bytes;
		my $size = 200000;
		while ( $bytes = read( FH, $char, $size ) ) {
			if ( $bytes <= 0 ) {
				close FH;
				last;
			} else {
				print STDOUT $char;
			}
			last if $bytes < $size;
		}
		close FH;
		main::logger "DEBUG: streaming $url completed\n" if $opt->{debug};

	# Recording - disabled
	} else {
		# Commented out cos this is stream-only - don't want anything in history as a result
		#main::logger "INFO: Copying $url to $prog->{filepart}\n" if $opt->{verbose};
		#if ( ! copy( $url, $prog->{filepart} ) ) {
		#	main::logger "\rERROR: Recording failed\n";
			main::logger "\rERROR: Recording failed - this is a stream-only programme\n";
			return 'next';
		#}
		#move $prog->{filepart}, $prog->{filename} if $prog->{filepart} ne $prog->{filename};
		## symlink file
		#$prog->create_symlink( $prog->{symlink}, $prog->{filename} ) if $opt->{symlink};
	}

	return 0;
}

