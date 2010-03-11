package gip::Options;

use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use Getopt::Long;
use strict;

# Class vars
# Global options
my $opt_format_ref;
# Constructor
# Usage: $opt = Options->new( 'optname' => 'testing 123', 'myopt2' => 'myval2', <and so on> );
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	bless $self, $type;
}


# Use to bind a new options ref to the class global $opt_format_ref var
sub add_opt_format_object {
	my $self = shift;
	$Options::opt_format_ref = shift;
}


# Parse cmdline opts using supplied hash
# If passthru flag is set then no error will result if there are unrecognised options etc
# Usage: $opt_cmdline->parse( [passthru] );
sub parse {
	my $this = shift;
	my $pass_thru = shift;
	my $opt_format_ref = $Options::opt_format_ref;
	# Build hash for passing to GetOptions module
	my %get_opts;

	for my $name ( grep !/^_/, keys %{$opt_format_ref} ) {
		my $format = @{ $opt_format_ref->{$name} }[1];
		$get_opts{ $format } = \$this->{$name};
	}

	# Allow bundling of single char options
	Getopt::Long::Configure("bundling");
	if ( $pass_thru ) {
		Getopt::Long::Configure("pass_through");
	} else {
		Getopt::Long::Configure("no_pass_through");
	}
	
	# cmdline opts take precedence
	# get options
	return GetOptions(%get_opts);
}



sub copyright_notice {
	shift;
	my $text = sprintf "get_iplayer v%.2f, ", $version;
	$text .= <<'EOF';
Copyright (C) 2008-2010 Phil Lewis
  This program comes with ABSOLUTELY NO WARRANTY; for details use --warranty.
  This is free software, and you are welcome to redistribute it under certain
  conditions; use --conditions for details.

EOF
	return $text;
}



