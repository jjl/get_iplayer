package Programme::bbciplayer;

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
use base 'Programme';


# Return hash of version => verpid given a pid
sub get_verpids {
	my ( $prog, $ua ) = @_;
	my $url;

	# If this is already a live or streaming verpid just pass it through	
	# e.g. http://www.bbc.co.uk/mediaselector/4/gtis/?server=cp52115.live.edgefcs.net&identifier=sport1a@s2388&kind=akamai&application=live&cb=28022
	if ( $prog->{pid} =~ m{^http.+/mediaselector/4/[gm]tis}i ) {
		# bypass all the xml parsing and return
		$prog->{verpids}->{default} = $1 if $prog->{pid} =~ m{^.+(\?.+)$};

		# Name
		my $title;
		$title = $1 if $prog->{pid} =~ m{identifier=(.+?)&};
		$title =~ s/\@/_/g;

		# Add to prog hash
		$prog->{versions} = join ',', keys %{ $prog->{verpids} };
		$prog->{title} = decode_entities($title);
		return 0;
	
	# Determine if the is a standard pid, Live TV or EMP TV URL
	# EMP URL
	} elsif ( $prog->{pid} =~ /^http/i ) {
		$url = $prog->{pid};
		# May aswell set the web page metadata here if not set
		$prog->{web} = $prog->{pid} if ! $prog->{web};
		# Scrape the EMP web page and get playlist URL
		my $xml = main::request_url_retry( $ua, $url, 3 );
		if ( ! $xml ) {
			main::logger "\rERROR: Failed to get EMP page from BBC site\n\n";
			return 1;
		}
		# flatten
		$xml =~ s/\n/ /g;
		# Find playlist URL in various guises
		if ( $xml =~ m{<param\s+name="playlist"\s+value="(http.+?)"}i ) {
			$url = $1;
		# setPlaylist("http://www.bbc.co.uk/mundo/meta/dps/2009/06/emp/090625_video_festival_ms.emp.xml")
		# emp.setPlaylist("http://www.bbc.co.uk/learningzone/clips/clips/p_chin/bb/p_chin_ch_05303_16x9_bb.xml")
		} elsif ( $xml =~ m{setPlaylist\("(http.+?)"\)}i ) {
			$url = $1;
		# playlist = "http://www.bbc.co.uk/worldservice/meta/tx/flash/live/eneuk.xml";
		} elsif ( $xml =~ m{\splaylist\s+=\s+"(http.+?)";}i ) {
			$url = $1;
		# iplayer Programmes page format (also rewrite the pid)
		# href="http://www.bbc.co.uk/iplayer/episode/b00ldhj2"
		} elsif ( $xml =~ m{href="http://www.bbc.co.uk/iplayer/episode/(b0[a-z0-9]{6})"} ) {
			$prog->{pid} = $1;
			$url = 'http://www.bbc.co.uk/iplayer/playlist/'.$1;
		} elsif ( $url =~ m{^http.+.xml$} ) {
			# Just keep the url as it is probably already an xml playlist
		## playlist: "http://www.bbc.co.uk/iplayer/playlist/bbc_radio_one",
		#} elsif ( $xml =~ m{playlist: "http.+?playlist\/(\w+?)"}i ) {
		#	$prog->{pid} = $1;
		#	$url = 'http://www.bbc.co.uk/iplayer/playlist/'.$prog->{pid};
		}
		# URL decode url
		$url = main::url_decode( $url );
	# iPlayer LiveTV or PID
	} else {
		$url = 'http://www.bbc.co.uk/iplayer/playlist/'.$prog->{pid};
	}
	
	main::logger "INFO: iPlayer metadata URL = $url\n" if $opt->{verbose};
	#main::logger "INFO: Getting version pids for programme $prog->{pid}        \n" if ! $opt->{verbose};

	# send request
	my $xml = main::request_url_retry( $ua, $url, 3 );
	if ( ! $xml ) {
		main::logger "\rERROR: Failed to get version pid metadata from iplayer site\n\n";
		return 1;
	}
	# The URL http://www.bbc.co.uk/iplayer/playlist/<PID> contains for example:
	#<?xml version="1.0" encoding="UTF-8"?>
	#<playlist xmlns="http://bbc.co.uk/2008/emp/playlist" revision="1">
	#  <id>tag:bbc.co.uk,2008:pips:b00dlrc8:playlist</id>
	#  <link rel="self" href="http://www.bbc.co.uk/iplayer/playlist/b00dlrc8"/>
	#  <link rel="alternate" href="http://www.bbc.co.uk/iplayer/episode/b00dlrc8"/>
	#  <link rel="holding" href="http://www.bbc.co.uk/iplayer/images/episode/b00dlrc8_640_360.jpg" height="360" width="640" type="image/jpeg" />
	#  <title>Amazon with Bruce Parry: Episode 1</title>
	#  <summary>Bruce Parry begins an epic adventure in the Amazon following the river from source to sea, beginning  in the High Andes and visiting the Ashaninka tribe.</summary>                                                                                                        
	#  <updated>2008-09-18T14:03:35Z</updated>
	#  <item kind="ident">
	#    <id>tag:bbc.co.uk,2008:pips:bbc_two</id>
	#    <mediator identifier="bbc_two" name="pips"/>
	#  </item>
	#  <item kind="programme" duration="3600" identifier="b00dlr9p" group="b00dlrc8" publisher="pips">
	#    <tempav>1</tempav>
	#    <id>tag:bbc.co.uk,2008:pips:b00dlr9p</id>
	#    <service id="bbc_two" href="http://www.bbc.co.uk/iplayer/bbc_two">BBC Two</service>
	#    <masterbrand id="bbc_two" href="http://www.bbc.co.uk/iplayer/bbc_two">BBC Two</masterbrand>
	#
	#    <alternate id="default" />
	#    <guidance>Contains some strong language.</guidance>
	#    <mediator identifier="b00dlr9p" name="pips"/>
	#  </item>
	#  <item kind="programme" duration="3600" identifier="b00dp4xn" group="b00dlrc8" publisher="pips">
	#    <tempav>1</tempav>
	#    <id>tag:bbc.co.uk,2008:pips:b00dp4xn</id>
	#    <service id="bbc_one" href="http://www.bbc.co.uk/iplayer/bbc_one">BBC One</service>
	#    <masterbrand id="bbc_two" href="http://www.bbc.co.uk/iplayer/bbc_two">BBC Two</masterbrand>
	#
	#    <alternate id="signed" />
	#    <guidance>Contains some strong language.</guidance>
	#    <mediator identifier="b00dp4xn" name="pips"/>
	#  </item>

	# If a prog is totally unavailable you get 
	# ...
	# <updated>2009-01-15T23:13:33Z</updated>
	# <noItems reason="noMedia" />
	#
	#                <relatedLink>
	                
	# flatten
	$xml =~ s/\n/ /g;

	# Detect noItems or no programmes
	if ( $xml =~ m{<noItems\s+reason="noMedia"} || $xml !~ m{kind="(programme|radioProgramme)"} ) {
		main::logger "\rWARNING: No programmes are available for this pid\n";
		return 1;
	}

	# Get title
	# <title>Amazon with Bruce Parry: Episode 1</title>
	my ( $title, $prog_type );
	$title = $1 if $xml =~ m{<title>\s*(.+?)\s*<\/title>};

	# Get type
	$prog_type = 'tv' if grep /kind="programme"/, $xml;
	$prog_type = 'radio' if grep /kind="radioProgramme"/, $xml;

	# Split into <item kind="programme"> sections
	my $prev_version = '';
	for ( split /<item\s+kind="(radioProgramme|programme)"/, $xml ) {
		main::logger "DEBUG: Block: $_\n" if $opt->{debug};
		my ($verpid, $version);

		# Treat live streams accordingly
		# Live TV
		if ( m{\s+simulcast="true"} ) {
			$version = 'default';
			$verpid = "http://www.bbc.co.uk/emp/simulcast/".$1.".xml" if m{\s+live="true"\s+identifier="(.+?)"};
			main::logger "INFO: Using Live TV: $verpid\n" if $opt->{verbose} && $verpid;

		# Live/Non-live EMP tv/radio XML URL
		} elsif ( $prog->{pid} =~ /^http/i && $url =~ /^http.+xml$/ ) {
			$version = 'default';
			$verpid = $url;
			main::logger "INFO: Using Live/Non-live EMP tv/radio XML URL: $verpid\n" if $opt->{verbose} && $verpid;

		# Live/Non-live EMP tv/radio
		} elsif ( $prog->{pid} =~ /^http/i ) {
			$version = 'default';
			# <connection kind="akamai" identifier="48502/mundo/flash/2009/06/glastonbury_16x9_16x9_bb" server="cp48502.edgefcs.net"/>
			# <connection kind="akamai" identifier="intl/abercrombie" server="cp57856.edgefcs.net" />
			# <connection kind="akamai" application="live" identifier="sport2a@s2405" server="cp52115.live.edgefcs.net" tokenIssuer="akamaiUk" />
			# <connection kind="akamai" identifier="secure/p_chin/p_chin_ch_05303_16x9_bb" server="cp54782.edgefcs.net" tokenIssuer="akamaiUk"/>
			# <connection kind="akamai" application="live" identifier="eneuk_live@6512" server="wsliveflash.bbc.co.uk" />
			# verpid = ?server=cp52115.live.edgefcs.net&identifier=sport2a@s2405&kind=akamai&application=live
			$verpid = "?server=$4&identifier=$3&kind=$1&application=$2" if $xml =~ m{<connection\s+kind="(.+?)"\s+application="(.+?)"\s+identifier="(.+?)"\s+server="(.+?)"};
			# Or try this if application is not defined (i.e. like in learning zone)
			if ( ! $verpid ) {
				$verpid = "?server=$3&identifier=$2&kind=$1&application=ondemand" if $xml =~ m{<connection\s+kind="(.+?)"\s+identifier="(.+?)"\s+server="(.+?)"};
			}
			main::logger "INFO: Using Live/Non-live EMP tv/radio: $verpid\n" if $opt->{verbose} && $verpid;

		# Live radio
		} elsif ( m{\s+live="true"\s} ) {
			# Try to get live stream version and verpid
			# <item kind="radioProgramme" live="true" identifier="bbc_radio_one" group="bbc_radio_one">
			$verpid = $1 if m{\s+live="true"\s+identifier="(.+?)"};
			$version = 'default';
			main::logger "INFO: Using Live radio: $verpid\n" if $opt->{verbose} && $verpid;

		# Not Live standard TV and Radio
		} else {
			#  duration="3600" identifier="b00dp4xn" group="b00dlrc8" publisher="pips">
			$verpid = $1 if m{\s+duration=".*?"\s+identifier="(.+?)"};
			# <alternate id="default" />
			if ( m{<alternate\s+id="(.+?)"} ) {
				my $curr_version = lc($1);
				$version = lc($1);
				# if current version is already defined, add a numeric suffix
				if ( $prog->{verpids}->{$curr_version} ) {
					my $vercount = 1;
					# Search for the next free suffix
					while ( $prog->{verpids}->{$curr_version} ) {
						$vercount++;
						$curr_version = $version.$vercount;
					}
					$version = $curr_version;
				}
			# If this item has no version name then append $count to previous version found (a hack but I think it works)
			} else {
				# determine version name and trailing count (if any)
				$prev_version =~ m{^(.+)(\d*)$};
				my $prev_count = $2 || 1;
				$prev_version = $1 || 'default';
				$prev_count++;
				$version = $prev_version.$prev_count;
			}
			main::logger "INFO: Using Not Live standard TV and Radio: $verpid\n" if $opt->{verbose} && $verpid;
		}

		next if ! ($verpid && $version);
		$prev_version = $version;
		$prog->{verpids}->{$version} = $verpid;
		$prog->{durations}->{$version} = $1 if m{duration="(\d+?)"};
		main::logger "INFO: Version: $version, VersionPid: $verpid, Duration: $prog->{durations}->{$version}\n" if $opt->{verbose};  
	}

	# Add to prog hash
	$prog->{versions} = join ',', keys %{ $prog->{verpids} };
	$prog->{title} = decode_entities($title);
	return 0;
}



