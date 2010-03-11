package Programme::bbclive;

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

# Inherit from Programme class
use base 'Programme::bbciplayer';

# Class vars
sub file_prefix_format { '<name> <episode> <dldate> <dltime>' }

# Class cmdline Options
sub opt_format {
	return {};
}



# Method to return optional list_entry format
sub optional_list_entry_format {
	return '';
}


sub clean_pid {
	my $prog = shift;

	# If this is a BBC *iPlayer* Live channel
	#if ( $prog->{pid} =~ m{http.+bbc\.co\.uk/iplayer/console/}i ) {
	#	# Just leave the URL as the pid
	# e.g. http://www.bbc.co.uk/iplayer/playlive/bbc_radio_fourfm/
	if ( $prog->{pid} =~ m{http.+bbc\.co\.uk/iplayer}i ) {
		# Remove extra URL path for URLs like 'http://www.bbc.co.uk/iplayer/playlive/bbc_radio_one/'
		$prog->{pid} =~ s/^http.+\/(.+?)\/?$/$1/g;

	# Else this is an embedded media player URL (live or otherwise)
	} elsif ($prog->{pid} =~ m{^http}i ) {
		# Just leave the URL as the pid
	}
}



# Usage: Programme::liveradio->get_links( \%prog, 'liveradio' );
# Uses: %{ channels() }, \%prog
sub get_links {
	shift; # ignore obj ref
	my $prog = shift;
	my $prog_type = shift;
	# Hack to get correct 'channels' method because this methods is being shared with Programme::radio
	my %channels = %{ main::progclass($prog_type)->channels_filtered( main::progclass($prog_type)->channels() ) };

	for ( sort keys %channels ) {

			# Extract channel
			my $channel = $channels{$_};
			my $pid = $_;
			my $name = $channels{$_};
			my $episode = 'live';
			main::logger "DEBUG: '$pid, $name - $episode, $channel'\n" if $opt->{debug};

			# build data structure
			$prog->{$pid} = main::progclass($prog_type)->new(
				'pid'		=> $pid,
				'name'		=> $name,
				'versions'	=> 'default',
				'episode'	=> $episode,
				'desc'		=> "Live stream of $name",
				'guidance'	=> '',
				#'thumbnail'	=> "http://static.bbc.co.uk/mobile/iplayer_widget/img/ident_${pid}.png",
				'thumbnail'	=> "http://www.bbc.co.uk/iplayer/img/station_logos/${pid}.png",
				'channel'	=> $channel,
				#'categories'	=> join(',', @category),
				'type'		=> $prog_type,
				'web'		=> "http://www.bbc.co.uk/iplayer/playlive/${pid}/",
			);
	}
	main::logger "\n";
	return 0;
}



sub download {
	# Delegate to Programme::tv (same function is used)
	return Programme::tv::download(@_);
}