# Usage: $opt_cmdline->usage( <helplevel>, <manpage>, <dump> );
sub usage {
	my $this = shift;
	# Help levels: 0:Intermediate, 1:Advanced, 2:Basic
	my $helplevel = shift;
	my $manpage = shift;
	my $dumpopts = shift;
	my $opt_format_ref = $Options::opt_format_ref;
	my %section_name;
	my %name_syntax;
	my %name_desc;
	my @usage;
	my @man;
	my @dump;
	push @man, 
		'.TH GET_IPLAYER "1" "January 2010" "Phil Lewis" "get_iplayer Manual"',
		'.SH NAME', 'get_iplayer - Stream Recording tool and PVR for BBC iPlayer, BBC Podcasts and more',
		'.SH SYNOPSIS',
		'\fBget_iplayer\fR [<options>] [<regex|index> ...]',
		'.PP',
		'\fBget_iplayer\fR \fB--get\fR [<options>] <regex|index> ...',
		'.br',
		'\fBget_iplayer\fR <url> \fB--type\fR=<type> [<options>]',
		'.PP',
		'\fBget_iplayer\fR <pid|url> [\fB--type\fR=<type> <options>]',
		'.PP',
		'\fBget_iplayer\fR \fB--stream\fR [<options>] <regex|index> | mplayer \fB-cache\fR 3072 -',
		'.PP',
		'\fBget_iplayer\fR \fB--stream\fR [<options>] \fB--type\fR=<type> <pid|url> | mplayer \fB-cache\fR 3072 -',
		'.PP',
		'\fBget_iplayer\fR \fB--stream\fR [<options>] \fB--type\fR=livetv,liveradio <regex|index> \fB--player\fR="mplayer -cache 128 -"',
		'.PP',
		'\fBget_iplayer\fR \fB--update\fR',
		'.SH DESCRIPTION',
		'\fBget_iplayer\fR lists, searches and records BBC iPlayer TV/Radio, BBC Podcast programmes. Other 3rd-Party plugins may be available.',
		'.PP',
		'\fBget_iplayer\fR has three modes: recording a complete programme for later playback, streaming a programme',
		'directly to a playback application, such as mplayer; and as a Personal Video Recorder (PVR), subscribing to',
		'search terms and recording programmes automatically. It can also stream or record live BBC iPlayer output',
		'.PP',
		'If given no arguments, \fBget_iplayer\fR updates and displays the list of currently available programmes.',
		'Each available programme has a numerical identifier, \fBpid\fR.',
		'\fBget_iplayer\fR records BBC iPlayer programmes by pretending to be an iPhone, which means that some programmes in the list are unavailable for recording.',
		'It can also utilise the \fBrtmpdump\fR or \fBflvstreamer\fR tools to record programmes from RTMP flash streams at various qualities.',
		'.PP',
		'In PVR mode, \fBget_iplayer\fR can be called from cron to record programmes to a schedule.',
		'.SH "OPTIONS"' if $manpage;
	push @usage, 'Usage ( Also see http://linuxcentre.net/getiplayer/documentation ):';
	push @usage, ' List All Programmes:            get_iplayer [--type=<TYPE>]';
	push @usage, ' Search Programmes:              get_iplayer <REGEX>';
	push @usage, ' Record Programmes by Search:    get_iplayer <REGEX> --get';
	push @usage, ' Record Programmes by Index:     get_iplayer <INDEX> --get';
	push @usage, ' Record Programmes by URL:       get_iplayer [--type=<TYPE>] "<URL>"';
	push @usage, ' Record Programmes by PID:       get_iplayer [--type=<TYPE>] --pid=<PID>';
	push @usage, ' Stream Programme to Player:     get_iplayer --stream <INDEX> | mplayer -cache 3072 -' if $helplevel == 1;
	push @usage, ' Stream BBC Embedded Media URL:  get_iplayer --stream --type=<TYPE> "<URL>" | mplayer -cache 128 -' if $helplevel != 2;
	push @usage, ' Stream Live iPlayer Programme:  get_iplayer --stream --type=livetv,liveradio <REGEX|INDEX> --player="mplayer -cache 128 -"' if $helplevel != 2;
	push @usage, '';
	push @usage, ' Update get_iplayer:             get_iplayer --update [--force]';
	push @usage, '';
	push @usage, ' Basic Help:                     get_iplayer --basic-help' if $helplevel != 2;
	push @usage, ' Intermediate Help:              get_iplayer --help' if $helplevel == 2;
	push @usage, ' Advanced Help:                  get_iplayer --long-help' if $helplevel != 1;

	for my $name (keys %{$opt_format_ref} ) {
		next if not $opt_format_ref->{$name};
		my ( $helpmask, $format, $section, $syntax, $desc ) = @{ $opt_format_ref->{$name} };
		# Skip advanced options if not req'd
		next if $helpmask == 1 && $helplevel != 1;
		# Skip internediate options if not req'd
		next if $helpmask != 2 && $helplevel == 2;
		push @{$section_name{$section}}, $name if $syntax;
		$name_syntax{$name} = $syntax;
		$name_desc{$name} = $desc;
	}

	# Build the help usage text
	# Each section
	for my $section ( 'Search', 'Display', 'Recording', 'Download', 'Output', 'PVR', 'Config', 'External Program', 'Misc' ) {
		next if not defined $section_name{$section};
		my @lines;
		my @manlines;
		my @dumplines;
		#Runs the PVR using all saved PVR searches (intended to be run every hour from cron etc)
		push @man, ".SS \"$section Options:\"" if $manpage;
		push @dump, '', "$section Options:" if $dumpopts;
		push @usage, '', "$section Options:";
		# Each name in this section array
		for my $name ( sort @{ $section_name{$section} } ) {
			push @manlines, '.TP'."\n".'\fB'.$name_syntax{$name}."\n".$name_desc{$name} if $manpage;
			my $dumpname = $name;
			$dumpname =~ s/^_//g;
			push @dumplines, sprintf(" %-20s %-32s %s", $dumpname, $name_syntax{$name}, $name_desc{$name} ) if $dumpopts;
			push @lines, sprintf(" %-32s %s", $name_syntax{$name}, $name_desc{$name} );
		}
		push @usage, sort @lines;
		push @man, sort @manlines;
		push @dump, sort @dumplines;
	}

	# Create manpage
	if ( $manpage ) {
		push @man,
			'.SH AUTHOR',
			'get_iplayer is written and maintained by Phil Lewis <iplayer2 (at sign) linuxcentre.net>.',
			'.PP',
			'This manual page was originally written by Jonathan Wiltshire <debian@jwiltshire.org.uk> for the Debian project (but may be used by others).',
			'.SH COPYRIGHT NOTICE';
		push @man, Options->copyright_notice;
		# Escape '-'
		s/\-/\\-/g for @man;
		# Open manpage file and write contents
		if (! open (MAN, "> $manpage") ) {
			main::logger "ERROR: Cannot write to manpage file '$manpage'\n";
			exit 1;
		}
		print MAN join "\n", @man, "\n";
		close MAN;
		main::logger "INFO: Wrote manpage file '$manpage'\n";

	# Print options dump and quit
	} elsif ( $dumpopts ) {
		main::logger join "\n", @dump, "\n";
	
	# Print usage and quit
	} else {
		main::logger join "\n", @usage, "\n";
	}

	exit 1;
}


