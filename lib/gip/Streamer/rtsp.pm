package gip::Streamer::rtsp;

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


# %prog (only for lame id3 tagging and {mode})
# Actually do the rtsp streaming
sub get {
	my ( $stream, $ua, $url, $prog ) = @_;
	my $childpid;

	# get bandwidth options value
	# Download bandwidth bps used for rtsp streams
	my $bandwidth = $opt->{bandwidth} || 512000;

	# Parse/recurse playlist if required to get mms url
	$url = main::get_playlist_url( $ua, $url, 'rtsp' );

	# Add stop and start if defined
	# append: ?start=5400&end=7400 or &start=5400&end=7400
	if ( $opt->{start} || $opt->{stop} ) {
		# Make sure we add the correct separator for adding to the rtsp url
		my $prefix_char = '?';
		$prefix_char = '&' if $url =~ m/\?.+/;
		if ( $opt->{start} && $opt->{stop} ) {
			$url .= "${prefix_char}start=$opt->{start}&end=$opt->{stop}";
		} elsif ( $opt->{start} && not $opt->{stop} ) {
			$url .= "${prefix_char}start=$opt->{start}";
		} elsif ( $opt->{stop} && not $opt->{start} ) {
			$url .= "${prefix_char}end=$opt->{stop}";
		}
	}
	
	# Create named pipe
	if ( $^O !~ /^MSWin32$/ ) {
		mkfifo($namedpipe, 0700);
	} else {
		main::logger "WARNING: fifos/named pipes are not supported - only limited output modes will be supported\n";
	}
	
	main::logger "INFO: RTSP URL = $url\n" if $opt->{verbose};

	# Create ID3 tagging options for lame (escape " for shell)
	my ( $id3_name, $id3_episode, $id3_desc, $id3_channel ) = ( $prog->{name}, $prog->{episode}, $prog->{desc}, $prog->{channel} );
	s|"|\\"|g for ($id3_name, $id3_episode, $id3_desc, $id3_channel);
	$binopts->{lame} .= " --ignore-tag-errors --ty ".( (localtime())[5] + 1900 )." --tl \"$id3_name\" --tt \"$id3_episode\" --ta \"$id3_channel\" --tc \"$id3_desc\" ";

	# Use post-streaming transcoding using lame if namedpipes are not supported (i.e. ActivePerl/Windows)
	# (Fallback if no namedpipe support and raw/wav not specified)
	if ( ( ! -p $namedpipe ) && ! ( $opt->{raw} || $opt->{wav} ) ) {
			my @cmd;
			# Remove filename extension
			$prog->{filepart} =~ s/\.mp3$//gi;
			# Remove named pipe
			unlink $namedpipe;
			main::logger "INFO: Recording wav format (followed by transcoding)\n";
			my $wavfile = "$prog->{filepart}.wav";
			# Strip off any leading drivename in win32 - mplayer doesn't like this for pcm output files
			$wavfile =~ s|^[a-zA-Z]:||g;
			@cmd = (
				$bin->{mplayer},
				@{ $binopts->{mplayer} },
				'-cache', 128,
				'-bandwidth', $bandwidth,
				'-vc', 'null',
				'-vo', 'null',
				'-ao', "pcm:waveheader:fast:file=\"$wavfile\"",
				$url,
			);
			# Create symlink if required
			$prog->create_symlink( $prog->{symlink}, "$prog->{filepart}.wav" ) if $opt->{symlink};
			if ( main::run_cmd( 'STDERR', @cmd ) ) {
				unlink $prog->{symlink};
				return 'next';
			}
			# Transcode
			main::logger "INFO: Transcoding $prog->{filepart}.wav\n";
			my $cmd = "$bin->{lame} $binopts->{lame} \"$prog->{filepart}.wav\" \"$prog->{filepart}.mp3\" 1>&2";
			main::logger "DEGUG: Running $cmd\n" if $opt->{debug};
			# Create symlink if required
			$prog->create_symlink( $prog->{symlink}, "$prog->{filepart}.mp3" ) if $opt->{symlink};		
			if ( system($cmd) || (-f "$prog->{filepart}.wav" && stat("$prog->{filepart}.wav")->size < $prog->min_download_size()) ) {
				unlink $prog->{symlink};
				return 'next';
			}
			unlink "$prog->{filepart}.wav";
			move "$prog->{filepart}.mp3", $prog->{filename};
			$prog->{ext} = 'mp3';
		
	} elsif ( $opt->{wav} && ! $opt->{stdout} ) {
		main::logger "INFO: Writing wav format\n";
		my $wavfile = $prog->{filepart};
		# Strip off any leading drivename in win32 - mplayer doesn't like this for pcm output files
		$wavfile =~ s|^[a-zA-Z]:||g;
		# Start the mplayer process and write to wav file
		my @cmd = (
			$bin->{mplayer},
			@{ $binopts->{mplayer} },
			'-cache', 128,
			'-bandwidth', $bandwidth,
			'-vc', 'null',
			'-vo', 'null',
			'-ao', "pcm:waveheader:fast:file=\"$wavfile\"",
			$url,
		);
		# Create symlink if required
		$prog->create_symlink( $prog->{symlink}, $prog->{filepart} ) if $opt->{symlink};		
		if ( main::run_cmd( 'STDERR', @cmd ) ) {
			unlink $prog->{symlink};
			return 'next';
		}
		# Move file to done state
		move $prog->{filepart}, $prog->{filename} if $prog->{filepart} ne $prog->{filename} && ! $opt->{nowrite};

	# No transcoding if --raw was specified
	} elsif ( $opt->{raw} && ! $opt->{stdout} ) {
		# Write out to .ra ext instead (used on fallback if no fifo support)
		main::logger "INFO: Writing raw realaudio stream\n";
		# Start the mplayer process and write to raw file
		my @cmd = (
			$bin->{mplayer},
			@{ $binopts->{mplayer} },
			'-cache', 128,
			'-bandwidth', $bandwidth,
			'-dumpstream',
			'-dumpfile', $prog->{filepart},
			$url,
		);
		# Create symlink if required
		$prog->create_symlink( $prog->{symlink}, $prog->{filepart} ) if $opt->{symlink};		
		if ( main::run_cmd( 'STDERR', @cmd ) ) {
			unlink $prog->{symlink};
			return 'next';
		}
		# Move file to done state
		move $prog->{filepart}, $prog->{filename} if $prog->{filepart} ne $prog->{filename} && ! $opt->{nowrite};

	# Fork a child to do transcoding on the fly using a named pipe written to by mplayer
	# Use transcoding via named pipes
	} elsif ( -p $namedpipe )  {
		$childpid = fork();
		if (! $childpid) {
			# Child starts here
			$| = 1;
			main::logger "INFO: Transcoding $prog->{filepart}\n";

			# Stream mp3 to file and stdout simultaneously
			if ( $opt->{stdout} && ! $opt->{nowrite} ) {
				# Create symlink if required
				$prog->create_symlink( $prog->{symlink}, $prog->{filepart} ) if $opt->{symlink};
				if ( $opt->{wav} || $opt->{raw} ) {
					# Race condition - closes named pipe immediately unless we wait
					sleep 5;
					# Create symlink if required
					$prog->create_symlink( $prog->{symlink}, $prog->{filepart} ) if $opt->{symlink};
					main::tee($namedpipe, $prog->{filepart});
					#system( "cat $namedpipe 2>/dev/null| $bin->{tee} $prog->{filepart}");
				} else {
					my $cmd = "$bin->{lame} $binopts->{lame} \"$namedpipe\" - 2>/dev/null| $bin->{tee} \"$prog->{filepart}\"";
					main::logger "DEGUG: Running $cmd\n" if $opt->{debug};
					# Create symlink if required
					$prog->create_symlink( $prog->{symlink}, $prog->{filepart} ) if $opt->{symlink};
					system($cmd);
				}

			# Stream mp3 stdout only
			} elsif ( $opt->{stdout} && $opt->{nowrite} ) {
				if ( $opt->{wav} || $opt->{raw} ) {
					sleep 5;
					main::tee($namedpipe);
					#system( "cat $namedpipe 2>/dev/null");
				} else {
					my $cmd = "$bin->{lame} $binopts->{lame} \"$namedpipe\" - 2>/dev/null";
					main::logger "DEGUG: Running $cmd\n" if $opt->{debug};
					system( "$bin->{lame} $binopts->{lame} \"$namedpipe\" - 2>/dev/null");
				}

			# Stream mp3 to file directly
			} elsif ( ! $opt->{stdout} ) {
				my $cmd = "$bin->{lame} $binopts->{lame} \"$namedpipe\" \"$prog->{filepart}\" >/dev/null 2>/dev/null";
				main::logger "DEGUG: Running $cmd\n" if $opt->{debug};
				# Create symlink if required
				$prog->create_symlink( $prog->{symlink}, $prog->{filepart} ) if $opt->{symlink};
				system($cmd);
			}
			# Remove named pipe
			unlink $namedpipe;

			# Move file to done state
			move $prog->{filepart}, $prog->{filename} if $prog->{filepart} ne $prog->{filename} && ! $opt->{nowrite};
			main::logger "INFO: Transcoding thread has completed\n";
			# Re-symlink if required
			$prog->create_symlink( $prog->{symlink}, $prog->{filename} ) if $opt->{symlink};
			exit 0;
		}
		# Start the mplayer process and write to named pipe
		# Raw mode
		if ( $opt->{raw} ) {
			my @cmd = (
				$bin->{mplayer},
				@{ $binopts->{mplayer} },
				'-cache', 32,
				'-bandwidth', $bandwidth,
				'-dumpstream',
				'-dumpfile', $namedpipe,
				$url,
			);
			if ( main::run_cmd( 'STDERR', @cmd ) ) {
				# If we fail then kill off child processes
				kill 9, $childpid;
				unlink $prog->{symlink};
				return 'next';
			}
		# WAV / mp3 mode - seems to fail....
		} else {
			my @cmd = (
				$bin->{mplayer},
				@{ $binopts->{mplayer} },
				'-cache', 128,
				'-bandwidth', $bandwidth,
				'-vc', 'null',
				'-vo', 'null',
				'-ao', "pcm:waveheader:fast:file=$namedpipe",
				$url,
			);
			if ( main::run_cmd( 'STDERR', @cmd ) ) {
				# If we fail then kill off child processes
				kill 9, $childpid;
				unlink $prog->{symlink};
				return 'next';
			}
		}
		# Wait for child processes to prevent zombies
		wait;

		unlink $namedpipe;
	} else {
		main::logger "ERROR: Unsupported method of download on this platform\n";
		return 'next';
	}

	main::logger "INFO: Recorded $prog->{filename}\n";
	# Re-symlink if required
	$prog->create_symlink( $prog->{symlink}, $prog->{filename} ) if $opt->{symlink};

	return 0;
}


