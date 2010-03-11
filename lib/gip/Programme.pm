package gip::Programme;

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
use Cwd 'abs_path';

# Class vars
# Global options
my $optref;
my $opt;
# File format
sub file_prefix_format { return '<name> - <episode> <pid> <version>' };
# index min/max
sub index_min { return 0 }
sub index_max { return 9999999 };
# Class cmdline Options
sub opt_format {
	return {
	};
}


# Filter channel names matched with options --refreshexclude/--refreshinclude
sub channels_filtered {
	my $prog = shift;
	my $channelsref = shift;
	my %channels = %{ $channelsref };
	# include/exclude matching channels as required
	my $include_regex = '.*';
	my $exclude_regex = '^ROUGEVALUE$';
	# Create a regex from any comma separated values
	$exclude_regex = '('.(join '|', ( split /,/, $opt->{refreshexclude} ) ).')' if $opt->{refreshexclude};
	$include_regex = '('.(join '|', ( split /,/, $opt->{refreshinclude} ) ).')' if $opt->{refreshinclude};
	for my $channel ( keys %channels ) {
		if ( $channels{$channel} !~ /$exclude_regex/i && $channels{$channel} =~ /$include_regex/i ) {
			main::logger "INFO: Will refresh channel $channels{$channel}\n" if $opt->{verbose};
		} else {
			delete $channels{$channel};
		}
	}
	return \%channels;
}


sub channels {
	return {};
}


sub channels_schedule {
        return {};
}


# Method to return optional list_entry format
sub optional_list_entry_format {
	my $prog = shift;
	return '';
}


# Returns the modes to try for this prog type
sub modelist {
	return '';
}


# Default minimum expected download size for a programme type
sub min_download_size {
	return 1024000;
}


# Default cache expiry in seconds
sub expiry {
	return 14400;
}


# Constructor
# Usage: $prog{$pid} = gip::Programme->new( 'pid' => $pid, 'name' => $name, <and so on> );
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	## Ensure that all instances reference the same class global $optref var
	# $self->{optref} = $gip::Programme::optref;
	# Ensure the subclass $opt var is pointing to the Superclass global optref
	$opt = $gip::Programme::optref;
	bless $self, $type;
}


# Use to bind a new options ref to the class global $optref var
sub add_opt_object {
	my $self = shift;
	$gip::Programme::optref = shift;
}


# $opt->{<option>} access method
sub opt {
	my $self = shift;
	my $optname = shift;
	return $opt->{$optname};

	#return $gip::Programme::optref->{$optname};	
	#my $opt = $self->{optref};
	#return $self->{optref}->{$optname};
}


# Cleans up a pid and removes url parts that might be specified
sub clean_pid {
}


# This gets run before the download retry loop if this class type is selected
sub init {
}


# Return metadata of the prog
sub get_metadata {
	my $prog = shift;
	my $ua = shift;
	$prog->{modes}->{default} = $prog->modelist();
	if ( keys %{ $prog->{verpids} } == 0 ) {
		if ( $prog->get_verpids( $ua ) ) {
			main::logger "ERROR: Could not get version pid metadata\n" if $opt->{verbose};
			return 1;
		}
	}
	$prog->{versions} = join ',', sort keys %{ $prog->{verpids} };
	return 0;
}


# Return metadata which is generic such as time and date
sub get_metadata_general {
	my $prog = shift;
	my @t;

	# Special case for history mode, use {timeadded} to generate these two fields as this represents the time of recording
	if ( $opt->{history} && $prog->{timeadded} ) {
		@t = localtime( $prog->{timeadded} );

	# Else use current time
	} else {
		@t = localtime();
	}

	#($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = localtime();
	$prog->{dldate} = sprintf "%02s-%02s-%02s", $t[5] + 1900, $t[4] + 1, $t[3];
	$prog->{dltime} = sprintf "%02s:%02s:%02s", $t[2], $t[1], $t[0];

	return 0;
}


# Displays specified metadata from supplied object
# Usage: $prog->display_metadata( <array of elements to display> )
sub display_metadata {
	my %data = %{$_[0]};
	shift;
	my @keys = @_;
	@keys = keys %data if $#_ < 0;
	main::logger "\n";
	for (@keys) {
		# Format timeadded field nicely
		if ( /^timeadded$/ ) {
			if ( $data{$_} ) {
				my @t = gmtime( time() - $data{$_} );
				main::logger sprintf "%-15s %s\n", $_.':', "$t[7] days $t[2] hours ago ($data{$_})";
			}
		# Streams data
		} elsif ( /^streams$/ ) {
			# skip these
		# If hash then list keys
		} elsif ( ref$data{$_} eq 'HASH' ) {
			for my $key ( sort keys %{$data{$_}} ) {
				main::logger sprintf "%-15s ", $_.':';
				if ( ref$data{$_}->{$key} ne 'HASH' ) {
					main::logger "$key: $data{$_}->{$key}";
				# This is the same as 'modes' list
				#} else {
				#	main::logger "$key: ".(join ',', sort keys %{ $data{$_}->{$key} } );
				}
				main::logger "\n";
			}
		# else just print out key value pair
		} else {
			main::logger sprintf "%-15s %s\n", $_.':', $data{$_} if $data{$_};		
		}
	}
	main::logger "\n";
	return 0;
}



# Return a list of episode pids from the given contents page/pid
sub get_pids_recursive {
	my $prog = shift;
	return '';
}