# Add all the options into supplied hash from specified class
# Usage: Options->get_class_options( 'gip::Programme:tv' );
sub get_class_options {
	shift;
	my $classname = shift;
	my $opt_format_ref = $Options::opt_format_ref;
	# If the method exists...
	eval { $classname->opt_format() };
	if ( ! $@ ) {
		my %tmpopt = %{ $classname->opt_format() };
		for my $thisopt ( keys %tmpopt ) {
			$opt_format_ref->{$thisopt} = $tmpopt{$thisopt}; 
		}	
	}
}


# Copies values in one instance to another only if they are set with a value/defined
# Usage: $opt->copy_set_options_from( $opt_cmdline );
sub copy_set_options_from {
	my $this_to = shift;
	my $this_from = shift;
	# Merge cmdline options into $opt instance (only those options defined)
	for ( keys %{$this_from} ) {
		$this_to->{$_} = $this_from->{$_} if defined $this_from->{$_};
	}
}



# specify regex of options that cannot be saved
sub excludeopts {
	return '^(help|debug|get|pvr|prefs|preset|warranty|conditions)';
}


# List all available presets in the specified dir
sub preset_list {
	my $opt = shift;
	my $dir = shift;
	main::logger "INFO: Valid presets: ";
	if ( opendir( DIR, "${profile_dir}/presets/" ) ) {
		my @preset_list = grep !/(^\.|~$)/, readdir DIR;
		closedir DIR;
		main::logger join ',', @preset_list;
	}
	main::logger "\n";
}


# Clears all option entries for a particular preset (i.e. deletes the file)
sub clear {
	my $opt = shift;
	my $prefsfile = shift;
	$opt->show( $prefsfile );
	unlink $prefsfile;
	main::logger "INFO: Removed all above options from $prefsfile\n";
}


# $opt->add( $opt_cmdline, $optfile, @search_args )
# Add/change cmdline-only options to file
sub add {
	my $opt = shift;
	my $this_cmdline = shift;
	my $optfile = shift;
	my @search_args = @_;

	# Load opts file
	my $entry = get( $opt, $optfile );

	# Add search args to opts
	$this_cmdline->{search} = '('.(join '|', @search_args).')' if @search_args;

	# Merge all cmdline opts into $entry except for these
	my $regex = $opt->excludeopts;
	for ( grep !/$regex/, keys %{ $this_cmdline } ) {
		# if this option is on the cmdline
		if ( defined $this_cmdline->{$_} ) {
			main::logger "INFO: Changed option '$_' from '$entry->{$_}' to '$this_cmdline->{$_}'\n" if defined $entry->{$_} && $this_cmdline->{$_} ne $entry->{$_};
			main::logger "INFO: Added option '$_' = '$this_cmdline->{$_}'\n" if not defined $entry->{$_};
			$entry->{$_} = $this_cmdline->{$_};
		}
	}

	# Save opts file
	put( $opt, $entry, $optfile );
}



# $opt->add( $opt_cmdline, $optfile )
# Add/change cmdline-only options to file
sub del {
	my $opt = shift;
	my $this_cmdline = shift;
	my $optfile = shift;
	my @search_args = @_;
	return 0 if ! -f $optfile;

	# Load opts file
	my $entry = get( $opt, $optfile );

	# Add search args to opts
	$this_cmdline->{search} = '('.(join '|', @search_args).')' if @search_args;

	# Merge all cmdline opts into $entry except for these
	my $regex = $opt->excludeopts;
	for ( grep !/$regex/, keys %{ $this_cmdline } ) {
		main::logger "INFO: Deleted option '$_' = '$this_cmdline->{$_}'\n" if defined $this_cmdline->{$_} && defined $entry->{$_};
		delete $entry->{$_} if defined $this_cmdline->{$_};
	}

	# Save opts file
	put( $opt, $entry, $optfile );
}



# $opt->show( $optfile )
# show options from file
sub show {
	my $opt = shift;
	my $optfile = shift;
	return 0 if ! -f $optfile;

	# Load opts file
	my $entry = get( $opt, $optfile );

	# Merge all cmdline opts into $entry except for these
	main::logger "Options in '$optfile'\n";
	my $regex = $opt->excludeopts;
	for ( keys %{ $entry } ) {
		main::logger "\t$_ = $entry->{$_}\n";
	}
}



