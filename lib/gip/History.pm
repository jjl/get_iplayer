package gip::History;

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use strict;

# Class vars
# Global options

# Constructor
# Usage: $hist = gip::History->new();
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	## Ensure the subclass $opt var is pointing to the Superclass global optref
	$opt = $gip::History::optref;
	bless $self, $type;
}


# $opt->{<option>} access method
sub opt {
	my $self = shift;
	my $optname = shift;
	return $opt->{$optname};
}


# Use to bind a new options ref to the class global $opt_ref var
sub add_opt_object {
	my $self = shift;
	$gip::History::optref = shift;
}


# Uses global @history_format
# Adds prog to history file (with a timestamp) so that it is not rerecorded after deletion
sub add {
	my $hist = shift;
	my $prog = shift;

	# Only add if a pid is specified
	return 0 if ! $prog->{pid};
	# Don't add to history if nowrite is used
	return 0 if $opt->{nowrite};

	# Add to history
	if ( ! open(HIST, ">> $historyfile") ) {
		main::logger "ERROR: Cannot write or append to $historyfile\n";
		exit 11;
	}
	# Update timestamp
	$prog->{timeadded} = time();
	# Write each field into a line in the history file
	print HIST $prog->{$_}.'|' for @history_format;
	print HIST "\n";
	close HIST;

	# (re)load whole hist
	# Would be nicer to just add the entry to the history object but this is safer.
	$hist->load();

	return 0;
}