# Return hash of version => verpid given a pid
# Also put verpids in $prog->{verpids}->{<version>} = <verpid>
sub get_verpids {
	my $prog = shift;
	$prog->{verpids}->{'default'} = 1;
	return 0;
}



# Download Subtitles, convert to srt(SubRip) format and apply time offset
sub download_subtitles {
	# return failed...
	return 1;
}



# Usage: generate_version_list ($prog)
# Returns sorted array of versions
sub generate_version_list {
	my $prog = shift;
	
	# Default Order with which to search for programme versions (can be overridden by --versionlist option)
	my @version_search_order = qw/ default original signed audiodescribed opensubtitled shortened lengthened other /;
	@version_search_order = split /,/, $opt->{versionlist} if $opt->{versionlist};

	# check here for no matching verpids for specified version search list???
	my $got = 0;
	my @version_list;
	for my $version ( @version_search_order ) {
		if ( defined $prog->{verpids}->{$version} ) {
			$got++;
			push @version_list, $version;
		}
	}

	if ( $got == 0 ) {
		main::logger "INFO: No versions of this programme were selected (".(join ',', sort keys %{ $prog->{verpids} })." are available)\n";
	} else {
		main::logger "INFO: Will search for versions: ".(join ',', @version_list)."\n" if $opt->{verbose};
	}
	return @version_list;
}



# Retry the recording of a programme
# Usage: download_retry_loop ( $prog )
sub download_retry_loop {
	my $prog = shift;
	my $hist = shift;

	# Run the type init
	$prog->init();

	# If already downloaded then return (unless its for multimode)
	return 0 if ( ! $opt->{multimode} ) && $hist->check( $prog->{pid} );

	# Skip and warn if there is no pid
	if ( ! $prog->{pid} ) {
		main::logger "ERROR: No PID for index $_ (try using --type option ?)\n";
		return 1;
	}

	# Setup user-agent
	my $ua = main::create_ua( 'desktop' );

	# This pre-gets all the metadata - not entirely necessary but it does help - maybe only have when --metadata or --command is used
	# Also need full metadata for AtomicParsley or if --fileprefix is used
	$prog->get_metadata_general();
	if ( $opt->{fileprefix} || $opt->{metadata} || $opt->{command} || main::exists_in_path( 'atomicparsley' ) ) {
		if ( $prog->get_metadata( $ua ) ) {
			main::logger "ERROR: Could not get programme metadata\n" if $opt->{verbose};
			return 1;
		}
	}

	# Look up version pids for this prog - this does nothing if above get_metadata has alredy completed
	if ( keys %{ $prog->{verpids} } == 0 ) {
		if ( $prog->get_verpids( $ua ) ) {
			main::logger "ERROR: Could not get version pid metadata\n" if $opt->{verbose};
			return 1;
		}
	}

	# Re-check history because get_verpids() can update the pid (e.g. BBC /programmes/ URLs)
	return 0 if ( ! $opt->{multimode} ) && $hist->check( $prog->{pid} );

	# if %{ $prog->{verpids} } is empty then skip this programme recording attempt
	if ( (keys %{ $prog->{verpids} }) == 0 ) {
		main::logger "INFO: No versions exist for this programme\n";
		return 1;
	}


	my @version_search_list = $prog->generate_version_list;
	return 1 if $#version_search_list < 0;

	# Get all possible (or user overridden) modes for this prog recording
	my $modelist = $prog->modelist;
	main::logger "INFO: Mode list: $modelist\n" if $opt->{verbose};

	######## version loop #######
	# Do this for each version tried in this order (if they appeared in the content)
	for my $version ( @version_search_list ) {
		my $retcode = 1;
		main::logger "DEBUG: Trying version '$version'\n" if $opt->{debug};
		if ( $prog->{verpids}->{$version} ) {
			main::logger "INFO: Checking existence of $version version\n";
			$prog->{version} = $version;
			main::logger "INFO: Version = $prog->{version}\n" if $opt->{verbose};

			# Try to get stream data for this version if not already populated
			if ( not defined $prog->{streams}->{$version} ) {
				$prog->{streams}->{$version} = $prog->get_stream_data( $prog->{verpids}->{$version} );
			}

			########## mode loop ########
			# record prog depending on the prog type

			# only use modes that exist
			my @modes;
			my @available_modes = sort keys %{ $prog->{streams}->{$version} };
			for my $modename ( split /,/, $modelist ) {
				# find all numbered modes starting with this modename
				push @modes, sort { $a cmp $b } grep /^$modename(\d+)?$/, @available_modes;
			}

			# Check for no applicable modes - report which ones are available if none are specified
			if ($#modes < 0) {
				my %available_modes_short;
				# Strip the number from the end of the mode name and make a unique array
				for ( @available_modes ) {
					my $modename = $_;
					$modename =~ s/\d+$//g;
					$available_modes_short{$modename}++;
				}
				main::logger "INFO: No specified modes ($modelist) available for this programme with version '$version' (try using --modes=".(join ',', sort keys %available_modes_short).")\n";
				next;
			}
			main::logger "INFO: ".join(',', @modes)." modes will be tried for version $version\n";

			# Expand the modes into a loop
			for my $mode ( @modes ) {
				chomp( $mode );
				$prog->{mode} = $mode;
				# Keep short mode name for substitutions
				$prog->{modeshort} = $mode;
				$prog->{modeshort} =~ s/\d+$//g;

				# If multimode is used, skip only modes which are in the history
				next if $opt->{multimode} && $hist->check( $prog->{pid}, $mode );

				main::logger "INFO: Trying $mode mode to record $prog->{type}: $prog->{name} - $prog->{episode}\n";

				# try the recording for this mode (rtn==0 -> success, rtn==1 -> next mode, rtn==2 -> next prog)
				$retcode = mode_ver_download_retry_loop( $prog, $hist, $ua, $mode, $version, $prog->{verpids}->{$version} );
				main::logger "DEBUG: mode_ver_download_retry_loop retcode = $retcode\n" if $opt->{debug};

				# quit if successful or skip (unless --multimode selected)
				last if ( $retcode == 0 || $retcode == 2 ) && ! $opt->{multimode};
			}
		}
		# Break out of loop if we have a successful recording for this version and mode
		return 0 if not $retcode;
	}

	if (! $opt->{test}) {
		main::logger "ERROR: Failed to record '$prog->{name} - $prog->{episode} ($prog->{pid})'\n";
	}
	return 1;
}