# $opt->save( $opt_cmdline, $optfile )
# Save cmdline-only options to file
sub put {
	my $opt = shift;
	my $entry = shift;
	my $optfile = shift;

	unlink $optfile;
	main::logger "DEBUG: adding/changing options to $optfile:\n" if $opt->{debug};
	open (OPT, "> $optfile") || die ("ERROR: Cannot save options to $optfile\n");
	for ( keys %{ $entry } ) {
		if ( defined $entry->{$_} ) {
			print OPT "$_ $entry->{$_}\n";
			main::logger "DEBUG: Saving option $_ = $entry->{$_}\n" if $opt->{debug};
		}
	}
	close OPT;

	main::logger "INFO: Options file $optfile updated\n";
	return;
}



# Returns a hashref of 'optname => internal_opt_name' for all options
sub get_opt_map {
	my $opt_format_ref = $Options::opt_format_ref;

	# Get a hash or optname -> internal_opt_name
	my $optname;
	for my $optint ( keys %{ $opt_format_ref } ) {
		my $format = @{ $opt_format_ref->{$optint} }[1];
		#main::logger "INFO: Opt Format '$format'\n";
		$format =~ s/=.*$//g;
		# Parse each option format
		for ( split /\|/, $format ) {
			next if /^$/;
			#main::logger "INFO: Opt '$_' -> '$optint'\n";
			if ( defined $optname->{$_} ) {
				main::logger "ERROR: Duplicate Option defined '$_' -> '$optint' and '$optname->{$_}'\n";
				exit 11;
			}
			$optname->{$_} = $optint;
		}
	}
	for my $optint ( keys %{ $opt_format_ref } ) {
		$optname->{$optint} = $optint;
	}
	return $optname;
}


# $entry = get( $opt, $optfile )
# get all options from file into $entry ($opt is used just to get access to general options like debug)
sub get {
	my $opt = shift;
	my $optfile = shift;
	my $opt_format_ref = $Options::opt_format_ref;
	my $entry;
	return $entry if ( ! defined $optfile ) || ( ! -f $optfile );

	my $optname = get_opt_map();

	# Load opts
	main::logger "DEBUG: Parsing options from $optfile:\n" if $opt->{debug};
	open (OPT, "< $optfile") || die ("ERROR: Cannot read options file $optfile\n");
	while(<OPT>) {
		/^\s*([\w\-_]+)\s+(.*)\s*$/;
		next if not defined $1;
		# Error if the option is not valid
		if ( not defined $optname->{$1} ) {
			# Force error to go to STDERR (prevents PVR runs getting STDOUT warnings)
			$opt->{stderr} = 1;
			main::logger "WARNING: Ignoring invalid option in $optfile: '$1 = $2'\n";
			main::logger "INFO: Please remove and use 'get_iplayer --dump-options' to display all valid options\n";
			delete $opt->{stderr};
			next;
		}
		# Warn if it is listed as a deprecated internal option name
		if ( defined @{ $opt_format_ref->{$1} }[2] && @{ $opt_format_ref->{$1} }[2] eq 'Deprecated' ) {
			main::logger "WARNING: Deprecated option in $optfile: '$1 = $2'\n";
			main::logger "INFO: Use --dump-opts to display all valid options\n";
		}
		chomp( $entry->{ $optname->{$1} } = $2 );
		main::logger "DEBUG: Loaded option $1 ($optname->{$1}) = $2\n" if $opt->{debug};
	}
	close OPT;
	return $entry;
}



# $opt_file->load( $opt, $optfile )
# Load default options from file(s) into instance
sub load {
	my $this_file = shift;
	my $opt = shift;
	my @optfiles = ( @_ );

	# If multiple files are specified, load them in order listed
	for my $optfile ( @optfiles ) {
		# Load opts
		my $entry = get( $opt, $optfile );
		# Copy to $this_file instance
		$this_file->copy_set_options_from( $entry );
	}

	return;
}



# Usage: $opt_file->display( [<exclude regex>], [<title>] );
# Display options
sub display {
	my $this = shift;
	my $title = shift || 'Options';
	my $excluderegex = shift || 'ROGUEVALUE';
	my $regex = $this->excludeopts;
	main::logger "$title:\n";
	for ( grep !/$regex/i, sort keys %{$this} ) {
		main::logger "\t$_ = $this->{$_}\n" if defined $this->{$_} && $this->{$_};
	}
	main::logger "\n";
	return 0;
}



