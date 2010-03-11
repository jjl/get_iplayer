package gip::PVR;

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use IO::Seekable;
use IO::Socket;
use strict;
use Time::Local;

# Class vars
my %vars = {};
# Global options
my $optref;
my $opt_fileref;
my $opt_cmdlineref;
my $opt;
my $opt_file;
my $opt_cmdline;

# Class cmdline Options
sub opt_format {
	return {
		pvr		=> [ 0, "pvr|pvrrun|pvr-run!", 'PVR', '--pvr [pvr search name]', "Runs the PVR using all saved PVR searches (intended to be run every hour from cron etc). The list can be limited by adding a regex to the command."],
		pvrexclude	=> [ 0, "pvrexclude|pvr-exclude=s", 'PVR', '--pvr-exclude <string>', "Exclude the PVR searches to run by seacrh name (regex or comma separated values)"],
		pvrsingle	=> [ 0, "pvrsingle|pvr-single=s", 'PVR', '--pvr-single <search name>', "Runs a named PVR search"],
		pvradd		=> [ 0, "pvradd|pvr-add=s", 'PVR', '--pvradd <search name>', "Save the named PVR search with the specified search terms"],
		pvrdel		=> [ 0, "pvrdel|pvr-del=s", 'PVR', '--pvrdel <search name>', "Remove the named search from the PVR searches"],
		pvrdisable	=> [ 1, "pvrdisable|pvr-disable=s", 'PVR', '--pvr-disable <search name>', "Disable (not delete) a named PVR search"],
		pvrenable	=> [ 1, "pvrenable|pvr-enable=s", 'PVR', '--pvr-enable <search name>', "Enable a previously disabled named PVR search"],
		pvrlist		=> [ 0, "pvrlist|pvr-list!", 'PVR', '--pvrlist', "Show the PVR search list"],
		pvrqueue	=> [ 0, "pvrqueue|pvr-queue!", 'PVR', '--pvrqueue', "Add currently matched programmes to queue for later one-off recording using the --pvr option"],
		pvrscheduler	=> [ 0, "pvrscheduler|pvr-scheduler=n", 'PVR', '--pvrscheduler <seconds>', "Runs the PVR using all saved PVR searches every <seconds>"],
		comment		=> [ 1, "comment=s", 'PVR', '--comment <string>', "Adds a comment to a PVR search"],
	};
}


# Constructor
# Usage: $pvr = gip::PVR->new();
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	## Ensure the subclass $opt var is pointing to the Superclass global optref
	$opt = $gip::PVR::optref;
	$opt_file = $gip::PVR::opt_fileref;
	$opt_cmdline = $gip::PVR::opt_cmdlineref;
	bless $self, $type;
}


# Use to bind a new options ref to the class global $opt_ref var
sub add_opt_object {
	my $self = shift;
	$gip::PVR::optref = shift;
}
# Use to bind a new options ref to the class global $opt_fileref var
sub add_opt_file_object {
	my $self = shift;
	$gip::PVR::opt_fileref = shift;
}
# Use to bind a new options ref to the class global $opt_cmdlineref var
sub add_opt_cmdline_object {
	my $self = shift;
	$gip::PVR::opt_cmdlineref = shift;
}


# Use to bind a new options ref to the class global $optref var
sub setvar {
	my $self = shift;
	my $varname = shift;
	my $value = shift;
	$vars{$varname} = $value;
}
sub getvar {
	my $self = shift;
	my $varname = shift;
	return $vars{$varname};
}


# $opt->{<option>} access method
sub opt {
	my $self = shift;
	my $optname = shift;
	return $opt->{$optname};
}


