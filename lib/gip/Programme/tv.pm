package gip::Programme::tv;

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
use base 'gip::Programme::bbciplayer';

# Class vars
sub index_min { return 1 }
sub index_max { return 9999 }
sub channels {
	return {
		'bbcone'			=> 'BBC One',
		'bbctwo'			=> 'BBC Two',
		'bbcthree'			=> 'BBC Three',
		'bbcfour'			=> 'BBC Four',
		'bbcnews'			=> 'BBC News 24',
		'cbbc'				=> 'CBBC',
		'cbeebies'			=> 'CBeebies',
		'parliament'			=> 'BBC Parliament',
		'bbcwebonly'			=> 'BBC Web Only',
		'bbchd'				=> 'BBC HD',
		'bbcalba'			=> 'BBC Alba',
		'categories/news/tv'		=> 'BBC News',
		'categories/sport/tv'		=> 'BBC Sport',
		'categories/signed'		=> 'Signed',
		'categories/audiodescribed'	=> 'Audio Described',
		'popular/tv'			=> 'Popular',
		'highlights/tv'			=> 'Highlights',
	};
}


# channel ids be found on http://www.bbc.co.uk/bbcone/programmes/schedules/today
sub channels_schedule {
	return {
		'bbcalba/programmes/schedules'		=> 'BBC Alba',
		'bbcfour/programmes/schedules'		=> 'BBC Four',
		'bbchd/programmes/schedules'		=> 'BBC HD',
		'bbcnews/programmes/schedules'		=> 'BBC News 24',
		'bbcone/programmes/schedules/london'	=> 'BBC One London',
		'bbcone/programmes/schedules/ni'	=> 'BBC One Northern Ireland',
		'bbcone/programmes/schedules/scotland'	=> 'BBC One Scotland',
		'bbcone/programmes/schedules/wales'	=> 'BBC One Wales',
		'parliament/programmes/schedules'	=> 'BBC Parliament',
		'bbcthree/programmes/schedules'		=> 'BBC Three',
		'bbctwo/programmes/schedules/england'	=> 'BBC Two England',
		'bbctwo/programmes/schedules/ni'	=> 'BBC Two Northern Ireland',
		'bbctwo/programmes/schedules/scotland'	=> 'BBC Two Scotland',
		'bbctwo/programmes/schedules/wales'	=> 'BBC Two Wales',
		'cbbc/programmes/schedules'		=> 'CBBC',
		'cbeebies/programmes/schedules'		=> 'CBeebies',
	};
}


# Class cmdline Options
sub opt_format {
	return {
		tvmode		=> [ 1, "tvmode|vmode=s", 'Recording', '--tvmode <mode>,<mode>,...', "TV Recoding modes: iphone,rtmp,flashhd,flashvhigh,flashhigh,flashstd,flashnormal,flashlow,n95_wifi (default: iphone,flashhigh,flashstd,flashnormal)"],
		outputtv	=> [ 1, "outputtv=s", 'Output', '--outputtv <dir>', "Output directory for tv recordings"],
		vlc		=> [ 1, "vlc=s", 'External Program', '--vlc <path>', "Location of vlc or cvlc binary"],
		rtmptvopts	=> [ 1, "rtmp-tv-opts|rtmptvopts=s", 'Recording', '--rtmp-tv-opts <options>', "Add custom options to flvstreamer/rtmpdump for tv"],
	};
}



# Method to return optional list_entry format
sub optional_list_entry_format {
	my $prog = shift;
	my @format;
	for ( qw/ channel categories versions / ) {
		push @format, $prog->{$_} if defined $prog->{$_};
	}
	return ', '.join ', ', @format;
}



# Returns the modes to try for this prog type
sub modelist {
	my $prog = shift;
	my $mlist = $opt->{tvmode} || $opt->{modes};
	
	# Defaults
	if ( ! $mlist ) {
		if ( ! main::exists_in_path('flvstreamer') ) {
			main::logger "WARNING: Not using flash modes since flvstreamer/rtmpdump is not found\n" if $opt->{verbose};
			$mlist = 'iphone';
		} else {
			$mlist = 'iphone,flashhigh,flashstd,flashnormal';
		}
	}
	# Deal with BBC TV fallback modes and expansions
	# Valid modes are iphone,rtmp,flashhigh,flashnormal,flashlow,n95_wifi
	# 'rtmp' or 'flash' => 'flashhigh,flashnormal'
	$mlist = main::expand_list($mlist, 'best', 'flashhd,flashvhigh,flashhigh,iphone,flashstd,flashnormal,flashlow');
	$mlist = main::expand_list($mlist, 'flash', 'flashhigh,flashstd,flashnormal');
	$mlist = main::expand_list($mlist, 'rtmp', 'flashhigh,flashstd,flashnormal');

	return $mlist;
}