# get full episode metadata given pid and ua. Uses two different urls to get data
sub get_metadata {
	my $prog = shift;
	my $ua = shift;
	my $metadata;
	my $entry;
	my $prog_feed_url = 'http://feeds.bbc.co.uk/iplayer/episode/'; # $pid

	my ($name, $episode, $desc, $available, $channel, $expiry, $meddesc, $longdesc, $summary, $versions, $guidance, $prog_type, $categories, $player, $thumbnail, $seriestitle, $episodetitle, $nametitle, $seriesnum, $episodenum );

	# This URL works for all prog types:
	# http://www.bbc.co.uk/iplayer/playlist/${pid}

	# This URL only works for TV progs:
	# http://www.bbc.co.uk/iplayer/metafiles/episode/${pid}.xml

	# This URL works for tv/radio prog types:
	# http://www.bbc.co.uk/iplayer/widget/episodedetail/episode/${pid}/template/mobile/service_type/tv/

	# This URL works for tv/radio prog types (has long synopsis):
	# http://www.bbc.co.uk/programmes/{pid}.rdf

	# This URL works for tv/radio prog types:
	# http://feeds.bbc.co.uk/iplayer/episode/$pid

	# Works for all Verison PIDs to get the last/first broadcast dates
	# http://www.bbc.co.uk/programmes/<verpid>.rdf

	main::logger "DEBUG: Getting Metadata for $prog->{pid}:\n" if $opt->{debug};

	# Entry format
	#<?xml version="1.0" encoding="utf-8"?>                                      
	#<?xml-stylesheet href="http://www.bbc.co.uk/iplayer/style/rss.css" type="text/css"?>
	#<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:media="http://search.yahoo.com/mrss/" xml:lang="en-GB">
	#  <title>BBC iPlayer - Episode Detail: Edith Bowman: 22/09/2008</title>                                                                          
	#  <subtitle>Sara Cox sits in for Edith with another Cryptic Randomizer.</subtitle>
	#  <updated>2008-09-29T10:59:45Z</updated>
	#  <id>tag:feeds.bbc.co.uk,2008:/iplayer/feed/episode/b00djtfh</id>
	#  <link rel="related" href="http://www.bbc.co.uk/iplayer" type="text/html" />
	#  <link rel="self" href="http://feeds.bbc.co.uk/iplayer/episode/b00djtfh" type="application/atom+xml" />
	#  <author>
	#    <name>BBC</name>
	#    <uri>http://www.bbc.co.uk</uri>
	#  </author>
	#  <entry>
	#    <title type="text">Edith Bowman: 22/09/2008</title>
	#    <id>tag:feeds.bbc.co.uk,2008:PIPS:b00djtfh</id>
	#    <updated>2008-09-15T01:28:36Z</updated>
	#    <summary>Sara Cox sits in for Edith with another Cryptic Randomizer.</summary>
	#    <content type="html">
	#      &lt;p&gt;
	#        &lt;a href=&quot;http://www.bbc.co.uk/iplayer/episode/b00djtfh?src=a_syn30&quot;&gt;
	#          &lt;img src=&quot;http://www.bbc.co.uk/iplayer/images/episode/b00djtfh_150_84.jpg&quot; alt=&quot;Edith Bowman: 22/09/2008&quot; /&gt;
	#        &lt;/a&gt;
	#      &lt;/p&gt;
	#      &lt;p&gt;
	#        Sara Cox sits in for Edith with movie reviews and great new music, plus another Cryptic Randomizer.
	#      &lt;/p&gt;
	#    </content>
	#    <link rel="alternate" href="http://www.bbc.co.uk/iplayer/episode/b00djtfh?src=a_syn31" type="text/html" title="Edith Bowman: 22/09/2008">
	#      <media:content medium="audio" duration="10800">
	#        <media:title>Edith Bowman: 22/09/2008</media:title>
	#        <media:description>Sara Cox sits in for Edith with movie reviews and great new music, plus another Cryptic Randomizer.</media:description>
	#        <media:player url="http://www.bbc.co.uk/iplayer/episode/b00djtfh?src=a_syn31" />
	#        <media:category scheme="urn:bbc:metadata:cs:iPlayerUXCategoriesCS" label="Entertainment">9100099</media:category>
	#        <media:category scheme="urn:bbc:metadata:cs:iPlayerUXCategoriesCS" label="Music">9100006</media:category>
	#        <media:category scheme="urn:bbc:metadata:cs:iPlayerUXCategoriesCS" label="Pop &amp; Chart">9200069</media:category>
	#        <media:rating scheme="urn:simple">adult</media:rating>
	#        <media:credit role="Production Department" scheme="urn:ebu">BBC Radio 1</media:credit>
	#        <media:credit role="Publishing Company" scheme="urn:ebu">BBC Radio 1</media:credit>
	#        <media:thumbnail url="http://www.bbc.co.uk/iplayer/images/episode/b00djtfh_86_48.jpg" width="86" height="48" />
	#        <media:thumbnail url="http://www.bbc.co.uk/iplayer/images/episode/b00djtfh_150_84.jpg" width="150" height="84" />
	#        <media:thumbnail url="http://www.bbc.co.uk/iplayer/images/episode/b00djtfh_178_100.jpg" width="178" height="100" />
	#        <media:thumbnail url="http://www.bbc.co.uk/iplayer/images/episode/b00djtfh_512_288.jpg" width="512" height="288" />
	#        <media:thumbnail url="http://www.bbc.co.uk/iplayer/images/episode/b00djtfh_528_297.jpg" width="528" height="297" />
	#        <media:thumbnail url="http://www.bbc.co.uk/iplayer/images/episode/b00djtfh_640_360.jpg" width="640" height="360" />
	#        <dcterms:valid>
	#          start=2008-09-22T15:44:20Z;
	#          end=2008-09-29T15:02:00Z;
	#          scheme=W3C-DTF
	#        </dcterms:valid>
	#      </media:content>
	#    </link>
	#    <link rel="self" href="http://feeds.bbc.co.uk/iplayer/episode/b00djtfh?format=atom" type="application/atom+xml" title="22/09/2008" />
	#    <link rel="related" href="http://www.bbc.co.uk/programmes/b006wks4/microsite" type="text/html" title="Edith Bowman" />
	#    <link rel="parent" href="http://feeds.bbc.co.uk/iplayer/programme_set/b006wks4" type="application/atom+xml" title="Edith Bowman" />
	#  </entry>
	#</feed>

	# Don't get metadata from this URL if the pid contains a full url (problem: this still tries for BBC iPlayer live channels)
	if ( $prog->{pid} !~ m{^http}i ) {
		$entry = main::request_url_retry($ua, $prog_feed_url.$prog->{pid}, 3, '', '');
		decode_entities($entry);
		main::logger "DEBUG: $prog_feed_url.$prog->{pid}:\n$entry\n\n" if $opt->{debug};
		# Flatten
		$entry =~ s|\n| |g;

		if ( $entry =~ m{<dcterms:valid>\s*start=.+?;\s*end=(.*?);} ) {
			$expiry = $1;
			$prog->{expiryrel} = Programme::get_time_string( $expiry, time() );
		}
		$available = $1 if $entry =~ m{<dcterms:valid>\s*start=(.+?);\s*end=.*?;};
		$prog_type = $1 if $entry =~ m{medium=\"(\w+?)\"};
		$prog_type = 'tv' if $prog_type eq 'video';
		$prog_type = 'radio' if $prog_type eq 'audio';
		$desc = $1 if $entry =~ m{<media:description>\s*(.*?)\s*<\/media:description>};
		$meddesc = '';
		$meddesc = $1 if $entry =~ m{<content type="html">\s*(.+?)\s*</content>};
		decode_entities( $meddesc );
		$meddesc =~ s|^.+<p>\s*(.+?)\s*</p>|$1|g;
		$meddesc =~ s|[\n\r]| |g;
		$summary = $1 if $entry =~ m{<summary>\s*(.*?)\s*</summary>};
		$guidance = $1 if $entry =~ m{<media:rating scheme="urn:simple">(.+?)<\/media:rating>};
		$player = $1 if $entry =~ m{<media:player\s*url=\"(.*?)\"\s*\/>};
		# Get all thumbnails into elements of thumbnailN with increasing width
		my %thumbnails;
		for ( split /<media:thumbnail/, $entry ) {
			my ( $url, $width );
			( $url, $width ) = ( $1, $2 ) if m{\s+url="\s*(http://.+?)\s*"\s+width="\s*(\d+)\s*"\s+height="\s*\d+\s*"};
			$thumbnails{ $width } = $url if $width && $url;
		}
		my $count = 1;
		for ( sort {$a <=> $b} keys %thumbnails ) {
			$prog->{ 'thumbnail'.$count } = $thumbnails{ $_ };
			$thumbnails{ $count } = $thumbnails{ $_ };
			$count++;
		}
		# Use the default cache thumbnail unless --thumbsize=NNN is used where NNN is either the width or thumbnail index number
		$thumbnail = $thumbnails{ $opt->{thumbsize} } if defined $opt->{thumbsize};
		( $name, $episode ) = Programme::bbciplayer::split_title( $1 ) if $entry =~ m{<title\s+type="text">\s*(.+?)\s*<};
		$channel = $1 if $entry =~ m{<media:credit\s+role="Publishing Company"\s+scheme="urn:ebu">(.+?)<};

		# Get the title from the atom link refs only to determine the episode and series number
		$episodetitle = $2 if $entry =~ m{<link\s+rel="self"\s+href="http[^"]+?/episode/[^"]+?"\s+type="(application/atom\+xml|text/html)"\s+title="(.+?)"};
		$seriestitle = $2 if $entry =~ m{<link\s+rel="parent"\s+href="http[^"]+?/programme_set/[^"]+?"\s+type="(application/atom\+xml|text/html)"\s+title="(.+?)"};
		$nametitle = $2 if $entry =~ m{<link\s+rel="related"\s+href="http[^"]+?/programmes/[^"]+?"\s+type="(application/atom\+xml|text/html)"\s+title="(.+?)"};

		my @cats;
		for (split /<media:category scheme=\".+?\"/, $entry) {
			push @cats, $1 if m{\s*label="(.+?)">\d+<\/media:category>};
		}
		$categories = join ',', @cats;
	}


	# Even more info...
	#<?xml version="1.0" encoding="utf-8"?>                                  
	#<rdf:RDF xmlns:rdf      = "http://www.w3.org/1999/02/22-rdf-syntax-ns#" 
	#         xmlns:rdfs     = "http://www.w3.org/2000/01/rdf-schema#"       
	#         xmlns:foaf     = "http://xmlns.com/foaf/0.1/"                  
	#         xmlns:po       = "http://purl.org/ontology/po/"                
	#         xmlns:mo       = "http://purl.org/ontology/mo/"                
	#         xmlns:skos     = "http://www.w3.org/2008/05/skos#"             
	#         xmlns:time     = "http://www.w3.org/2006/time#"                
	#         xmlns:dc       = "http://purl.org/dc/elements/1.1/"            
	#         xmlns:dcterms  = "http://purl.org/dc/terms/"                   
	#         xmlns:wgs84_pos= "http://www.w3.org/2003/01/geo/wgs84_pos#"    
	#         xmlns:timeline = "http://purl.org/NET/c4dm/timeline.owl#"
	#         xmlns:event    = "http://purl.org/NET/c4dm/event.owl#">
	#
	#<rdf:Description rdf:about="/programmes/b00mbvmz.rdf">
	#  <rdfs:label>Description of the episode Episode 5</rdfs:label>
	#  <dcterms:created rdf:datatype="http://www.w3.org/2001/XMLSchema#dateTime">2009-08-17T00:16:16+01:00</dcterms:created>
	#  <dcterms:modified rdf:datatype="http://www.w3.org/2001/XMLSchema#dateTime">2009-08-21T16:09:30+01:00</dcterms:modified>
	#  <foaf:primaryTopic rdf:resource="/programmes/b00mbvmz#programme"/>
	#</rdf:Description>
	#
	#<po:Episode rdf:about="/programmes/b00mbvmz#programme">
	#
	#  <dc:title>Episode 5</dc:title>
	#  <po:short_synopsis>Jem Stansfield tries to defeat the US Navy&#39;s latest weapon with foam and a crash helmet.</po:short_synopsis>
	#  <po:medium_synopsis>Jem Stansfield attempts to defeat the US Navy&#39;s latest weapon with no more than some foam and a crash helmet, while zoologist Liz Bonnin gets in contact with her frog brain.</po:medium_synopsis>
	#  <po:long_synopsis>Jem Stansfield attempts to defeat the US Navy&#39;s latest weapon with no more than some foam and a crash helmet.
	#
	#Zoologist Liz Bonnin gets in contact with her frog brain, Dallas Campbell re-programmes his caveman brain to become a thrill-seeker, and Dr Yan Wong gets his thrills from inhaling sulphur hexafluoride.
	#The programme is co-produced with The Open University.
	#For more ways to put science to the test, go to the Hands-on Science area at www.bbc.co.uk/bang for details of our free roadshow touring the UK and activities that you can try at home.</po:long_synopsis>
	#  <po:microsite rdf:resource="http://www.bbc.co.uk/bang"/>
	#  <po:masterbrand rdf:resource="/bbcone#service"/>
	#  <po:position rdf:datatype="http://www.w3.org/2001/XMLSchema#int">5</po:position>
	#  <po:genre rdf:resource="/programmes/genres/factual/scienceandnature/scienceandtechnology#genre" />
	#  <po:version rdf:resource="/programmes/b00mbvhc#programme" />
	#
	#</po:Episode>
	#
	#<po:Series rdf:about="/programmes/b00lywwy#programme">
	#  <po:episode rdf:resource="/programmes/b00mbvmz#programme"/>
	#</po:Series>
	#
	#<po:Brand rdf:about="/programmes/b00lwxj1#programme">
	#  <po:episode rdf:resource="/programmes/b00mbvmz#programme"/>
	#</po:Brand>
	#</rdf:RDF>

	# Get metadata from this URL only if the pid contains a standard BBC iPlayer PID)
	if ( $prog->{pid} =~ /^\w{8}$/ ) {
		$entry = main::request_url_retry($ua, 'http://www.bbc.co.uk/programmes/'.$prog->{pid}.'.rdf', 3, '', '');
		decode_entities($entry);
		main::logger "DEBUG: $prog_feed_url.$prog->{pid}:\n$entry\n\n" if $opt->{debug};
		# Flatten
		$entry =~ s|[\n\r]| |g;
		$longdesc = $1 if $entry =~ m{<po:long_synopsis>\s*(.+?)\s*</po:long_synopsis>};
		# Detect if this is just a series pid and report other episodes in the
		# form of <po:episode rdf:resource="/programmes/b00fyl5z#programme" />
		my $rdftitle = $1 if $entry =~ m{<dc:title>(.+?)<};
	}


	# Get list of available modes for each version available
	# populate version pid metadata if we don't have it already
	if ( keys %{ $prog->{verpids} } == 0 ) {
		if ( $prog->get_verpids( $ua ) ) {
			main::logger "ERROR: Could not get version pid metadata\n" if $opt->{verbose};
			# Only return at this stage unless we want metadata only for various reasons
			return 1 if ! ( $opt->{info} || $opt->{metadataonly} || $opt->{thumbonly} )
		}
	}
	$versions = join ',', sort keys %{ $prog->{verpids} };
	my $modes;
	my $mode_sizes;
	my $first_broadcast;
	my $last_broadcast;
	# Do this for each version tried in this order (if they appeared in the content)
	for my $version ( sort keys %{ $prog->{verpids} } ) {
		# Set duration for this version if it is not defined
		$prog->{durations}->{$version} = $prog->{duration} if $prog->{duration} =~ /\d+/ && ! $prog->{durations}->{$version};
		# Try to get stream data for this version if it isn't already populated
		if ( not defined $prog->{streams}->{$version} ) {
			# Add streamdata to object
			$prog->{streams}->{$version} = get_stream_data($prog, $prog->{verpids}->{$version} );
		}
		$modes->{$version} = join ',', sort keys %{ $prog->{streams}->{$version} };
		# Estimate the file sizes for each mode
		my @sizes;
		for my $mode ( sort keys %{ $prog->{streams}->{$version} } ) {
			next if ( ! $prog->{durations}->{$version} ) || (! $prog->{streams}->{$version}->{$mode}->{bitrate} );
			push @sizes, sprintf( "%s=%.0fMB", $mode, $prog->{streams}->{$version}->{$mode}->{bitrate} * $prog->{durations}->{$version} / 8.0 / 1024.0 );
		}
		$mode_sizes->{$version} = join ',', @sizes;
		
		# get the last/first broadcast dates from the RDF for this verpid
		# rdf url: http://www.bbc.co.uk/programmes/<verpid>.rdf
		# Date in this format 'CCYY-MM-DDTHH:MM:SS+01:00'
		# Don't get this feed if the verpid starts with '?'
		my $rdf_url = 'http://www.bbc.co.uk/programmes/'.$prog->{verpids}->{$version}.'.rdf';
		my $rdf;
		$rdf = main::request_url_retry($ua, $rdf_url, 3, '', '') if $prog->{verpids}->{$version} !~ m{^\?};
		decode_entities($rdf);
		main::logger "DEBUG: $rdf_url:\n$rdf\n\n" if $opt->{debug};
		# Flatten
		$rdf =~ s|\n| |g;
		# Get min/max bcast dates from rdf
		my ( $first, $last, $first_string, $last_string ) = ( 9999999999, 0, 'Never', 'Never' );

		# <po:(First|Repeat)Broadcast>
		#  <po:schedule_date rdf:datatype="http://www.w3.org/2001/XMLSchema#date">2009-06-06</po:schedule_date>
		#    <event:time>
		#        <timeline:Interval>
		#              <timeline:start rdf:datatype="http://www.w3.org/2001/XMLSchema#dateTime">2009-06-06T21:30:00+01:00</timeline:start>
		for ( split /<po:(First|Repeat)Broadcast>/, $rdf ) {
			my $timestring;
			my $epoch;
			$timestring = $1 if m{<timeline:start\s+rdf:datatype=".+?">(20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d([+-]\d\d:\d\d|Z))<};
			next if ! $timestring;
			$epoch = Programme::get_time_string( $timestring );
			main::logger "DEBUG: $version: $timestring -> $epoch\n" if $opt->{debug};
			if ( $epoch < $first ) {
				$first = $epoch;
				$first_string = $timestring;
			}
			if ( $epoch > $last ) {
				$last = $epoch;
				$last_string = $timestring;
			}
		}
		# Only set these attribs if required
		if ( $first < 9999999999 && $last > 0 ) {
			$prog->{firstbcast}->{$version} = $first_string;
			$prog->{lastbcast}->{$version} = $last_string;
			$prog->{firstbcastrel}->{$version} = Programme::get_time_string( $first_string, time() );
			$prog->{lastbcastrel}->{$version} = Programme::get_time_string( $last_string, time() );
		}
	}

	# Extract the seriesnum
	my $regex = 'Series\s+'.main::regex_numbers();
	# Extract the seriesnum
	if ( "$prog->{name} $prog->{episode}" =~ m{$regex}i ) {
		$seriesnum = main::convert_words_to_number( $1 );
	} elsif ( $seriestitle =~ m{$regex}i ) {
		$seriesnum = main::convert_words_to_number( $1 );
	}

	# Extract the episode num
	my $regex_1 = 'Episode\s+'.main::regex_numbers();
	my $regex_2 = '^'.main::regex_numbers().'\.\s+';
	if ( "$prog->{name} $prog->{episode}" =~ m{$regex_1}i ) {
		$episodenum = main::convert_words_to_number( $1 );
	} elsif ( "$name $episode" =~ m{$regex_1}i ) {
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

	# Use the longer of the episode texts
	$episode = $episodetitle if length( $episodetitle ) > length( $episode );
	$episode = $prog->{episode} if length( $prog->{episode} ) > length( $episode );

	# Create a stripped episode and series with numbers removed + senum s##e## element.
	$prog->{episodeshort} = $prog->{episode};
	$prog->{episodeshort} =~ s/(^|:(\s+))\d+\.\s+/$1/i;
	$prog->{episodeshort} =~ s/:?\s*Episode\s+.+?(:\s*|$)//i;
	$prog->{episodeshort} =~ s/:?\s*Series\s+.+?(:\s*|$)//i;
	$prog->{episodeshort} = $prog->{episode} if $prog->{episodeshort} eq '';
	$prog->{nameshort} = $prog->{name};
	$prog->{nameshort} =~ s/:?\s*Series\s+.+?(:\s*|$)//i;

	# Conditionally set the senum
	$prog->{senum} = sprintf "s%02se%02s", $seriesnum, $episodenum if $seriesnum != 0 || $episodenum != 0;

	# Default to 150px width thumbnail;
	my $thumbsize = $opt->{thumbsizecache} || 150;
	my $thumbnail_prefix = 'http://www.bbc.co.uk/iplayer/images/episode';

	# Thumbnail fallback if normal short pid (i.e. not URL)
	$thumbnail = "${thumbnail_prefix}/$prog->{pid}".Programme::bbciplayer->thumb_url_suffixes->{ $thumbsize } if ! ( $thumbnail || $prog->{thumbnail} ) && $prog->{pid} !~ /^http/;
	
	# Fill in from cache if not got from metadata
	$prog->{name} 		= $name || $prog->{name};
	$prog->{episode} 	= $episode || $prog->{episode} || $prog->{name};
	$prog->{type}		= $prog_type || $prog->{type};
	$prog->{channel}	= $channel || $prog->{channel};
	$prog->{expiry}		= $expiry || $prog->{expiry};
	$prog->{versions}	= $versions;
	$prog->{guidance}	= $guidance || $prog->{guidance};
	$prog->{categories}	= $categories || $prog->{categories};
	$prog->{desc}		= $longdesc || $meddesc || $desc || $prog->{desc} || $summary;
	$prog->{descmedium}	= $meddesc;
	$prog->{descshort}	= $summary;
	$prog->{player}		= $player;
	$prog->{thumbnail}	= $thumbnail || $prog->{thumbnail};
	$prog->{modes}		= $modes;
	$prog->{modesizes}	= $mode_sizes;
	$prog->{episodenum}	= $episodenum;
	$prog->{seriesnum}	= $seriesnum;

	return 0;
}



sub get_pids_recursive {
	my $prog = shift;
	my $ua = main::create_ua( 'desktop' );
	my @pids = ();

	# Clean up the pid
	$prog->clean_pid();

	# Skip RDF retrieval if a web URL
	return $prog->{pid} if $prog->{pid} =~ '^http';

	eval "use XML::Simple";
	if ($@) {
		main::logger "WARNING: Please download and run latest installer or install the XML::Simple perl module to use the Series and Brand pid parsing functionality\n";
		push @pids, $prog->{pid};
	} else {
		#use Data::Dumper qw(Dumper);
		my $rdf = get_rdf_data( $ua, $prog->{pid} );
		if ( ! $rdf ) {
			main::logger "WARNING: PID URL contained no RDF data. Trying to record PID directly.\n";
			return $prog->{pid};
		}
		# an episode-only pid page
		if ( $rdf->{'po:Episode'} ) {
			main::logger "INFO: Episode-only pid detected\n";
			# No need to lookup - we already are an episode pid
			push @pids, $prog->{pid};
		# a series pid page
		} elsif ( $rdf->{'po:Series'} ) {
			main::logger "INFO: Series pid detected\n";
			push @pids, parse_rdf_series( $ua, $prog->{pid} );
			if ( ! $opt->{pidrecursive} ) {
				main::logger "INFO: Please run the command again using one of the above episode PIDs or to get all programmes add the --pid-recursive option\n";
				return ();
			}
		# a brand pid page
		} elsif ( $rdf->{'po:Brand'} ) {
			main::logger "INFO: Brand pid detected\n";
			push @pids, parse_rdf_brand( $ua, $prog->{pid} );
			if ( ! $opt->{pidrecursive} ) {
				main::logger "INFO: Please run the command again using one of the above episode PIDs or to get all programmes add the --pid-recursive option\n";
				return ();
			}
		}
	}
	# now make list unique
	@pids = main::make_array_unique_ordered( @pids );
	return @pids;
}



# Gets the episode data from a given episode pid
sub parse_rdf_episode {
	my $ua = shift;
	my $uri = shift;
	my $rdf = get_rdf_data( $ua, $uri );
	if ( ! $rdf ) {
		main::logger "WARNING: Episode PID rdf URL contained no RDF data.\n";
		return '';
	}
	my $pid = extract_pid( $uri );
	main::logger "INFO:      Episode '".$rdf->{'po:Episode'}->{'dc:title'}."' ($pid)\n";
	# We don't really need the ver pids from here
	if ( ref$rdf->{'po:Episode'}->{'po:version'} eq 'ARRAY' ) {
		for my $verpid_element ( @{ $rdf->{'po:Episode'}->{'po:version'} } ) {
			main::logger "INFO:        With Version PID '".extract_pid( %{ $verpid_element }->{'rdf:resource'} )."'\n" if $opt->{debug};
		}
	} else {
		main::logger "INFO:        With Version PID '".extract_pid( $rdf->{'po:Episode'}->{'po:version'}->{'rdf:resource'} )."'\n" if $opt->{debug};
	}
	main::logger "INFO:        From Series PID '".extract_pid( $rdf->{'po:Series'}->{'rdf:about'} )."'\n" if $opt->{debug};
	main::logger "INFO:        From Brand PID '".extract_pid( $rdf->{'po:Brand'}->{'rdf:about'} )."'\n" if $opt->{debug};
}



sub parse_rdf_series {
	my $ua = shift;
	my $uri = shift;
	my $rdf = get_rdf_data( $ua, $uri );
	if ( ! $rdf ) {
		main::logger "WARNING: Series PID rdf URL contained no RDF data.\n";
		return '';
	}
	my @pids = ();
	my $spid = extract_pid( $rdf->{'po:Series'}->{'rdf:about'} );
	main::logger "INFO:    Series: '".$rdf->{'po:Series'}->{'dc:title'}."' ($spid)\n";
	main::logger "INFO:      From Brand PID '".$rdf->{'po:Brand'}->{'rdf:about'}."'\n" if $opt->{debug};
	for my $episode_element ( @{ $rdf->{'po:Series'}->{'po:episode'} } ) {
		my $pid = extract_pid( %{ $episode_element }->{'po:Episode'}->{'rdf:about'} );
		main::logger "INFO:      Episode '".%{ $episode_element }->{'po:Episode'}->{'dc:title'}."' ($pid)\n";
		push @pids, $pid;
		#parse_rdf_episode( $ua, $pid );
	}
	return @pids;
}



sub parse_rdf_brand {
	my $ua = shift;
	my $uri = shift;
	my $rdf = get_rdf_data( $ua, $uri );
	if ( ! $rdf ) {
		main::logger "WARNING: Brand PID rdf URL contained no RDF data.\n";
		return '';
	}
	my @pids = ();
	my $bpid = extract_pid( $uri );
	main::logger "INFO:  Brand: '".$rdf->{'po:Brand'}->{'dc:title'}."' ($bpid)\n";
	for my $series_element ( @{ $rdf->{'po:Brand'}->{'po:series'} } ) {
		main::logger "INFO: With Series pid '".%{ $series_element }->{'rdf:resource'}."'\n" if $opt->{debug};
		push @pids, parse_rdf_series( $ua, %{ $series_element }->{'rdf:resource'} );
	}
	main::logger "INFO:    Series: <None>\n" if $#{ $rdf->{'po:Brand'}->{'po:episode'} };
	for my $episode_element ( @{ $rdf->{'po:Brand'}->{'po:episode'} } ) {
		main::logger "INFO:      Episode pid: ".%{ $episode_element }->{'rdf:resource'}."\n" if $opt->{debug};
		push @pids, extract_pid( %{ $episode_element }->{'rdf:resource'} );
		parse_rdf_episode( $ua, %{ $episode_element }->{'rdf:resource'} );
	}
	return @pids;
}



# Extracts and returns a pid from a URI/URL
sub extract_pid {
	return $1 if $_[0] =~ m{/?([wpb]0[a-z0-9]{6})};
	return '';
}



# Given a pid, gets the rdf URL and returns an XML::Simple object
sub get_rdf_data {
	eval "use XML::Simple";
	if ($@) {
		main::logger "WARNING: Please download and run latest installer or install the XML::Simple perl module to use the Series and Brand pid parsing functionality\n";
		return;
	}
	#use Data::Dumper qw(Dumper);
	my $ua = shift;
	my $uri = shift;
	my $pid = extract_pid( $uri );
	my $entry = main::request_url_retry($ua, 'http://www.bbc.co.uk/programmes/'.$pid.'.rdf', 3, '', '');
	if ( ! $entry ) {
		main::logger "WARNING: rdf URL contained no data\n";
		return '';
	}
	decode_entities( $entry );
	# Flatten
	$entry =~ s|[\n\r]| |g;
	my $simple = new XML::Simple();
	my $rdf = $simple->XMLin( $entry );
	#main::logger Dumper ( $rdf )."\n" if $opt->{debug};
	return $rdf;
}



# Intelligently split name and episode from title string for BBC iPlayer metadata
sub split_title {
	my $title = shift;
	my ( $name, $episode );
	# <title type="text">The Sarah Jane Adventures: Series 1: Revenge of the Slitheen: Part 2</title>
	# <title type="text">The Story of Tracy Beaker: Series 4 Compilation: Independence Day/Beaker Witch Project</title>
	# <title type="text">The Sarah Jane Adventures: Series 1: The Lost Boy: Part 2</title>
	if ( $title =~ m{^(.+?Series.*?):\s+(.+?)$} ) {
		( $name, $episode ) = ( $1, $2 );
	} elsif ( $title =~ m{^(.+?):\s+(.+)$} ) {
		( $name, $episode ) = ( $1, $2 );
	# Catch all - i.e. no ':' separators
	} else {
		( $name, $episode ) = ( $title, '-' );
	}
	return ( $name, $episode );
}



# Returns hash
sub thumb_url_suffixes {
	return {
		86	=> '_86_48.jpg',
		150	=> '_150_84.jpg',
		178	=> '_178_100.jpg',
		512	=> '_512_288.jpg',
		528	=> '_528_297.jpg',
		640	=> '_640_360.jpg',
		832	=> '_832_468.jpg',
		1	=> '_86_48.jpg',
		2	=> '_150_84.jpg',
		3	=> '_178_100.jpg',
		4	=> '_512_288.jpg',
		5	=> '_528_297.jpg',
		6	=> '_640_360.jpg',
		7	=> '_832_468.jpg',
	}
}


#new_stream_report($mattribs, $cattribs)
sub new_stream_report {
	my $mattribs = shift;
	my $cattribs = shift;
	
	main::logger "New BBC iPlayer Stream Found:\n";
	main::logger "MEDIA-ELEMENT:\n";
		
	# list media attribs
	main::logger "MEDIA-ATTRIBS:\n";
	for (keys %{ $mattribs }) {
		main::logger "\t$_ => $mattribs->{$_}\n";
	}
	
	my @conn;
	if ( defined $cattribs ) {
		@conn = ( $cattribs );
	} else {
		@conn = @{ $mattribs->{connections} };
	}
	for my $cattribs ( @conn ) {
		main::logger "\tCONNECTION-ELEMENT:\n";
			
		# Print attribs
		for (keys %{ $cattribs }) {
			main::logger "\t\t$_ => $cattribs->{$_}\n";
		}	
	}
	return 0;
}



sub parse_metadata {
	my @medias;
	my $xml = shift;
	my %elements;

	# Parse all 'media' elements
	my $element = 'media';
	while ( $xml =~ /<$element\s+(.+?)>(.+?)<\/$element>/sg ) {
		my $xml = $2;
		my $mattribs = parse_attributes( $1 );

		# Parse all 'connection' elements
		my $element = 'connection';
		while ( $xml =~ /<$element\s+(.+?)\/>/sg ) {
			# push to data structure
			push @{ $mattribs->{connections} }, parse_attributes( $1 );
		}
		push @medias, $mattribs;
	}


	# Parse and dump structure
	if ( $opt->{debug} ) {
		for my $mattribs ( @medias ) {
			main::logger "MEDIA-ELEMENT:\n";
		
			# list media attribs
			main::logger "MEDIA-ATTRIBS:\n";
			for (keys %{ $mattribs }) {
				main::logger "\t$_ => $mattribs->{$_}\n";
			}

			for my $cattribs ( @{ $mattribs->{connections} } ) {
				main::logger "\tCONNECTION-ELEMENT:\n";
			
				# Print attribs
				for (keys %{ $cattribs }) {
					main::logger "\t\t$_ => $cattribs->{$_}\n";
				}	
			}
		}	
	}
	
	return @medias;
}



sub parse_attributes {
	$_ = shift;
	my $attribs;
	# Parse all attributes
	while ( /([\w]+?)="(.*?)"/sg ) {
		$attribs->{$1} = $2;
	}
	return $attribs;
}



sub get_stream_data_cdn {
	my ( $data, $mattribs, $mode, $streamer, $ext ) = ( @_ );
	my $data_pri = {};

	# Public Non-Live EMP Video without auth
	#if ( $cattribs->{kind} eq 'akamai' && $cattribs->{identifier} =~ /^public\// ) {
	#	$data->{$mode}->{bitrate} = 480; # ??
	#	$data->{$mode}->{swfurl} = "http://news.bbc.co.uk/player/emp/2.11.7978_8433/9player.swf";
	# Live TV, Live EMP Video or Non-public EMP video
	#} elsif ( $cattribs->{kind} eq 'akamai' ) {
	#	$data->{$mode}->{bitrate} = 480; # ??

	my $count = 1;
	for my $cattribs ( @{ $mattribs->{connections} } ) {
		# Common attributes
		# swfurl = Default iPlayer swf version
		my $conn = {
			swfurl		=> "http://www.bbc.co.uk/emp/10player.swf?revision=15501_15796",
			ext		=> $ext,
			streamer	=> $streamer,
			bitrate		=> $mattribs->{bitrate},
			server		=> $cattribs->{server},
			identifier	=> $cattribs->{identifier},
			authstring	=> $cattribs->{authString},
			priority	=> $cattribs->{priority},
		};

		# Akamai CDN
		if ( $cattribs->{kind} eq 'akamai' ) {
			# Set the live flag if this is not an ondemand stream
			$conn->{live} = 1 if defined $cattribs->{application} && $cattribs->{application} =~ /^live/;
			# Default appication is 'ondemand'
			$cattribs->{application} = 'ondemand' if ! $cattribs->{application};

			# if the authString is not set and this is a live (i.e. simulcast) then try to get an authstring
			# Maybe should this be general for all CDNs?
			if ( ! $cattribs->{authString} ) {
				# Build URL
				my $media_stream_live_prefix = 'http://www.bbc.co.uk/mediaselector/4/gtis/stream/';
				my $url = ${media_stream_live_prefix}."?server=$cattribs->{server}&identifier=$cattribs->{identifier}&kind=$cattribs->{kind}&application=$cattribs->{application}";
				my $xml = main::request_url_retry( main::create_ua( 'desktop' ), $url, 3, undef, undef, 1 );
				main::logger "\n$xml\n" if $opt->{debug};
				$cattribs->{authString} = $1 if $xml =~ m{<token>(.+?)</token>};
				$conn->{authstring} = $cattribs->{authString};
			}

			if ( $cattribs->{authString} ) {
				### ??? live and Live TV, Live EMP Video or Non-public EMP video:
				$conn->{playpath} = "$cattribs->{identifier}?auth=$cattribs->{authString}&aifp=v001";
			} else {
				$conn->{playpath} = $cattribs->{identifier};
			}
			if ( $cattribs->{authString} ) {
				$conn->{streamurl} = "rtmp://$cattribs->{server}:1935/$cattribs->{application}?_fcs_vhost=$cattribs->{server}&auth=$cattribs->{authString}&aifp=v001&slist=$cattribs->{identifier}";
			} else {
				$conn->{streamurl} = "rtmp://$cattribs->{server}:1935/$cattribs->{application}?_fcs_vhost=$cattribs->{server}&undefined";
			}
			# Remove offending mp3/mp4: at the start of the identifier (don't remove in stream url)
			$cattribs->{identifier} =~ s/^mp[34]://;
			if ( $cattribs->{authString} ) {
				$conn->{application} = "$cattribs->{application}?_fcs_vhost=$cattribs->{server}&auth=$cattribs->{authString}&aifp=v001&slist=$cattribs->{identifier}";
			} else {
				$conn->{application} = "$cattribs->{application}?_fcs_vhost=$cattribs->{server}&undefined";
			}
			# Port 1935? for live?
			$conn->{tcurl} = "rtmp://$cattribs->{server}:80/$conn->{application}";

		# Limelight CDN
		} elsif ( $cattribs->{kind} eq 'limelight' ) {
			decode_entities( $cattribs->{authString} );
			$conn->{playpath} = "$cattribs->{identifier}?$cattribs->{authString}";
			# Remove offending mp3/mp4: at the start of the identifier (don't remove in stream url)
			### Not entirely sure if this is even required for video modes either??? - not reqd for aac and low
			# $conn->{playpath} =~ s/^mp[34]://g;
			$conn->{streamurl} = "rtmp://$cattribs->{server}:1935/ondemand?_fcs_vhost=$cattribs->{server}&auth=$cattribs->{authString}&aifp=v001&slist=$cattribs->{identifier}";
			$conn->{application} = $cattribs->{application};
			$conn->{tcurl} = "rtmp://$cattribs->{server}:1935/$conn->{application}";
			
		# Level3 CDN	
		} elsif ( $cattribs->{kind} eq 'level3' ) {
			$conn->{playpath} = $cattribs->{identifier};
			$conn->{application} = "$cattribs->{application}?$cattribs->{authString}";
			$conn->{tcurl} = "rtmp://$cattribs->{server}:1935/$conn->{application}";
			$conn->{streamurl} = "rtmp://$cattribs->{server}:1935/ondemand?_fcs_vhost=$cattribs->{server}&auth=$cattribs->{authString}&aifp=v001&slist=$cattribs->{identifier}";

		# iplayertok CDN
		} elsif ( $cattribs->{kind} eq 'iplayertok' ) {
			$conn->{application} = $cattribs->{application};
			decode_entities($cattribs->{authString});
			$conn->{playpath} = "$cattribs->{identifier}?$cattribs->{authString}";
			$conn->{playpath} =~ s/^mp[34]://g;
			$conn->{streamurl} = "rtmp://$cattribs->{server}:1935/ondemand?_fcs_vhost=$cattribs->{server}&auth=$cattribs->{authString}&aifp=v001&slist=$cattribs->{identifier}";
			$conn->{tcurl} = "rtmp://$cattribs->{server}:1935/$conn->{application}";

		# sis/edgesuite/sislive streams
		} elsif ( $cattribs->{kind} eq 'sis' || $cattribs->{kind} eq 'edgesuite' || $cattribs->{kind} eq 'sislive' ) {
			$conn->{streamurl} = $cattribs->{href};

		# http stream
		} elsif ( $cattribs->{kind} eq 'http' ) {
			$conn->{streamurl} = $cattribs->{href};

		# drm license - ignore
		} elsif ( $cattribs->{kind} eq 'licence' ) {

		# iphone new
		} elsif ( $cattribs->{kind} eq 'securesis' ) {
			$conn->{streamurl} = $cattribs->{href};

		# Unknown CDN
		} else {
			new_stream_report($mattribs, $cattribs) if $opt->{verbose};
			next;
		}

		get_stream_set_type( $conn, $mattribs, $cattribs );

		# Find the next free mode name
		while ( defined $data->{$mode.$count} ) {
			$count++;
		}
		# Add to data structure
		$data->{$mode.$count} = $conn;
		$count++;
	}

	# Add to data structure hased by priority
	$count = 1;
	while ( defined $data->{$mode.$count} ) {
		$data_pri->{ $data->{$mode.$count}->{priority} } = $data->{$mode.$count};
		$count++;
	}
	# Sort mode number according to priority
	$count = 1;
	for my $priority ( reverse sort {$a <=> $b} keys %{ $data_pri } ) {
		# Add to data structure hashed by priority
		$data->{$mode.$count} = $data_pri->{ $priority };
		main::logger "DEBUG: Mode $mode$count = priority $priority\n" if $opt->{debug};
		$count++;
	}
}



# Builds connection type string
sub get_stream_set_type {
		my ( $conn, $mattribs, $cattribs ) = ( @_ );
		my @type;
		push @type, "($mattribs->{service})" if $mattribs->{service};
		push @type, "$conn->{streamer}";
		push @type, "$mattribs->{encoding}" if $mattribs->{encoding};
		push @type, "$mattribs->{width}x$mattribs->{height}" if $mattribs->{width} && $mattribs->{height};
		push @type, "$mattribs->{bitrate}kbps" if $mattribs->{bitrate};
		push @type, "stream";
		push @type, "(CDN: $cattribs->{kind}/$cattribs->{priority})" if $cattribs->{kind} && $cattribs->{priority};
		push @type, "(CDN: $cattribs->{kind})" if $cattribs->{kind} && not defined $cattribs->{priority};
		$conn->{type} = join ' ', @type;
}



# Generic
# Gets media streams data for this version pid
# $media = undef|<modename>
sub get_stream_data {
	my ( $prog, $verpid, $media ) = @_;
	my $data = {};
	my $media_stream_data_prefix = 'http://www.bbc.co.uk/mediaselector/4/mtis/stream/'; # $verpid
	my $media_stream_live_prefix = 'http://www.bbc.co.uk/mediaselector/4/gtis/stream/'; # $verpid

	# Setup user agent with redirection enabled
	my $ua = main::create_ua( 'desktop' );
	$opt->{quiet} = 0 if $opt->{streaminfo};

	# BBC streams
	my $xml;
	my @medias;

	# If this is an EMP stream verpid
	if ( $verpid =~ /^\?/ ) {
		$xml = main::request_url_retry( $ua, $media_stream_live_prefix.$verpid, 3, undef, undef, 1 );
		main::logger "\n$xml\n" if $opt->{debug};
		my $mattribs;
		my $cattribs;
		# Parse connection attribs
		$cattribs->{server} = $1 if $xml =~ m{<server>(.+?)</server>};
		$cattribs->{kind} = $1 if $xml =~ m{<kind>(.+?)</kind>};
		$cattribs->{identifier} = $1 if $xml =~ m{<identifier>(.+?)</identifier>};
		$cattribs->{authString} = $1 if $xml =~ m{<token>(.+?)</token>};
		$cattribs->{application} = $1 if $xml =~ m{<application>(.+?)</application>};
		# TV / EMP video (flashnormal mode)
		if ( $prog->{type} eq 'tv' || $prog->{type} eq 'livetv' ) {
			# Parse XML
			#<server>cp56493.live.edgefcs.net</server>
			#<identifier>bbc1_simcast@s3173</identifier>
			#<token>dbEb_c0abaHbWcxaYbRcHcQbfcMczaocvaB-bklOc_-c0-d0i_-EpnDBnzoNDqEnxF</token>
			#<kind>akamai</kind>
			#<application>live</application>
			#width="512" height="288" type="video/x-flv" encoding="vp6"
			$mattribs = { kind => 'video', type => 'video/x-flv', encoding => 'vp6', width => 512, height => 288 };
		# AAC Live Radio / EMP Audio
		} elsif ( $prog->{type} eq 'radio' || $prog->{type} eq 'liveradio' ) {
			# MP3 (flashaudio mode)
			if ( $cattribs->{identifier} =~ m{mp3:} ) {
				$mattribs = { kind => 'audio', type => 'audio/mpeg', encoding => 'mp3' };
			# AAC (flashaac mode)
			} else {
				$mattribs = { kind => 'audio', type => 'audio/mp4', encoding => 'aac' };
			}
		}
		# Push into media data structure
		push @{ $mattribs->{connections} }, $cattribs;
		push @medias, $mattribs;

	# Live simulcast verpid: http://www.bbc.co.uk/emp/simulcast/bbc_one_london.xml
	} elsif ( $verpid =~ /http:/ ) {
		$xml = main::request_url_retry( $ua, $verpid, 3, undef, undef, 1 );
		main::logger "\n$xml\n" if $opt->{debug};
		@medias = parse_metadata( $xml );

	# Could also use Javascript based one: 'http://www.bbc.co.uk/iplayer/mediaselector/4/js/stream/$verpid?cb=NNNNN
	} else {
		$xml = main::request_url_retry( $ua, $media_stream_data_prefix.$verpid.'?cb='.( sprintf "%05.0f", 99999*rand(0) ), 3, undef, undef, 1 );
		main::logger "\n$xml\n" if $opt->{debug};
		@medias = parse_metadata( $xml );
	}

	# Parse and dump structure
	my $mode;
	for my $mattribs ( @medias ) {
		
		# New iphone stream
		if ( $mattribs->{service} eq 'iplayer_streaming_http_mp4' ) {
			# Fix/remove some audio stream attribs
			if ( $prog->{type} eq 'radio' ) {
				$mattribs->{bitrate} = 128;
				delete $mattribs->{width};
				delete $mattribs->{height};
			}
			get_stream_data_cdn( $data, $mattribs, 'iphone', 'iphone', 'mov' );
		
		
		# flashhd modes
		} elsif (	$mattribs->{kind} eq 'video' &&
				$mattribs->{type} eq 'video/mp4' &&
				$mattribs->{encoding} eq 'h264'
		) {
			# Determine classifications of modes based mainly on bitrate

			# flashhd modes
			if ( $mattribs->{bitrate} > 3000 ) {
				get_stream_data_cdn( $data, $mattribs, 'flashhd', 'rtmp', 'mp4' );

			# flashvhigh modes
			} elsif ( $mattribs->{bitrate} > 1200 ) {
				get_stream_data_cdn( $data, $mattribs, 'flashvhigh', 'rtmp', 'mp4' );

			# flashhigh modes
			} elsif ( $mattribs->{bitrate} > 700 ) {
				get_stream_data_cdn( $data, $mattribs, 'flashhigh', 'rtmp', 'mp4' );

			# flashstd modes
			} elsif ( $mattribs->{bitrate} > 400 && $mattribs->{width} >= 500 ) {
				get_stream_data_cdn( $data, $mattribs, 'flashstd', 'rtmp', 'mp4' );

			}
			
		# flashnormal modes (also live and EMP modes)
		} elsif (	$mattribs->{kind} eq 'video' &&
				$mattribs->{type} eq 'video/x-flv' &&
				$mattribs->{encoding} eq 'vp6'
		) {
			get_stream_data_cdn( $data, $mattribs, 'flashnormal', 'rtmp', 'avi' );

		# flashlow modes
		} elsif (	$mattribs->{kind} eq 'video' &&
				$mattribs->{type} eq 'video/x-flv' &&
				$mattribs->{encoding} eq 'spark'
		) {
			get_stream_data_cdn( $data, $mattribs, 'flashlow', 'rtmp', 'avi' );

		# flashnormal modes without encoding specifed - assume vp6
		} elsif (	$mattribs->{kind} eq 'video' &&
				$mattribs->{type} eq 'video/x-flv'
		) {
			$mattribs->{encoding} = 'vp6';
			get_stream_data_cdn( $data, $mattribs, 'flashnormal', 'rtmp', 'avi' );

		# n95 modes
		} elsif (	$mattribs->{kind} eq 'video' &&
				$mattribs->{type} eq 'video/mpeg' &&
				$mattribs->{encoding} eq 'h264'
		) {
			# n95_wifi modes
			if ( $mattribs->{bitrate} > 140 ) {
				$mattribs->{width} = $mattribs->{width} || 320;
				$mattribs->{height} = $mattribs->{height} || 176;
				get_stream_data_cdn( $data, $mattribs, 'n95_wifi', '3gp', '3gp' );

			# n95_3g modes
			} else {
				$mattribs->{width} = $mattribs->{width} || 176;
				$mattribs->{height} = $mattribs->{height} || 96;
				get_stream_data_cdn( $data, $mattribs, 'n95_3g', '3gp', '3gp' );
			}

		# WMV drm modes - still used?
		} elsif (	$mattribs->{kind} eq 'video' &&
				$mattribs->{type} eq 'video/wmv'
		) {
			$mattribs->{width} = $mattribs->{width} || 320;
			$mattribs->{height} = $mattribs->{height} || 176;
			get_stream_data_cdn( $data, $mattribs, 'mobile_wmvdrm', 'http', 'wmv' );
			# Also DRM (same data - just remove _mobile from href and identfier)
			$mattribs->{width} = 672;
			$mattribs->{height} = 544;
			get_stream_data_cdn( $data, $mattribs, 'wmvdrm', 'http', 'wmv' );
			$data->{wmvdrm}->{identifier} =~ s/_mobile//g;
			$data->{wmvdrm}->{streamurl} =~ s/_mobile//g;

		# flashaac modes
		} elsif (	$mattribs->{kind} eq 'audio' &&
				$mattribs->{type} eq 'audio/mp4'
				# This also catches worldservice who happen not to set the encoding type
				# && $mattribs->{encoding} eq 'aac'
		) {
			# flashaachigh
			if (  $mattribs->{bitrate} >= 192 ) {
				get_stream_data_cdn( $data, $mattribs, 'flashaachigh', 'rtmp', 'aac' );

			# flashaacstd
			} elsif ( $mattribs->{bitrate} >= 96 ) {
				get_stream_data_cdn( $data, $mattribs, 'flashaacstd', 'rtmp', 'aac' );

			# flashaaclow
			} else {
				get_stream_data_cdn( $data, $mattribs, 'flashaaclow', 'rtmp', 'aac' );
			}

		# flashaudio modes
		} elsif (	$mattribs->{kind} eq 'audio' &&
				( $mattribs->{type} eq 'audio/mpeg' || $mattribs->{type} eq 'audio/mp3' )
				#&& $mattribs->{encoding} eq 'mp3'
		) {
			get_stream_data_cdn( $data, $mattribs, 'flashaudio', 'rtmp', 'mp3' );

		# RealAudio modes
		} elsif (	$mattribs->{type} eq 'audio/real' &&
				$mattribs->{encoding} eq 'real'
		) {
			get_stream_data_cdn( $data, $mattribs, 'realaudio', 'rtsp', 'mp3' );

		# wma modes
		} elsif (	$mattribs->{type} eq 'audio/wma' &&
				$mattribs->{encoding} eq 'wma'
		) {
			get_stream_data_cdn( $data, $mattribs, 'wma', 'mms', 'wma' );

		# aac3gp modes
		} elsif (	$mattribs->{kind} eq '' &&
				$mattribs->{type} eq 'audio/mp4' &&
				$mattribs->{encoding} eq 'aac'
		) {
			# Not sure how to stream these yet
			#$mattribs->{kind} = 'sis';
			#get_stream_data_cdn( $data, $mattribs, 'aac3gp', 'http', 'aac' );

		# Subtitles modes
		} elsif (	$mattribs->{kind} eq 'captions' &&
				$mattribs->{type} eq 'application/ttaf+xml'
		) {
			get_stream_data_cdn( $data, $mattribs, 'subtitles', 'http', 'srt' );

		# Catch unknown
		} else {
			new_stream_report($mattribs, undef) if $opt->{verbose};
		}	
	}

	# Do iphone redirect check regardless of an xml entry for iphone (except for EMP/Live) - sometimes the iphone streams exist regardless
	# Skip check if the modelist selected excludes iphone
	if ( $prog->{pid} !~ /^http/i && $verpid !~ /^\?/ && $verpid !~ /^http:/ && grep /^iphone/, split ',', $prog->modelist() ) {
		if ( my $streamurl = Streamer::iphone->get_url($ua, $prog->{pid}) ) {
			my $mode = 'iphone1';
			if ( $prog->{type} eq 'radio' ) {
				$data->{$mode}->{bitrate} = 128;
				$data->{$mode}->{type} = "(iplayer_streaming_http_mp3) http mp3 128kbps stream";
			} else {
				$data->{$mode}->{bitrate} = 480;
				$data->{$mode}->{type} = "(iplayer_streaming_http_mp4) http h264 480x272 480kbps stream";
			}
			$data->{$mode}->{streamurl} = $streamurl;
			$data->{$mode}->{streamer} = 'iphone';
			$data->{$mode}->{ext} = 'mov';
			get_stream_set_type( $data->{$mode} ) if ! $data->{$mode}->{type};
		} else {
			main::logger "DEBUG: No iphone redirect stream\n" if $opt->{verbose};
		}
	}

	# Report modes found
	if ( $opt->{verbose} ) {
		main::logger "INFO: Found mode $_: $data->{$_}->{type}\n" for sort keys %{ $data };
	}

	# Return a hash with media => url if '' is specified - otherwise just the specified url
	if ( ! $media ) {
		return $data;
	} else {
		# Make sure this hash exists before we pass it back...
		$data->{$media}->{exists} = 0 if not defined $data->{$media};
		return $data->{$media};
	}
}