# Uses global @history_format
# returns, for all the pids in the history file, $history->{pid}->{key} = value
sub load {
	my $hist = shift;

	# Return if force option specified or stdout streaming only
	return 0 if ( $opt->{force} && ! $opt->{pid} ) || $opt->{stdout} || $opt->{nowrite};

	# clear first
	$hist->clear();

	main::logger "INFO: Loading recordings history\n" if $opt->{verbose};
	if ( ! open(HIST, "< $historyfile") ) {
		main::logger "WARNING: Cannot read $historyfile\n\n" if $opt->{verbose} && -f $historyfile;
		return 0;
	}

	# Slow. Needs to be faster
	while (<HIST>) {
		chomp();
		# Ignore comments
		next if /^[\#\s]/;
		# Populate %prog_old from cache
		# Get history line
		my @record = split /\|/;
		my $record_entries;
		# Update fields in %history hash for $pid
		for ( @history_format ) {
			$record_entries->{$_} = ( shift @record ) || '';
		}
		# Create new history entry
		if ( defined $hist->{ $record_entries->{pid} } ) {
 			main::logger "WARNING: duplicate pid $record_entries->{pid} in history\n" if $opt->{debug};
			# Append filename and modes - could be a multimode entry
			$hist->{ $record_entries->{pid} }->{mode} .= ','.$record_entries->{mode} if defined $record_entries->{mode};
			$hist->{ $record_entries->{pid} }->{filename} .= ','.$record_entries->{filename} if defined $record_entries->{filename};
			main::logger "DEBUG: Loaded and merged '$record_entries->{pid}' = '$record_entries->{name} - $record_entries->{episode}' from history\n" if $opt->{debug};
		} else {
			# workaround empty names
			#$record_entries->{name} = 'pid:'.$record_entries->{pid} if ! $record_entries->{name};
			$hist->{ $record_entries->{pid} } = gip::History->new();
			$hist->{ $record_entries->{pid} } = $record_entries;
			main::logger "DEBUG: Loaded '$record_entries->{pid}' = '$record_entries->{name} - $record_entries->{episode}' from history\n" if $opt->{debug};
		}
	}
	close (HIST);
	return 0;
}



# Clear the history in %{$hist}
sub clear {
	my $hist = shift;
	# There is probably a faster way
	delete $hist->{$_} for keys %{ $pvr };
	return 0;
}



# Loads hist from file if required
sub conditional_load {
	my $hist = shift;

	# Load if empty
	if ( ! keys %{ $hist } ) {
		main::logger "INFO: Loaded history for first check.\n" if $opt->{verbose};
		$hist->load();
	}
	return 0;
}



# Returns a history pid instance ref
sub get_record {
	my $hist = shift;
	my $pid = shift;
	$hist->conditional_load();
	if ( defined $hist->{$pid} ) {
		return $hist->{$pid};
	}
	return undef;
}



# Returns a list of current history pids
sub get_pids {
	my $hist = shift;
	$hist->conditional_load();
	return keys %{ $hist };
}



# Lists current history items
# Requires a load()
sub list_progs {
	my $hist = shift;
	my $prog = {};
	my ( @search_args ) = ( @_ );

	# Load if empty
	$hist->conditional_load();

	# This is a 'well dirty' hack to allow all the Programme class methods to be used on the history objects
	# Basically involves copying all history objects into prog objects and then calling the required method

	# Sort index by timestamp
	my %index_hist;
	main::sort_index( $hist, \%index_hist, undef, 'timeadded' );

	for my $index ( sort {$a <=> $b} keys %index_hist ) {
		my $record = $index_hist{$index};
		my $progrec;
		if ( not main::is_prog_type( $record->{type} ) ) {
			main::logger "WARNING: Programme type '$record->{type}' does not exist - using generic class\n" if $opt->{debug};
			$progrec = gip::Programme->new();
		} else {
			# instantiate a new Programme object and copy all metadata from this history object into it
			$progrec = main::progclass( $record->{type} )->new();
		}
		for my $key ( keys %{ $record } ) {
			$progrec->{$key} = $record->{$key};
		}
		$prog->{ $progrec->{pid} } = $progrec;
		# CAVEAT: The filename is comma-separated if there is a multimode download. For now just use the first one
		if ( $prog->{ $progrec->{pid} }->{mode} =~ /\w+,\w+/ ) {
			$prog->{ $progrec->{pid} }->{mode} =~ s/,.+$//g;
			$prog->{ $progrec->{pid} }->{filename} =~ s/,.+$//g;
		}
	}

	# Parse remaining args
	my @match_list;
	for ( @search_args ) {
		chomp();

		# If Numerical value < $max_index and the object exists from loaded prog types
		if ( /^[\d]+$/ && $_ <= $max_index ) {
			if ( defined $index_hist{$_} ) {
				main::logger "INFO: Search term '$_' is an Index value\n" if $opt->{verbose};
				push @match_list, $prog->{ $index_hist{$_}->{pid} };
			}

		# If PID then find matching programmes with 'pid:<pid>'
		} elsif ( m{^\s*pid:(.+?)\s*$}i ) {
			if ( defined $prog->{$1} ) {
				main::logger "INFO: Search term '$1' is a pid\n" if $opt->{verbose};
				push @match_list, $prog->{$1};
			} else {
				main::logger "INFO: Search term '$1' is a non-existent pid in the history\n";
			}

		# Else assume this is a programme name regex
		} else {
			main::logger "INFO: Search term '$_' is a substring\n" if $opt->{verbose};
			push @match_list, main::get_regex_matches( $prog, $_ );
		}
	}
	
	# Prune list of history entries with non-existant media files
	if ( $opt->{skipdeleted} ) {
		my @pruned = ();
		for my $this ( @match_list ) {
			# Skip if no filename in history
			if ( defined $this->{filename} && $this->{filename} ) {
				# Skip if the originally recorded file no longer exists
				if ( ! -f $this->{filename} ) {
					main::logger "DEBUG: Skipping metadata/thumbnail - file no longer exists: '$this->{filename}'\n" if $opt->{verbose};
				} else {
					push @pruned, $this;
				}
			}
		}
		@match_list = @pruned;
	}

	# De-dup matches and retain order then list matching programmes in history
	main::list_progs( undef, main::make_array_unique_ordered( @match_list ) );

	return 0;
}



# Generic
# Checks history for previous download of this pid
sub check {
	my $hist = shift;
	my $pid = shift;
	my $mode = shift;
	my $silent = shift;
	return 0 if ! $pid;

	# Return if force option specified or stdout streaming only
	return 0 if $opt->{force} || $opt->{stdout} || $opt->{nowrite};

	# Load if empty
	$hist->conditional_load();

	if ( defined $hist->{ $pid } ) {
		my ( $name, $episode, $histmode ) = ( $hist->{$pid}->{name}, $hist->{$pid}->{episode}, $hist->{$pid}->{mode} );
		main::main::logger "DEBUG: Found PID='$pid' with MODE='$histmode' in history\n" if $opt->{debug};
		if ( $opt->{multimode} ) {
			# Strip any number off the end of the mode names for the comparison
			$mode =~ s/\d+$//g;
			# Check against all modes in the comma separated list
			my @hmodes = split /,/, $histmode;
			for ( @hmodes ) {
				s/\d+$//g;
				if ( $mode eq $_ ) {
					main::logger "INFO: $name - $episode ($pid / $mode) Already in history ($historyfile) - use --force to override\n" if ! $silent;
					return 1;
				}
			}
		} else {
			main::logger "INFO: $name - $episode ($pid) Already in history ($historyfile) - use --force to override\n" if ! $silent;
			return 1;
		}
	}

	main::logger "INFO: Programme not in history\n" if $opt->{verbose} && ! $silent;
	return 0;
}