# Cleans up a pid and removes url parts that might be specified
sub clean_pid {
	my $prog = shift;

	# Extract the appended start timestamp if it exists and set options accordingly e.g. '?t=16m51s'
	if ( $prog->{pid} =~ m{\?t=(\d+)m(\d+)s$} ) {
		# calculate the start offset
		$opt->{start} = $1*60.0 + $2;
	}
	
	# Expand Short iplayer URL redirects
	# e.g. http://bbc.co.uk/i/lnc8s/
	if ( $prog->{pid} =~ m{bbc\.co\.uk\/i\/[a-z0-9]{5}\/.*$}i ) {
		# Do a recursive redirect lookup to get the final URL
		my $ua = main::create_ua( 'desktop' );
		main::proxy_disable($ua) if $opt->{partialproxy};
		my $res;
		do {
			# send request (use simple_request here because that will not allow redirects)
			$res = $ua->simple_request( HTTP::Request->new( 'GET', $prog->{pid} ) );
			if ( $res->is_redirect ) {
				$prog->{pid} = $res->header("location");
				$prog->{pid} = 'http://bbc.co.uk'.$prog->{pid} if $prog->{pid} !~ /^http/;
				main::logger "DEBUG: got short url redirect to '$prog->{pid}' from iplayer site\n" if $opt->{debug};
			}
		} while ( $res->is_redirect );
		main::proxy_enable($ua) if $opt->{partialproxy};
		main::logger "DEBUG: Final expanded short URL is '$prog->{pid}'\n" if $opt->{debug};
	}
		
	# If this is an iPlayer pid
	if ( $prog->{pid} =~ m{^([pb]0[a-z0-9]{6})$} ) {
		# extract b??????? format from any URL containing it
		$prog->{pid} = $1;

	# If this an URL containing a PID (except for BBC programmes URLs)
	} elsif ( $prog->{pid} =~ m{^http.+\/([pb]0[a-z0-9]{6})\/?.*$} && $prog->{pid} !~ m{/programmes/} ) {
		# extract b??????? format from any URL containing it
		$prog->{pid} = $1;

	# If this is a BBC *iPlayer* Live channel
	# e.g. http://www.bbc.co.uk/iplayer/playlive/bbc_radio_fourfm/
	} elsif ( $prog->{pid} =~ m{http.+bbc\.co\.uk/iplayer}i ) {
		# Remove extra URL path for URLs like 'http://www.bbc.co.uk/iplayer/playlive/bbc_one_london/' or 'http://www.bbc.co.uk/iplayer/tv/bbc_one'
		$prog->{pid} =~ s/^http.+\/(.+?)\/?$/$1/g;
	# Else this is an embedded media player URL (live or otherwise)
	} elsif ($prog->{pid} =~ m{^http}i ) {
		# Just leave the URL as the pid
	}
}