# returns 1 on fail, 0 on success
sub mode_ver_download_retry_loop {
	my ( $prog, $hist, $ua, $mode, $version, $version_pid ) = ( @_ );
	my $retries = $opt->{attempts} || 3;
	my $count = 0;
	my $retcode;

	# Use different number of retries for flash modes
	$retries = $opt->{attempts} || 50 if $mode =~ /^flash/;

	# Retry loop
	for ($count = 1; $count <= $retries; $count++) {
		main::logger "INFO: Attempt number: $count / $retries\n" if $opt->{verbose};

		$retcode = $prog->download( $ua, $mode, $version, $version_pid );
		main::logger "DEBUG: Record using $mode mode return code: '$retcode'\n" if $opt->{verbose};

		# Exit
		if ( $retcode eq 'abort' ) {
			main::logger "ERROR: aborting get_iplayer\n";
			exit 1;

		# Try Next prog
		} elsif ( $retcode eq 'skip' ) {
			main::logger "INFO: skipping this programme\n";
			return 2;

		# Try Next mode
		} elsif ( $retcode eq 'next' ) {
			# break out of this retry loop
			main::logger "INFO: skipping $mode mode\n";
			last;

		# Success
		} elsif ( $retcode eq '0' ) {
			# No need to do all these post-tasks if its streaming-only
			if ( $opt->{stdout} ) {
				# Run user command if streaming-only or a stream was writtem
				$prog->run_user_command( $opt->{command} ) if $opt->{command};
				# Skip
			} else {
				# Add to history, tag file, and run post-record command if a stream was written
				main::logger "\n";
				if ( ! $opt->{nowrite} ) {
					$hist->add( $prog );
					$prog->tag_file;
				}
				$prog->download_thumbnail if $opt->{thumb};
				$prog->create_metadata_file if $opt->{metadata};
				if ( ! $opt->{nowrite} ) {
					$prog->run_user_command( $opt->{command} ) if $opt->{command};
				}
			}
			$prog->report() if $opt->{pvr};
			return 0;

		# Retry this mode
		} elsif ( $retcode eq 'retry' && $count < $retries ) {
			main::logger "WARNING: Retry recording for '$prog->{name} - $prog->{episode} ($prog->{pid})'\n";
			# Try to get stream data for this version/mode - retries require new auth data
			$prog->{streams}->{$version} = $prog->get_stream_data( $version_pid );
		}
	}
	return 1;
}



# Send a message to STDOUT so that cron can use this to email 
sub report {
	my $prog = shift;
	print STDOUT "New $prog->{type} programme: '$prog->{name} - $prog->{episode}', '$prog->{desc}'\n";
	return 0;
}