# Load all PVR searches and run one-by-one
# Usage: $pvr->run( [pvr search name] )
sub run {
	my $pvr = shift;
	my $pvr_name_regex = shift || '.*';
	my $exclude_regex = '_ROUGE_VALUE_';

	# Don't attempt to record programmes with pids in history
	my $hist = History->new();

	# Load all PVR searches
	$pvr->load_list();

	if ( $opt->{pvrexclude} ) {
		$exclude_regex = '('.(join '|', ( split /,/, $opt->{pvrexclude} ) ).')';
	}

	# For each PVR search (or single one if specified)
	my @names = ( grep !/$exclude_regex/i, grep /$pvr_name_regex/i, sort {lc $a cmp lc $b} keys %{$pvr} );

	main::logger "Running PVR Searches:\n";
	for my $name ( @names ) {
		# Ignore if this search is disabled
		if ( $pvr->{$name}->{disable} ) {
			main::logger "\nSkipping '$name' (disabled)\n" if $opt->{verbose};
			next;
		}
		main::logger "$name\n";
		# Clear then Load options for specified pvr search name
		my @search_args = $pvr->load_options($name);

		## Display all options used for this pvr search
		#$opt->display('Default Options', '(help|debug|get|^pvr)');

		# Switch on --hide option
		$opt->{hide} = 1;
		# Switch off --future option (no point in checking future programmes)
		$opt->{future} = '';
		# Dont allow --refresh with --pvr
		$opt->{refresh} = '';
		# Do the recording (force --get option)
		$opt->{get} = 1 if ! $opt->{test};

		# If this is a one-off queue pid entry then delete the PVR entry upon successful recording(s)
		if ( $pvr->{$name}->{pid} && $name =~ /^ONCE_/ ) {
			my $failcount = main::find_pid_matches( $hist );
			$pvr->del( $name ) if not $failcount;

		# Just make recordings of matching progs
		} else {
			main::download_matches( $hist, main::find_matches( $hist, @search_args ) );
		}
	}
}



sub run_scheduler {
	my $pvr = shift;
	my $interval = $opt->{pvrscheduler};
	# Ensure the caches refresh every run (assume cache refreshes take at most 300 seconds)
	$opt_cmdline->{expiry} = $interval - 300;
	main::logger "INFO: Scheduling the PVR to run every $interval secs\n";
	while ( 1 ) {
		my $start_time = time();
		$opt_cmdline->{pvr} = 1;
		$pvr->run();
		my $remaining = $interval - ( time() - $start_time );
		if ( $remaining > 0 ) {
			main::logger "INFO: Sleeping for $remaining secs\n";
			sleep $remaining;
		}
	}
}



# If queuing, only add pids because the index number might change by the time the pvr runs
# If --pid and --type <type> is specified then add this prog also
sub queue {
	my $pvr = shift;
	my @search_args = @_;

	# Switch on --hide option
	$opt->{hide} = 1;
	# Switch on --future option - we want to search upcoming programmes
	$opt->{future} = 1;
	my $hist = History->new();

	# PID and TYPE specified
	if ( $opt_cmdline->{pid} ) {
		# ensure we only have one prog type defined
		if ( $opt->{type} && $opt->{type} !~ /,/ ) {
			# Add to PVR if not already in history (unless multimode specified)
			$pvr->add( "ONCE_$opt_cmdline->{pid}" ) if ( ! $hist->check( $opt_cmdline->{pid} ) ) || $opt->{multimode};
		} else {
			main::logger "ERROR: Cannot add a pid to the PVR queue without a single --type specified\n";
			return 1;
		}

	# Search specified
	} else {
		my @matches = main::find_matches( $hist, @search_args );
		# Add a PVR entry for each matching prog PID
		for my $this ( @matches ) {
			$opt_cmdline->{pid} = $this->{pid};
			$opt_cmdline->{type} = $this->{type};
			$pvr->add( $this->substitute('ONCE_<name> - <episode> <pid>') );
		}

	}
	return 0;
}



