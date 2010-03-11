package gip::Streamer::3gp;

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
# Actually do the 3gp / N95 h.264 streaming
sub get {
	my ( $stream, $ua, $url, $prog ) = @_;

	# Resolve URL if required
	if ( $url =~ /^http/ ) {
		my $url1 = main::request_url_retry($ua, $url, 2, '', '');
		chomp($url1);
		$url = $url1;
	}

	my @opts;
	@opts = @{ $binopts->{vlc} } if $binopts->{vlc};

	main::logger "INFO: URL = $url\n" if $opt->{verbose};
	if ( ! $opt->{stdout} ) {
		main::logger "INFO: Recording Low Quality H.264 stream\n";
		my @cmd = (
			$bin->{vlc},
			@opts,
			'--sout', 'file/ts:'.$prog->{filepart},
			$url,
			'vlc://quit',
		);
		if ( main::run_cmd( 'STDERR', @cmd ) ) {
			return 'next';
		}

	# to STDOUT
	} else {
		main::logger "INFO: Streaming Low Quality H.264 stream to stdout\n";
		my @cmd = (
			$bin->{vlc},
			@opts,
			'--sout', 'file/ts:-',
			$url,
			'vlc://quit',
		);
		if ( main::run_cmd( 'STDERR', @cmd ) ) {
			return 'next';
		}
	}
	main::logger "INFO: Recorded $prog->{filename}\n";
	# Moving file into place as complete (if not stdout)
	move($prog->{filepart}, $prog->{filename}) if $prog->{filepart} ne $prog->{filename} && ! $opt->{stdout};

	$prog->create_symlink( $prog->{symlink}, $prog->{filename} ) if $opt->{symlink};

	return 0;
}