# Add id3 tag to MP3/AAC files if required
sub tag_file {
	my $prog = shift;

	# Return if file does not exist
	return if ! -f $prog->{filename};

	if ( $prog->{filename} =~ /\.(aac|mp3|m4a)$/i ) {
		# Create ID3 tagging options for external tagger program (escape " for shell)
		my ( $id3_name, $id3_episode, $id3_desc, $id3_channel ) = ( $prog->{name}, $prog->{episode}, $prog->{desc}, $prog->{channel} );
		s|"|\\"|g for ($id3_name, $id3_episode, $id3_desc, $id3_channel);
		# Only tag if the required tool exists
		if ( main::exists_in_path('id3v2') ) {
			main::logger "INFO: id3 tagging $prog->{ext} file\n";
			my @cmd = (
				$bin->{id3v2}, 
				'--artist', $id3_channel,
				'--album', $id3_name,
				'--song', $id3_episode,
				'--comment', 'Description:'.$id3_desc,
				'--year', substr( $prog->{firstbcast}->{$prog->{version}}, 0, 4 ) || ((localtime())[5] + 1900),
				$prog->{filename},
			);
			if ( main::run_cmd( 'STDERR', @cmd ) ) {
				main::logger "WARNING: Failed to tag $prog->{ext} file\n";
				return 2;
			}
		} else {
			main::logger "WARNING: Cannot tag $prog->{ext} file\n" if $opt->{verbose};
		}

	} elsif ( $prog->{filename} =~ /\.(mp4|m4v)$/i ) {
		# Create mp4 tagging options for external tagging program.
		my $tags;
		for my $tag ( keys %{$prog} ) {
			# Used for firstbcast etc which are a version based HASH
			if ( ref$prog->{$tag} eq 'HASH' ) {
				$tags->{$tag} = $prog->{$tag}->{$prog->{version}};
			} else {
				$tags->{$tag} = $prog->{$tag};
			}
			$tags->{$tag} =~ s|"|\\"|g;
		}

		# Make 'duration' == 'length' for the selected version
		$tags->{duration} = $prog->{durations}->{$prog->{version}} if $prog->{durations}->{$prog->{version}};

		# Only tag if the required tool exists
		if ( main::exists_in_path( 'atomicparsley' ) ) {
			# Download the thumbnail if it doesn't already exist
			$prog->download_thumbnail if ! -f $prog->{thumbfile};

			# Download Thubnail file as well for inclusion into MP4 stream.
			# Apple TV/iTunes will use it.
			main::logger "INFO: mp4 tagging $prog->{ext} file\n";

			# extract year from firstbcast e.g. 2009-10-05T22:35:00+01:00
			#$year =~ s/^.*(20\d\d|19\d\d).*$/$1/g;
			# If year isn't set correctly in the information, then assume today.
			$tags->{firstbcast} = (localtime())[5] + 1900 if ! $tags->{firstbcast};

			# Add guidance if set
			$tags->{guidance} = 'clean';
			$tags->{guidance} = 'explicit' if $prog->{guidance};

			# Show type
			my $stik = 'TV Show';
			$stik = 'Movie' if $tags->{categories} =~ m{(film|movie)}i;

			# Strip series and episode text from name, longname, episode
			for my $tag ( qw/name longname episode/ ) {
				$tags->{$tag} =~ s/(:\s*)?(Series|Episode)\s*\d+(:\s*)?//gi;
			}
			my $title = "$tags->{longname} - $tags->{episode}";
			# strip any trailing '-' and whitespace
			$title =~ s/[\s\-]*$//g;

			# Build the command
			my @cmd = (
				$bin->{atomicparsley}, $prog->{filename},
				'--TVNetwork',	$tags->{channel},
				'--description',$tags->{descshort},
				'--comment',	$tags->{descshort},
				'--title',	$title,
				'--TVShowName',	$tags->{longname},
				'--TVEpisode',	$tags->{pid},
				'--artist',	$tags->{name},
				'--year',	$tags->{firstbcast},
				'--advisory',	$tags->{guidance},
				'--genre',	$tags->{categories},
				'--stik',	$stik,
				'--overWrite',	# Saves temp files being left around.
			);

			# Add the thumbnail if one was downloaded
			push @cmd, "--artwork", $prog->{thumbfile} if -f $prog->{thumbfile};

			# Add the series and episode numbers if they are defined
			push @cmd, "--TVSeasonNum", $prog->{seriesnum} if $prog->{seriesnum};
			push @cmd, "--TVEpisodeNum", $prog->{episodenum} if $prog->{episodenum};

			# time of recording - this messes up iTunes somewhat
			#push @cmd, "--purchaseDate", "$prog->{dldate}T$prog->{dltime}Z" if $prog->{dldate} && $prog->{dltime};

			# After running, clean up thumbnail file unless it is required using the thumbnail option.
			if ( main::run_cmd( 'STDERR', @cmd ) ) {
				main::logger "WARNING: Failed to tag $prog->{ext} file\n";
				unlink $prog->{thumbfile} if ! $opt->{thumb};
				return 2;
			}
			unlink $prog->{thumbfile} if ! $opt->{thumb};
		}
	}
}



# Create a metadata file if required
sub create_metadata_file {
	my $prog = shift;
	my $template;
	my $filename;

	# XML templaye for XBMC movies - Ref: http://xbmc.org/wiki/?title=Import_-_Export_Library#Movies
	$filename->{xbmc_movie} = "$prog->{dir}/$prog->{fileprefix}.nfo";
	$template->{xbmc_movie} = '
	<movie>
		<title>[name] - [episode]</title>
		<outline>[desc]</outline>
		<plot>[desc]</plot>
		<tagline>[descshort]</tagline>
		<runtime>[duration]</runtime>
		<thumb>[thumbnail]</thumb>
		<id>[pid]</id>
		<filenameandpath>[dir]/[fileprefix].[ext]</filenameandpath>
		<trailer></trailer>
		<genre>[categories]</genre>
		<year>[firstbcast]</year>
		<credits>[channel]</credits>
        </movie>
	';

	# XML template for XBMC - Ref: http://xbmc.org/wiki/?title=Import_-_Export_Library#TV_Episodes
	$filename->{xbmc} = "$prog->{dir}/$prog->{fileprefix}.nfo";
	$template->{xbmc} = '
	<episodedetails>
		<title>[name] - [episode]</title>
		<rating>10.00</rating>
		<season>[seriesnum]</season>
		<episode>[episodenum]</episode>
		<plot>[desc]</plot>
		<credits>[channel]</credits>
		<aired>[firstbcast]</aired>
	</episodedetails>
	';

	# XML template for Freevo - Ref: http://doc.freevo.org/MovieFxd
	$filename->{freevo} = "$prog->{dir}/$prog->{fileprefix}.fxd";
	$template->{freevo} = '<?xml version="1.0" ?>
	<freevo>
		<FREEVOTYPE title="[longname]">
			<video>
				<file id="f1">[fileprefix].[ext]</file>
			</video>
			<info>
				<rating></rating>
				<userdate>[dldate] [dltime]</userdate>
				<plot>[desc]</plot>
				<tagline>[episode]</tagline>
				<year>[firstbcast]</year>
				<genre>[categories]</genre>
				<runtime>[duration]</runtime>
				<channel>[channel]</channel>
			</info>
		</FREEVOTYPE>
	</freevo>
	';

	# Generic XML template for all info
	$filename->{generic} = "$prog->{dir}/$prog->{fileprefix}.xml";
	$template->{generic}  = '<?xml version="1.0" encoding="UTF-8" ?>'."\n";
	$template->{generic} .= '<program_meta_data xmlns="http://linuxcentre.net/xmlstuff/get_iplayer" revision="1">'."\n";
	$template->{generic} .= "\t<$_>[$_]</$_>\n" for ( sort keys %{$prog} );
	$template->{generic} .= "</program_meta_data>\n";

	return if ! -d $prog->{dir};
	if ( not defined $template->{ $opt->{metadata} } ) {
		main::logger "WARNING: metadata type '$opt->{metadata}' is not valid - must be one of ".(join ',', keys %{$template} )."\n";
		return;
	}

	main::logger "INFO: Writing $opt->{metadata} metadata to file '$filename->{ $opt->{metadata} }'\n";

	if ( open(XML, "> $filename->{ $opt->{metadata} }") ) {
		my $text = $prog->substitute( $template->{ $opt->{metadata} }, 3, '\[', '\]' );
		# Strip out unsubstituted tags
		$text =~ s/<.+?>\[.+?\]<.+?>[\s\n\r]*//g;
		# Hack: substitute here because freevo needs either <audio> or <movie> depending on filetype
		if ( $opt->{metadata} eq 'freevo' ) {
			if ( $prog->{type} =~ /radio/i ) {
				$text =~ s/FREEVOTYPE/audio/g;
			} else {
				$text =~ s/FREEVOTYPE/movie/g;
			}
		}
		print XML $text;
		close XML;
	} else {
		main::logger "WARNING: Couldn't write to metadata file '$filename->{ $opt->{metadata} }'\n";
	}
}