# Save the options on the cmdline as a PVR search with the specified name
sub add {
	my $pvr = shift;
	my $name = shift;
	my @search_args = @_;
	my @options;
	# validate name
	if ( $name !~ m{[\w\-\+]+} ) {
		main::logger "ERROR: Invalid PVR search name '$name'\n";
		return 1;
	}
	# Parse valid options and create array (ignore options from the options files that have not been overriden on the cmdline)
	for ( grep !/(webrequest|future|nocopyright|^test|metadataonly|subsonly|thumbonly|stdout|^get|update|^save|^prefs|help|expiry|nowrite|tree|terse|streaminfo|listformat|^list|showoptions|hide|info|pvr.*)$/, sort {lc $a cmp lc $b} keys %{$opt_cmdline} ) {
		if ( defined $opt_cmdline->{$_} ) {
				push @options, "$_ $opt_cmdline->{$_}";
				main::logger "DEBUG: Adding option $_ = $opt_cmdline->{$_}\n" if $opt->{debug};
		}
	}
	# Add search args to array
	for ( my $count = 0; $count <= $#search_args; $count++ ) {
		push @options, "search${count} $search_args[$count]";
		main::logger "DEBUG: Adding search${count} = $search_args[$count]\n" if $opt->{debug};
	}
	# Save search to file
	$pvr->save( $name, @options );
	return 0;
}



# Delete the named PVR search
sub del {
	my $pvr = shift;
	my $name = shift;
	# validate name
	if ( $name !~ m{[\w\-\+]+} ) {
		main::logger "ERROR: Invalid PVR search name '$name'\n";
		return 1;
	}
	# Delete pvr search file
	if ( -f $vars{pvr_dir}.$name ) {
		unlink $vars{pvr_dir}.$name;
		main::logger "INFO: Deleted PVR search '$name'\n";
	} else {
		main::logger "ERROR: PVR search '$name' does not exist\n";
		return 1;
	}
	return 0;
}



# Display all the PVR searches
sub display_list {
	my $pvr = shift;
	# Load all the PVR searches
	$pvr->load_list();
	# Print out list
	main::logger "All PVR Searches:\n\n";
	for my $name ( sort {lc $a cmp lc $b} keys %{$pvr} ) {
		# Report whether disabled
		if ( $pvr->{$name}->{disable} ) {
			main::logger "pvrsearch = $name (disabled)\n";
		} else {
			main::logger "pvrsearch = $name\n";
		}
		for ( sort keys %{ $pvr->{$name} } ) {
			main::logger "\t$_ = $pvr->{$name}->{$_}\n";
		}
		main::logger "\n";
	}
	return 0;
}



# Load all the PVR searches into %{$pvr}
sub load_list {
	my $pvr = shift;
	# Clear any previous data in $pvr
	$pvr->clear_list();
	# Make dir if not existing
	mkpath $vars{pvr_dir} if ! -d $vars{pvr_dir};
	# Get list of files in pvr_dir
	# open file with handle DIR
	opendir( DIR, $vars{pvr_dir} );
	if ( ! opendir( DIR, $vars{pvr_dir}) ) {
		main::logger "ERROR: Cannot open directory $vars{pvr_dir}\n";
		return 1;
	}
	# Get contents of directory (ignoring . .. and ~ files)
	my @files = grep ! /(^\.{1,2}$|^.*~$)/, readdir DIR;
	# Close the directory
	closedir DIR;
	# process each file
	for my $file (@files) {
		chomp($file);
		# Re-add the dir
		$file = "$vars{pvr_dir}/$file";
		next if ! -f $file;
		if ( ! open (PVR, "< $file") ) {
			main::logger "WARNING: Cannot read PVR search file $file\n";
			next;
		}
		my @options = <PVR>;
		close PVR;
		# Get search name from filename
		my $name = $file;
		$name =~ s/^.*\/([^\/]+?)$/$1/g;
		for (@options) {
			/^\s*([\w\-_]+?)\s+(.*)\s*$/;
			main::logger "DEBUG: PVR search '$name': option $1 = $2\n" if $opt->{debug};
			$pvr->{$name}->{$1} = $2;
		}
		main::logger "INFO: Loaded PVR search '$name'\n" if $opt->{verbose};
	}
	main::logger "INFO: Loaded PVR search list\n" if $opt->{verbose};
	return 0;
}



