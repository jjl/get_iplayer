		'1xtra/programmes/schedules'		=> 'BBC 1Xtra',
		'radio1/programmes/schedules/england'	=> 'BBC Radio 1 England',
		'radio1/programmes/schedules/northernireland'=> 'BBC Radio 1 Northern Ireland',
		'radio1/programmes/schedules/scotland'	=> 'BBC Radio 1 Scotland',
		'radio1/programmes/schedules/wales'	=> 'BBC Radio 1 Wales',
		'radio2/programmes/schedules'		=> 'BBC Radio 2',
		'radio3/programmes/schedules'		=> 'BBC Radio 3',
		'radio4/programmes/schedules/fm'	=> 'BBC Radio 4 FM',
		'radio4/programmes/schedules/lw'	=> 'BBC Radio 4 LW',
		'5live/programmes/schedules'		=> 'BBC Radio 5 live',
		'5livesportsextra/programmes/schedules'	=> 'BBC 5 live Sports Extra',
		'6music/programmes/schedules'		=> 'BBC 6 Music',
		'radio7/programmes/schedules'		=> 'BBC 7',
		'asiannetwork/programmes/schedules'	=> 'BBC Asian Network',
		'radiofoyle/programmes/schedules'	=> 'BBC Radio Foyle',
		'radioscotland/programmes/schedules/fm'	=> 'BBC Radio Scotland', # fm,mw,orkney,shetland,highlandsandislands
		'radionangaidheal/programmes/schedules'	=> 'BBC Radio Nan Gaidheal',
		'radioulster/programmes/schedules'	=> 'BBC Radio Ulster',
		'radiowales/programmes/schedules/fm'	=> 'BBC Radio Wales FM',
		'radiowales/programmes/schedules/mw'	=> 'BBC Radio Wales MW',
		#'bbc_radio_cymru'			=> 'BBC Radio Cymru', # ????
		'worldservice/programmes/schedules'	=> 'BBC World Service',
		'cumbria/programmes/schedules'		=> 'BBC Cumbria',
		'newcastle/programmes/schedules'	=> 'BBC Newcastle',
		'tees/programmes/schedules'		=> 'BBC Tees',
		'lancashire/programmes/schedules'	=> 'BBC Lancashire',
		'merseyside/programmes/schedules'	=> 'BBC Merseyside',
		'manchester/programmes/schedules'	=> 'BBC Manchester',
		'leeds/programmes/schedules'		=> 'BBC Leeds',
		'sheffield/programmes/schedules'	=> 'BBC Sheffield',
		'york/programmes/schedules'		=> 'BBC York',
		'humberside/programmes/schedules'	=> 'BBC Humberside',
		'lincolnshire/programmes/schedules'	=> 'BBC Lincolnshire',
		'nottingham/programmes/schedules'	=> 'BBC Nottingham',
		'leicester/programmes/schedules'	=> 'BBC Leicester',
		'derby/programmes/schedules'		=> 'BBC Derby',
		'stoke/programmes/schedules'		=> 'BBC Stoke',
		'shropshire/programmes/schedules'	=> 'BBC Shropshire',
		'wm/programmes/schedules'		=> 'BBC WM',
		'coventry/programmes/schedules'		=> 'BBC Coventry & Warwickshire',
		'herefordandworcester/programmes/schedules'=> 'BBC Hereford & Worcester',
		'northampton/programmes/schedules'	=> 'BBC Northampton',
		'threecounties/programmes/schedules'	=> 'BBC Three Counties',
		'cambridgeshire/programmes/schedules'	=> 'BBC Cambridgeshire',
		'norfolk/programmes/schedules'		=> 'BBC Norfolk',
		'suffolk/programmes/schedules'		=> 'BBC Suffolk',
		'essex/programmes/schedules'		=> 'BBC Essex',
		'london/programmes/schedules'		=> 'BBC London',
		'kent/programmes/schedules'		=> 'BBC Kent',
		'surrey/programmes/schedules'		=> 'BBC Surrey',
		'sussex/programmes/schedules'		=> 'BBC Sussex',
		'oxford/programmes/schedules'		=> 'BBC Oxford',
		'berkshire/programmes/schedules'	=> 'BBC Berkshire',
		'solent/programmes/schedules'		=> 'BBC Solent',
		'gloucestershire/programmes/schedules'	=> 'BBC Gloucestershire',
		'wiltshire/programmes/schedules'	=> 'BBC Wiltshire',
		'bristol/programmes/schedules'		=> 'BBC Bristol',
		'somerset/programmes/schedules'		=> 'BBC Somerset',
		'devon/programmes/schedules'		=> 'BBC Devon',
		'cornwall/programmes/schedules'		=> 'BBC Cornwall',
		'guernsey/programmes/schedules'		=> 'BBC Guernsey',
		'jersey/programmes/schedules'		=> 'BBC Jersey',
	};
}


