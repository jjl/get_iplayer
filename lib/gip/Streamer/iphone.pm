		'bbc_radio_cornwall'			=> 'BBC Cornwall',
		'bbc_radio_guernsey'			=> 'BBC Guernsey',
		'bbc_radio_jersey'			=> 'BBC Jersey',
		'popular/radio'				=> 'Popular',
		'highlights/radio'			=> 'Highlights',
	};
}


# channel ids be found on http://www.bbc.co.uk/bbcone/programmes/schedules/today
sub channels_schedule {
	return {


################### BBC Live Parent class #################


################### Live TV class #################

################### Live Radio class #################

################### Streamer class #################


################### Streamer::iphone class #################
package gip::Streamer::iphone;

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



# Generic
# Get streaming iphone URL
# More iphone stream data http://www.bbc.co.uk/json/stream/b0067vmx/iplayer_streaming_http_mp4?r=585330738351 HTTP/1.1
# Capabilities based on IP address: http://www.bbc.co.uk/mobile/iplayer-mgw/damp/proxytodemi?ip=111.222.333.444
# Category codes list: http://www.bbc.co.uk/mobile/iwiplayer/category_codes.php
sub get_url {
	shift;
	my $ua = shift;
	my $pid = shift;

	# Look for href="http://download.iplayer.bbc.co.uk/iplayer_streaming_http_mp4/5439950172312621205.mp4?token=iVX.lots.of.text.x9Z%2F2GNBdQKl0%3D%0A&amp;pid=b00qhs36"
	my $url;
	my $iphone_download_prefix = 'http://www.bbc.co.uk/mobile/iplayer/episode';
	my $url_0 = ${iphone_download_prefix}.'/'.${pid};
	main::logger "INFO: iphone stream URL = $url_0\n" if $opt->{verbose};
	my $safari_ua = main::create_ua( 'safari' );
	my $html = main::request_url_retry( $safari_ua, $url_0, 3, undef, undef, 1 );
	$html =~ s/\n/ /g;
	# Check for guidance warning
	my $guidance_post;
	$guidance_post = $1 if $html =~ m{(isOver\d+)};
	if ( $guidance_post ) {
		my $h = new HTTP::Headers(
			'User-Agent'		=> main::user_agent( 'coremedia' ),
			'Accept'		=> '*/*',
			'Accept-Language'	=> 'en',
			'Connection'		=> 'keep-alive',
 			'Pragma'		=> 'no-cache',
		);
		main::logger "INFO: Guidance '$guidance_post' Warning Detected\n" if $opt->{verbose};
		# Now post this var and get html again
		my $req = HTTP::Request->new('POST', $url_0, $h);
		$req->content_type('application/x-www-form-urlencoded');
		$req->content('form=guidanceprompt&'.$guidance_post.'=1');
		my $res = $ua->request($req);
		$html = $res->as_string;
	}
	$url = decode_entities($1) if $html =~ m{href="(http.//download\.iplayer\.bbc\.co\.uk/iplayer_streaming_http_mp4.+?)"};
	main::logger "DEBUG: Got iphone mediaselector URL: $url\n" if $opt->{verbose};
	
	if ( ! $url ) {
		main::logger "ERROR: Failed to get iphone URL from iplayer site\n\n";
	}
	return $url;
}



# %prog (only for %prog for mode and tagging)
# Get the h.264/mp3 stream
# ( $ua, $url_2, $prog '0|1 == rearrange moov' )
sub get {
	my ( $stream, $ua, $url_2, $prog ) = @_;
	my $childpid;
	my $rearrange = 0;
	my $iphone_block_size	= 0x2000000; # 32MB

	# Stage 3a: Download 1st byte to get exact file length
	main::logger "INFO: Stage 3 URL = $url_2\n" if $opt->{verbose};

	# Override the $rearrange value is --raw option is specified
	$rearrange = 1 if $prog->{type} eq 'tv' && not $opt->{raw};
	main::logger "DEBUG: Rearrang mov file mode = $rearrange (type: $prog->{type}, raw: $opt->{raw})\n" if $opt->{debug};
		
	# Use url prepend if required
	if ( defined $opt->{proxy} && $opt->{proxy} =~ /^prepend:/ ) {
		$url_2 = $opt->{proxy}.main::url_encode( $url_2 );
		$url_2 =~ s/^prepend://g;
	}

	# Setup request header
	my $h = new HTTP::Headers(
		'User-Agent'	=> main::user_agent( 'coremedia' ),
		'Accept'	=> '*/*',
		'Range'		=> 'bytes=0-1',
	);
	# detect bad url => not available
	if ( $url_2 !~ /^http:\/\// ) {
		main::logger "WARNING: iphone version not available\n";
		return 'next';
	}
	my $req = HTTP::Request->new ('GET', $url_2, $h);
	my $res = $ua->request($req);
	# e.g. Content-Range: bytes 0-1/181338136 (return if no content length returned)
	my $download_len = $res->header("Content-Range");
	if ( ! $download_len ) {
		main::logger "WARNING: iphone version not available\n";
		return 'retry';
	}
	$download_len =~ s|^bytes 0-1/(\d+).*$|$1|;
	main::logger "INFO: Download File Length $download_len\n" if $opt->{verbose};

	# Only do this if we're rearranging QT streams
	my $mdat_start = 0;
	# default to this if we are not rearranging (tells the download chunk loop where to stop - i.e. EOF instead of end of mdat atom)
	my $moov_start = $download_len + 1;
	my $header;
	if ($rearrange) {
		# Get ftyp+wide header etc
		$mdat_start = 0x1c;
		my $buffer = main::download_block(undef, $url_2, $ua, 0, $mdat_start + 4);
		# Get bytes upto (but not including) mdat atom start -> $header
		$header = substr($buffer, 0, $mdat_start);
		
		# Detemine moov start
		# Get mdat_length_chars from downloaded block
		my $mdat_length_chars = substr($buffer, $mdat_start, 4);
		my $mdat_length = bytestring_to_int($mdat_length_chars);
		main::logger "DEBUG: mdat_length = ".main::get_hex($mdat_length_chars)." = $mdat_length\n" if $opt->{debug};
		main::logger "DEBUG: mdat_length (decimal) = $mdat_length\n" if $opt->{debug};
		# The MOOV box starts one byte after MDAT box ends
		$moov_start = $mdat_start + $mdat_length;
	}

	# If we have partial content and wish to stream, resume the recording & spawn off STDOUT from existing file start 
	# Sanity check - we cannot support resuming of partial content if we're streaming also. 
	if ( $opt->{stdout} && (! $opt->{nowrite}) && -f $prog->{filepart} ) {
		main::logger "WARNING: Partially recorded file exists, streaming will start from the beginning of the programme\n";
		# Don't do usual streaming code - also force all messages to go to stderr
		delete $opt->{stdout};
		$opt->{stderr} = 1;
		$childpid = fork();
		if (! $childpid) {
			# Child starts here
			main::logger "INFO: Streaming directly for partially recorded file $prog->{filepart}\n";
			if ( ! open( STREAMIN, "< $prog->{filepart}" ) ) {
				main::logger "INFO: Cannot Read partially recorded file to stream\n";
				exit 4;
			}
			my $outbuf;
			# Write out until we run out of bytes
			my $bytes_read = 65536;
			while ( $bytes_read == 65536 ) {
				$bytes_read = read(STREAMIN, $outbuf, 65536 );
				#main::logger "INFO: Read $bytes_read bytes\n";
				print STDOUT $outbuf;
			}
			close STREAMIN;
			main::logger "INFO: Stream thread has completed\n";
			exit 0;
		}
	}

	# Open file if required
	my $fh = main::open_file_append($prog->{filepart});

	# If the partial file already exists, then resume from the correct mdat/download offset
	my $restart_offset = 0;
	my $moovdata;
	my $moov_length = 0;

	if ($rearrange) {
		# if cookie fails then trigger a retry after deleting cookiejar
		# Determine orginal moov atom length so we can work out if the partially recorded file has the moov atom in it already
		$moov_length = bytestring_to_int( main::download_block( undef, $url_2, $ua, $moov_start, $moov_start+3 ) );
		main::logger "INFO: original moov atom length = $moov_length                          \n" if $opt->{verbose};
		# Sanity check this moov length - chances are that were being served up a duff file if this is > 10% of the file size or < 64k
		if ( $moov_length > (${moov_start}/9.0) || $moov_length < 65536 ) {
			main::logger "WARNING: Bad file recording, deleting cookie                 \n";
			$ua->cookie_jar( HTTP::Cookies->new( file => $cookiejar.'coremedia', autosave => 0, ignore_discard => 0 ) );
			unlink $cookiejar.'coremedia';
			unlink $prog->{filepart};
			return 'retry';
		}

		# we still need an accurate moovlength for the already downloaded moov atom for resume restart_offset.....
		# If we have no existing file, a file which doesn't yet even have the moov atom, or using stdout (or no-write option)
		# (allow extra 1k on moov_length for metadata when testing)
		if ( $opt->{stdout} || $opt->{nowrite} || stat($prog->{filepart})->size < ($moov_length+$mdat_start+1024) ) {
			# get moov chunk into memory
			$moovdata = main::download_block( undef, $url_2, $ua, $moov_start, (${download_len}-1) );
			main::logger "                                                                                                         \r" if $opt->{hash};
			# Create new udta atom with child atoms for metadata
			# Ref: http://atomicparsley.sourceforge.net/mpeg-4files.html
			my $udta_new = create_qt_atom('udta',
				create_qt_atom( chr(0xa9).'nam', $prog->{name}.' - '.$prog->{episode}, 'string' ).
				create_qt_atom( chr(0xa9).'alb', $prog->{name}, 'string' ).
				create_qt_atom( chr(0xa9).'trk', $prog->{episode}, 'string' ).
				create_qt_atom( chr(0xa9).'aut', $prog->{channel}, 'string' ).
				create_qt_atom( chr(0xa9).'ART', $prog->{channel}, 'string' ).
				create_qt_atom( chr(0xa9).'cpy', $prog->{channel}, 'string' ).
				create_qt_atom( chr(0xa9).'des', $prog->{descshort}, 'string' ).
				create_qt_atom( chr(0xa9).'gen', $prog->{categories}, 'string' ).
				create_qt_atom( chr(0xa9).'cmt', 'Recorded using get_iplayer', 'string' ).
				create_qt_atom( chr(0xa9).'req', 'QuickTime 6.0 or greater', 'string' ).
				create_qt_atom( chr(0xa9).'day', substr( $prog->{firstbcast}->{$prog->{version}}, 0, 4 ) || ((localtime())[5] + 1900), 'string' )
			, '' );
			# Insert new udta atom over the old one and get the new $moov_length (and update moov atom size field)
			replace_moov_udta_atom ( $udta_new, $moovdata );

			# Process the moov data so that we can relocate it (change the chunk offsets that are absolute)
			# Also update moov+_length to be accurate after metadata is added etc
			$moov_length = relocate_moov_chunk_offsets( $moovdata );
			main::logger "INFO: New moov atom length = $moov_length                          \n" if $opt->{verbose};
			# write moov atom to file next (yes - were rearranging the file - header+moov+mdat - not header+mdat+moov)
			main::logger "INFO: Appending ftype+wide+moov atoms to $prog->{filepart}\n" if $opt->{verbose};
			# Write header atoms (ftyp, wide)
			print $fh $header if ! $opt->{nowrite};
			print STDOUT $header if $opt->{stdout};
			# Write moov atom
			print $fh $moovdata if ! $opt->{nowrite};
			print STDOUT $moovdata if $opt->{stdout};
			# If were not resuming we want to only start the download chunk loop from mdat_start 
			$restart_offset = $mdat_start;
		}

		# Get accurate moov_length from file (unless stdout or nowrite options are specified)
		# Assume header+moov+mdat atom layout
		if ( (! $opt->{stdout}) && (! $opt->{nowrite}) && stat($prog->{filepart})->size > ($moov_length+$mdat_start) ) {
				main::logger "INFO: Getting moov atom length from partially recorded file $prog->{filepart}\n" if $opt->{verbose};
				if ( ! open( MOOVDATA, "< $prog->{filepart}" ) ) {
					main::logger "ERROR: Cannot Read partially recorded file\n";
					return 'next';
				}
				my $data;
				seek(MOOVDATA, $mdat_start, 0);
				if ( read(MOOVDATA, $data, 4, 0) != 4 ) {
					main::logger "ERROR: Cannot Read moov atom length from partially recorded file\n";
					return 'next';
				}
				close MOOVDATA;
				# Get moov atom size from file
				$moov_length = bytestring_to_int( substr($data, 0, 4) );
				main::logger "INFO: moov atom length (from partially recorded file) = $moov_length                          \n" if $opt->{verbose};
		}
	}

	# If we have a too-small-sized file (greater than moov_length+mdat_start) and not stdout and not no-write then this is a partial recording
	if (-f $prog->{filepart} && (! $opt->{stdout}) && (! $opt->{nowrite}) && stat($prog->{filepart})->size > ($moov_length+$mdat_start) ) {
		# Calculate new start offset (considering that we've put moov first in file)
		$restart_offset = stat($prog->{filepart})->size - $moov_length;
		main::logger "INFO: Resuming recording from $restart_offset                        \n";
	}

	# Not sure if this is already done in download method???
	# Create symlink if required
	$prog->create_symlink( $prog->{symlink}, $prog->{filepart} ) if $opt->{symlink};

	# Start marker
	my $start_time = time();

	# Download mdat in blocks
	my $chunk_size = $iphone_block_size;
	for ( my $s = $restart_offset; $s < ${moov_start}-1; $s+= $chunk_size ) {
		# get mdat chunk into file
		my $retcode;
		my $e;
		# Get block end offset
		if ( ($s + $chunk_size - 1) > (${moov_start}-1) ) {
			$e = $moov_start - 1;
		} else {
			$e = $s + $chunk_size - 1;
		}
		# Get block from URL and append to $prog->{filepart}
		if ( main::download_block($prog->{filepart}, $url_2, $ua, $s, $e, $download_len, $fh ) ) {
			main::logger "\rERROR: Could not download block $s - $e from $prog->{filepart}\n\n";
			return 'retry';
		}
	}

	# Close fh
	close $fh;

	# end marker
	my $end_time = time() + 0.0001;

	# Calculate average speed, duration and total bytes recorded
	main::logger sprintf("\rINFO: Recorded %.2fMB in %s at %5.0fkbps to %s\n", 
		($moov_start - 1 - $restart_offset) / (1024.0 * 1024.0),
		sprintf("%02d:%02d:%02d", ( gmtime($end_time - $start_time))[2,1,0] ), 
		( $moov_start - 1 - $restart_offset ) / ($end_time - $start_time) / 1024.0 * 8.0, 
		$prog->{filename} );

	# Moving file into place as complete (if not stdout)
	move($prog->{filepart}, $prog->{filename}) if $prog->{filepart} ne $prog->{filename} && ! $opt->{stdout};

	# Re-symlink file
	$prog->create_symlink( $prog->{symlink}, $prog->{filename} ) if $opt->{symlink};

	return 0;
}



# Usage: moov_length = relocate_moov_chunk_offsets(<binary string>)
sub relocate_moov_chunk_offsets {
	my $moovdata = $_[0];
	# Change all the chunk offsets in moov->stco atoms and add moov_length to them all
	# get moov atom length - same as length($moovdata)
	my $moov_length = bytestring_to_int( substr($moovdata, 0, 4) );
	# Use index() to search for a string within a string
	my $i = -1;
	while (($i = index($moovdata, 'stco', $i)) > -1) {

		# determine length of atom (4 bytes preceding stco)
		my $stco_len = bytestring_to_int( substr($moovdata, $i-4, 4) );
		main::logger "INFO: Found stco atom at moov atom offset: $i length $stco_len\n" if $opt->{verbose};

		# loop through all chunk offsets in this atom and add offset (== moov atom length)
		for (my $j = $i+12; $j < $stco_len+$i-4; $j+=4) {
			my $chunk_offset = bytestring_to_int( substr($moovdata, $j, 4) );
			$chunk_offset += $moov_length;
			# write back bytes into $moovdata
			write_msb_value_at_offset( $moovdata, $j, $chunk_offset );
		}
		# skip over this whole atom now it is processed
		$i += $stco_len;
	}
	# Write $moovdata back to calling string
	$_[0] = $moovdata;
	return $moov_length;
}



# Replace the moov->udta atom with a new user-supplied one and update the moov atom size
# Usage: replace_moov_udta_atom ( $udta_new, $moovdata )
sub replace_moov_udta_atom {
	my $udta_new = $_[0];
	my $moovdata = $_[1];

	# get moov atom length
	my $moov_length = bytestring_to_int( substr($moovdata, 0, 4) );

	# Find the original udta atom start 
	# Use index() to search for a string within a string ($i will point at the beginning of the atom)
	my $i = index($moovdata, 'udta', -1) - 4;

	# determine length of old atom (4 bytes preceding the name)
	my $udta_old_len = bytestring_to_int( substr($moovdata, $i, 4) );
	main::logger "INFO: Found udta atom at moov atom offset: $i length $udta_old_len\n" if $opt->{verbose};

	# Save the data before the udta atom
	my $moovdata_before_udta = substr($moovdata, 0, $i);

	# Save the remainder portion of data after the udta atom for later
	my $udta_new_len = length( $udta_new );
	my $moovdata_after_udta = substr($moovdata, $i, $moov_length - ( $i + $udta_new_len ) );

	# Old udta atom should we need it
	### my $udta_old = substr($moovdata, $i, $udta_len);

	# Create new moov atom
	$moovdata = $moovdata_before_udta.$udta_new.$moovdata_after_udta;
	main::logger "INFO: Inserted new udta atom at moov atom offset: $i length $udta_new_len\n" if $opt->{verbose};

	# Recalculate the moov size and insert into moovdata
	write_msb_value_at_offset( $moovdata, 0, length($moovdata) );
	
	# Write $moovdata back to calling string
	$_[1] = $moovdata;

	return 0;
}



# Converts a string of chars to it's MSB decimal value
sub bytestring_to_int {
	# Reverse to LSB order
        my $buf = reverse shift;
        my $dec = 0;
        for (my $i=0; $i<length($buf); $i++) {
		# Multiply byte value by 256^$i then accumulate
                $dec += (ord substr($buf, $i, 1)) * 256 ** $i;
        }
        #main::logger "DEBUG: Decimal value = $dec\n" if $opt->{verbose};
        return $dec;
}



# Write the msb 4 byte $value starting at $offset into the passed string
# Usage: write_msb_value($string, $offset, $value)
sub write_msb_value_at_offset {
	my $offset = $_[1];
	my $value = $_[2];
	substr($_[0], $offset+0, 1) = chr( ($value >> 24) & 0xFF );
	substr($_[0], $offset+1, 1) = chr( ($value >> 16) & 0xFF );
	substr($_[0], $offset+2, 1) = chr( ($value >>  8) & 0xFF );
	substr($_[0], $offset+3, 1) = chr( ($value >>  0) & 0xFF );
	return 0;
}



# Returns a string containing an QT atom
# Usage: create_qt_atom(<atome name>, <atom data>, ['string'])
sub create_qt_atom {
	my ($name, $data, $prog_type) = (@_);
	if (length($name) != 4) {
		main::logger "ERROR: Inavlid QT atom name length '$name'\n";
		exit 1;
	}
	# prepend string length if this is a string type
	if ( defined $prog_type && $prog_type eq 'string' ) {
		my $value = length($data);
		$data = '1111'.$data;
		# overwrite '1111' with total atom length in 2-byte MSB + 0x0 0x0
		substr($data, 0, 1) = chr( ($value >> 8) & 0xFF );
		substr($data, 1, 1) = chr( ($value >> 0) & 0xFF );
		substr($data, 2, 1) = chr(0);
		substr($data, 3, 1) = chr(0);
	}
	my $atom = '0000'.$name.$data;
	# overwrite '0000' with total atom length in MSB
	write_msb_value_at_offset( $atom, 0, length($name.$data) + 4 );
	return $atom;
}