# Clear all the PVR searches in %{$pvr}
sub clear_list {
	my $pvr = shift;
	# There is probably a faster way
	delete $pvr->{$_} for keys %{ $pvr };
	return 0;
}



# Save the array options specified as a PVR search
sub save {
	my $pvr = shift;
	my $name = shift;
	my @options = @_;
	# Sanitize name
	$name = StringUtils::sanitize_path( $name );
	# Make dir if not existing
	mkpath $vars{pvr_dir} if ! -d $vars{pvr_dir};
	main::logger "INFO: Saving PVR search '$name':\n";
	# Open file
	if ( ! open (PVR, "> $vars{pvr_dir}/${name}") ) { 
		main::logger "ERROR: Cannot save PVR search to $vars{pvr_dir}.$name\n";
		return 1;
	}
	# Write options array to file
	for (@options) {
		print PVR "$_\n";
		main::logger "\t$_\n";
	}
	close PVR;
	return 0;
}


# Uses globals: $profile_dir, $optfile_system, $optfile_default
# Uses class globals: %opt, %opt_file, %opt_cmdline
# Returns @search_args
# Clear all exisiting global args and opts then load the options specified in the default options and specified PVR search
sub load_options {
	my $pvr = shift;
	my $name = shift;

	my $optfile_preset;
	# Clear out existing options and file options hashes
	%{$opt} = ();

	# If the preset option is used in the PVR search then use it.
	if ( $pvr->{$name}->{preset} ) {
		$optfile_preset = ${profile_dir}."/presets/".$pvr->{$name}->{preset};
		main::logger "DEBUG: Using preset file: $optfile_preset\n" if $opt_cmdline->{debug};
	}

	# Re-copy options read from files at start of whole run
	$opt->copy_set_options_from( $opt_file );

	# Load options from $optfile_preset into $opt (uses $opt_cmdline as readonly options for debug/verbose etc)
	$opt->load( $opt_cmdline, $optfile_preset );
	
	# Clear search args
	@search_args = ();
	# Set each option from the search
	for ( sort {$a cmp $b} keys %{ $pvr->{$name} } ) {
		# Add to list of search args if this is not an option
		if ( /^search\d+$/ ) {
			main::logger "INFO: $_ = $pvr->{$name}->{$_}\n" if $opt->{verbose};
			push @search_args, $pvr->{$name}->{$_};
		# Else populate options, ignore disable option
		} elsif ( $_ ne 'disable' ) {
			main::logger "INFO: Option: $_ = $pvr->{$name}->{$_}\n" if $opt->{verbose};
			$opt->{$_} = $pvr->{$name}->{$_};
		}
	}

	# Allow cmdline args to override those in the PVR search
	# Re-copy options from the cmdline
	$opt->copy_set_options_from( $opt_cmdline );
	return @search_args;
}



# Disable a PVR search by adding 'disable 1' option
sub disable {
	my $pvr = shift;
	my $name = shift;
	$pvr->load_list();
	my @options;
	for ( keys %{ $pvr->{$name} }) {
		push @options, "$_ $pvr->{$name}->{$_}";
	}
	# Add the disable option
	push @options, 'disable 1';
	$pvr->save( $name, @options );
	return 0;
}



# Re-enable a PVR search by removing 'disable 1' option
sub enable {
	my $pvr = shift;
	my $name = shift;
	$pvr->load_list();
	my @options;
	for ( keys %{ $pvr->{$name} }) {
		push @options, "$_ $pvr->{$name}->{$_}";
	}
	# Remove the disable option
	@options = grep !/^disable\s/, @options;
	$pvr->save( $name, @options );	
	return 0;
}