# Usage: print $prog{$pid}->substitute('<name>-<pid>-<episode>', [mode], [begin regex tag], [end regex tag]);
# Return a string with formatting fields substituted for a given pid
# sanitize_mode == 0 then sanitize final string but dont sanitize '/' in field values
# sanitize_mode == 1 then sanitize final string and also sanitize '/' in field values
# sanitize_mode == 2 then just substitute only
# sanitize_mode == 3 then substitute then use encode entities for fields only
# sanitize_mode == 4 then substitute then escape characters in fields only for use in double-quoted shell text.
#
# Also if it find a HASH type then the $prog->{<version>} element is searched and used
# Likewise, if a ARRAY type is found, elements are joined with commas
sub substitute {
	my ( $self, $string, $sanitize_mode, $tag_begin, $tag_end ) = ( @_ );
	$sanitize_mode = 0 if not defined $sanitize_mode;
	$tag_begin = '\<' if not defined $tag_begin;
	$tag_end = '\>' if not defined $tag_end;
	my $version = $self->{version} || 'unknown';
	my $replace = '';

	# Make 'duration' == 'length' for the selected version
	$self->{duration} = $self->{durations}->{$version} if $self->{durations}->{$version};

	# Tokenize and substitute $format
	for my $key ( keys %{$self} ) {

		my $value = $self->{$key};

		# Get version specific value if this key is a hash
		if ( ref$value eq 'HASH' ) {
			if ( ref$value->{$version} ne 'HASH' ) {
				$value = $value->{$version};
			} else {
				$value = 'unprintable';
			}
		}

		# Join array elements if value is ARRAY type
		if ( ref$value eq 'ARRAY' ) {
			$value = join ',', @{ $value };
		}

		$value = '' if not defined $value;
		main::logger "DEBUG: Substitute ($version): '$key' => '$value'\n" if $opt->{debug};
		# Remove/replace all non-nice-filename chars if required
		if ($sanitize_mode == 0) {
			$replace = StringUtils::sanitize_path( $value );
		# html entity encode
		} elsif ($sanitize_mode == 3) {
			$replace = encode_entities( $value );
		# escape these chars: ! ` \ "
		} elsif ($sanitize_mode == 4) {
			$replace = $value;
			$replace =~ s/([\!"\\`])/\\$1/g;
		} else {
			$replace = $value;
		}
		$key = $tag_begin.$key.$tag_end;
		$string =~ s|$key|$replace|gi;
	}

	if ( $sanitize_mode == 0 || $sanitize_mode == 1 ) {
		# Remove empty tags
		my $key = $tag_begin.'.*?'.$tag_end;
		$string =~ s|$key||m;
		# Strip whitespace if required
		$string =~ s/[\s_]+/_/g if ! $opt->{whitespace};
		# Remove/replace all non-nice-filename chars if required except for fwd slashes
		return StringUtils::sanitize_path( $string, 1 );
	} else {
		return $string;
	}
}

	

# Determine the correct filenames for a recording
# Sets the various filenames and creates appropriate directories
# Gets more programme metadata if the prog name does not exist
#
# Uses:
#	$opt->{fileprefix}
#	$opt->{subdir}
#	$opt->{whitespace}
#	$opt->{test}
# Requires: 
#	$prog->{dir}
# Sets: 
#	$prog->{fileprefix}
#	$prog->{filename}
#	$prog->{filepart}
#	$prog->{symlink}
# Returns 0 on success, 1 on failure (i.e. if the <filename> already exists)
#
sub generate_filenames {
	my ($prog, $ua, $format, $multipart) = (@_);

	# Get and set more meta data - Set the %prog values from metadata if they aren't already set (i.e. with --pid option)
	if ( ! $prog->{name} ) {
		if ( $prog->get_metadata( $ua ) ) {
			main::logger "ERROR: Could not get programme metadata\n" if $opt->{verbose};
			return 1;
		}
		$prog->get_metadata_general();
	}

	# Determine direcotry and find it's absolute path
	if ( $^O !~ /^MSWin32$/ ) {
		$prog->{dir} = abs_path( $opt->{ 'output'.$prog->{type} } || $opt->{output} || $ENV{IPLAYER_OUTDIR} || '.' );
	} else {
		$prog->{dir} = $opt->{ 'output'.$prog->{type} } || $opt->{output} || $ENV{IPLAYER_OUTDIR} || '.';
	}
	
	# Add modename to default format string if multimode option is used
	$format .= ' <mode>' if $opt->{multimode};

	$prog->{fileprefix} = $opt->{fileprefix} || $format;

	# get $name, $episode from title
	my ( $name, $episode ) = gip::Programme::bbciplayer::split_title( $prog->{title} ) if $prog->{title};
	$prog->{name} = $name if $name && ! $prog->{name};
	$prog->{episode} = $episode if $episode && ! $prog->{episode};

	# store the name extracted from the title metadata in <longname> else just use the <name> field
	$prog->{longname} = $name || $prog->{name};

	# Set some common metadata fallbacks
	$prog->{nameshort} = $prog->{name} if ! defined $prog->{nameshort};
	$prog->{episodeshort} = $prog->{episode} if ! defined $prog->{episodeshort};

	# Create descmedium, descshort by truncation of desc if they don't already exist
	$prog->{descmedium} = substr( $prog->{desc}, 0, 1024 ) if ! defined $prog->{descmedium};
	$prog->{descshort} = substr( $prog->{desc}, 0, 255 ) if ! defined $prog->{descshort};

	# substitute fields and sanitize $prog->{fileprefix}
	main::logger "DEBUG: Substituted '$prog->{fileprefix}' as " if $opt->{debug};
	# Don't allow <mode> in fileprefix as it can break when resumes fallback on differently numbered modes of the same type change for <modeshort>
	$prog->{fileprefix} =~ s/<mode>/<modeshort>/g;
	$prog->{fileprefix} = $prog->substitute( $prog->{fileprefix} );

	# Truncate filename to 240 chars (allows for extra stuff to keep it under system 256 limit)
	$prog->{fileprefix} = substr( $prog->{fileprefix}, 0, 240 );
	main::logger "'$prog->{fileprefix}'\n" if $opt->{debug};

	# Change the date in the filename to ISO8601 format if required
	$prog->{fileprefix} =~ s|(\d\d)[/_](\d\d)[/_](20\d\d)|$3-$2-$1|g if $opt->{isodate};

	# Special case for history mode, parse the fileprefix and dir from filename if it is already defined
	if ( $opt->{history} && defined $prog->{filename} && $prog->{filename} ne '' ) {
		( $prog->{dir}, $prog->{fileprefix}, $prog->{ext} ) = ( $1, $3, $4 ) if $prog->{filename} =~ m{^((.*)[\//]+)?([^\//]+?)\.(\w+)$};
	}

	# Don't create subdir if we are only testing recordings
	# Create a subdir for programme sorting option
	if ( $opt->{subdir} ) {
		my $subdir = $prog->substitute( $opt->{subdirformat} || '<longname>' );
		$prog->{dir} .= "/${subdir}";
		$prog->{dir} =~ s|\/\/|\/|g;
		main::logger("INFO: Creating subdirectory $prog->{dir} for programme\n") if $opt->{verbose};
	}

	# Create a subdir if there are multiple parts
	if ( $multipart ) {
		$prog->{dir} .= "/$prog->{fileprefix}";
		$prog->{dir} .= s|\/\/|\/|g;
		main::logger("INFO: Creating multi-part subdirectory $prog->{dir} for programme\n") if $opt->{verbose};
	}

	# Create dir if it does not exist
	mkpath("$prog->{dir}") if (! -d "$prog->{dir}") && (! $opt->{test});

	main::logger("\rINFO: File name prefix = $prog->{fileprefix}                 \n");

	# Use a dummy file ext if one isn't set - helps with readability of metadata
	$prog->{ext} = 'EXT' if ! $prog->{ext};
	
	# Don't override the {filename} if it is already set (i.e. for history info) or unless multimode option is specified
	$prog->{filename} = "$prog->{dir}/$prog->{fileprefix}.$prog->{ext}" if ( defined $prog->{filename} && $prog->{filename} =~ /\.EXT$/ ) || $opt->{multimode} || ! $prog->{filename};
	$prog->{filepart} = "$prog->{dir}/$prog->{fileprefix}.partial.$prog->{ext}";

	# Create symlink filename if required
	if ( $opt->{symlink} ) {
		# Substitute the fields for the pid
		$prog->{symlink} = $prog->substitute( $opt->{symlink} );
		main::logger("INFO: Symlink file name will be '$prog->{symlink}'\n") if $opt->{verbose};
		# remove old symlink
		unlink $prog->{symlink} if -l $prog->{symlink} && ! $opt->{test};
	}

	# overwrite/error if the file already exists and is going to be written to
	if (
		( ! $opt->{nowrite} )
		&& ( ! $opt->{metadataonly} )
		&& ( ! $opt->{thumbonly} )
		&& ( ! $opt->{subsonly} )
		&& -f $prog->{filename} 
		&& stat($prog->{filename})->size > $prog->min_download_size()
	) {
		if ( $opt->{overwrite} ) {
			main::logger("INFO: Overwriting file $prog->{filename}\n\n");
			unlink $prog->{filename};
		} else {
			main::logger("WARNING: File $prog->{filename} already exists\n\n");
			return 1;
		}
	}

	# Determine thumbnail filename
	if ( $prog->{thumbnail} =~ /^http/i ) {
		my $ext;
		$ext = $1 if $prog->{thumbnail} =~ m{\.(\w+)$};
		$ext = $opt->{thumbext} || $ext;
		$prog->{thumbfile} = "$prog->{dir}/$prog->{fileprefix}.${ext}";
	}

	main::logger "DEBUG: File prefix:        $prog->{fileprefix}\n" if $opt->{debug};
	main::logger "DEBUG: File ext:           $prog->{ext}\n" if $opt->{debug};
	main::logger "DEBUG: Directory:          $prog->{dir}\n" if $opt->{debug};
	main::logger "DEBUG: Partial Filename:   $prog->{filepart}\n" if $opt->{debug};
	main::logger "DEBUG: Final Filename:     $prog->{filename}\n" if $opt->{debug};
	main::logger "DEBUG: Thumnail Filename:  $prog->{thumbfile}\n" if $opt->{debug};
	main::logger "DEBUG: Raw Mode: $opt->{raw}\n" if $opt->{debug};

	# Check path length is < 256 chars
	if ( length( $prog->{filepart} ) > 255 ) {
		main::logger("ERROR: Generated filename is too long, please use --fileprefix option to shorten it to below 250 characters ('$prog->{filepart}')\n\n");
		return 1;
	}
	return 0;
}



# Run a user specified command
# e.g. --command 'echo "<pid> <name> recorded"'
# run_user_command($pid, 'echo "<pid> <name> recorded"');
sub run_user_command {
	my $prog = shift;
	my $command = shift;

	# Substitute the fields for the pid (and sanitize for double-quoted shell use)
	$command = $prog->substitute( $command, 4 );

	# run command
	main::logger "INFO: Running command '$command'\n" if $opt->{verbose};
	my $exit_value = main::run_cmd( 'normal', $command );
	
	main::logger "ERROR: Command Exit Code: $exit_value\n" if $exit_value;
	main::logger "INFO: Command succeeded\n" if $opt->{verbose} && ! $exit_value;
        return 0;
}



# %type
# Display a line containing programme info (using long, terse, and type options)
sub list_entry {
	my ( $prog, $prefix, $tree, $number_of_types, $episode_count, $episode_width ) = ( @_ );

	my $prog_type = '';
	# Show the type field if >1 type has been specified
	$prog_type = "$prog->{type}, " if $number_of_types > 1;
	my $name;
	# If tree view
	if ( $opt->{tree} ) {
		$prefix = '  '.$prefix;
		$name = '';
	} else {
		$name = "$prog->{name} - ";
	}

	main::logger "\n${prog_type}$prog->{name}\n" if $opt->{tree} && ! $tree;
	# Display based on output options
	if ( $opt->{listformat} ) {
		# Slow. Needs to be faster e.g:
		#main::logger 'ENTRY'."$prog->{index}|$prog->{thumbnail}|$prog->{pid}|$prog->{available}|$prog->{type}|$prog->{name}|$prog->{episode}|$prog->{versions}|$prog->{duration}|$prog->{desc}|$prog->{channel}|$prog->{categories}|$prog->{timeadded}|$prog->{guidance}|$prog->{web}|$prog->{filename}|$prog->{mode}\n";
		main::logger $prefix.$prog->substitute( $opt->{listformat}, 2 )."\n";
	} elsif ( $opt->{series} && $episode_width && $episode_count && ! $opt->{tree} ) {
		main::logger sprintf( "%s%-${episode_width}s %5s %s\n", $prefix, $prog->{name}, "($episode_count)", $prog->{categories} );
	} elsif ( $opt->{long} ) {
		my @time = gmtime( time() - $prog->{timeadded} );
		main::logger "${prefix}$prog->{index}:\t${prog_type}${name}$prog->{episode}".$prog->optional_list_entry_format.", $time[7] days $time[2] hours ago - $prog->{desc}\n";
	} elsif ( $opt->{terse} ) {
		main::logger "${prefix}$prog->{index}:\t${prog_type}${name}$prog->{episode}\n";
	} else {
		main::logger "${prefix}$prog->{index}:\t${prog_type}${name}$prog->{episode}".$prog->optional_list_entry_format."\n";
	}
	return 0;
}



sub list_entry_html {
	my ($prog, $tree) = (@_);
	my $html;
	# If tree view
	my $name = encode_entities( $prog->{name} );
	my $episode = encode_entities( $prog->{episode} );
	my $desc = encode_entities( $prog->{desc} );
	my $channel = encode_entities( $prog->{channel} );
	my $type = encode_entities( $prog->{type} );
	my $categories = encode_entities( $prog->{categories} );

	# Header
	if ( not $tree ) {
		# Assume all thumbnails for a prog name are the same
		$html = "<tr bgcolor='#cccccc'>
			<td rowspan=1 width=150><a href=\"$prog->{web}\"><img height=84 width=150 src=\"$prog->{thumbnail}\"></a></td>
				<td><a href=\"$prog->{web}\">${name}</a></td>
				<td>${channel}</td>
				<td>${type}</td>
				<td>${categories}</td>
			</tr>
		\n";
	# Follow-on episodes
	}
		$html .= "<tr>
				<td>$_</td>
				<td><a href=\"$prog->{web}\">${episode}</a></td>
				<td colspan=3>${desc}</td>
			</tr>
		\n";
	return $html;
}


# Creates symlink
# Usage: $prog->create_symlink( <symlink>, <target> );
sub create_symlink {
	my $prog = shift;
	my $symlink = shift;
	my $target = shift;

	# remove old symlink
	unlink $symlink if -l $symlink;
	# Create symlink
	symlink $target, $symlink;
	main::logger "INFO: Created symlink from '$symlink' -> '$target'\n" if $opt->{verbose};
}



# Get time ago made available (x days y hours ago) from '2008-06-22T05:01:49Z' and specified epoch time
# Or, Get time in epoch from '2008-06-22T05:01:49Z' or '2008-06-22T05:01:49[+-]NN:NN' if no specified epoch time
sub get_time_string {
	$_ = shift;
	my $diff = shift;

	# extract $year $mon $mday $hour $min $sec $tzhour $tzmin
	my ($year, $mon, $mday, $hour, $min, $sec, $tzhour, $tzmin);
	if ( m{(\d\d\d\d)\-(\d\d)\-(\d\d)T(\d\d):(\d\d):(\d\d)} ) {
		($year, $mon, $mday, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
	} else {
		return '';
	}

	# positive TZ offset
	($tzhour, $tzmin) = ($1, $2) if m{\d\d\d\d\-\d\d\-\d\dT\d\d:\d\d:\d\d\+(\d\d):(\d\d)};
	# negative TZ offset
	($tzhour, $tzmin) = ($1*-1, $2*-1) if m{\d\d\d\d\-\d\d\-\d\dT\d\d:\d\d:\d\d\-(\d\d):(\d\d)};
	# ending in 'Z'
	($tzhour, $tzmin) = (0, 0) if m{\d\d\d\d\-\d\d\-\d\dT\d\d:\d\d:\d\dZ};

	main::logger "DEBUG: $_ = $year, $mon, $mday, $hour, $min, $sec, $tzhour, $tzmin\n" if $opt->{debug};
	# Sanity check date data
	return '' if $year < 1970 || $mon < 1 || $mon > 12 || $mday < 1 || $mday > 31 || $hour < 0 || $hour > 24 || $min < 0 || $min > 59 || $sec < 0 || $sec > 59 || $tzhour < -13 || $tzhour > 13 || $tzmin < -59 || $tzmin > 59;
	# Year cannot be > 2032 so limit accordingly :-/
	$year = 2038 if $year > 2038;
	# Calculate the seconds difference between epoch_now and epoch_datestring and convert back into array_time
	my $epoch = timegm($sec, $min, $hour, $mday, ($mon-1), ($year-1900), undef, undef, 0) - $tzhour*60*60 - $tzmin*60;
	my $rtn;
	if ( $diff ) {
		# Return time ago
		if ( $epoch < $diff ) {
			my @time = gmtime( $diff - ( timegm($sec, $min, $hour, $mday, ($mon-1), ($year-1900), undef, undef, 0) - $tzhour*60*60 - $tzmin*60 ) );
			# The time() func gives secs since 1970, gmtime is since 1900
			my $years = $time[5] - 70;
			$rtn = "$years years " if $years;
			$rtn .= "$time[7] days $time[2] hours ago";
			return $rtn;
		# Return time to go
		} elsif ( $epoch > $diff ) {
			my @time = gmtime( ( timegm($sec, $min, $hour, $mday, ($mon-1), ($year-1900), undef, undef, 0) - $tzhour*60*60 - $tzmin*60 ) - $diff );
			my $years = $time[5] - 70;
			$rtn = 'in ';
			$rtn .= "$years years " if $years;
			$rtn .= "$time[7] days $time[2] hours";
			return $rtn;
		# Return 'Now'
		} else {
			return "now";
		}
	# Return time in epoch
	} else {
		# Calculate the seconds difference between epoch_now and epoch_datestring and convert back into array_time
		return timegm($sec, $min, $hour, $mday, ($mon-1), ($year-1900), undef, undef, 0) - $tzhour*60*60 - $tzmin*60;
	}
}



sub download_thumbnail {
	my $prog = shift;
	my $file;
	my $ext;
	my $image;
		
	if ( $prog->{thumbnail} =~ /^http/i && $prog->{thumbfile} ) {
		main::logger "INFO: Getting thumbnail from $prog->{thumbnail}\n" if $opt->{verbose};
		$file = $prog->{thumbfile};

		# Download thumb
		$image = main::request_url_retry( main::create_ua( 'desktop', 1 ), $prog->{thumbnail}, 1);
		if (! $image ) {
			main::logger "ERROR: Thumbnail Download failed\n";
			return 1;
		} else {
			main::logger "INFO: Downloaded Thumbnail to '$file'\n";
		}

	} else {
		# Return if we have no url
		main::logger "INFO: Thumbnail not available\n" if $opt->{verbose};
		return 2;
	}

	# Write to file
	unlink($file);
	open( my $fh, "> $file" );
	binmode $fh;
	print $fh $image;
	close $fh;

	return 0;
}