# Class cmdline Options
sub opt_format {
	return {
		radiomode	=> [ 1, "radiomode|amode=s", 'Recording', '--radiomode <mode>,<mode>,...', "Radio Recording mode(s): iphone,flashaac,flashaachigh,flashaacstd,flashaaclow,flashaudio,realaudio,wma (default: iphone,flashaachigh,flashaacstd,flashaudio,realaudio,flashaaclow)"],
		bandwidth 	=> [ 1, "bandwidth=n", 'Recording', '--bandwidth', "In radio realaudio mode specify the link bandwidth in bps for rtsp streaming (default 512000)"],
		lame		=> [ 0, "lame=s", 'External Program', '--lame <path>', "Location of lame binary"],
		outputradio	=> [ 1, "outputradio=s", 'Output', '--outputradio <dir>', "Output directory for radio recordings"],
		wav		=> [ 1, "wav!", 'Recording', '--wav', "In radio realaudio mode output as wav and don't transcode to mp3"],
		rtmpradioopts	=> [ 1, "rtmp-radio-opts|rtmpradioopts=s", 'Recording', '--rtmp-radio-opts <options>', "Add custom options to flvstreamer/rtmpdump for radio"],
	};
}



# This gets run before the download retry loop if this class type is selected
sub init {
	# Force certain options for radio
	# Force --raw otherwise realaudio stdout streaming fails
	# (this would normally be a bad thing but since its a stdout stream we 
	# won't be downloading other types of progs afterwards)
	$opt->{raw} = 1 if $opt->{stdout} && $opt->{nowrite};
}



# Method to return optional list_entry format
sub optional_list_entry_format {
	my $prog = shift;
	my @format;
	for ( qw/ channel categories / ) {
		push @format, $prog->{$_} if defined $prog->{$_};
	}
	return ', '.join ', ', @format;
}



# Default minimum expected download size for a programme type
sub min_download_size {
	return 102400;
}



# Returns the modes to try for this prog type
sub modelist {
	my $prog = shift;
	my $mlist = $opt->{radiomode} || $opt->{modes};
	
	# Defaults
	if ( ! $mlist ) {
		if ( ! main::exists_in_path('flvstreamer') ) {
			main::logger "WARNING: Not using flash modes since flvstreamer/rtmpdump is not found\n" if $opt->{verbose};
			$mlist = 'iphone,realaudio,wma';
		} else {
			$mlist = 'iphone,flashaachigh,flashaacstd,flashaudio,realaudio,flashaaclow,wma';
		}
	}
	# Deal with BBC Radio fallback modes and expansions
	# Valid modes are iphone,rtmp,flashaac,flashaudio,realaudio,wmv
	# 'rtmp' or 'flash' => 'flashaudio,flashaac'
	# flashaac => flashaachigh,flashaacstd,flashaaclow
	# flashaachigh => flashaachigh1,flashaachigh2
	$mlist = main::expand_list($mlist, 'best', 'flashaachigh,flashaacstd,iphone,flashaudio,realaudio,flashaaclow,wma');
	$mlist = main::expand_list($mlist, 'flash', 'flashaudio,flashaac');
	$mlist = main::expand_list($mlist, 'rtmp', 'flashaudio,flashaac');
	$mlist = main::expand_list($mlist, 'flashaac', 'flashaachigh,flashaacstd,flashaaclow');

	return $mlist;
}



sub clean_pid {
	my $prog = shift;

	## extract [bpw]??????? format - remove surrounding url
	#$prog->{pid} =~ s/^.+\/([bpw]\w{7})(\..+)?$/$1/g;
	## Remove extra URL path for URLs like 'http://www.bbc.co.uk/iplayer/radio/bbc_radio_one'
	#$prog->{pid} =~ s/^.+\/(.+?)\/?$/$1/g;

	# If this is an iPlayer pid
	if ( $prog->{pid} =~ m{^([bpw]0[a-z0-9]{6})$} ) {
		# extract b??????? format from any URL containing it
		$prog->{pid} = $1;

	# If this is an iPlayer programme pid URL (and not on BBC programmes site)
	} elsif ( $prog->{pid} =~ m{^http.+\/([bpw]0[a-z0-9]{6})\/?.*$} && $prog->{pid} !~ m{/programmes/} ) {
		# extract b??????? format from any URL containing it
		$prog->{pid} = $1;

	# If this is a BBC *iPlayer* Live channel
	#} elsif ( $prog->{pid} =~ m{http.+bbc\.co\.uk/iplayer/console/}i ) {
	#	# Just leave the URL as the pid

	# e.g. http://www.bbc.co.uk/iplayer/playlive/bbc_radio_fourfm/
	} elsif ( $prog->{pid} =~ m{http.+bbc\.co\.uk/iplayer}i ) {
		# Remove extra URL path for URLs like 'http://www.bbc.co.uk/iplayer/playlive/bbc_radio_one/'
		$prog->{pid} =~ s/^http.+\/(.+?)\/?$/$1/g;

	# Else this is an embedded media player URL (live or otherwise)
	} elsif ($prog->{pid} =~ m{^http}i ) {
		# Just leave the URL as the pid
	}
}



sub get_links {
	shift;
	# Delegate to Programme::tv (same function is used)
	return Programme::tv->get_links(@_);
}



sub download {
	# Delegate to Programme::tv (same function is used)
	return Programme::tv::download(@_);
}

