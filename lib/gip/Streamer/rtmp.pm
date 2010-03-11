package Streamer::rtmp;

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


sub opt_format {
	return {
		ffmpeg		=> [ 0, "ffmpeg=s", 'External Program', '--ffmpeg <path>', "Location of ffmpeg binary"],
		rtmpport	=> [ 1, "rtmpport=n", 'Recording', '--rtmpport <port>', "Override the RTMP port (e.g. 443)"],
		flvstreamer	=> [ 0, "flvstreamer|rtmpdump=s", 'External Program', '--flvstreamer <path>', "Location of flvstreamer/rtmpdump binary"],
	};
}


# %prog (only for {ext} and {mode})
# Actually do the RTMP streaming
sub get {
	my ( $stream, undef, undef, $prog, %streamdata ) = @_;
	my @cmdopts;

	my $url_2 	= $streamdata{streamurl};
	my $server	= $streamdata{server};
	my $application = $streamdata{application};
	my $tcurl 	= $streamdata{tcurl};
	my $authstring 	= $streamdata{authstring};
	my $swfurl 	= $streamdata{swfurl};
	my $playpath 	= $streamdata{playpath};
	my $port 	= $streamdata{port} || $opt->{rtmpport} || 1935;
	my $protocol	= $streamdata{protocol} || 0;
	my $mode	= $prog->{mode};
	push @cmdopts, ( split /\s+/, $streamdata{extraopts} ) if $streamdata{extraopts};

	my $file_tmp;
	my @cmd;
	
	if ( $opt->{raw} ) {
		$file_tmp = $prog->{filepart};
	} else {
		$file_tmp = $prog->{filepart}.'.flv'
	}

	# Remove failed file recording (below a certain size) - hack to get around flvstreamer/rtmpdump not returning correct exit code
	if ( -f $file_tmp && stat($file_tmp)->size < $prog->min_download_size() ) {
		unlink( $file_tmp );
	}
		
	# Add custom options to flvstreamer/rtmpdump for this type if specified with --rtmp-<type>-opts
	if ( defined $opt->{'rtmp'.$prog->{type}.'opts'} ) {
		push @cmdopts, ( split /\s+/, $opt->{'rtmp'.$prog->{type}.'opts'} );
	}

	# rtmpdump/flvstreamer version detection e.g. 'RTMPDump v1.5', 'FLVStreamer v1.7a', 'RTMPDump 2.1b'
	my $rtmpver;
	chomp( $rtmpver = (grep /^(RTMPDump|FLVStreamer)/i, `"$bin->{flvstreamer}" 2>&1`)[0] );
	$rtmpver =~ s/^\w+\s+v?([\.\d]+).*$/$1/g;
	main::logger "INFO: $bin->{flvstreamer} version $rtmpver\n" if $opt->{verbose};
	main::logger "INFO: RTMP_URL: $url_2, tcUrl: $tcurl, application: $application, authString: $authstring, swfUrl: $swfurl, file: $prog->{filepart}, file_done: $prog->{filename}\n" if $opt->{verbose};

	# Save the effort and don't support < v1.5
	if ( $rtmpver < 1.5 ) {
		main::logger "WARNING: rtmpdump >= 1.5 or flvstreamer is required - please upgrade\n";
		return 'next';
	}

	# Add --live option if required
	if ( $streamdata{live} ) {
		if ( $rtmpver < 1.8 ) {
			main::logger "WARNING: Please use flvstreamer v1.8 or later for more reliable live streaming\n";
		}
		push @cmdopts, '--live';
	}

	# Add start stop options if defined
	if ( $opt->{start} || $opt->{stop} ) {
		if ( $rtmpver < 1.8 ) {
			main::logger "ERROR: Please use flvstreamer v1.8c or later for start/stop features\n";
			exit 4;
		}
		push @cmdopts, ( '--start', $opt->{start} ) if $opt->{start};
		push @cmdopts, ( '--stop', $opt->{stop} ) if $opt->{stop};
	}
	
	# Add hashes option if required
	push @cmdopts, '--hashes' if $opt->{hash};
	
	# Create symlink if required
	$prog->create_symlink( $prog->{symlink}, $file_tmp ) if $opt->{symlink};

	# Deal with stdout streaming
	if ( $opt->{stdout} && not $opt->{nowrite} ) {
		main::logger "ERROR: Cannot stream RTMP to STDOUT and file simultaneously\n";
		exit 4;
	}
	if ( $opt->{stdout} && $opt->{nowrite} ) {
		if ( $rtmpver < 1.7) {
			push @cmdopts, ( '-o', '-' );
		}
	} else {
		push @cmdopts, ( '--resume', '-o', $file_tmp );
	}
	push @cmdopts, @{ $binopts->{flvstreamer} } if $binopts->{flvstreamer};
	
	my $return;
	# Different invocation depending on version
	# if playpath is defined
	if ( $playpath ) {
		@cmd = (
			$bin->{flvstreamer},
			'--port', $port,
			'--protocol', $protocol,
			'--playpath', $playpath,
			'--host', $server,
			'--swfUrl', $swfurl,
			'--tcUrl', $tcurl,
			'--app', $application,
			@cmdopts,
		);
	# Using just streamurl (i.e. no playpath defined)
	} else {
		@cmd = (
			$bin->{flvstreamer},
			'--port', $port,
			'--protocol', $protocol,
			'--rtmp', $streamdata{streamurl},
			@cmdopts,
		);
	}

	$return = main::run_cmd( 'normal', @cmd );

	# exit behaviour when streaming
	if ( $opt->{nowrite} && $opt->{stdout} ) {
		if ( $return == 0 ) {
			main::logger "\nINFO: Streaming completed successfully\n";
			return 0;
		} else {
			main::logger "\nINFO: Streaming failed with exit code $return\n";
			return 'abort';
		}
	}

	# if we fail during the rtmp streaming, try to resume (this gets new streamdata again so that it isn't stale)
	return 'retry' if $return && -f $file_tmp && stat($file_tmp)->size > $prog->min_download_size();

	# If file is too small or non-existent then delete and try next mode
	if ( (! -f $file_tmp) || ( -f $file_tmp && stat($file_tmp)->size < $prog->min_download_size()) ) {
		main::logger "WARNING: Failed to stream file $file_tmp via RTMP\n";
		unlink $file_tmp;
		return 'next';
	}
	
	# Retain raw flv format if required
	if ( $opt->{raw} ) {
		move($file_tmp, $prog->{filename}) if $file_tmp ne $prog->{filename} && ! $opt->{stdout};
		return 0;

	# Convert flv to mp3/aac
	} elsif ( $mode =~ /^flashaudio/ ) {
		# We could do id3 tagging here with ffmpeg but id3v2 does this later anyway
		# This fails
		# $cmd = "$bin->{ffmpeg} -i \"$file_tmp\" -vn -acodec copy -y \"$prog->{filepart}\" 1>&2";
		# This works but it's really bad bacause it re-transcodes mp3 and takes forever :-(
		# $cmd = "$bin->{ffmpeg} -i \"$file_tmp\" -acodec libmp3lame -ac 2 -ab 128k -vn -y \"$prog->{filepart}\" 1>&2";
		# At last this removes the flv container and dumps the mp3 stream! - mplayer dumps core but apparently succeeds
		@cmd = (
			$bin->{mplayer},
			@{ $binopts->{mplayer} },
			'-dumpaudio',
			$file_tmp,
			'-dumpfile', $prog->{filepart},
		);
	# Convert flv to aac/mp4a
	} elsif ( $mode =~ /flashaac/ ) {
		# This works as long as we specify aac and not mp4a
		@cmd = (
			$bin->{ffmpeg},
			'-i', $file_tmp,
			'-vn',
			'-acodec', 'copy',
			'-y', $prog->{filepart},
		);
	# Convert video flv to mp4/avi if required
	} else {
		@cmd = (
			$bin->{ffmpeg},
			'-i', $file_tmp,
			'-vcodec', 'copy',
			'-acodec', 'copy',
			'-f', $prog->{ext},
			'-y', $prog->{filepart},
		);
	}


	# Run flv conversion and delete source file on success
	my $return = main::run_cmd( 'STDERR', @cmd );
	if ( (! $return) && -f $prog->{filepart} && stat($prog->{filepart})->size > $prog->min_download_size() ) {
			unlink( $file_tmp );

	# If the ffmpeg conversion failed, remove the failed-converted file attempt - move the file as done anyway
	} else {
		main::logger "WARNING: flv conversion failed - retaining flv file\n";
		unlink $prog->{filepart};
		$prog->{filepart} = $file_tmp;
		$prog->{filename} = $file_tmp;
	}
	# Moving file into place as complete (if not stdout)
	move($prog->{filepart}, $prog->{filename}) if $prog->{filepart} ne $prog->{filename} && ! $opt->{stdout};
	
	# Re-symlink file
	$prog->create_symlink( $prog->{symlink}, $prog->{filename} ) if $opt->{symlink};

	main::logger "INFO: Recorded $prog->{filename}\n";
	return 0;
}