# Usage: gip::Programme::tv->get_links( \%prog, 'tv' );
# Uses: %{ channels() }, \%prog
sub get_links {
	shift; # ignore obj ref
	my $prog = shift;
	my $prog_type = shift;
	# Hack to get correct 'channels' method because this methods is being shared with gip::Programme::radio
	my %channels = %{ main::progclass($prog_type)->channels_filtered( main::progclass($prog_type)->channels() ) };
	my $channel_feed_url = 'http://feeds.bbc.co.uk/iplayer'; # /$channel/list
	my $bbc_prog_page_prefix = 'http://www.bbc.co.uk/programmes'; # /$pid
	my $thumbnail_prefix = 'http://www.bbc.co.uk/iplayer/images/episode';
	my $xml;
	my $feed_data;
	my $res;
	main::logger "INFO: Getting $prog_type Index Feeds\n";
	# Setup User agent
	my $ua = main::create_ua( 'desktop', 1 );

	# Download index feed
	# Sort feeds so that category based feeds are done last - this makes sure that the channels get defined correctly if there are dups
	my @channel_list;
	push @channel_list, grep !/(categor|popular|highlights)/, keys %channels;
	push @channel_list, grep  /categor/, keys %channels;
	push @channel_list, grep  /popular/, keys %channels;
	push @channel_list, grep  /highlights/, keys %channels;
	for ( @channel_list ) {

		my $url = "${channel_feed_url}/$_/list/limit/400";
		main::logger "DEBUG: Getting feed $url\n" if $opt->{verbose};
		$xml = main::request_url_retry($ua, $url, 3, '.', "WARNING: Failed to get programme index feed for $_ from iplayer site\n");
		decode_entities($xml);
		
		# Feed as of August 2008
		#	 <entry>
		#	   <title type="text">Bargain Hunt: Series 18: Oswestry</title>
		#	   <id>tag:feeds.bbc.co.uk,2008:PIPS:b0088jgs</id>
		#	   <updated>2008-07-22T00:23:50Z</updated>
		#	   <content type="html">
		#	     &lt;p&gt;
		#	       &lt;a href=&quot;http://www.bbc.co.uk/iplayer/episode/b0088jgs?src=a_syn30&quot;&gt;
		#		 &lt;img src=&quot;http://www.bbc.co.uk/iplayer/images/episode/b0088jgs_150_84.jpg&quot; alt=&quot;Bargain Hunt: Series 18: Oswestry&quot; /&gt;
		#	       &lt;/a&gt;
		#	     &lt;/p&gt;
		#	     &lt;p&gt;
		#	       The teams are at an antiques fair in Oswestry showground. Hosted by Tim Wonnacott.
		#	     &lt;/p&gt;
		#	   </content>
		#	   <category term="Factual" />
		#          <category term="Guidance" />
		#	   <category term="TV" />
		#	   <link rel="via" href="http://www.bbc.co.uk/iplayer/episode/b0088jgs?src=a_syn30" type="text/html" title="Bargain Hunt: Series 18: Oswestry" />
		#       </entry>
		#

		### New Feed
		#  <entry>
		#    <title type="text">House of Lords: 02/07/2008</title>
		#    <id>tag:bbc.co.uk,2008:PIPS:b00cd5p7</id>
		#    <updated>2008-06-24T00:15:11Z</updated>
		#    <content type="html">
		#      <p>
		#	<a href="http://www.bbc.co.uk/iplayer/episode/b00cd5p7?src=a_syn30">
		#	  <img src="http://www.bbc.co.uk/iplayer/images/episode/b00cd5p7_150_84.jpg" alt="House of Lords: 02/07/2008" />
		#	</a>
		#      </p>
		#      <p>
		#	House of Lords, including the third reading of the Health and Social Care Bill. 1 July.
		#      </p>
		#    </content>
		#    <category term="Factual" scheme="urn:bbciplayer:category" />
		#    <link rel="via" href="http://www.bbc.co.uk/iplayer/episode/b00cd5p7?src=a_syn30" type="application/atom+xml" title="House of Lords: 02/07/2008">
		#    </link>
		#  </entry>

		### Newer feed (Sept 2009)
		#  <entry>
		#    <title type="text">BBC Proms: 2009: Prom 65: Gustav Mahler Jugend Orchester</title>
		#    <id>tag:feeds.bbc.co.uk,2008:PIPS:b00mgw03</id>
		#    <updated>2009-09-05T03:29:07Z</updated>
		#    <content type="html">
		#      &lt;p&gt;
		#        &lt;a href=&quot;http://www.bbc.co.uk/iplayer/episode/b00mgw03/BBC_Proms_2009_Prom_65_Gustav_Mahler_Jugend_Orchester/&quot;&gt;
		#          &lt;img src=&quot;http://node1.bbcimg.co.uk/iplayer/images/episode/b00mgw03_150_84.jpg&quot; alt=&quot;BBC Proms: 2009: Prom 65: Gustav Mahler Jugend Orchester&quot; /&gt;
		#        &lt;/a&gt;
		#      &lt;/p&gt;
		#      &lt;p&gt;
		#        The Gustav Mahler Youth Orchestra perform works by Mahler, Richard Strauss and Ligeti.
		#      &lt;/p&gt;
		#    </content>
		#    <category term="Music" />
		#    <category term="Classical" />
		#    <category term="TV" />
		#    <link rel="alternate" href="http://www.bbc.co.uk/iplayer/episode/b00mgw03/BBC_Proms_2009_Prom_65_Gustav_Mahler_Jugend_Orchester/" type="text/html" title="BBC Proms: 2009: Prom 65: Gustav Mahler Jugend Orchester">
		#      <media:content>
		#        <media:thumbnail url="http://node1.bbcimg.co.uk/iplayer/images/episode/b00mgw03_150_84.jpg" width="150" height="84" />
		#      </media:content>
		#    </link>
		#    <link rel="self" href="http://feeds.bbc.co.uk/iplayer/episode/b00mgw03" type="application/atom+xml" title="Prom 65: Gustav Mahler Jugend Orchester" />
		#    <link rel="related" href="http://www.bbc.co.uk/programmes/b007v097/microsite" type="text/html" title="BBC Proms" />
		#  </entry>


		# Parse XML

		# get list of entries within <entry> </entry> tags
		my @entries = split /<entry>/, $xml;
		# Discard first element == header
		shift @entries;

		main::logger "INFO: Got ".($#entries + 1)." programmes\n" if $opt->{verbose};
		foreach my $entry (@entries) {
			my ( $title, $name, $episode, $episodetitle, $nametitle, $episodenum, $seriesnum, $desc, $pid, $available, $channel, $duration, $thumbnail, $version, $guidance );
			
			my $entry_flat = $entry;
			$entry_flat =~ s/\n/ /g;

			# <id>tag:bbc.co.uk,2008:PIPS:b008pj3w</id>
			$pid = $1 if $entry =~ m{<id>.*PIPS:(.+?)</id>};

			# <title type="text">Richard Hammond's Blast Lab: Series Two: Episode 11</title>
			# <title type="text">Skate Nation: Pro-Skate Camp</title>
			$title = $1 if $entry =~ m{<title\s*.*?>\s*(.*?)\s*</title>};

			# determine name and episode from title
			( $name, $episode ) = gip::Programme::bbciplayer::split_title( $title );

			# Get the title from the atom link refs only to determine the longer episode name
			$episodetitle = $1 if $entry =~ m{<link\s+rel="self"\s+href="http.+?/episode/.+?"\s+type="application/atom\+xml"\s+title="(.+?)"};
			$nametitle = $1 if $entry =~ m{<link\s+rel="related"\s+href="http.+?/programmes/.+?"\s+type="text/html"\s+title="(.+?)"};

			# Extract the seriesnum
			my $regex = 'Series\s+'.main::regex_numbers();
			$seriesnum = main::convert_words_to_number( $1 ) if "$name $episode" =~ m{$regex}i;

			# Extract the episode num
			my $regex_1 = 'Episode\s+'.main::regex_numbers();
			my $regex_2 = '^'.main::regex_numbers().'\.\s+';
			if ( "$name $episode" =~ m{$regex_1}i ) { 
				$episodenum = main::convert_words_to_number( $1 );
			} elsif ( $episode =~ m{$regex_2}i ) {
				$episodenum = main::convert_words_to_number( $1 );
			} elsif ( $episodetitle =~ m{$regex_2}i ) {
				$episodenum = main::convert_words_to_number( $1 );
			}

			# Re-insert the episode number if the episode text doesn't have it
			if ( $episodenum && $episodetitle =~ /^\d+\./ && $episode !~ /^(.+:\s+)?\d+\./ ) {
				$episode =~ s/^(.+:\s+)?(.*)$/$1$episodenum. $2/;
			}

			#<p>    House of Lords, including the third reading of the Health and Social Care Bill. 1 July.   </p>    </content>
			$desc = $1 if $entry =~ m{<p>\s*(.*?)\s*</p>\s*</content>};
			# Remove unwanted html tags
			$desc =~ s!</?(br|b|i|p|strong)\s*/?>!!gi;

			# Parse the categories into hash
			# <category term="Factual" />
			my @category;
			for my $line ( grep /<category/, (split /\n/, $entry) ) {
				push @category, $1 if $line =~ m{<category\s+term="(.+?)"};
			}
			# strip commas - they confuse sorting and spliting later
			s/,//g for @category;

			# Extract channel
			$channel = $channels{$_};

			main::logger "DEBUG: '$pid, $name - $episode, $channel'\n" if $opt->{debug};

			# Merge and Skip if this pid is a duplicate
			if ( defined $prog->{$pid} ) {
				main::logger "WARNING: '$pid, $prog->{$pid}->{name} - $prog->{$pid}->{episode}, $prog->{$pid}->{channel}' already exists (this channel = $channel)\n" if $opt->{verbose};
				# Since we use the 'Signed' (or 'Audio Described') channel to get sign zone/audio described data, merge the categories from this entry to the existing entry
				if ( $prog->{$pid}->{categories} ne join(',', sort @category) ) {
					my %cats;
					$cats{$_} = 1 for ( @category, split /,/, $prog->{$pid}->{categories} );
					main::logger "INFO: Merged categories for $pid from $prog->{$pid}->{categories} to ".join(',', sort keys %cats)."\n" if $opt->{verbose};
					$prog->{$pid}->{categories} = join(',', sort keys %cats);
				}

				# If this a popular or highlights programme then add these tags to categories
				my %cats;
				$cats{$_} = 1 for ( @category, split /,/, $prog->{$pid}->{categories} );
				$cats{Popular} = 1 if $channel eq 'Popular';
				$cats{Highlights} = 1 if $channel eq 'Highlights';
				$prog->{$pid}->{categories} = join(',', sort keys %cats);

				# If this is a dupicate pid and the channel is now Signed then both versions are available
				$version = 'signed' if $channel eq 'Signed';
				$version = 'audiodescribed' if $channel eq 'Audio Described';
				# Add version to versions for existing prog
				$prog->{$pid}->{versions} = join ',', main::make_array_unique_ordered( (split /,/, $prog->{$pid}->{versions}), $version );
				next;
			}

			# Set guidance based on category
			$guidance = 'Yes' if grep /guidance/i, @category;

			# Check for signed-only or audiodescribed-only version from Channel
			if ( $channel eq 'Signed' ) {
				$version = 'signed';
			} elsif ( $channel eq 'Audio Described' ) {
				$version = 'audiodescribed';
			} else {
				$version = 'default';
			}

			# Default to 150px width thumbnail;
			my $thumbsize = $opt->{thumbsizecache} || 150;

			# build data structure
			$prog->{$pid} = main::progclass($prog_type)->new(
				'pid'		=> $pid,
				'name'		=> $name,
				'versions'	=> $version,
				'episode'	=> $episode,
				'seriesnum'	=> $seriesnum,
				'episodenum'	=> $episodenum,
				'desc'		=> $desc,
				'guidance'	=> $guidance,
				'available'	=> 'Unknown',
				'duration'	=> 'Unknown',
				'thumbnail'	=> "${thumbnail_prefix}/${pid}".gip::Programme::bbciplayer->thumb_url_suffixes->{ $thumbsize },
				'channel'	=> $channel,
				'categories'	=> join(',', sort @category),
				'type'		=> $prog_type,
				'web'		=> "${bbc_prog_page_prefix}/${pid}.html",
			);

		}
	}

	# Get future schedules if required
	# http://www.bbc.co.uk/cbbc/programmes/schedules/this_week.xml
	# http://www.bbc.co.uk/cbbc/programmes/schedules/next_week.xml
	if ( $opt->{refreshfuture} ) {
		# Hack to get correct 'channels' method because this methods is being shared with gip::Programme::radio
		my %channels = %{ main::progclass($prog_type)->channels_filtered( main::progclass($prog_type)->channels_schedule() ) };
		# Only get schedules for real channels
		@channel_list = keys %channels;
		for my $channel_id ( @channel_list ) {
			my @schedule_feeds = (
				"http://www.bbc.co.uk/${channel_id}/this_week.xml",
				"http://www.bbc.co.uk/${channel_id}/next_week.xml",
			);
			for my $url ( @schedule_feeds ) {
				main::logger "DEBUG: Getting feed $url\n" if $opt->{verbose};
				$xml = main::request_url_retry($ua, $url, 3, '.', "WARNING: Failed to get programme schedule feed for $channel_id from iplayer site\n");
				decode_entities($xml);
		
				#      <broadcast>
				#        <start>2010-01-11T11:25:00Z</start>
				#        <end>2010-01-11T11:30:00Z</end>
				#        <duration>300</duration>
				#        <episode>
				#          <pid>b00l6wjs</pid>
				#          <title>Vampire Bats</title>
				#          <short_synopsis>How to survive the most dangerous
				#          situations that Mother Nature can chuck at
				#          you.</short_synopsis>
				#          <medium_synopsis>A light-hearted look at how to survive
				#          the most dangerous situations that Mother Nature can
				#          chuck at you.</medium_synopsis>
				#          <long_synopsis></long_synopsis>
				#          <iplayer>
				#            <audio_expires />
				#            <video_expires>2010-01-18T11:29:00Z</video_expires>
				#          </iplayer>
				#          <position>16</position>
				#          <series>
				#            <pid>b00kh5x3</pid>
				#            <title>Shorts</title>
				#          </series>
				#          <brand>
				#            <pid>b00kh5y8</pid>
				#            <title>Sam and Mark's Guide to Dodging Disaster</title>
				#          </brand>
				#        </episode>
				#      </broadcast>

				# get list of entries within <broadcast> </broadcast> tags
				my @entries = split /<broadcast>/, $xml;
				# Discard first element == header
				shift @entries;
				main::logger "INFO: Got ".($#entries + 1)." programmes\n" if $opt->{verbose};
				my $now = time();
				foreach my $entry (@entries) {
					my ( $title, $channel, $name, $episode, $episodetitle, $nametitle, $seriestitle, $episodenum, $seriesnum, $desc, $pid, $available, $duration, $thumbnail, $version, $guidance );

					my $entry_flat = $entry;
					$entry_flat =~ s/\n/ /g;

					$pid = $1 if $entry =~ m{<episode>.*?<pid>\s*(.+?)\s*</pid>};

					$episode = $1 if $entry =~ m{<episode>.*?<title>\s*(.*?)\s*</title>};
					$nametitle = $1 if $entry =~ m{<brand>.*?<title>\s*(.*?)\s*</title>.*?</brand>};
					$seriestitle = $1 if $entry =~ m{<series>.*?<title>\s*(.*?)\s*</title>.*?</series>};

					# Set name
					if ( $nametitle && $seriestitle ) {
						$name = "$nametitle: $seriestitle";
					} elsif ( $seriestitle && ! $nametitle ) {
						$name = $seriestitle;
					# Fallback to episade name if the BBC missed out both Series and Name
					} elsif ( ( ! $seriestitle ) && ! $nametitle ) {
						$name = $episode;
					} else {
						$name = $nametitle;
					}

					# Extract the seriesnum
					my $regex = 'Series\s+'.main::regex_numbers();
					$seriesnum = main::convert_words_to_number( $1 ) if $seriestitle =~ m{$regex}i;

					# Extract the episode num
					my $regex_1 = 'Episode\s+'.main::regex_numbers();
					my $regex_2 = '^'.main::regex_numbers().'\.\s+';
					if ( $episode =~ m{$regex_1}i ) { 
						$episodenum = main::convert_words_to_number( $1 );
					} elsif ( $episode =~ m{$regex_2}i ) {
						$episodenum = main::convert_words_to_number( $1 );
					}

					# extract desc
					if ( $entry =~ m{<long_synopsis>\s*(.+?)\s*</long_synopsis>} ) {
						$desc = $1;
					} elsif ( $entry =~ m{<medium_synopsis>\s*(.+?)\s*</medium_synopsis>} ) {
						$desc = $1;
					} elsif ( $entry =~ m{<short_synopsis>\s*(.+?)\s*</short_synopsis>} ) {
						$desc = $1;
					};
					# Remove unwanted html tags
					$desc =~ s!</?(br|b|i|p|strong)\s*/?>!!gi;

					$duration = $1 if $entry =~ m{<duration>\s*(.+?)\s*</duration>};
					$available = $1 if $entry =~ m{<start>\s*(.+?)\s*</start>};

					# Extract channel nice name
					$channel = $channels{$channel_id};

					main::logger "DEBUG: '$pid, $name - $episode, $channel'\n" if $opt->{debug};

					# Merge and Skip if this pid is a duplicate
					if ( defined $prog->{$pid} ) {
						main::logger "WARNING: '$pid, $prog->{$pid}->{name} - $prog->{$pid}->{episode}, $prog->{$pid}->{channel}' already exists (this channel = $channel)\n" if $opt->{verbose};
						# Update this info from schedule (not available in the usual iplayer channels feeds)
						$prog->{$pid}->{duration} = $duration;
						$prog->{$pid}->{episodenum} = $episodenum if ! $prog->{$pid}->{episodenum};
						$prog->{$pid}->{seriesnum} = $seriesnum if ! $prog->{$pid}->{seriesnum};
						# don't add this as some progs are already available
						#$prog->{$pid}->{available} = $available;
						next;
					}

					$version = 'default';

					# Default to 150px width thumbnail;
					my $thumbsize = $opt->{thumbsizecache} || 150;

					# Don't create this prog instance if the availablity is in the past 
					# this prevents programmes which never appear in iPlayer from being indexed
					next if gip::Programme::get_time_string( $available ) < $now;

					# build data structure
					$prog->{$pid} = main::progclass($prog_type)->new(
						'pid'		=> $pid,
						'name'		=> $name,
						'versions'	=> $version,
						'episode'	=> $episode,
						'seriesnum'	=> $seriesnum,
						'episodenum'	=> $episodenum,
						'desc'		=> $desc,
						'available'	=> $available,
						'duration'	=> $duration,
						'thumbnail'	=> "${thumbnail_prefix}/${pid}".gip::Programme::bbciplayer->thumb_url_suffixes->{ $thumbsize },
						'channel'	=> $channel,
						'type'		=> $prog_type,
						'web'		=> "${bbc_prog_page_prefix}/${pid}.html",
					);
				}
			}		

		}
	}
	main::logger "\n";
	return 0;
}



# Usage: download (<prog>, <ua>, <mode>, <version>, <version_pid>)
sub download {
	my ( $prog, $ua, $mode, $version, $version_pid ) = ( @_ );

	# Check if we need 'tee'
	if ( $mode =~ /^real/ && (! main::exists_in_path('tee')) && $opt->{stdout} && (! $opt->{nowrite}) ) {
		main::logger "\nERROR: tee does not exist in path, skipping\n";
		return 'next';
	}
	if ( $mode =~ /^(real|wma)/ && (! main::exists_in_path('mplayer')) ) {
		main::logger "\nWARNING: Required mplayer does not exist\n";
		return 'next';
	}
	# Check if we have mplayer and lame
	if ( $mode =~ /^real/ && (! $opt->{wav}) && (! $opt->{raw}) && (! main::exists_in_path('lame')) ) {
		main::logger "\nWARNING: Required lame does not exist, will save file in wav format\n";
		$opt->{wav} = 1;
	}
	# Check if we have vlc
	if ( $mode =~ /^n95/ && (! main::exists_in_path('vlc')) ) {
		main::logger "\nWARNING: Required vlc does not exist\n";
		return 'next';
	}
	# if rtmpdump does not exist
	if ( $mode =~ /^flash/ && ! main::exists_in_path('flvstreamer')) {
		main::logger "WARNING: Required program flvstreamer/rtmpdump does not exist (see http://linuxcentre.net/getiplayer/installation and http://linuxcentre.net/getiplayer/download)\n";
		return 'next';
	}
	# Force raw mode if ffmpeg is not installed
	if ( $mode =~ /^flash/ && ! main::exists_in_path('ffmpeg')) {
		main::logger "\nWARNING: ffmpeg does not exist - not converting flv file\n";
		$opt->{raw} = 1;
	}

	# Get extension from streamdata if defined and raw not specified
	$prog->{ext} = $prog->{streams}->{$version}->{$mode}->{ext};

	# Nasty hacky filename ext overrides based on non-default fallback modes
	# Override iphone ext from metadata which is wrong for radio
	$prog->{ext} = 'mp3' if $mode =~ /^iphone/ && $prog->{type} eq 'radio';
	# Override realaudio ext based on raw / wav
	$prog->{ext} = 'ra'  if $opt->{raw} &&  $mode =~ /^real/;
	$prog->{ext} = 'wav' if $opt->{wav} &&  $mode =~ /^real/;
	# Override flash ext based on raw
	$prog->{ext} = 'flv' if $opt->{raw} && $mode =~ /^flash/;


	# Determine the correct filenames for this recording
	if ( $prog->generate_filenames( $ua, $prog->file_prefix_format() ) ) {
		# Create symlink if required
		$prog->create_symlink( $prog->{symlink}, $prog->{filename}) if $opt->{symlink};
		return 'skip';
	}
	
	# Skip from here if we are only testing recordings
	return 'skip' if $opt->{test};

	# Get subtitles if they exist and are required 
	# best to do this before streaming file so that the subtitles can be enjoyed while recording progresses
	my $subfile_done;
	my $subfile;
	if ( $opt->{subtitles} ) {
		$subfile_done = "$prog->{dir}/$prog->{fileprefix}.srt";
		$subfile = "$prog->{dir}/$prog->{fileprefix}.partial.srt";
		main::logger "\n";
		$prog->download_subtitles( $ua, $subfile );
	}


	my $return = 0;
	# Only get the stream if we are writing a file or streaming
	if ( $opt->{stdout} || ! $opt->{nowrite} ) {
		# set mode
		$prog->{mode} = $mode;

		# Disable proxy here if required
		main::proxy_disable($ua) if $opt->{partialproxy};

		# Instantiate new streamer based on streamdata
		my $class = "gip::Streamer::$prog->{streams}->{$version}->{$mode}->{streamer}";
		my $stream = $class->new;

		# Do recording
		$return = $stream->get( $ua, $prog->{streams}->{$version}->{$mode}->{streamurl}, $prog, %{ $prog->{streams}->{$version}->{$mode} } );

		# Re-enable proxy here if required
		main::proxy_enable($ua) if $opt->{partialproxy};
	}

	# Rename the subtitle file accordingly if the stream get was successful
	move($subfile, $subfile_done) if $opt->{subtitles} && -f $subfile && ! $return;

	return $return;
}



# BBC iPlayer TV
# Download Subtitles, convert to srt(SubRip) format and apply time offset
# Todo: get the subtitle streamurl before this...
sub download_subtitles {
	my $prog = shift;
	my ( $ua, $file ) = @_;
	my $suburl;
	my $subs;
	
	# Don't redownload subs if the file already exists
	if ( ( -f $file || -f "$prog->{dir}/$prog->{fileprefix}.partial.srt" ) && ! $opt->{overwrite} ) {
		main::logger "INFO: Skipping subtitles download - file already exists: $file\n" if $opt->{verbose};
		return 0;
	}

	$suburl = $prog->{streams}->{$prog->{version}}->{subtitles1}->{streamurl};
	# Return if we have no url
	if (! $suburl) {
		main::logger "INFO: Subtitles not available\n";
		return 2;
	}

	main::logger "INFO: Getting Subtitles from $suburl\n" if $opt->{verbose};

	# Open subs file
	unlink($file);
	open( my $fh, "> $file" );
	binmode $fh;

	# Download subs
	$subs = main::request_url_retry($ua, $suburl, 2);
	if (! $subs ) {
		main::logger "ERROR: Subtitle Download failed\n";
		close $fh;
		unlink($file) if -f $file;
		return 1;
	} else {
		# Dump raw subs into a file if required
		if ( $opt->{subsraw} ) {
			unlink("$prog->{dir}/$prog->{fileprefix}.ttxt");
			main::logger "INFO: 'Downloading Raw Subtitles to $prog->{dir}/$prog->{fileprefix}.ttxt'\n";
			open( my $fhraw, "> $prog->{dir}/$prog->{fileprefix}.ttxt");
			binmode $fhraw;
			print $fhraw $subs;
			close $fhraw;
		}
		main::logger "INFO: Downloading Subtitles to '$prog->{dir}/$prog->{fileprefix}.srt'\n";
	}

	# Convert the format to srt
	# SRT:
	#1
	#00:01:22,490 --> 00:01:26,494
	#Next round!
	#
	#2
	#00:01:33,710 --> 00:01:37,714
	#Now that we've moved to paradise, there's nothing to eat.
	#
	
	# TT:
	#<p begin="0:01:12.400" end="0:01:13.880">Thinking.</p>
	#<p begin="00:01:01.88" id="p15" end="00:01:04.80"><span tts:color="cyan">You're thinking of Hamburger Hill...<br /></span>Since we left...</p>
	#<p begin="00:00:18.48" id="p0" end="00:00:20.52">APPLAUSE AND CHEERING</p>
	my $count = 1;
	my @lines = grep /<p\s.*begin=/, split /\n/, $subs;
	for ( @lines ) {
		my ( $begin, $end, $sub );
		# Remove <br /> elements
		s|<br.*?>| |g;
		# Remove >1 spaces
		s|\s{2,}| |g;
		( $begin, $end, $sub ) = ( $1, $2, $3 ) if m{<p\s+.*begin="(.+?)".+end="(.+?)".*?>(.+?)<\/p>};
		if ($begin && $end && $sub ) {
			# Format numerical field widths
			$begin = sprintf( '%02d:%02d:%02d,%02d', split /[:\.,]/, $begin );
			$end = sprintf( '%02d:%02d:%02d,%02d', split /[:\.,]/, $end );
			# Add trailing zero if ttxt format only uses hundreths of a second
			$begin .= '0' if $begin =~ m{,\d\d$};
			$end .= '0' if $end =~ m{,\d\d$};
			if ($opt->{suboffset}) {
				$begin = main::subtitle_offset( $begin, $opt->{suboffset} );
				$end = main::subtitle_offset( $end, $opt->{suboffset} );
			}
			# Separate individual lines based on <span>s
			$sub =~ s|<span.*?>(.*?)</span>|\n$1\n|g;
			if ($sub =~ m{\n}) {
				chomp($sub);
				$sub =~ s|^\n?|- |;
				$sub =~ s|\n+|\n- |g;
			}
			decode_entities($sub);
			# Write to file
			print $fh "$count\n";
			print $fh "$begin --> $end\n";
			print $fh "$sub\n\n";
			$count++;
		}
	}	
	close $fh;

	return 0;
}

