package gip::Streamer::mms;

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



# %prog (only used for {mode} and generating multi-part file prefixes)
# Actually do the MMS video streaming
sub get {
	my ( $stream, $ua, $urls, $prog ) = @_;
	my $file_tmp;
	my $cmd;
	my @url_list = split /\|/, $urls;
	my @file_tmp_list;
	my %threadpid;
	my $retries = $opt->{attempts} || 3;

	main::logger "INFO: MMS_URLs: ".(join ', ', @url_list).", file: $prog->{filepart}, file_done: $prog->{filename}\n" if $opt->{verbose};

	if ( $opt->{stdout} ) {
		main::logger "ERROR: stdout streaming isn't supported for mms streams\n";
		return 'next';
	}

	# Start marker
	my $start_time = time();
	# Download each mms url (multi-threaded to stream in parallel)
	my $file_part_prefix = "$prog->{dir}/$prog->{fileprefix}_part";
	for ( my $count = 0; $count <= $#url_list; $count++ ) {
		
		# Parse/recurse playlist if required to get mms url
		$url_list[$count] = main::get_playlist_url( $ua, $url_list[$count], 'mms' );

		# Create temp recording filename
		$file_tmp = sprintf( "%s%02d.".$prog->{ext}, $file_part_prefix, $count+1);
		$file_tmp_list[$count] = $file_tmp;
		#my $null;
		#$null = '-really-quiet' if ! $opt->{quiet};
		# Can also use 'mencoder mms://url/ -oac copy -ovc copy -o out.asf' - still gives zero exit code on failed stream...
		# Can also use $bin->{vlc} --sout file/asf:\"$file_tmp\" \"$url_list[$count]\" vlc://quit
		# The vlc cmd does not quit of there is an error - it just hangs
		# $cmd = "$bin->{mplayer} $binopts->{mplayer} -dumpstream \"$url_list[$count]\" -dumpfile \"$file_tmp\" $null 1>&2";
		# Use backticks to invoke mplayer and grab all output then grep for 'read error'
		# problem is that the following output is given by mplayer at the end of liong streams:
		#read error:: Operation now in progress
		#pre-header read failed
		#Core dumped ;)
		#vo: x11 uninit called but X11 not initialized..
		#
		#Exiting... (End of file)
		$cmd = "\"$bin->{mplayer}\" ".(join ' ', @{ $binopts->{mplayer} } )." -dumpstream \"$url_list[$count]\" -dumpfile \"$file_tmp\" 2>&1";
		main::logger "INFO: Command: $cmd\n" if $opt->{verbose};

		# fork streaming threads
		if ( not $opt->{mmsnothread} ) {
			my $childpid = fork();
			if (! $childpid) {
				# Child starts here
				main::logger "INFO: Streaming to file $file_tmp\n";
				# Remove old file
				unlink $file_tmp;
				# Retry loop
				my $retry = $retries;
				while ($retry) {
					my $cmdoutput = `$cmd`;
					my $exitcode = $?;
					main::logger "DEBUG: Command '$cmd', Output:\n$cmdoutput\n\n" if $opt->{debug};
					# Assume file is fully downloaded if > 10MB and we get an error reported !!!
					if ( ( -f $prog->{filename} && stat($prog->{filename})->size < $prog->min_download_size()*10.0 && grep /(read error|connect error|Failed, exiting)/i, $cmdoutput ) || $exitcode ) {
						# Failed, retry
						main::logger "WARNING: Failed, retrying to stream $file_tmp, exit code: $exitcode\n";
						$retry--;
					} else {
						# Successfully streamed
						main::logger "INFO: Streaming thread has completed for file $file_tmp\n";
						exit 0;
					}
				}
				main::logger "ERROR: Record thread failed after $retries retries for $file_tmp (renamed to ${file_tmp}.failed)\n";
				move $file_tmp, "${file_tmp}.failed";
				exit 1;
			}
			# Create a hash of process_id => 'count'
			$threadpid{$childpid} = $count;

		# else stream each part in turn
		} else {
			# Child starts here
			main::logger "INFO: Recording file $file_tmp\n";
			# Remove old file
			unlink $file_tmp;
			# Retry loop
			my $retry = $retries;
			my $done = 0;
			while ( $retry && not $done ) {
				my $cmdoutput = `$cmd`;
				my $exitcode = $?;
				main::logger "DEBUG: Command '$cmd', Output:\n$cmdoutput\n\n" if $opt->{debug};
				# Assume file is fully downloaded if > 10MB and we get an error reported !!!
				if ( ( -f $prog->{filename} && stat($prog->{filename})->size < $prog->min_download_size()*10.0 && grep /(read error|connect error|Failed, exiting)/i, $cmdoutput ) || $exitcode ) {
				#if ( grep /(read error|connect error|Failed, exiting)/i, $cmdoutput || $exitcode ) {
					# Failed, retry
					main::logger "DEBUG: Trace of failed command:\n####################\n${cmdoutput}\n####################\n" if $opt->{debug};
					main::logger "WARNING: Failed, retrying to stream $file_tmp, exit code: $exitcode\n";
					$retry--;
				} else {
					# Successfully downloaded
					main::logger "INFO: Streaming has completed to file $file_tmp\n";
					$done = 1;
				}
			} 
			# if the programme part failed after a few retries...
			if (not $done) {
				main::logger "ERROR: Recording failed after $retries retries for $file_tmp (renamed to ${file_tmp}.failed)\n";
				move $file_tmp, "${file_tmp}.failed";
				return 'next';
			}
		} 
	}

	# If doing a threaded streaming, monitor the progress and thread completion
	if ( not $opt->{mmsnothread} ) {
		# Wait for all threads to complete
		$| = 1;
		# Autoreap zombies
		$SIG{CHLD}='IGNORE';
		my $done = 0;
		my $done_symlink;
		while (keys %threadpid) {
			my @sizes;
			my $total_size = 0;
			my $total_size_new = 0;
			my $format = "Threads: ";
			sleep 1;
			#main::logger "DEBUG: ProcessIDs: ".(join ',', keys %threadpid)."\n";
			for my $procid (sort keys %threadpid) {
				my $size = 0;
				# Is this child still alive?
				if ( kill 0 => $procid ) {
					main::logger "DEBUG Thread $threadpid{$procid} still alive ($file_tmp_list[$threadpid{$procid}])\n" if $opt->{debug};
					# Build the status string
					$format .= "%d) %.3fMB   ";
					$size = stat($file_tmp_list[$threadpid{$procid}])->size if -f $file_tmp_list[$threadpid{$procid}];
					push @sizes, $threadpid{$procid}+1, $size/(1024.0*1024.0);
					$total_size_new += $size;
					# Now create a symlink if this is the first part and size > $prog->min_download_size()
					if ( $threadpid{$procid} == 0 && $done_symlink != 1 && $opt->{symlink} && $size > $prog->min_download_size() ) {
						# Symlink to file if only one part or to dir if multi-part
						if ( $#url_list ) {
							$prog->create_symlink( $prog->{symlink}, $prog->{dir} );
						} else {
							$prog->create_symlink( $prog->{symlink}, $file_tmp_list[$threadpid{$procid}] );
						}
						$done_symlink = 1;
					}
				# Thread has completed/failed
				} else {
					$size = stat($file_tmp_list[$threadpid{$procid}])->size if -f $file_tmp_list[$threadpid{$procid}];
					# end marker
					my $end_time = time() + 0.0001;
					# Calculate average speed, duration and total bytes downloaded
					main::logger sprintf("INFO: Thread #%d Recorded %.2fMB in %s at %5.0fkbps to %s\n", 
						($threadpid{$procid}+1),
						$size / (1024.0 * 1024.0),
						sprintf("%02d:%02d:%02d", ( gmtime($end_time - $start_time))[2,1,0] ), 
						$size / ($end_time - $start_time) / 1024.0 * 8.0,
						$file_tmp_list[$threadpid{$procid}] );
					# Remove from thread test list
					delete $threadpid{$procid};
				}
			}
			$format .= " recorded (%.0fkbps)        \r";
			main::logger sprintf $format, @sizes, ($total_size_new - $total_size) / (time() - $start_time) / 1024.0 * 8.0;
		}
		main::logger "INFO: All streaming threads completed\n";	
		# Unset autoreap
		delete $SIG{CHLD};
	}
	# If not all files > min_size then assume streaming failed
	for (@file_tmp_list) {
		# If file doesnt exist or too small then skip
		if ( (! -f $_) || ( -f $_ && stat($_)->size < $prog->min_download_size() ) ) {
			main::logger "ERROR: Recording of programme failed, skipping\n" if $opt->{verbose};
			return 'next';
		}
	}

#	# Retain raw format if required
#	if ( $opt->{raw} ) {
#		# Create symlink to first part file
#		$prog->create_symlink( $prog->{symlink}, $file_tmp_list[0] ) if $opt->{symlink};
#		return 0;
#	}
#
#	# Convert video asf to mp4 if required - need to find a suitable converter...
#	} else {
#		# Create part of cmd that specifies each partial file
#		my $filestring;
#		$filestring .= " -i \"$_\" " for (@file_tmp_list);
#		$cmd = "$bin->{ffmpeg} $binopts->{ffmpeg} $filestring -vcodec copy -acodec copy -f $prog->{ext} -y \"$prog->{filepart}\" 1>&2";
#	}
#
#	main::logger "INFO: Command: $cmd\n\n" if $opt->{verbose};
#	# Run asf conversion and delete source file on success
#	if ( ! system($cmd) ) {
#		unlink( @file_tmp_list );
#	} else {
#		main::logger "ERROR: asf conversion failed - retaining files ".(join ', ', @file_tmp_list)."\n";
#		return 2;
#	}
#	# Moving file into place as complete (if not stdout)
#	move($prog->{filepart}, $prog->{filename}) if ! $opt->{stdout};
#	# Create symlink if required
#	$prog->create_symlink( $prog->{symlink}, $prog->{filename} ) if $opt->{symlink};
	return 0;
}

