package Programme::livetv;

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
use base 'Programme::bbclive';

# Class vars
sub index_min { return 80000 }
sub index_max { return 80099 }
sub channels {
	return {
		'bbc_one'			=> 'BBC One',
		'bbc_two'			=> 'BBC Two',
		'bbc_three'			=> 'BBC Three',
		'bbc_four'			=> 'BBC Four',
		'cbbc'				=> 'CBBC',
		'cbeebies'			=> 'CBeebies',
		'bbc_news24'			=> 'BBC News 24',
		'bbc_parliament'		=> 'BBC Parliament',
	};
}


# Class cmdline Options
sub opt_format {
	return {
		livetvmode	=> [ 1, "livetvmode=s", 'Recording', '--livetvmode <mode>,<mode>,...', "Live TV Recoding modes: flashhd,flashvhigh,flashhigh,flashstd,flashnormal (default: flashhd,flashvhigh,flashhigh,flashstd,flashnormal)"],
		outputlivetv	=> [ 1, "outputlivetv=s", 'Output', '--outputlivetv <dir>', "Output directory for live tv recordings"],
		rtmplivetvopts	=> [ 1, "rtmp-livetv-opts|rtmplivetvopts=s", 'Recording', '--rtmp-livetv-opts <options>', "Add custom options to flvstreamer/rtmpdump for livetv"],
	};
}



# This gets run before the download retry loop if this class type is selected
sub init {
	# Force certain options for Live 
	# Force only one try if live and recording to file
	$opt->{attempts} = 1 if ( ! $opt->{attempts} ) && ( ! $opt->{nowrite} );
	# Force to skip checking history if live
	$opt->{force} = 1;
}



# Returns the modes to try for this prog type
sub modelist {
	my $prog = shift;
	my $mlist = $opt->{livetvmode} || $opt->{modes};
	
	# Defaults
	if ( ! $mlist ) {
		$mlist = 'flashhd,flashvhigh,flashhigh,flashstd,flashnormal';
	}
	# Deal with BBC TV fallback modes and expansions
	# Valid modes are rtmp,flashhigh,flashstd
	# 'rtmp' or 'flash' => 'flashhigh,flashnormal'
	$mlist = main::expand_list($mlist, 'best', 'flashhd,flashvhigh,flashhigh,flashstd,flashnormal,flashlow');
	$mlist = main::expand_list($mlist, 'flash', 'flashhd,flashvhigh,flashhigh,flashstd,flashnormal,flashlow');
	$mlist = main::expand_list($mlist, 'rtmp', 'flashhd,flashvhigh,flashhigh,flashstd,flashnormal,flashlow');

	return $mlist;
}



# Default minimum expected download size for a programme type
sub min_download_size {
	return 102400;
}


