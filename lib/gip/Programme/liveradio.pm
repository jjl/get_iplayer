package gip::Programme::liveradio;

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
use base 'gip::Programme::bbclive';

# Class vars
sub index_min { return 80100 }
sub index_max { return 80199 }
sub channels {
	return {
		'bbc_1xtra'				=> 'BBC 1Xtra',
		'bbc_radio_one'				=> 'BBC Radio 1',
		'bbc_radio_two'				=> 'BBC Radio 2',
		'bbc_radio_three'			=> 'BBC Radio 3',
		'bbc_radio_fourfm'			=> 'BBC Radio 4 FM',
		'bbc_radio_fourlw'			=> 'BBC Radio 4 LW',
		'bbc_radio_five_live'			=> 'BBC Radio 5 live',
		'bbc_radio_five_live_sports_extra'	=> 'BBC 5 live Sports Extra',
		'bbc_6music'				=> 'BBC 6 Music',
		'bbc_7'					=> 'BBC 7',
		'bbc_asian_network'			=> 'BBC Asian Network',
		'bbc_radio_foyle'			=> 'BBC Radio Foyle',
		'bbc_radio_scotland'			=> 'BBC Radio Scotland',
		'bbc_radio_nan_gaidheal'		=> 'BBC Radio Nan Gaidheal',
		'bbc_radio_ulster'			=> 'BBC Radio Ulster',
		'bbc_radio_wales'			=> 'BBC Radio Wales',
		'bbc_radio_cymru'			=> 'BBC Radio Cymru',
		'http://www.bbc.co.uk/worldservice/includes/1024/screen/audio_console.shtml?stream=live' => 'BBC World Service',
		'bbc_world_service' 			=> 'BBC World Service Intl',
		'bbc_radio_cumbria'			=> 'BBC Cumbria',
		'bbc_radio_newcastle'			=> 'BBC Newcastle',
		'bbc_tees'				=> 'BBC Tees',
		'bbc_radio_lancashire'			=> 'BBC Lancashire',
		'bbc_radio_merseyside'			=> 'BBC Merseyside',
		'bbc_radio_manchester'			=> 'BBC Manchester',
		'bbc_radio_leeds'			=> 'BBC Leeds',
		'bbc_radio_sheffield'			=> 'BBC Sheffield',
		'bbc_radio_york'			=> 'BBC York',
		'bbc_radio_humberside'			=> 'BBC Humberside',
		'bbc_radio_lincolnshire'		=> 'BBC Lincolnshire',
		'bbc_radio_nottingham'			=> 'BBC Nottingham',
		'bbc_radio_leicester'			=> 'BBC Leicester',
		'bbc_radio_derby'			=> 'BBC Derby',
		'bbc_radio_stoke'			=> 'BBC Stoke',
		'bbc_radio_shropshire'			=> 'BBC Shropshire',
		'bbc_wm'				=> 'BBC WM',
		'bbc_radio_coventry_warwickshire'	=> 'BBC Coventry & Warwickshire',
		'bbc_radio_hereford_worcester'		=> 'BBC Hereford & Worcester',
		'bbc_radio_northampton'			=> 'BBC Northampton',
		'bbc_three_counties_radio'		=> 'BBC Three Counties',
		'bbc_radio_cambridge'			=> 'BBC Cambridgeshire',
		'bbc_radio_norfolk'			=> 'BBC Norfolk',
		'bbc_radio_suffolk'			=> 'BBC Suffolk',
		'bbc_radio_sussex'			=> 'BBC Sussex',
		'bbc_radio_essex'			=> 'BBC Essex',
		'bbc_london'				=> 'BBC London',
		'bbc_radio_kent'			=> 'BBC Kent',
		'bbc_southern_counties_radio'		=> 'BBC Southern Counties',
		'bbc_radio_oxford'			=> 'BBC Oxford',
		'bbc_radio_berkshire'			=> 'BBC Berkshire',
		'bbc_radio_solent'			=> 'BBC Solent',
		'bbc_radio_gloucestershire'		=> 'BBC Gloucestershire',
		'bbc_radio_swindon'			=> 'BBC Swindon',
		'bbc_radio_wiltshire'			=> 'BBC Wiltshire',
		'bbc_radio_bristol'			=> 'BBC Bristol',
		'bbc_radio_somerset_sound'		=> 'BBC Somerset',
		'bbc_radio_devon'			=> 'BBC Devon',
		'bbc_radio_cornwall'			=> 'BBC Cornwall',
		'bbc_radio_guernsey'			=> 'BBC Guernsey',
		'bbc_radio_jersey'			=> 'BBC Jersey',
	};
}


# Class cmdline Options
sub opt_format {
	return {
		liveradiomode	=> [ 1, "liveradiomode=s", 'Recording', '--liveradiomode <mode>,<mode>,..', "Live Radio Recording modes: flashaac,realaudio,wma"],
		outputliveradio	=> [ 1, "outputliveradio=s", 'Output', '--outputliveradio <dir>', "Output directory for live radio recordings"],
		rtmpliveradioopts => [ 1, "rtmp-liveradio-opts|rtmpliveradioopts=s", 'Recording', '--rtmp-liveradio-opts <options>', "Add custom options to flvstreamer/rtmpdump for liveradio"],
	};
}



# This gets run before the download retry loop if this class type is selected
sub init {
	# Force certain options for Live 
	# Force --raw otherwise realaudio stdout streaming fails
	# (this would normally be a bad thing but since its a live stream we 
	# won't be downloading other types of progs afterwards)
	$opt->{raw} = 1 if $opt->{stdout} && $opt->{nowrite};
	# Force only one try if live and recording to file
	$opt->{attempts} = 1 if ( ! $opt->{attempts} ) && ( ! $opt->{nowrite} );
	# Force to skip checking history if live
	$opt->{force} = 1;
}



# Returns the modes to try for this prog type
sub modelist {
	my $prog = shift;
	my $mlist = $opt->{liveradiomode} || $opt->{modes};
	
	# Defaults
	if ( ! $mlist ) {
		if ( ! main::exists_in_path('flvstreamer') ) {
			main::logger "WARNING: Not using flash modes since flvstreamer/rtmpdump is not found\n" if $opt->{verbose};
			$mlist = 'realaudio,wma';
		} else {
			$mlist = 'flashaachigh,flashaacstd,realaudio,flashaaclow,wma';
		}
	}
	# Deal with BBC Radio fallback modes and expansions
	# Valid modes are rtmp,flashaac,realaudio,wmv
	# 'rtmp' or 'flash' => 'flashaac'
	# flashaac => flashaachigh,flashaacstd,flashaaclow
	# flashaachigh => flashaachigh1,flashaachigh2
	$mlist = main::expand_list($mlist, 'best', 'flashaachigh,flashaacstd,realaudio,flashaaclow,wma');
	$mlist = main::expand_list($mlist, 'flash', 'flashaac');
	$mlist = main::expand_list($mlist, 'rtmp', 'flashaac');
	$mlist = main::expand_list($mlist, 'flashaac', 'flashaachigh,flashaacstd,flashaaclow');

	return $mlist;
}



# Default minimum expected download size for a programme type
sub min_download_size {
	return 102400;
}

