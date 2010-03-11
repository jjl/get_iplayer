#!/usr/bin/env perl
# get_iplayer - Lists, Records and Streams BBC iPlayer TV and Radio programmes + other Programmes via 3rd-party plugins
#
#    Copyright (C) 2008-2010 Phil Lewis
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Author: Phil Lewis
# Email: iplayer2 (at sign) linuxcentre.net
# Web: http://linuxcentre.net/iplayer
# License: GPLv3 (see LICENSE.txt)
#
#
#
# Help:
#	./get_iplayer --help | --longhelp
#
# Changelog:
# 	http://linuxcentre.net/get_iplayer/CHANGELOG.txt
#
# Example Usage and Documentation:
# 	http://linuxcentre.net/getiplayer/documentation
#
# Todo:
# * Fix non-uk detection - iphone auth?
# * Index/Record live radio streams w/schedule feeds to assist timing
# * Remove all rtsp/mplayer/lame/tee dross when realaudio streams become obselete (not quite yet)
# ** all global vars into a class???
# ** Cut down 'use' clauses in each class
# * stdout streaming with mms
# * Add podcast links to web pvr manager
# * Add PVR search src to recording history
# * Fix unicode / wide chars in rdf
#
# Known Issues:
# * CAVEAT: The filenames and modes in the history are comma-separated if there was a multimode download. For now it just uses the first one.
#

use strict;
use warnings;
use 5.005; # 'our' support

our $VERSION = 2.72;
use lib 'lib'; # FIXME: Can't deploy with this in
#use gip;
use Env qw[@PATH];
use Fcntl;
use File::Copy;
use File::Path;
use File::stat;
use Getopt::Long;
use HTML::Entities;
use HTTP::Cookies;
use HTTP::Headers;
use IO::Seekable;
use IO::Socket;
use LWP::ConnCache;
use LWP::UserAgent;
use POSIX qw(mkfifo);
use POSIX qw(:termios_h);
use strict;
#use warnings;
use Time::Local;
use URI;

use gip::History;
use gip::Options;
use gip::Programme;
use gip::Programme::bbciplayer;
use gip::Programme::live;
use gip::Programme::liveradio;
use gip::Programme::livetv;
use gip::Programme::radio;
use gip::Programme::tv;
use gip::PVR;
use gip::Streamer;
use gip::Streamer::3gp;
use gip::Streamer::filestreamonly;
use gip::Streamer::http;
use gip::Streamer::iphone;
use gip::Streamer::mms;
use gip::Streamer::rtmp;
use gip::Streamer::rtsp;



my %SIGORIG;
# Save default SIG actions
$SIGORIG{$_} = $SIG{$_} for keys %SIG;
$|=1;

# Hash of where plugin files were found so that the correct ones can be updated
my %plugin_files;

# Hash of all prog types => Programme class
# Add an entry here if another Programme class is added
my %prog_types = (
	tv		=> 'gip::Programme::tv',
	radio		=> 'gip::Programme::radio',
	liveradio	=> 'gip::Programme::liveradio',
	livetv		=> 'gip::Programme::livetv',
);


# Programme instance data
# $prog{$pid} = Programme->new (
#	'index'		=> <index number>,
#	'name'		=> <programme short name>,
#	'episode'	=> <Episode info>,
#	'desc'		=> <Long Description>,
#	'available'	=> <Date/Time made available or remaining>,
#	'duration'	=> <duration in free text form>
#	'versions'	=> <comma separated list of versions, e.g default, signed, audiodescribed>
#	'thumbnail'	=> <programme thumbnail url>
#	'channel	=> <channel>
#	'categories'	=> <Comma separated list of categories>
# 	'type'		=> <prog_type>
#	'timeadded'	=> <timestamp when programme was added to cache>
#	'version'	=> <selected version e.g default, signed, audiodescribed, etc - only set before recording>
#	'filename'	=> <Path and Filename of saved file - set only while recording>
#	'dir'		=> <Filename Directory of saved file - set only while recording>
#	'fileprefix'	=> <Filename Prefix of saved file - set only while recording>
#	'ext'		=> <Filename Extension of saved file - set only while recording>
#);


# Define general 'option names' => ( <help mask>, <option help section>, <option cmdline format>, <usage text>, <option help> )
# <help mask>: 0 for normal help, 1 for advanced help, 2 for basic help
# If you want the option to be hidden then don't specify <option help section>, use ''
# Entries with keys starting with '_' are not parsed only displayed as help and in man pages.
my $opt_format = {
	# Recording
	attempts	=> [ 1, "attempts=n", 'Recording', '--attempts <number>', "Number of attempts to make or resume a failed connection"],
	force		=> [ 1, "force|force-download!", 'Recording', '--force', "Ignore programme history (unsets --hide option also). Forces a script update if used wth -u"],
	get		=> [ 2, "get|record|g!", 'Recording', '--get, -g', "Start recording matching programmes"],
	hash		=> [ 1, "hash!", 'Recording', '--hash', "Show recording progress as hashes"],
	metadataonly	=> [ 1, "metadataonly|metadata-only!", 'Recording', '--metadata-only', "Create specified metadata info file without any recording or streaming (can also be used with thumbnail option)."],
	mmsnothread	=> [ 1, "mmsnothread!", 'Recording', '--mmsnothread', "Disable parallel threaded recording for mms"],
	modes		=> [ 0, "modes=s", 'Recording', '--modes <mode>,<mode>,...', "Recoding modes: iphone,flashhd,flashvhigh,flashhigh,flashstd,flashnormal,flashlow,n95_wifi,flashaac,flashaachigh,flashaacstd,flashaaclow,flashaudio,realaudio,wma"],
	multimode	=> [ 1, "multimode!", 'Recording', '--multimode', "Allow the recording of more than one mode for the same programme - WARNING: will record all specified/default modes!!"],
	overwrite	=> [ 1, "overwrite|over-write!", 'Recording', '--overwrite', "Overwrite recordings if they already exist"],
	partialproxy	=> [ 1, "partial-proxy!", 'Recording', '--partial-proxy', "Only uses web proxy where absolutely required (try this extra option if your proxy fails)"],
	_url		=> [ 2, "", 'Recording', '--url "<url>"', "Record the embedded media player in the specified URL. Use with --type=<type>."],
	pid		=> [ 2, "pid|url=s", 'Recording', '--pid <pid>', "Record an arbitrary pid that does not necessarily appear in the index."],
	pidrecursive	=> [ 1, "pidrecursive|pid-recursive!", 'Recording', '--pid-recursive', "When used with --pid record all the embedded pids if the pid is a series or brand pid."],
	proxy		=> [ 0, "proxy|p=s", 'Recording', '--proxy, -p <url>', "Web proxy URL e.g. 'http://USERNAME:PASSWORD\@SERVER:PORT' or 'http://SERVER:PORT'"],
	raw		=> [ 0, "raw!", 'Recording', '--raw', "Don't transcode or change the recording/stream in any way (i.e. radio/realaudio, rtmp/flv, iphone/mov)"],
	start		=> [ 1, "start=s", 'Recording', '--start <secs>', "Recording/streaming start offset (rtmp and realaudio only)"],
	stop		=> [ 1, "stop=s", 'Recording', '--stop <secs>', "Recording/streaming stop offset (can be used to limit live rtmp recording length) rtmp and realaudio only"],
	suboffset	=> [ 1, "suboffset=n", 'Recording', '--suboffset <offset>', "Offset the subtitle timestamps by the specified number of milliseconds"],
	subtitles	=> [ 2, "subtitles|subs!", 'Recording', '--subtitles', "Download subtitles into srt/SubRip format if available and supported"],
	subsonly	=> [ 1, "subtitlesonly|subsonly|subtitles-only|subs-only!", 'Recording', '--subtitles-only', "Only download the subtitles, not the programme"],
	subsraw		=> [ 1, "subsraw!", 'Recording', '--subsraw', "Additionally save the raw subtitles file"],
	test		=> [ 1, "test|t!", 'Recording', '--test, -t', "Test only - no recording (will show programme type)"],
	thumb		=> [ 1, "thumb|thumbnail!", 'Recording', '--thumb', "Download Thumbnail image if available"],
	thumbonly	=> [ 1, "thumbonly|thumbnailonly|thumbnail-only|thumb-only!", 'Recording', '--thumbnail-only', "Only Download Thumbnail image if available, not the programme"],

	# Search
	before		=> [ 1, "before=n", 'Search', '--before', "Limit search to programmes added to the cache before N hours ago"],
	category 	=> [ 0, "category=s", 'Search', '--category <string>', "Narrow search to matched categories (regex or comma separated values)"],
	channel		=> [ 0, "channel=s", 'Search', '--channel <string>', "Narrow search to matched channel(s) (regex or comma separated values)"],
	exclude		=> [ 0, "exclude=s", 'Search', '--exclude <string>', "Narrow search to exclude matched programme names (regex or comma separated values)"],
	excludecategory	=> [ 0, "xcat|exclude-category=s", 'Search', '--exclude-category <string>', "Narrow search to exclude matched catogories (regex or comma separated values)"],
	excludechannel	=> [ 0, "xchan|exclude-channel=s", 'Search', '--exclude-channel <string>', "Narrow search to exclude matched channel(s) (regex or comma separated values)"],
	fields		=> [ 0, "fields=s", 'Search', '--fields <field1>,<field2>,..', "Searches only in the specified comma separated fields"],
	future		=> [ 1, "future!", 'Search', '--future', "Search future programme schedule if it has been indexed (refresh cache with: --refresh --refresh-future)."],
	long		=> [ 0, "long|l!", 'Search', '--long, -l', "Additionally search in programme descriptions and episode names (same as --fields=name,episode,desc )"],
	search		=> [ 1, "search=s", 'Search', '--search <search term>', "GetOpt compliant way of specifying search args"],
	history		=> [ 1, "history!", 'Search', '--history', "Search/show recordings history"],
	since		=> [ 0, "since=n", 'Search', '--since', "Limit search to programmes added to the cache in the last N hours"],
	type		=> [ 2, "type=s", 'Search', '--type <type>', "Only search in these types of programmes: ".join(',', keys %prog_types).",all (tv is default)"],
	versionlist	=> [ 1, "versionlist|versions|version-list=s", 'Search', '--versions <versions>', "Version of programme to search or record (e.g. '--versions signed,audiodescribed,default')"],

	# Output
	command		=> [ 1, "c|command=s", 'Output', '--command, -c <command>', "Run user command after successful recording using args such as <pid>, <name> etc"],
	email		=> [ 1, "email=s", 'Output', '--email <address>', "Email HTML index of matching programmes to specified address"],
	emailsmtp	=> [ 1, "emailsmtpserver|email-smtp=s", 'Output', '--email-smtp <hostname>', "SMTP server IP address to use to send email (default: localhost)"],
	emailsender	=> [ 1, "emailsender|email-sender=s", 'Output', '--email-sender <address>', "Optional email sender address"],
	fatfilename	=> [ 1, "fatfilenames|fatfilename!", 'Output', '--fatfilename', "Omit characters forbidden by FAT filesystems from filenames but keep whitespace"],
	fileprefix	=> [ 1, "file-prefix|fileprefix=s", 'Output', '--file-prefix <format>', "The filename prefix (excluding dir and extension) using formatting fields. e.g. '<name>-<episode>-<pid>'"],
	fxd		=> [ 1, "fxd=s", 'Output', '--fxd <file>', "Create Freevo FXD XML of matching programmes in specified file"],
	html		=> [ 1, "html=s", 'Output', '--html <file>', "Create basic HTML index of matching programmes in specified file"],
	isodate		=> [ 1, "isodate!",  'Output', '--isodate', "Use ISO8601 dates (YYYY-MM-DD) in filenames"],
	metadata	=> [ 1, "metadata=s", 'Output', '--metadata <type>', "Create metadata info file after recording. Valid types are: xbmc, xbmc_movie, freevo, generic"],
	mythtv		=> [ 1, "mythtv=s", 'Output', '--mythtv <file>', "Create Mythtv streams XML of matching programmes in specified file"],
	nowrite		=> [ 1, "no-write|nowrite|n!", 'Output', '--nowrite, -n', "No writing of file to disk (use with -x to prevent a copy being stored on disk)"],
	output		=> [ 2, "output|o=s", 'Output', '--output, -o <dir>', "Recording output directory"],
	player		=> [ 0, "player=s", 'Output', "--player \'<command> <options>\'", "Use specified command to directly play the stream"],
	stdout		=> [ 1, "stdout|x", 'Output', '--stdout, -x', "Additionally stream to STDOUT (so you can pipe output to a player)"],
	stream		=> [ 0, "stream!", 'Output', '--stream', "Stream to STDOUT (so you can pipe output to a player)"],
	subdir		=> [ 1, "subdirs|subdir|s!", 'Output', '--subdir, -s', "Put Recorded files into Programme name subdirectory"],
	subdirformat	=> [ 1, "subdirformat|subdirsformat|subdir-format=s", 'Output', '--subdir-format <format>', "The format to be used for the subdirectory naming using formatting fields. e.g. '<nameshort>-<seriesnum>'"],
	symlink		=> [ 1, "symlink|freevo=s", 'Output', '--symlink <file>', "Create symlink to <file> once we have the header of the recording"],
	thumbext	=> [ 1, "thumbext|thumb-ext=s", 'Output', '--thumb-ext <ext>', "Thumbnail filename extension to use"],
	thumbsizecache	=> [ 1, "thumbsizecache=n", 'Output', '--thumbsizecache <index|width>', "Default thumbnail size/index to use when building cache and index (see --info for thumbnailN: to get size/index)"],
	thumbsize	=> [ 1, "thumbsize|thumbsizemeta=n", 'Output', '--thumbsize <index|width>', "Default thumbnail size/index to use for the current recording and metadata (see --info for thumbnailN: to get size/index)"],
	whitespace	=> [ 1, "whitespace|ws|w!", 'Output', '--whitespace, -w', "Keep whitespace (and escape chars) in filenames"],
	xmlchannels	=> [ 1, "xml-channels|fxd-channels!", 'Output', '--xml-channels', "Create freevo/Mythtv menu of channels -> programme names -> episodes"],
	xmlnames	=> [ 1, "xml-names|fxd-names!", 'Output', '--xml-names', "Create freevo/Mythtv menu of programme names -> episodes"],
	xmlalpha	=> [ 1, "xml-alpha|fxd-alpha!", 'Output', '--xml-alpha', "Create freevo/Mythtv menu sorted alphabetically by programme name"],

	# Config
	expiry		=> [ 1, "expiry|e=n", 'Config', '--expiry, -e <secs>', "Cache expiry in seconds (default 4hrs)"],
	refresh		=> [ 2, "refresh|flush|f!", 'Config', '--refresh, --flush, -f', "Refresh cache"],
	limitmatches	=> [ 1, "limitmatches|limit-matches=n", 'Config', '--limit-matches <number>', "Limits the number of matching results for any search (and for every PVR search)"],
	nopurge		=> [ 0, "no-purge|nopurge!", 'Config', '--nopurge', "Don't ask to delete programmes recorded over 30 days ago"],	
	packagemanager	=> [ 1, "packagemanager=s", 'Config', '--packagemanager <string>', "Tell the updater that we were installed using a package manager and don't update (use either: apt,rpm,deb,yum,disable)"],
	pluginsupdate	=> [ 1, "pluginsupdate|plugins-update!", 'Config', '--plugins-update', "Update get_iplayer plugins to the latest"],
	prefsadd	=> [ 0, "addprefs|add-prefs|prefsadd|prefs-add!", 'Config', '--prefs-add', "Add/Change specified saved user or preset options"],
	prefsdel	=> [ 0, "del-prefs|delprefs|prefsdel|prefs-del!", 'Config', '--prefs-del', "Remove specified saved user or preset options"],
	prefsclear	=> [ 0, "clear-prefs|clearprefs|prefsclear|prefs-clear!", 'Config', '--prefs-clear', "Remove *ALL* saved user or preset options"],
	prefsshow	=> [ 0, "showprefs|show-prefs|prefsshow|prefs-show!", 'Config', '--prefs-show', "Show saved user or preset options"],
	preset		=> [ 1, "preset|z=s", 'Config', '--preset, -z <name>', "Use specified user options preset"],
	presetlist	=> [ 1, "listpresets|list-presets|presetlist|preset-list!", 'Config', '--preset-list', "Show all valid presets"],
	profiledir	=> [ 1, "profiledir|profile-dir=s", 'Config', '--profile-dir <dir>', "Override the user profile directory/folder"],
	refreshinclude	=> [ 1, "refreshinclude|refresh-include=s", 'Config', '--refresh-include <string>', "Include matched channel(s) when refreshing cache (regex or comma separated values)"],
	refreshexclude	=> [ 1, "refreshexclude|refresh-exclude|ignorechannels=s", 'Config', '--refresh-exclude <string>', "Exclude matched channel(s) when refreshing cache (regex or comma separated values)"],
	refreshfuture	=> [ 1, "refreshfuture!", 'Config', '--refresh-future', "Obtain future programme schedule when refreshing cache (between 7-14 days)"],
	skipdeleted	=> [ 1, "skipdeleted!", 'Config', "--skipdeleted", "Skip the download of metadata/thumbs/subs if the media file no longer exists. Use with --history & --metadataonly/subsonly/thumbonly."],
	update		=> [ 2, "update|u!", 'Config', '--update, -u', "Update get_iplayer if a newer one exists"],
	webrequest	=> [ 1, "webrequest=s", 'Config', '--webrequest <urlencoded string>', 'Specify all options as a urlencoded string of "name=val&name=val&..."' ],

	# Display
	conditions	=> [ 1, "conditions!", 'Display', '--conditions', 'Shows GPLv3 conditions'],
	debug		=> [ 1, "debug!", 'Display', '--debug', "Debug output"],
	dumpoptions	=> [ 1, "dumpoptions|dumpopts|dump-options!", 'Display', '--dump-options', 'Dumps all options with their internal option key names'],
	helpbasic	=> [ 2, "help-basic|usage|bh|hb|helpbasic|basichelp|basic-help!", 'Display', '--helpbasic, --usage', "Basic help text"],
	help		=> [ 2, "help|h!", 'Display', '--help, -h', "Intermediate help text"],
	helplong	=> [ 2, "help-long|advanced|long-help|longhelp|lh|hl|helplong!", 'Display', '--helplong', "Advanced help text"],
	hide		=> [ 1, "hide!", 'Display', '--hide', "Hide previously recorded programmes"],
	info		=> [ 2, "i|info!", 'Display', '--info, -i', "Show full programme metadata and availability of modes and subtitles (max 50 matches)"],
	list		=> [ 1, "list=s", 'Display', '--list <categories|channel>', "Show a list of available categories/channels for the selected type and exit"],
	listformat	=> [ 1, "listformat=s", 'Display', '--listformat <format>', "Display programme data based on a user-defined format string (such as <pid>, <name> etc)"],
	listplugins	=> [ 1, "listplugins!", 'Display', '--listplugins', "Display a list of currently available plugins or programme types"],
	_long		=> [ 0, "", 'Display', '--long, -l', "Show long programme info"],
	manpage		=> [ 1, "manpage=s", 'Display', '--manpage <file>', "Create man page based on current help text"],
	nocopyright	=> [ 1, "nocopyright!", 'Display', '--nocopyright', "Don't display copyright header"],
	page		=> [ 1, "page=n", 'Display', '--page <number>', "Page number to display for multipage output"],
	pagesize	=> [ 1, "pagesize=n", 'Display', '--pagesize <number>', "Number of matches displayed on a page for multipage output"],
	quiet		=> [ 1, "q|quiet|silent!", 'Display', '--quiet, -q', "No logging output"],
	series		=> [ 1, "series!", 'Display', '--series', "Display Programme series names only with number of episodes"],
	showcacheage	=> [ 1, "showcacheage|show-cache-age!", 'Display', '--show-cache-age', "Displays the age of the selected programme caches then exit"],
	showoptions	=> [ 1, "showoptions|showopts|show-options!", 'Display', '--show-options', 'Shows options which are set and where they are defined'],
	sortmatches	=> [ 1, "sortmatches|sort=s", 'Display', '--sort <fieldname>', "Field to use to sort displayed matches"],
	sortreverse	=> [ 1, "sortreverse!", 'Display', '--sortreverse', "Reverse order of sorted matches"],
	streaminfo	=> [ 1, "streaminfo!", 'Display', '--streaminfo', "Returns all of the media stream urls of the programme(s)"],
	terse		=> [ 0, "terse!", 'Display', '--terse', "Only show terse programme info (does not affect searching)"],
	tree		=> [ 0, "tree!", 'Display', '--tree', "Display Programme listings in a tree view"],
	verbose		=> [ 1, "verbose|v!", 'Display', '--verbose, -v', "Verbose"],
	showver		=> [ 1, "V!", 'Display', '-V', "Show get_iplayer version and exit."],
	warranty	=> [ 1, "warranty!", 'Display', '--warranty', 'Displays warranty section of GPLv3'],

	# External Program
	atomicparsley	=> [ 1, "atomicparsley|atomic-parsley=s", 'External Program', '--atomicparsley <path>', "Location of AtomicParsley tagger binary"],
	id3v2		=> [ 1, "id3tag|id3v2=s", 'External Program', '--id3v2 <path>', "Location of id3v2 or id3tag binary"],
	mplayer		=> [ 1, "mplayer=s", 'External Program', '--mplayer <path>', "Location of mplayer binary"],

	# Deprecated

};


# Pre-processed options instance
my $opt_pre = gip::Options->new();
# Final options instance
my $opt = gip::Options->new();
# Command line options instance
my $opt_cmdline = gip::Options->new();
# Options file instance
my $opt_file = gip::Options->new();
# Bind opt_format to Options class
gip::Options->add_opt_format_object( $opt_format );

# Set Programme/PVR/Streamer class global var refs to the Options instance
gip::History->add_opt_object( $opt );
gip::Programme->add_opt_object( $opt );
gip::PVR->add_opt_object( $opt );
gip::PVR->add_opt_file_object( $opt_file );
gip::PVR->add_opt_cmdline_object( $opt_cmdline );
gip::Streamer->add_opt_object( $opt );
# Kludge: Create dummy Streamer, History and Programme instances (without a single instance, none of the bound options work)
gip::History->new();
gip::Programme->new();
gip::Streamer->new();

# Print to STDERR/STDOUT if not quiet unless verbose or debug
sub logger(@) {
	my $msg = shift || '';
	# Make sure quiet can be overridden by verbose and debug options
	if ( $opt->{verbose} || $opt->{debug} || ! $opt->{quiet} ) {
		# Only send messages to STDERR if pvr or stdout options are being used.
		if ( $opt->{stdout} || $opt->{pvr} || $opt->{stderr} || $opt->{stream} ) {
			print STDERR $msg;
		} else {
			print STDOUT $msg;
		}
	}
}


# Pre-Parse the cmdline using the opt_format hash so that we know some of the options before we properly parse them later
# Parse options with passthru mode (i.e. ignore unknown options at this stage) 
# need to save and restore @ARGV to allow later processing)
my @argv_save = @ARGV;
$opt_pre->parse( 1 );
@ARGV = @argv_save;
# Copy a few options over to opt so that logger works
$opt->{debug} = $opt->{verbose} = 1 if $opt_pre->{debug};
$opt->{verbose} = 1 if $opt_pre->{verbose};
$opt->{quiet} = 1 if $opt_pre->{quiet};
$opt->{pvr} = 1 if $opt_pre->{pvr};
$opt->{stdout} = 1 if $opt_pre->{stdout} || $opt_pre->{stream};

# show version and exit
if ( $opt_pre->{showver} ) {
	print STDERR gip::Options->copyright_notice;
	exit 0;
}

# This is where all profile data/caches/cookies etc goes
my $profile_dir;
# This is where system-wide default options are specified
my $optfile_system;

# Options directories specified by env vars
if ( defined $ENV{GETIPLAYERUSERPREFS} && $ENV{GETIPLAYERSYSPREFS} ) {
	$profile_dir = $opt_pre->{profiledir} || $ENV{GETIPLAYERUSERPREFS};
	$optfile_system = $ENV{GETIPLAYERSYSPREFS};

# Otherwise look for windows style file locations
} elsif ( defined $ENV{USERPROFILE} ) {
	$profile_dir = $opt_pre->{profiledir} || $ENV{USERPROFILE}.'/.get_iplayer';
	$optfile_system = $ENV{ALLUSERSPROFILE}.'/get_iplayer/options';

# Options on unix-like systems
} elsif ( defined $ENV{HOME} ) {
	$profile_dir = $opt_pre->{profiledir} || $ENV{HOME}.'/.get_iplayer';
	$optfile_system = '/etc/get_iplayer/options';
	# Show warning if this deprecated location exists and is not a symlink
	if ( -f '/var/lib/get_iplayer/options' && ! -l '/var/lib/get_iplayer/options' ) {
		logger "WARNING: System-wide options file /var/lib/get_iplayer/options will be deprecated in future, please use /etc/get_iplayer/options instead\n";
	}
}
# Make profile dir if it doesnt exist
mkpath $profile_dir if ! -d $profile_dir;


# get list of additional user plugins and load plugin
my $plugin_dir_system = '/usr/share/get_iplayer/plugins';
my $plugin_dir_user = "$profile_dir/plugins";
for my $plugin_dir ( ( $plugin_dir_user, $plugin_dir_system ) ) {
	if ( opendir( DIR, $plugin_dir ) ) {
		#logger "INFO: Checking for plugins in $plugin_dir\n";
		my @plugin_file_list = grep /^.+\.plugin$/, readdir DIR;
		closedir DIR;
		for ( @plugin_file_list ) {
			#logger "INFO: Got $_\n";
			chomp();
			$_ = "$plugin_dir/$_";
			m{^.*\/(.+?).plugin$};
			# keep in a hash for update
			$plugin_files{$_} = $1.'.plugin';
			# Skip if we have this plugin already
			next if (! $1) || $prog_types{$1};
			# Register the plugin
			$prog_types{$1} = "gip::Programme::$1";
			#logger "INFO: Loading $_\n";
			require $_;
			# Kludge: Create dummy instance (without a single instance, none of the bound options work)
			$prog_types{$1}->new();
		}
	}
}


# Set the personal options according to the specified preset
my $optfile_default = "${profile_dir}/options";
my $optfile_preset;
if ( $opt_pre->{preset} ) {
	# create dir if it does not exist
	mkpath "${profile_dir}/presets/" if ! -d "${profile_dir}/presets/";
        # Sanitize preset file name
	my $presetname = StringUtils::sanitize_path( $opt_pre->{preset} );
	$optfile_preset = "${profile_dir}/presets/${presetname}";
	logger "INFO: Using user options preset '${presetname}'\n";
}
logger "DEBUG: User Preset Options File: $optfile_preset\n" if defined $optfile_preset && $opt->{debug};


# Parse cmdline opts definitions from each Programme class/subclass
gip::Options->get_class_options( $_ ) for qw( gip::Streamer gip::Programme gip::PVR );
gip::Options->get_class_options( progclass($_) ) for progclass();
gip::Options->get_class_options( "gip::Streamer::$_" ) for qw( mms rtmp rtsp iphone mms 3gp http );


# Parse the cmdline using the opt_format hash
gip::Options->usage( 0 ) if not $opt_cmdline->parse();


# Parse options if we're not saving/adding/deleting options (system-wide options are overridden by personal options)
if ( ! ( $opt_pre->{prefsadd} || $opt_pre->{prefsdel} || $opt_pre->{prefsclear} ) ) {
	# Load options from files into $opt_file
	# system, Default, './.get_iplayer/options' and Preset options in that order should they exist
	$opt_file->load( $opt, '/var/lib/get_iplayer/options', $optfile_system, $optfile_default, './.get_iplayer/options', $optfile_preset );
	# Copy these loaded options into $opt
	$opt->copy_set_options_from( $opt_file );
}


# Copy to $opt from opt_cmdline those options which are actually set 
$opt->copy_set_options_from( $opt_cmdline );


# Update or show user opts file (or preset if defined) if required
if ( $opt_cmdline->{presetlist} ) {
	$opt->preset_list( "${profile_dir}/presets/" );
	exit 0;
} elsif ( $opt_cmdline->{prefsadd} ) {
	$opt->add( $opt_cmdline, $optfile_preset || $optfile_default, @ARGV );
	exit 0;
} elsif ( $opt_cmdline->{prefsdel} ) {
	$opt->del( $opt_cmdline, $optfile_preset || $optfile_default, @ARGV );
	exit 0;
} elsif ( $opt_cmdline->{prefsshow} ) {
	$opt->show( $optfile_preset || $optfile_default );
	exit 0;
} elsif ( $opt_cmdline->{prefsclear} ) {
	$opt->clear( $optfile_preset || $optfile_default );
	exit 0;
}


# List all valid programme type plugins (and built-ins)
if ( $opt->{listplugins} ) {
	main::logger join(',', keys %prog_types)."\n";
	exit 0;
}

# Show copyright notice
logger gip::Options->copyright_notice if not $opt->{nocopyright};

# Display prefs dirs if required
main::logger "INFO: User prefs dir: $profile_dir\n" if $opt->{verbose};
main::logger "INFO: System options dir: $optfile_system\n" if $opt->{verbose};


# Display Usage
gip::Options->usage( 2 ) if $opt_cmdline->{helpbasic};
gip::Options->usage( 0 ) if $opt_cmdline->{help};
gip::Options->usage( 1 ) if $opt_cmdline->{helplong};

# Dump all option keys and descriptions if required
gip::Options->usage( 1, 0, 1 ) if $opt_pre->{dumpoptions};

# Generate man page
gip::Options->usage( 1, $opt_cmdline->{manpage} ) if $opt_cmdline->{manpage};

# Display GPLv3 stuff
if ( $opt_cmdline->{warranty} || $opt_cmdline->{conditions}) {
	# Get license from GNU
	logger request_url_retry( create_ua( 'get_iplayer', 1 ), 'http://www.gnu.org/licenses/gpl-3.0.txt'."\n", 1);
	exit 1;
}

# Force plugins update if no plugins found
if ( ! keys %plugin_files ) {
	logger "WARNING: Running the updater again to obtain plugins.\n";
	$opt->{pluginsupdate} = 1;
}
# Update this script if required
update_script() if $opt->{update} || $opt->{pluginsupdate};



########## Global vars ###########

#my @cache_format = qw/index type name pid available episode versions duration desc channel categories thumbnail timeadded guidance web/;
my @history_format = qw/pid name episode type timeadded mode filename versions duration desc channel categories thumbnail guidance web episodenum seriesnum/;
# Ranges of numbers used in the indicies for each programme type
my $max_index = 0;
for ( progclass() ) {
	# Set maximum index number
	$max_index = progclass($_)->index_max if progclass($_)->index_max > $max_index;
}

# Setup signal handlers
$SIG{INT} = $SIG{PIPE} = \&cleanup;

# Other Non option-dependant vars
my $historyfile		= "${profile_dir}/download_history";
my $cookiejar		= "${profile_dir}/cookies.";
my $namedpipe 		= "${profile_dir}/namedpipe.$$";
my $lwp_request_timeout	= 20;
my $info_limit		= 40;
my $proxy_save;

# Option dependant var definitions
my $bin;
my $binopts;
my @search_args = @ARGV;
my $memcache = {};


########### Main processing ###########

# Use --webrequest to specify options in urlencoded format
if ( $opt->{webrequest} ) {
	# parse GET args
	my @webopts = split /[\&\?]/, $opt->{webrequest};
	for (@webopts) {
		# URL decode it
		$_ = main::url_decode( $_ );
		my ( $optname, $value );
		# opt val pair
		if ( m{^\s*([\w\-]+?)[\s=](.+)$} ) {
			( $optname, $value ) = ( $1, $2 );
		# flag only
		} elsif ( m{^\s*([\w\-]+)$} ) {
			( $optname, $value ) = ( $1, 1 );
		}
		# if the option is valid then add it
		if ( defined $opt_format->{$optname} ) {
			$opt_cmdline->{$optname} = $value;
			logger "INFO: webrequest OPT: $optname=$value\n" if $opt->{verbose};
		# Ignore invalid opts
		} else {
			logger "ERROR: Invalid webrequest OPT: $optname=$value\n" if $opt->{verbose};
		}
	}
	# Copy to $opt from opt_cmdline those options which are actually set - allows pvr-add to work which only looks at cmdline args
	$opt->copy_set_options_from( $opt_cmdline );
	# Remove this option now we've processed it
	delete $opt->{webrequest};
	delete $opt_cmdline->{webrequest};
}

# Add --search option to @search_args if specified
if ( defined $opt->{search} ) {
	push @search_args, $opt->{search};
	# Remove this option now we've processed it
	delete $opt->{search};
	delete $opt_cmdline->{search};
}
# Assume search term is '.*' if nothing is specified - i.e. lists all programmes
push @search_args, '.*' if ! $search_args[0];

# Auto-detect http:// url or <type>:http:// in a search term and set it as a --pid option (disable if --fields is used).
if ( $search_args[0] =~ m{^(\w+:)?http://} && ( ! $opt->{pid} ) && ( ! $opt->{fields} ) ) {
	$opt->{pid} = $search_args[0];
}

# PVR Lockfile location (keep global so that cleanup sub can unlink it)
my $lockfile;
$lockfile = $profile_dir.'/pvr_lock' if $opt->{pvr} || $opt->{pvrsingle} || $opt->{pvrscheduler};

# Delete cookies each session
unlink($cookiejar.'desktop');
unlink($cookiejar.'safari');
unlink($cookiejar.'coremedia');

# Create new PVR instance
# $pvr->{searchname}->{<option>} = <value>;
my $pvr = gip::PVR->new();
# Set some class-wide values
$pvr->setvar('pvr_dir', "${profile_dir}/pvr/" );

# PVR functions
if ( $opt->{pvradd} ) {
	$pvr->add( $opt->{pvradd}, @search_args );

} elsif ( $opt->{pvrdel} ) {
	$pvr->del( $opt->{pvrdel} );

} elsif ( $opt->{pvrdisable} ) {
	$pvr->disable( $opt->{pvrdisable} );

} elsif ( $opt->{pvrenable} ) {
	$pvr->enable( $opt->{pvrenable} );

} elsif ( $opt->{pvrlist} ) {
	$pvr->display_list();

} elsif ( $opt->{pvrqueue} ) {
	$pvr->queue( @search_args );

} elsif ( $opt->{pvrscheduler} ) {
	if ( $opt->{pvrscheduler} < 1800 ) {
		main::logger "ERROR: PVR schedule duration must be at least 1800 seconds\n";
		unlink $lockfile;
		exit 5;
	};
	# PVR Lockfile detection (with 12 hrs stale lockfile check)
	lockfile( 43200 ) if ! $opt->{test};
	$pvr->run_scheduler();

} elsif ( $opt->{pvr} ) {
	# PVR Lockfile detection (with 12 hrs stale lockfile check)
	lockfile( 43200 ) if ! $opt->{test};
	$pvr->run( @search_args );
	unlink $lockfile;

} elsif ( $opt->{pvrsingle} ) {
	# PVR Lockfile detection (with 12 hrs stale lockfile check)
	lockfile( 43200 ) if ! $opt->{test};
	$pvr->run( '^'.$opt->{pvrsingle}.'$' );
	unlink $lockfile;

# Record prog specified by --pid option
} elsif ( $opt->{pid} ) {
	my $hist = History->new();
	find_pid_matches( $hist );

# Show history
} elsif ( $opt->{history} ) {
	my $hist = History->new();
	$hist->list_progs( @search_args );

# Else just process command line args
} else {
	my $hist = History->new();
	download_matches( $hist, find_matches( $hist, @search_args ) );
	purge_downloaded_files( $hist, 30 );
}
exit 0;



sub init_search {
	# Show options
	$opt->display('Current options') if $opt->{verbose};
	# $prog->{pid}->object hash
	my $prog = {};
	# obtain prog object given index. e.g. $index_prog->{$index_no}->{element};
	my $index_prog = {};
	# hash of prog types specified
	my $type = {};
	logger "INFO: Search args: '".(join "','", @search_args)."'\n" if $opt->{verbose};

	# Ensure lowercase types
	$opt->{type} = lc( $opt->{type} );
	# Expand 'all' type to comma separated list all prog types
	$opt->{type} = join( ',', progclass() ) if $opt->{type} =~ /(all|any)/i;
	$type->{$_} = 1 for split /,/, $opt->{type};
	# --stream is the same as --stdout --nowrite
	if ( $opt->{stream} ) {
		$opt->{nowrite} = 1;
		$opt->{stdout} = 1;
		delete $opt->{stream};
	}
	# Redirect STDOUT to player command if one is specified
	if ( $opt->{player} && $opt->{nowrite} && $opt->{stdout} ) {
		open (STDOUT, "| $opt->{player}") || die "ERROR: Cannot open player command\n";
		STDOUT->autoflush(1);
		binmode STDOUT;
	}
	# Default to type=tv if no type option is set
	$type->{tv}		= 1 if keys %{ $type } == 0;

	# External Binaries
	$bin->{mplayer}		= $opt->{mplayer} || 'mplayer';
	delete $binopts->{mplayer};
	push @{ $binopts->{mplayer} }, '-nolirc';
	push @{ $binopts->{mplayer} }, '-v' if $opt->{debug};
	push @{ $binopts->{mplayer} }, '-really-quiet' if $opt->{quiet};

	$bin->{ffmpeg}		= $opt->{ffmpeg} || 'ffmpeg';

	$bin->{lame}		= $opt->{lame} || 'lame';
	delete $binopts->{lame};
	$binopts->{lame}	= '-f';
	$binopts->{lame}	.= ' --quiet ' if $opt->{quiet};

	$bin->{vlc}		= $opt->{vlc} || 'cvlc';
	delete $binopts->{vlc};
	push @{ $binopts->{vlc} }, '-vv' if $opt->{debug};

	$bin->{id3v2}		= $opt->{id3v2} || 'id3v2';
	$bin->{atomicparsley}	= $opt->{atomicparsley} || 'AtomicParsley';

	$bin->{tee}		= 'tee';

	$bin->{flvstreamer}	= $opt->{flvstreamer} || $opt->{rtmpdump} || 'flvstreamer';
	delete $binopts->{flvstreamer};
	push @{ $binopts->{flvstreamer} }, ( '--timeout', 10 );
	push @{ $binopts->{flvstreamer}	}, '--quiet' if $opt->{quiet};
	push @{ $binopts->{flvstreamer}	}, '--verbose' if $opt->{verbose};
	push @{ $binopts->{flvstreamer}	}, '--debug' if $opt->{debug};

	# quote binaries which allows for spaces in the path (only required if used via a shell)
	for ( $bin->{lame}, $bin->{tee} ) {
		s!^(.+)$!"$1"!g;
	}
	
	# Set --subtitles if --subsonly is used
	if ( $opt->{subsonly} ) {
		$opt->{subtitles} = 1;
	}

	# Set --thumbnail if --thumbonly is used
	if ( $opt->{thumbonly} ) {
		$opt->{thumb} = 1;
	}

	# Set --get && --nowrite if --metadataonly is used
	if ( $opt->{metadataonly} ) {
		if ( ! $opt->{metadata} ) {
			main::logger "ERROR: Please specify metadata type using --metadata=<type>\n";
			exit 2;
		}
	}

	# List all options and where they are set from then exit
	if ( $opt_cmdline->{showoptions} ) {
		# Show all options andf where set from
		$opt_file->display('Options from Files');
		$opt_cmdline->display('Options from Command Line');
		$opt->display('Options Used');
		logger "Search Args: ".join(' ', @search_args)."\n\n";
	}

	# Sanity check some conflicting options
	if ( $opt->{nowrite} && ! $opt->{stdout} ) {
		logger "ERROR: Cannot record to nowhere\n";
		exit 1;
	}

	# Sanity check valid --type specified
	for (keys %{ $type }) {
		if ( not progclass($_) ) {
			logger "ERROR: Invalid type '$_' specified. Valid types are: ".( join ',', progclass() )."\n";
			exit 3;
		}
	}
	
	# Web proxy
	$opt->{proxy} = $ENV{HTTP_PROXY} || $ENV{http_proxy} if not $opt->{proxy};
	logger "INFO: Using Proxy $opt->{proxy}\n" if $opt->{proxy};

	# Display the ages of the selected caches in seconds
	if ( $opt->{showcacheage} ) {
		for ( keys %{ $type } ) {
			my $cachefile = "${profile_dir}/${_}.cache";
			main::logger "INFO: $_ cache age: ".( time() - stat($cachefile)->mtime )." secs\n" if -f $cachefile;
		}
		exit 0;
	}
	return ( $type, $prog, $index_prog );
}



sub find_pid_matches {
	my $hist = shift;
	my @search_args = @_;
	my ( $type, $prog, $index_prog ) = init_search( @search_args );

	# Get prog by arbitrary '<type>:<pid>' or just '<pid>' (using the specified types)(then exit)
	my @try_types;
	my $pid;

	# If $opt->{pid} is in the form of '<type>:<pid>' and <type> is a valid type
	if ( $opt->{pid} =~ m{^(.+?)\:(.+?)$} && progclass(lc($1)) ) {
		my $prog_type;
		( $prog_type, $pid )= ( lc($1), $2 );
		# Only try to recording using this prog type
		@try_types = ($prog_type);
			
	# $opt->{pid} is in the form of '<pid>'
	} else {
		$pid = $opt->{pid};
		@try_types = (keys %{ $type });
	}
	logger "INFO: Will try prog types: ".(join ',', @try_types)."\n" if $opt->{verbose};
	return 0 if ( ! ( $opt->{multimode} || $opt->{metadataonly} || $opt->{info} || $opt->{thumbonly} || $opt->{subsonly} ) ) && $hist->check( $pid );	

	# Maybe we don't want to populate caches - this slows down --pid recordings ...
	# Populate cache with all specified prog types (strange perl bug?? - @try_types is empty after these calls if done in a $_ 'for' loop!!)
	# only get links and possibly refresh caches if > 1 type is specified
	# else only load cached data from file if it exists.
	my $load_from_file_only;
	$load_from_file_only = 1 if $#try_types == 0;
	for my $t ( @try_types ) {
		get_links( $prog, $index_prog, $t, $load_from_file_only );
	}

	# Simply record pid if we find it in the caches
	if ( $prog->{$pid}->{pid} ) {
		return download_pid_in_cache( $hist, $prog->{$pid} );
	}

	my $totalretcode = 1;
	my $quit_attempt = 0;
	my %done_pids;
	for my $prog_type ( @try_types ) {
		last if $quit_attempt;
	
		# See if the specified pid has other episode pids embedded - results in another list of pids.
		my $dummy = progclass($prog_type)->new( 'pid' => $pid, 'type' => $prog_type );
		my @pids = $dummy->get_pids_recursive();

		# Try to get pid using each speficied prog type
		# process all pids in @pids
		for my $pid ( @pids ) {
			# skip this pid if we have already completed it
			next if $done_pids{$pid};
			main::logger "INFO: Trying pid: $pid using type: $prog_type\n";
			my $retcode;
			if ( not $prog->{$pid}->{pid} ) {
				$retcode = download_pid_not_in_cache( $hist, $pid, $prog_type );
				# don't try again for other types because it was recorded successfully
				$done_pids{$pid} = 1 if ! $retcode;
			} else {
				$retcode = download_pid_in_cache( $hist, $prog->{$pid} );
				# if it's in the cache then there is no need to try this pid for other types
				$done_pids{$pid} = 1;
			}
			$totalretcode += $retcode;
		}
	}

	# return zero on success of all pid recordings (used for PVR queue)
	return $totalretcode;
}



sub download_pid_not_in_cache {
	my $hist = shift;
	my $pid = shift;
	my $prog_type = shift;
	my $retcode;

	# Force prog type and create new prog instance if it doesn't exist
	my $this;
	logger "INFO Trying to stream pid using type $prog_type\n";
	logger "INFO: pid not found in $prog_type cache\n";
	$this = progclass($prog_type)->new( 'pid' => $pid, 'type' => $prog_type );
	# if only one type is specified then we can clean up the pid which might actually be a url
	#if ( $#try_types == 0 ) {
		logger "INFO: Cleaning pid Old: '$this->{pid}', " if $opt->{verbose};
		$this->clean_pid;
		logger " New: '$this->{pid}'\n" if $opt->{verbose};
	#}
	# Display pid match for recording
	if ( $opt->{history} ) {
		$hist->list_progs( 'pid:'.$pid );
	}
	# Don't do a pid recording if metadataonly or thumbonly were specified
	if ( !( $opt->{metadataonly} || $opt->{thumbonly} || $opt->{subsonly} ) ) {
		return $this->download_retry_loop( $hist );
	}
}



sub download_pid_in_cache {
	my $hist = shift;
	my $this = shift;
	my $retcode;

	# Prune future scheduled match if not specified
	if ( (! $opt->{future}) && gip::Programme::get_time_string( $this->{available} ) > time() ) {
		# If the prog object exists with pid in history delete it from the prog list
		logger "INFO: Ignoring Future Prog: '$this->{index}: $this->{name} - $this->{episode} - $this->{available}'\n" if $opt->{verbose};
		# Don't attempt to download
		return 1;
	}
	logger "INFO Trying to stream pid using type $this->{type}\n";
	logger "INFO: pid found in cache\n";
	# Display pid match for recording
	if ( $opt->{history} ) {
		$hist->list_progs( 'pid:'.$this->{pid} );
	} else {
		list_progs( { $this->{type} => 1 }, $this );
	}
	# Don't do a pid recording if metadataonly or thumbonly were specified
	if ( !( $opt->{metadataonly} || $opt->{thumbonly} || $opt->{subsonly} ) ) {
		$retcode = $this->download_retry_loop( $hist );
	}
	return $retcode;
}



# Use the specified options to process the matches in specified array
# Usage: find_matches( $pids_history_ref, @search_args )
# Returns: array of objects to be downloaded
#      or: number of failed/remaining programmes to record using the match (excluding previously recorded progs) if --pid is specified
sub find_matches {
	my $hist = shift;
	my @search_args = @_;
	my ( $type, $prog, $index_prog ) = init_search( @search_args );

	# We don't actually need to get the links first for the specifiied type(s) if we have only index number specified (and not --list)
	my %got_cache;
	my $need_get_links = 0;
	if ( (! $opt->{list} ) ) {
		for ( @search_args ) {
			if ( (! /^[\d]+$/) || $_ > $max_index || $_ < 1 ) {
				logger "DEBUG: arg '$_' is not a programme index number - load specified caches\n" if $opt->{debug};
				$need_get_links = 1;
				last;
			}
		}
	}

	# Pre-populate caches if --list option used or there was a non-index specified
	if ( $need_get_links || $opt->{list} ) {
		# Get stream links from web site or from cache (also populates all hashes) specified in --type option
		for my $t ( keys %{ $type } ) {
			get_links( $prog, $index_prog, $t );
			$got_cache{ $t } = 1;
		}
	}

	# Parse remaining args
	my @match_list;
	my @index_search_args;
	for ( @search_args ) {
		chomp();

		# If Numerical value < $max_index and the object exists from loaded prog types
		if ( /^[\d]+$/ && $_ <= $max_index ) {
			if ( defined $index_prog->{$_} ) {
				logger "INFO: Search term '$_' is an Index value\n" if $opt->{verbose};
				push @match_list, $index_prog->{$_};
			} else {
				# Add to another list to search in other prog types
				push @index_search_args, $_;
			}

		# If PID then find matching programmes with 'pid:<pid>'
		} elsif ( m{^\s*pid:(.+?)\s*$}i ) {
			if ( defined $prog->{$1} ) {
				logger "INFO: Search term '$1' is a pid\n" if $opt->{verbose};
				push @match_list, $prog->{$1};
			} else {
				logger "INFO: Search term '$1' is a non-existent pid, use --pid instead and/or specify the correct programme type\n";
			}

		# Else assume this is a programme name regex
		} else {
			logger "INFO: Search term '$_' is a substring\n" if $opt->{verbose};
			push @match_list, get_regex_matches( $prog, $_ );
		}
	}
	
	# List elements (i.e. 'channel' 'categories') if required and exit
	if ( $opt->{list} ) {
		list_unique_element_counts( $type, $opt->{list}, @match_list );
		exit 0;
	}

	# Go get the cached data for other programme types if the index numbers require it
	for my $index ( @index_search_args ) {
		# see if this index number falls into a valid range for a prog type
		for my $prog_type ( progclass() ) {
			if ( $index >= progclass($prog_type)->index_min && $index <= progclass($prog_type)->index_max && ( ! $got_cache{$prog_type} ) ) {
				logger "DEBUG: Looking for index $index in $prog_type type\n" if $opt->{debug};
				# Get extra required programme caches
				logger "INFO: Additionally getting cached programme data for $prog_type\n" if $opt->{verbose};
				# Add new prog types to the type list
				$type->{$prog_type} = 1;
				# Get $prog_type stream links
				get_links( $prog, $index_prog, $prog_type );
				$got_cache{$prog_type} = 1;
			}
		}
		# Now check again if the index number exists in the cache before adding this prog to the match list
		if ( defined $index_prog->{$index}->{pid} ) {
			push @match_list, $index_prog->{$index} if defined $index_prog->{$index}->{pid};
		} else {
			logger "WARNING: Unmatched programme index '$index' specified - ignoring\n";
		}
	}

	# De-dup matches and retain order
	@match_list = main::make_array_unique_ordered( @match_list );

	# Prune out pids already recorded if opt{hide} is specified (cannot hide for multimode)
	if ( $opt->{hide} && ( not $opt->{force} ) && ( not $opt->{multimode} ) ) {
		my @pruned;
		for my $this (@match_list) {
			# If the prog object exists with pid in history delete it from the prog list
			if ( $hist->check( $this->{pid}, undef, 1 ) ) {
				logger "DEBUG: Ignoring Prog: '$this->{index}: $this->{name} - $this->{episode}'\n" if $opt->{debug};
			} else {
				push @pruned, $this;
			}
		}
		@match_list = @pruned;
	}

	# Prune future scheduled matches if not specified
	if ( ! $opt->{future} ) {
		my $now = time();
		my @pruned;
		for my $this (@match_list) {
			# If the prog object exists with pid in history delete it from the prog list
			my $available = gip::Programme::get_time_string( $this->{available} );
			if ( $available && $available > $now ) {
				logger "DEBUG: Ignoring Future Prog: '$this->{index}: $this->{name} - $this->{episode} - $this->{available}'\n" if $opt->{debug};
			} else {
				push @pruned, $this;
			}
		}
		@match_list = @pruned;		
	}
		
	# Truncate the array of matches if --limit-matches is specified
	if ( $opt->{limitmatches} && $#match_list > $opt->{limitmatches} - 1 ) {
		$#match_list = $opt->{limitmatches} - 1;
		main::logger "WARNING: The list of matching results was limited to $opt->{limitmatches} by --limit-matches\n";
	}

	# Display list for recording
	list_progs( $type, @match_list );

	# Write HTML and XML files if required (with search options applied)
	create_html_file( @match_list ) if $opt->{html};
	create_html_email( (join ' ', @search_args), @match_list ) if $opt->{email};
	create_xml( $opt->{fxd}, @match_list ) if $opt->{fxd};
	create_xml( $opt->{mythtv}, @match_list ) if $opt->{mythtv};

	return @match_list;
}



sub download_matches {
	my $hist = shift;
	my @match_list = @_;

	# Do the recordings based on list of index numbers if required
	my $failcount;
	if ( $opt->{get} || $opt->{stdout} ) {
		for my $this (@match_list) {
			$failcount += $this->download_retry_loop( $hist );
		}
	}

	return $failcount;
}



# Usage: list_progs( \%type, @prog_refs )
# Lists progs given an array of index numbers
sub list_progs {
	my $typeref = shift;
	# Use a rogue value if undefined
	my $number_of_types = keys %{$typeref} || 2;
	my $ua = create_ua( 'desktop', 1 );
	my %names;
	my ( @matches ) = ( @_ );
	

	# Setup user agent for a persistent connection to get programme metadata
	if ( $opt->{info} ) {
		# Truncate array if were lisiting info and > $info_limit entries are requested - be nice to the beeb!
		if ( $#matches >= $info_limit ) {
			$#matches = $info_limit - 1;
			logger "WARNING: Only processing the first $info_limit matches\n";
		}
	}

	# Sort array by specified field
	if ( $opt->{sortmatches} ) {
		# disable tree mode
		delete $opt->{tree};

		# Lookup table for numeric search fields
		my %sorttype = (
			index		=> 1,
			duration	=> 1,
			timeadded	=> 1,
		);
		my $sort_prog;
		for my $this ( @matches ) {
			# field needs to be made to be unique by adding '|pid'
			$sort_prog->{ "$this->{ $opt->{sortmatches} }|$this->{pid}" } = $this;
		}
		@matches = ();
		# Numeric search
		if ( defined $sorttype{ $opt->{sortmatches} } ) {
			for my $key ( sort {$a <=> $b} keys %{ $sort_prog } ) {
				push @matches, $sort_prog->{$key};
			}
		# alphanumeric search
		} else {
			for my $key ( sort {lc $a cmp lc $b} keys %{ $sort_prog } ) {
				push @matches, $sort_prog->{$key};
			}
		}
	}
	# Reverse sort?
	if ( $opt->{sortreverse} ) {
		my @tmp = reverse @matches;
		@matches = @tmp;
	}

	# Determine number of episodes for each name
	my %episodes;
	my $episode_width;
	if ( $opt->{series} ) {
		for my $this (@matches) {
			$episodes{ $this->{name} }++;
			$episode_width = length( $this->{name} ) if length( $this->{name} ) > $episode_width;
		}
	}

	# Sort display order by field (won't work in tree mode)
	

	# Calculate page sizes etc if required
	my $items = $#matches+1;
	my ( $pages, $page, $pagesize, $first, $last );
	if ( ! $opt->{page} ) {
		logger "Matches:\n" if $#matches >= 0;
	} else {
		$pagesize = $opt->{pagesize} || 25;
		# Calc first and last programme numbers
		$first = $pagesize * ( $opt->{page} - 1 );
		$last = $first + $pagesize;
		# How many pages
		$pages = int( $items / $pagesize ) + 1;
		# If we request a page that is too high
		$opt->{page} = $pages if $page > $pages;
		logger "Matches (Page $opt->{page}/${pages}".()."):\n" if $#matches >= 0;
	}
	# loop through all programmes in match
	for ( my $count=0; $count < $items; $count++ ) {
		my $this = $matches[$count];
		# Only display if the prog name is set
		if ( ( ! $opt->{page} ) || ( $opt->{page} && $count >= $first && $count < $last ) ) {
			if ( $this->{name} || ! ( $opt->{series} || $opt->{tree} ) ) {
				# Tree mode
				if ( $opt->{tree} ) {
					if (! defined $names{ $this->{name} }) {
						$this->list_entry( '', 0, $number_of_types );
						$names{ $this->{name} } = 1;
					} else {
						$this->list_entry( '', 1, $number_of_types );
					}
				# Series mode
				} elsif ( $opt->{series} ) {
					if (! defined $names{ $this->{name} }) {
						$this->list_entry( '', 0, $number_of_types, $episodes{ $this->{name} }, $episode_width );
						$names{ $this->{name} } = 1;
					}
				# Normal mode
				} else {
					$this->list_entry( '', 0, $number_of_types );
				}
			}
		}
		# Get info, create metadata, subtitles and/or thumbnail file (i.e. don't stream/record)
		if ( $opt->{info} || $opt->{metadataonly} || $opt->{thumbonly} || $opt->{subsonly} || $opt->{streaminfo} ) {
			$this->get_metadata_general();
			if ( $this->get_metadata( $ua ) ) {
				main::logger "ERROR: Could not get programme metadata\n" if $opt->{verbose};
				next;
			}
			# Search versions for versionlist versions
			my @versions = $this->generate_version_list;
			# Use first version in list if a version list is not specified
			$this->{version} = $versions[0] || 'default';
			$this->generate_filenames( $ua, $this->file_prefix_format() );
			# info
			$this->display_metadata( sort keys %{ $this } ) if $opt->{info};
			# subs
			if ( $opt->{subsonly} ) {
				# skip for non-tv
				$this->download_subtitles( $ua, "$this->{dir}/$this->{fileprefix}.srt" ) if $this->{type} eq 'tv';
			}
			# metadata
			$this->create_metadata_file if $opt->{metadataonly};
			# thumbnail
			$this->download_thumbnail if $opt->{thumbonly} && $this->{thumbnail};
			# streaminfo
			if ( $opt->{streaminfo} ) {
				main::display_stream_info( $this, $this->{verpids}->{$version}, $version );
				$opt->{quiet} = 0;
			}
			# remove offending metadata
			delete $this->{filename};
			delete $this->{filepart};
			delete $this->{ext};
		}
	}
	logger "\nINFO: ".($#matches + 1)." Matching Programmes\n" if ( $opt->{pvr} && $#matches >= 0 ) || ! $opt->{pvr};
}



# Returns matching programme objects using supplied regex
# Usage: get_regex_matches ( \%prog, $regex )
sub get_regex_matches {
	my $prog = shift;
	my $download_regex = shift;

	my %download_hash;
	my ( $channel_regex, $category_regex, $versions_regex, $channel_exclude_regex, $category_exclude_regex, $exclude_regex );

	if ( $opt->{channel} ) {
		$channel_regex = '('.(join '|', ( split /,/, $opt->{channel} ) ).')';
	} else {
		$channel_regex = '.*';
	}
	if ( $opt->{category} ) {
		$category_regex = '('.(join '|', ( split /,/, $opt->{category} ) ).')';
	} else {
		$category_regex = '.*';
	}
	if ( $opt->{versionlist} ) {
		$versions_regex = '('.(join '|', ( split /,/, $opt->{versionlist} ) ).')';
	} else {
		$versions_regex = '.*';
	}
	if ( $opt->{excludechannel} ) {
		$channel_exclude_regex = '('.(join '|', ( split /,/, $opt->{excludechannel} ) ).')';
	} else {
		$channel_exclude_regex = '^ROGUE$';
	}
	if ( $opt->{excludecategory} ) {
		$category_exclude_regex = '('.(join '|', ( split /,/, $opt->{excludecategory} ) ).')';
	} else {
		$category_exclude_regex = '^ROGUE$';
	}
	if ( $opt->{exclude} ) {
		$exclude_regex = '('.(join '|', ( split /,/, $opt->{exclude} ) ).')';
	} else {
		$exclude_regex = '^ROGUE$';
	}
	my $since = $opt->{since} || 999999;
	my $before = $opt->{before} || -999999;
	my $now = time();

	if ( $opt->{verbose} ) {
		main::logger "DEBUG: Search download_regex = $download_regex\n";
		main::logger "DEBUG: Search channel_regex = $channel_regex\n";
		main::logger "DEBUG: Search category_regex = $category_regex\n";
		main::logger "DEBUG: Search versions_regex = $versions_regex\n";
		main::logger "DEBUG: Search exclude_regex = $exclude_regex\n";
		main::logger "DEBUG: Search channel_exclude_regex = $channel_exclude_regex\n";
		main::logger "DEBUG: Search category_exclude_regex = $category_exclude_regex\n";
		main::logger "DEBUG: Search since = $since\n";
		main::logger "DEBUG: Search before = $before\n";
	}
	
	# Determine fields to search
	my @searchfields;
	# User-defined fields list
	if ( $opt->{fields} ) {
		@searchfields = split /\s*,\s*/, lc( $opt->{fields} );
	# Also search long descriptions and episode data if -l is specified
	} elsif ( $opt->{long} ) {
		@searchfields = ( 'name', 'episode', 'desc' );
	# Default to name search only
	} else {
		@searchfields = ( 'name' );
	}

	# Loop through each prog object
	for my $this ( values %{ $prog } ) {
		# Only include programmes matching channels and category regexes
		if ( $this->{channel} =~ /$channel_regex/i
		  && $this->{categories} =~ /$category_regex/i
		  && ( ( not defined $this->{versions} ) || $this->{versions} =~ /$versions_regex/i )
		  && $this->{channel} !~ /$channel_exclude_regex/i
		  && $this->{categories} !~ /$category_exclude_regex/i
		  && ( ( not defined $this->{timeadded} ) || $this->{timeadded} >= $now - ($since * 3600) )
		  && ( ( not defined $this->{timeadded} ) || $this->{timeadded} < $now - ($before * 3600) )
		) {
			# Add included matches
			my @compund_fields;
			push @compund_fields, $this->{$_} for @searchfields;
			$download_hash{ $this->{index} } = $this if (join ' ', @compund_fields) =~ /$download_regex/i;
		}
	}
	# Remove excluded matches
	for my $field ( @searchfields ) {
		for my $index ( keys %download_hash ) {
			my $this = $download_hash{$index};
			delete $download_hash{$index} if $this->{ $field } =~ /$exclude_regex/i;
		}
	}
	my @match_list;
	# Add all matching prog objects to array
	for my $index ( sort {$a <=> $b} keys %download_hash ) {
		push @match_list, $download_hash{$index};
	}

	return @match_list;
}



# Usage: sort_index( \%prog, \%index_prog, [$prog_type], [sortfield] )
# Populates the index if the prog hash as well as creating the %index_prog hash
# Should be run after any number of get_links methods
sub sort_index {
	my $prog = shift;
	my $index_prog = shift;
	my $prog_type = shift;
	my $sortfield = shift || 'name';
	my $counter = 1;
	my @sort_key;
	
	# Add index field based on alphabetical sorting by $sortfield
	# Start index counter at 'min' for this prog type
	$counter = progclass($prog_type)->index_min if defined $prog_type;

	# Create unique array of '<$sortfield|pid>' for this prog type
	for my $pid ( keys %{$prog} ) {
		# skip prog not of correct type and type is defined
		next if defined $prog_type && $prog->{$pid}->{type} ne $prog_type;
		push @sort_key, "$prog->{$pid}->{$sortfield}|$pid";
	}
	# Sort by $sortfield and index 
	for (sort @sort_key) {
		# Extract pid
		my $pid = (split /\|/)[1];

		# Insert prog instance var of the index number
		$prog->{$pid}->{index} = $counter;

		# Add the object reference into %index_prog hash
		$index_prog->{ $counter } = $prog->{$pid};

		# Increment the index counter for this prog type
		$counter++;
	}
	return 0;
}



sub make_array_unique_ordered {
	# De-dup array and retain order (don't ask!)
	my ( @array ) = ( @_ );
	my %seen = ();
	my @unique = grep { ! $seen{ $_ }++ } @array;
	return @unique;
}



# User Agents
# Uses global $ua_cache
my $ua_cache = {};
sub user_agent {
	my $id = shift || 'desktop';

	# Create user agents lists
	my $user_agent = {
		update		=> [ "get_iplayer updater (v${version} - $^O - $^V)" ],
		get_iplayer	=> [ "get_iplayer/$version $^O/$^V" ],
		desktop		=> [
				'Mozilla/4.0 (compatible; MSIE 7.0; Windows NT 5.1; .NET CLR 2.0.50<RAND>; .NET CLR 3.0.4506.2152; .NET CLR 3.5.30<RAND>; InfoPath.1)',
				'Mozilla/4.0 (compatible; MSIE 7.0; Windows NT 6.0; YPC 3.2.0; SLCC1; .NET CLR 2.0.50<RAND>; .NET CLR 3.0.04<RAND>)',
				'Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 6.1; WOW64; Trident/4.0; SLCC2; .NET CLR 2.0.50<RAND>; .NET CLR 3.5.30<RAND>; .NET CLR 3.0.30<RAND>; Media Center PC 6.0; InfoPath.2; MS-RTC LM 8)',
				'Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US) AppleWebKit/<RAND>.8 (KHTML, like Gecko) Chrome/2.0.178.0 Safari/<RAND>.8',
				'Mozilla/5.0 (compatible; MSIE 7.0; Windows NT 6.0; SLCC1; .NET CLR 2.0.50<RAND>; Media Center PC 5.0; c .NET CLR 3.0.0<RAND>6; .NET CLR 3.5.30<RAND>; InfoPath.1; el-GR)',
				'Mozilla/5.0 (Macintosh; U; PPC Mac OS X 10_4_11; tr) AppleWebKit/<RAND>.4+ (KHTML, like Gecko) Version/4.0dp1 Safari/<RAND>.11.2',
				'Mozilla/6.0 (Windows; U; Windows NT 7.0; en-US; rv:1.9.0.8) Gecko/2009032609 Firefox/3.0.9 (.NET CLR 3.5.30<RAND>)',
				'Opera/9.64 (X11; Linux i686; U; en) Presto/2.1.1',
				],
		safari		=> [
				'Mozilla/5.0 (iPhone; U; CPU iPhone OS 2_0 like Mac OS X; en-us) AppleWebKit/525.18.1 (KHTML, like Gecko) Version/3.1.1 Mobile/5A345 Safari/525.20',
				'Mozilla/5.0 (iPhone; U; CPU iPhone OS 2_0_1 like Mac OS X; en-us) AppleWebKit/525.18.1 (KHTML, like Gecko) Version/3.1.1 Mobile/5B108 Safari/525.20',
				'Mozilla/5.0 (iPhone; U; CPU iPhone OS 3_0 like Mac OS X; en-us) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7A341 Safari/528.16',
				'Mozilla/5.0 (iPhone; U; CPU iPhone OS 3_0_1 like Mac OS X; en-us) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7A400 Safari/528.16',
				'Mozilla/5.0 (iPhone; U; CPU iPhone OS 3_1_2 like Mac OS X; en-us) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7D11 Safari/528.16',
				'Mozilla/5.0 (iPhone; U; CPU iPhone OS 3_1_3 like Mac OS X; en-us) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7E18 Safari/528.16',
				],
		coremedia	=> [
				'Apple iPhone v1.1.4 CoreMedia v1.0.0.4A102',
				'Apple iPhone v1.1.5 CoreMedia v1.0.0.4B1',
				'Apple iPhone OS v2.0 CoreMedia v1.0.0.5A347',
				'Apple iPhone OS v2.0.1 CoreMedia v1.0.0.5B108',
				'Apple iPhone OS v2.1 CoreMedia v1.0.0.5F136',
				'Apple iPhone OS v2.1 CoreMedia v1.0.0.5F137',
				'Apple iPhone OS v2.1.1 CoreMedia v1.0.0.5F138',
				'Apple iPhone OS v2.2 CoreMedia v1.0.0.5G77',
				'Apple iPhone OS v2.2 CoreMedia v1.0.0.5G77a',
				'Apple iPhone OS v2.2.1 CoreMedia v1.0.0.5H11',
				'Apple iPhone OS v3.0 CoreMedia v1.0.0.7A341',
				'Apple iPhone OS v3.1.2 CoreMedia v1.0.0.7D11',
				],
	};

	# Remember the ua string for the entire session
	my $uas = $ua_cache->{$id};
	if ( ! $uas ) {
		# Randomize strings
		my @ualist = @{ $user_agent->{$id} };
		$uas = $ualist[rand @ualist];
		my $code = sprintf( "%03d", int(rand(1000)) );
		$uas =~ s/<RAND>/$code/g;
		$ua_cache->{$id} = $uas;
	}
	logger "DEBUG: Using $id user-agent string: '$uas'\n" if $opt->{debug};
	return $uas || '';
}



# Returns classname for prog type or if not specified, an array of all prog types
sub progclass {
	my $prog_type = shift;
	if ( $prog_type ) {
		return $prog_types{$prog_type};
	} elsif ( not defined $prog_type ) {
		return keys %prog_types;
	} else {
		main::logger "ERROR: Programe Type '$prog_type' does not exist. Try using --refresh\n";
		exit 3;
	}
}



# Returns classname for prog type or if not specified, an array of all prog types
sub is_prog_type {
	my $prog_type = shift;
	return 1 if defined $prog_types{$prog_type};
	return 0;
}



# Feed Info:
#	# aod index
#	http://www.bbc.co.uk/radio/aod/index_noframes.shtml
# 	# schedule feeds
#	http://www.bbc.co.uk/bbcthree/programmes/schedules.xml
#	# These need drill-down to get episodes:
#	# TV schedules by date
#	http://www.bbc.co.uk/iplayer/widget/schedule/service/cbeebies/date/20080704
#	# TV schedules in JSON, Yaml or XML
#	http://www.bbc.co.uk/<channel>/programmes/schedules.(json|yaml|xml)
#	# prog schedules by channel / date
#	http://www.bbc.co.uk/<channel>/programmes/schedules/(this_week|next_week|last_week|yesterday|today|tomorrow).(json|yaml|xml)
#	http://www.bbc.co.uk/<channel>/programmes/schedules/<year>/<month>/<day>[/ataglance].(json|yaml|xml)
#	http://www.bbc.co.uk/<channel>/programmes/schedules/<year>/<week>.(json|yaml|xml)
#	# TV index on programmes tv
#	http://www.bbc.co.uk/tv/programmes/a-z/by/*/player
#	# TV + Radio
#	http://www.bbc.co.uk/programmes/a-z/by/*/player
#	# All TV (limit has effect of limiting to 2.? times number entries kB??)
#	# seems that only around 50% of progs are available here compared to programmes site:
#	http://feeds.bbc.co.uk/iplayer/categories/tv/list/limit/200
#	# Search feed
#	http://feeds.bbc.co.uk/iplayer/<channel>/<searchword>/list
#	# All Radio
#	http://feeds.bbc.co.uk/iplayer/categories/radio/list/limit/999
#	# New:
#	# iCal feeds see: http://www.bbc.co.uk/blogs/radiolabs/2008/07/some_ical_views_onto_programme.shtml
#	http://bbc.co.uk/programmes/b0079cmw/episodes/player.ics
#	# Other data
#	http://www.bbc.co.uk/cbbc/programmes/genres/childrens/player
#	http://www.bbc.co.uk/programmes/genres/childrens/schedules/upcoming.ics
#
# Usage: get_links( \%prog, \%index_prog, <prog_type>, <only load from file flag> )
# Globals: $memcache
sub get_links {
	my $prog = shift;
	my $index_prog = shift;
	my $prog_type = shift;
	my $only_load_from_cache = shift;
	# Define cache file format (this is overridden by the header line of the cache file)
	my @cache_format = qw/index type name pid available episode seriesnum episodenum versions duration desc channel categories thumbnail timeadded guidance web/;

	my $now = time();
	my $cachefile = "${profile_dir}/${prog_type}.cache";

	# Read cache into $pid_old and $index_prog_old hashes if cache exists
	my $prog_old = {};
	my $index_prog_old = {};

	# By pass re-sorting and get straight from memcache if possible
	if ( keys %{ $memcache->{$prog_type} } && -f $cachefile && ! $opt->{refresh} ) {
		for my $pid ( keys %{ $memcache->{$prog_type} } ) {
			# Create new prog instance
			$prog->{$pid} = progclass( lc($memcache->{$prog_type}->{$pid}->{type}) )->new( 'pid' => $pid );
			# Deep-copy of elements in memcache prog instance to %prog
			$prog->{$pid}->{$_} = $memcache->{$prog_type}->{$pid}->{$_} for @cache_format;
			# Copy pid into index_prog hash
			$index_prog->{ $prog->{$pid}->{index} } = $pid;
		}
		logger "INFO: Got (quick) ".(keys %{ $memcache->{$prog_type} })." memcache entries for $prog_type\n" if $opt->{verbose};
		return 0;
	}

	# Open cache file (need to verify we can even read this)
	if ( -f $cachefile && open(CACHE, "< $cachefile") ) {
		my @cache_format_old = @cache_format;
		# Get file format and contents less any comments
		while (<CACHE>) {
			chomp();
			# Get cache format if specified
			if ( /^\#(.+?\|){3,}/ ) {
				@cache_format_old = split /[\#\|]/;
				shift @cache_format_old;
				logger "INFO: Cache format from existing $prog_type cache file: ".(join ',', @cache_format_old)."\n" if $opt->{debug};
				next;
			}
			# Ignore comments
			next if /^[\#\s]/;
			# Populate %prog_old from cache
			# Get cache line
			my @record = split /\|/;
			my $record_entries;
			# Update fields in %prog_old hash for $pid
			$record_entries->{$_} = shift @record for @cache_format_old;
			$prog_old->{ $record_entries->{pid} } = $record_entries;
			# Copy pid into index_prog_old hash
			$index_prog_old->{ $record_entries->{index} }  = $record_entries->{pid};
		}
		close (CACHE);
		logger "INFO: Got ".(keys %{ $prog_old })." file cache entries for $prog_type\n" if $opt->{verbose};

	# Else no mem or file cache
	} else {
		logger "INFO: No file cache exists for $prog_type\n" if $opt->{verbose};
	}


	# Do we need to refresh the cache ?
	# if a cache file doesn't exist/corrupted/empty, refresh option is specified or original file is older than $cache_sec then download new data
	my $cache_secs = $opt->{expiry} || main::progclass( $prog_type )->expiry() || 14400;
	main::logger "DEBUG: Cache expiry time for $prog_type is ${cache_secs} secs - refresh in ".( stat($cachefile)->mtime + $cache_secs - $now )." secs\n" if $opt->{debug} && -f $cachefile && ! $opt->{refresh};
	if ( (! $only_load_from_cache) && 
		( (! keys %{ $prog_old } ) || (! -f $cachefile) || $opt->{refresh} || ($now >= ( stat($cachefile)->mtime + $cache_secs )) )
	) {

		# Get links for specific type of programme class into %prog 
		if ( progclass( $prog_type )->get_links( $prog, $prog_type ) != 0 ) {
			# failed - leave cache unchanged
			main::logger "ERROR: Failed to retrieve programmes for $prog_type - skipping\n";
			return 0;
		}

		# Sort index for this prog type from cache file
		# sorts and references %prog objects into %index_prog
		sort_index( $prog, $index_prog, $prog_type );

		# Open cache file for writing
		unlink $cachefile;
		my $now = time();
		if ( open(CACHE, "> $cachefile") ) {
			print CACHE "#".(join '|', @cache_format)."\n";
			# loop through all progs just obtained through get_links above (in numerical index order)
			for my $index ( sort {$a <=> $b} keys %{$index_prog} ) {
				# prog object
				my $this = $index_prog->{ $index };
				# Only write entries for correct prog type
				if ( $this->{type} eq $prog_type ) {
					# Merge old and new data to retain timestamps
					# if the entry was in old cache then retain timestamp from old entry
					if ( $prog_old->{ $this->{pid} }->{timeadded} ) {
						$this->{timeadded} = $prog_old->{ $this->{pid} }->{timeadded};
					# Else this is a new entry
					} else {
						$this->{timeadded} = $now;
						$this->list_entry( 'Added: ' );
					}
					# Write each field into cache line
					print CACHE $this->{$_}.'|' for @cache_format;
					print CACHE "\n";
				}
			}
			close (CACHE);
		} else {
			logger "WARNING: Couldn't open cache file '$cachefile' for writing\n";
		}

		# Copy new progs into memcache
		for my $index ( keys %{ $index_prog } ) {
			my $pid = $index_prog->{ $index }->{pid};
			# Update fields in memcache from %prog hash for $pid
			$memcache->{$prog_type}->{$pid}->{$_} = $index_prog->{$index}->{$_} for @cache_format;
		}

		# purge pids in memcache that aren't in %prog
		for my $pid ( keys %{ $memcache->{$prog_type} } ) {
			if ( ! defined $prog->{$pid} ) {
				delete $memcache->{$prog_type}->{$pid};
				main::logger "DEBUG: Removed PID $pid from memcache\n" if $opt->{debug};
			}
		}


	# Else copy data from existing cache file into new prog instances and memcache
	} else {
		for my $pid ( keys %{ $prog_old } ) {

			# Create new prog instance
			$prog->{$pid} = progclass( lc($prog_old->{$pid}->{type}) )->new( 'pid' => $pid );

			# Deep-copy the data from %prog_old into %prog and $memcache->{$prog_type}
			for (@cache_format) {
				$prog->{$pid}->{$_} = $prog_old->{$pid}->{$_};
				# Update fields in memcache from %prog_old hash for $pid
				$memcache->{$prog_type}->{$pid}->{$_} = $prog_old->{$pid}->{$_};
			}

		}
		# Add prog objects to %index_prog hash
		$index_prog->{$_} = $prog->{ $index_prog_old->{$_} } for keys %{ $index_prog_old };
	}

	return 0;
}



# Generic
# Returns an offset timestamp given an srt begin or end timestamp and offset in ms
sub subtitle_offset {
	my ( $timestamp, $offset ) = @_;
	my ( $hr, $min, $sec, $ms ) = split /[:,\.]/, $timestamp;
	# split into hrs, mins, secs, ms
	my $ts = $ms + $sec*1000 + $min*60*1000 + $hr*60*60*1000 + $offset;
	$hr = int( $ts/(60*60*1000) );
	$ts -= $hr*60*60*1000;
	$min = int( $ts/(60*1000) );
	$ts -= $min*60*1000;
	$sec = int( $ts/1000 );
	$ts -= $sec*1000;
	$ms = $ts;
	return sprintf( '%02d:%02d:%02d,%03d', $hr, $min, $sec, $ms );
}



# Generic
sub display_stream_info {
	my ($prog, $verpid, $version) = (@_);
	# default version is 'default'
	$version = 'default' if not defined $verpid;
	# Get stream data if not defined
	if ( not defined $prog->{streams}->{$version} ) {
		logger "INFO: Getting media stream metadata for $prog->{name} - $prog->{episode}, $verpid ($version)\n" if $prog->{pid};
		$prog->{streams}->{$version} = $prog->get_stream_data( $verpid );
	}
	for my $prog_type ( sort keys %{ $prog->{streams}->{$version} } ) {
		logger "stream:     $prog_type\n";
		for my $entry ( sort keys %{ $prog->{streams}->{$version}->{$prog_type} } ) {
			logger sprintf("%-11s %s\n", $entry.':', $prog->{streams}->{$version}->{$prog_type}->{$entry} );
		}
		logger "\n";
	}
	return 0;
}



sub proxy_disable {
	my $ua = shift;
	$ua->proxy( ['http'] => undef );
	$proxy_save = $opt->{proxy};
	delete $opt->{proxy};
	main::logger "INFO: Disabled proxy: $proxy_save\n" if $opt->{verbose};
}



sub proxy_enable {
	my $ua = shift;
	$ua->proxy( ['http'] => $opt->{proxy} ) if $opt->{proxy} && $opt->{proxy} !~ /^prepend:/;
	$opt->{proxy} = $proxy_save;
	main::logger "INFO: Restored proxy to $opt->{proxy}\n" if $opt->{verbose};
}



# Generic
# Usage download_block($file, $url_2, $ua, $start, $end, $file_len, $fh);
#  ensure filehandle $fh is open in append mode
# or, $content = download_block(undef, $url_2, $ua, $start, $end, $file_len);
# Called in 4 ways:
# 1) write to real file			=> download_block($file, $url_2, $ua, $start, $end, $file_len, $fh);
# 2) write to real file + STDOUT	=> download_block($file, $url_2, $ua, $start, $end, $file_len, $fh); + $opt->{stdout}==true
# 3) write to STDOUT only		=> download_block($file, $url_2, $ua, $start, $end, $file_len, $fh); + $opt->{stdout}==true + $opt->{nowrite}==false
# 4) write to memory (and return data)  => download_block(undef, $url_2, $ua, $start, $end, $file_len, undef);
# 4) write to memory (and return data)  => download_block(undef, $url_2, $ua, $start, $end);
sub download_block {

	my ($file, $url, $ua, $start, $end, $file_len, $fh) = @_;
	my $orig_length;
	my $buffer;
	my $lastpercent = 0;
	my $now = time();
	
	# If this is an 'append to file' mode call
	if ( defined $file && $fh && (!$opt->{nowrite}) ) {
		# Stage 3b: Record File
		$orig_length = tell $fh;
		logger "INFO: Appending to $file\n" if $opt->{verbose};
	}

	# Setup request headers
	my $h = new HTTP::Headers(
		'User-Agent'	=> main::user_agent( 'coremedia' ),
		'Accept'	=> '*/*',
		'Range'        => "bytes=${start}-${end}",
	);

	# Use url prepend if required
	if ( defined $opt->{proxy} && $opt->{proxy} =~ /^prepend:/ ) {
		$url = $opt->{proxy}.main::url_encode( $url );
		$url =~ s/^prepend://g;
	}

	my $req = HTTP::Request->new ('GET', $url, $h);

	# Set time to use for download rate calculation
	# Define callback sub that gets called during download request
	# This sub actually writes to the open output file and reports on progress
	my $callback = sub {
		my ($data, $res, undef) = @_;
		# Don't write the output to the file if there is no content-length header
		return 0 if ( ! $res->header("Content-Length") );
		# If we don't know file length in advanced then set to size reported reported from server upon download
		$file_len = $res->header("Content-Length") + $start if ! defined $file_len;
		# Write output
		print $fh $data if ! $opt->{nowrite};
		print STDOUT $data if $opt->{stdout};
		# return if streaming to stdout - no need for progress
		return if $opt->{stdout} && $opt->{nowrite};
		return if $opt->{quiet};
		# current file size
		my $size = tell $fh;
		# Download percent
		my $percent = 100.0 * $size / $file_len;
		# Don't update display if we haven't dowloaded at least another 0.1%
		if ( not $opt->{hash} ) {
			return if ($percent - $lastpercent) < 0.1;
		} else {
			return if ($percent - $lastpercent) < 1;
		}
		$lastpercent = $percent;
		if ( $opt->{hash} ) {
			logger '#';
		} else {
			# download rates in bytes per second and time remaining
			my $rate_bps;
			my $rate;
			my $time;
			my $timecalled = time();
			if ($timecalled - $now < 1) {
				$rate = '-----kbps';
				$time = '--:--:--';
			} else {
				$rate_bps = ($size - $orig_length) / ($timecalled - $now);
				$rate = sprintf("%5.0fkbps", (8.0 / 1024.0) * $rate_bps);
				$time = sprintf("%02d:%02d:%02d", ( gmtime( ($file_len - $size) / $rate_bps ) )[2,1,0] );
			}
			logger sprintf "%8.2fMB / %.2fMB %s %5.1f%%, %s remaining         \r", 
				$size / 1024.0 / 1024.0, 
				$file_len / 1024.0 / 1024.0,
				$rate,
				$percent,
				$time,
			;
		}
	};

	my $callback_memory = sub {
		my ($data, $res, undef) = @_;
		# append output to buffer
		$buffer .= $data;
		return if $opt->{quiet};
		# current buffer size
		my $size = length($buffer);
		# download rates in bytes per second
		my $timecalled = time();
		my $rate_bps;
		my $rate;
		my $time;
		my $percent;
		# If we can get Content_length then display full progress
		if ($res->header("Content-Length")) {
			$file_len = $res->header("Content-Length") if ! defined $file_len;
			# Download percent
			$percent = 100.0 * $size / $file_len;
			if ( not $opt->{hash} ) {
				return if ($percent - $lastpercent) < 0.1;
			} else {
				return if ($percent - $lastpercent) < 1;
			}
			$lastpercent = $percent;
			if ( $opt->{hash} ) {
				logger '#';
			} else {
				# Block length
				$file_len = $res->header("Content-Length");
				if ($timecalled - $now < 0.1) {
					$rate = '-----kbps';
					$time = '--:--:--';
				} else {
					$rate_bps = $size / ($timecalled - $now);
					$rate = sprintf("%5.0fkbps", (8.0 / 1024.0) * $rate_bps );
					$time = sprintf("%02d:%02d:%02d", ( gmtime( ($file_len - $size) / $rate_bps ) )[2,1,0] );
				}
				# time remaining
				logger sprintf "%8.2fMB / %.2fMB %s %5.1f%%, %s remaining         \r", 
					$size / 1024.0 / 1024.0,
					$file_len / 1024.0 / 1024.0,
					$rate,
					$percent,
					$time,
				;
			}
		# Just used simple for if we cannot determine content length
		} else {
			if ($timecalled - $now < 0.1) {
				$rate = '-----kbps';
			} else {
				$rate = sprintf("%5.0fkbps", (8.0 / 1024.0) * $size / ($timecalled - $now) );
			}
			logger sprintf "%8.2fMB %s         \r", $size / 1024.0 / 1024.0, $rate;
		}
	};

	# send request
	logger "\nINFO: Downloading range ${start}-${end}\n" if $opt->{verbose};
	logger "\r                              \r" if not $opt->{hash};
	my $res;

	# If $fh undefined then get block to memory (fh always defined for stdout or file d/load)
	if (defined $fh) {
		logger "DEBUG: writing stream to stdout, Range: $start - $end of $url\n" if $opt->{verbose} && $opt->{stdout};
		logger "DEBUG: writing stream to $file, Range: $start - $end of $url\n" if $opt->{verbose} && !$opt->{nowrite};
		$res = $ua->request($req, $callback);
		if (  (! $res->is_success) || (! $res->header("Content-Length")) ) {
			logger "ERROR: Failed to Download block\n\n";
			return 5;
		}
                logger "INFO: Content-Length = ".$res->header("Content-Length")."                               \n" if $opt->{verbose};
		return 0;
		   
	# Memory Block
	} else {
		logger "DEBUG: writing stream to memory, Range: $start - $end of $url\n" if $opt->{debug};
		$res = $ua->request($req, $callback_memory);
		if ( (! $res->is_success) ) {
			logger "ERROR: Failed to Download block\n\n";
			return '';
		} else {
			return $buffer;
		}
	}
}



# Generic
# create_ua( <agentname>|'', [<cookie mode>] )
# cookie mode:	0: retain cookies
#		1: no cookies
#		2: retain cookies but discard if site requires it
sub create_ua {
	my $id = shift || '';
	my $nocookiejar = shift || 0;
	# Use either the key from the function arg if it exists or a random ua string
	my $agent = main::user_agent( $id ) || main::user_agent( 'desktop' );
	my $ua = LWP::UserAgent->new;
	$ua->timeout( $lwp_request_timeout );
	$ua->proxy( ['http'] => $opt->{proxy} ) if $opt->{proxy} && $opt->{proxy} !~ /^prepend:/;
	$ua->agent( $agent );
	# Using this slows down stco parsing!!
	#$ua->default_header( 'Accept-Encoding', 'gzip,deflate' );
	$ua->conn_cache(LWP::ConnCache->new());
	#$ua->conn_cache->total_capacity(50);
	$ua->cookie_jar( HTTP::Cookies->new( file => $cookiejar.$id, autosave => 1, ignore_discard => 1 ) ) if not $nocookiejar;
	$ua->cookie_jar( HTTP::Cookies->new( file => $cookiejar.$id, autosave => 1 ) ) if $nocookiejar == 2;
	main::logger "DEBUG: Using ".($nocookiejar ? "NoCookies " : "cookies.$id " )."user-agent '$agent'\n" if $opt->{debug};
	return $ua;
};	



# Generic
# Converts a string of chars to it's HEX representation
sub get_hex {
        my $buf = shift || '';
        my $ret = '';
        for (my $i=0; $i<length($buf); $i++) {
                $ret .= " ".sprintf("%02lx", ord substr($buf, $i, 1) );
        }
	logger "DEBUG: HEX string value = $ret\n" if $opt->{verbose};
        return $ret;
}



# Generic
# version of unix tee
# Usage tee ($infile, $outfile)
# If $outfile is undef then just cat file to STDOUT
sub tee {
	my ( $infile, $outfile ) = @_;
	# Open $outfile for writing, $infile for reading
	if ( $outfile) {
		if ( ! open( OUT, "> $outfile" ) ) {
			logger "ERROR: Could not open $outfile for writing\n";
			return 1;
		} else {
			logger "INFO: Opened $outfile for writing\n" if $opt->{verbose};
		}
	}
	if ( ! open( IN, "< $infile" ) ) {
		logger "ERROR: Could not open $infile for reading\n";
		return 2;
	} else {
		logger "INFO: Opened $infile for reading\n" if $opt->{verbose};
	}
	# Read and redirect IN
	while ( <IN> ) {
		print $_;
		print OUT $_ if $outfile;
	}
	# Close output file
	close OUT if $outfile;
	close IN;
	return 0;
}



# Generic
# Usage: $fh = open_file_append($filename);
sub open_file_append {
	local *FH;
	my $file = shift;
	# Just in case we actually write to the file - make this /dev/null
	$file = '/dev/null' if $opt->{nowrite};
	if ($file) {
		if ( ! open(FH, ">> $file") ) {
			logger "ERROR: Cannot write or append to $file\n\n";
			exit 1;
		}
	}
	# Fix for binary - needed for Windows
	binmode FH;
	return *FH;
}



# Generic
# Updates and overwrites this script - makes backup as <this file>.old
# Update logic:
# If the get_iplayer script is unwritable then quit - makes it harder for deb/rpm installed scripts to be overwritten
# If any available plugins in $plugin_dir_system are not writable then abort
# If all available plugins in $plugin_dir_system are writable then:
#	if any available plugins in $plugin_dir_user are not writable then abort
#	if all available plugins in $plugin_dir_user are writable then:
#		update script
#		update matching plugins in $plugin_dir_system
#		update matching plugins in $plugin_dir_user
#		warn of any plugins that are not in $plugin_dir_system or $plugin_dir_user and not available
sub update_script {
	my $version_url	= 'http://linuxcentre.net/get_iplayer/VERSION-get_iplayer';
	my $update_url	= 'http://linuxcentre.net/get_iplayer/get_iplayer';
	my $changelog_url = 'http://linuxcentre.net/get_iplayer/CHANGELOG.txt';
	my $latest_ver;
	# Get version URL
	my $script_file = $0;
	my $script_url;
	my %plugin_url;
	my $ua = create_ua( 'update', 1 );

	# Are we flagged as installed using a pkg manager?
	if ( $opt->{packagemanager} ) {
		if ( $opt->{packagemanager} =~ /(apt|deb|dpkg)/i ) {
			logger "INFO: Please run the following commands to update get_iplayer using $opt->{packagemanager}\n".
			"  wget http://linuxcentre.net/get_iplayer/packages/get-iplayer-current.deb\n".
			"  sudo dpkg -i get-iplayer-current.deb\n".
			"  sudo apt-get -f install\n";
		} elsif ( $opt->{packagemanager} =~ /yum/i ) {
			logger "INFO: Please run the following commands as root to update get_iplayer using $opt->{packagemanager}\n".
			"  wget http://linuxcentre.net/get_iplayer/packages/get_iplayer-current.noarch.rpm\n".
			"  yum --nogpgcheck localinstall get_iplayer-current.noarch.rpm\n";
		} elsif ( $opt->{packagemanager} =~ /rpm/i ) {
			logger "INFO: Please run the following command as root to update get_iplayer using $opt->{packagemanager}\n".
			"  rpm -Uvh http://linuxcentre.net/get_iplayer/packages/get_iplayer-current.noarch.rpm\n";
		} elsif ( $opt->{packagemanager} =~ /disable/i ) {
			logger "ERROR: get_iplayer should only be updated using your local package management system, for more information see http://linuxcentre.net/installation\n";
		} else {
			logger "ERROR: get_iplayer was installed using '$opt->{packagemanager}' package manager please refer to the update documentation at http://linuxcentre.net/getiplayer/installation/\n";
		}
		exit 1;
	} 

	# If the get_iplayer script is unwritable then quit - makes it harder for deb/rpm installed scripts to be overwritten
	if ( ! -w $script_file ) {
		logger "ERROR: $script_file is not writable - aborting update (maybe a package manager was used to install get_iplayer?)\n";
		exit 1;
	}

	# Force update if no plugins dir
	if ( ! -d "$profile_dir/plugins" ) {
		mkpath "$profile_dir/plugins";
		if ( ! -d "$profile_dir/plugins" ) {
			logger "ERROR: Cannot create '$profile_dir/plugins' - no plugins will be downloaded.\n";
			return 1;
		}
		$opt->{pluginsupdate} = 1;
	}

	logger "INFO: Current version is ".(sprintf '%.2f', $version)."\n";
	logger "INFO: Checking for latest version from linuxcentre.net\n";
	if ( $latest_ver = request_url_retry($ua, $version_url, 3 ) ) {
		chomp($latest_ver);
		# Compare version numbers
		if ( $latest_ver > $version || $opt->{force} || $opt->{pluginsupdate} ) {
			# reformat version number
			$latest_ver = sprintf('%.2f', $latest_ver);
			logger "INFO: Newer version $latest_ver available\n" if $latest_ver > $version;
			
			# Get the manifest of files to be updated
			my $base_url = "${update_url}-${latest_ver}";
			my $res;
			if ( not $res = request_url_retry($ua, "$base_url/MANIFEST.txt", 3 ) ) {
				logger "ERROR: Failed to obtain update file manifest - Update aborted\n";
				exit 3;
			}

			# get a list of plugins etc from the manifest
			for ( split /\n/, $res ) {
				chomp();
				my ( $type, $url) = split /\s/;
				if ( $type eq 'bin' ) {
					$script_url =  $url;
				} elsif ( $type eq 'plugins' ) {
					my $filename = $url;
					$filename =~ s|^.+/(.+?)$|$1|g;
					$plugin_url{$filename} = $url;
				}
			}

			# Now decide whether to update based on write permissions
			# %plugin_files:      contains hash of current full_path_to_plugin_file -> plugin_filename
			# %plugin_url:      contains a hash of plugin_filename -> update_url for available plugins from the update site

			# If any available plugins in $plugin_dir_system are not writable then abort
			# if any available plugins in $plugin_dir_user are not writable then abort

			# loop through each currently installed plugin
			for my $path ( keys %plugin_files ) {
				my $file = $plugin_files{$path};
				# If this in the list of available plugins
				if ( $plugin_url{$file} ) {
					if ( ! -w $path ) {
						logger "ERROR: Cannot write plugin $path - aborting update\n";
						exit 1;
					}
				# warn of any plugins that are not in $plugin_dir_system or $plugin_dir_user and not available
				} else {
					logger "WARNING: Plugin $path is not managed - not updating this plugin\n";
				}
			}

			# All available plugins in all plugin dirs are writable:
			# update script if required
			if ( $latest_ver > $version || $opt->{force} ) {
				logger "INFO: Updating $script_file (from $version to $latest_ver)\n";
				update_file( $ua, $script_url, $script_file ) if ! $opt->{test};
			}
			for my $path ( keys %plugin_files ) {
				my $file = $plugin_files{$path};
				# If there is an update available for this plugin file...
				if ( $plugin_url{$file} ) {
					logger "INFO: Updating $path\n";
					# update matching plugin
					update_file( $ua, $plugin_url{$file}, $path ) if ! $opt->{test};
				}
			}

			# Install plugins which are currently not installed
			for my $file ( keys %plugin_url ) {
				# Not found in either system or user plugins dir
				if ( ( ! -f "$plugin_dir_system/$file" ) && ( ! -f "$plugin_dir_user/$file" ) ) {
					logger "INFO: Found new plugin $file\n";
					# Is the system plugin dir writable?
					if ( -d $plugin_dir_system && -w $plugin_dir_system ) {
						logger "INFO: Installing $file in $plugin_dir_system\n";
						update_file( $ua, $plugin_url{$file}, "$plugin_dir_system/$file" ) if ! $opt->{test};
					} elsif ( -d $plugin_dir_user && -w $plugin_dir_user ) {
						logger "INFO: Installing $file in $plugin_dir_user\n";
						update_file( $ua, $plugin_url{$file}, "$plugin_dir_user/$file" ) if ! $opt->{test};
					} else {
						logger "INFO: Cannot install $file, plugin dirs are not writable\n";
					}
				}
			}

			# Show changelog since last version if this is an upgrade
			if ( $version < $latest_ver ) {
				logger "INFO: Change Log: http://linuxcentre.net/get_iplayer/CHANGELOG.txt\n";
				my $changelog = request_url_retry($ua, $changelog_url, 3 );
				my $current_ver = sprintf('%.2f', $version);
				$changelog =~ s|^(.*)Version\s+$current_ver.+$|$1|s;
				logger "INFO: Changes since version $current_ver:\n\n$changelog\n";
			}

		} else {
			logger "INFO: No update is necessary (latest version = $latest_ver)\n";
		}
				
	} else {
		logger "ERROR: Failed to connect to update site - Update aborted\n";
		exit 2;
	}

	exit 0;
}



# Updates a file:
# Usage: update_file( <ua>, <url>, <dest filename> )
sub update_file {
	my $ua = shift;
	my $url = shift;
	my $dest_file = shift;
	my $res;
	# Download the file
	if ( not $res = request_url_retry($ua, $url, 3) ) {
		logger "ERROR: Could not download update for ${dest_file} - Update aborted\n";
		exit 1;
	}
	# If the download was successful then copy over this file and make executable after making a backup of this script
	if ( -f $dest_file ) {
		if ( ! copy($dest_file, $dest_file.'.old') ) {
			logger "ERROR: Could not create backup file ${dest_file}.old - Update aborted\n";
			exit 1;
		}
	}
	# Check if file is writable
	if ( not open( FILE, "> $dest_file" ) ) {
		logger "ERROR: $dest_file is not writable by the current user - Update aborted\n";
		exit 1;
	}
	# Windows needs this
	binmode FILE;
	# Write contents to file
	print FILE $res;
	close FILE;
	chmod 0755, $dest_file;
	logger "INFO: Downloaded $dest_file\n";
}



# Usage: create_xml( @prog_objects )
# Creates the Freevo FXD or MythTV Streams meta data (and pre-downloads graphics - todo)
sub create_xml {
	my $xmlfile = shift;

	if ( ! open(XML, "> $xmlfile") ) {
		logger "ERROR: Couldn't open xml file $xmlfile for writing\n";
		return 1;
	}
	print XML "<?xml version=\"1.0\" ?>\n";
	print XML "<freevo>\n" if $opt->{fxd};
	print XML "<MediaStreams>\n" if $opt->{mythtv};

	if ( $opt->{xmlnames} ) {
		# containers sorted by prog names
		print XML "\t<container title=\"Programmes by Name\">\n" if $opt->{fxd};
		my %program_index;
		my %program_count;
		# create hash of programme_name -> index
	        for my $this (@_) {
	        	$program_index{ $this->{name} } = $_;
			$program_count{ $this->{name} }++;
		}
		for my $name ( sort keys %program_index ) {
			print XML "\t\t<container title=\"".encode_entities( $name )." ($program_count{$name})\">\n" if $opt->{fxd};
			print XML "\t<Streams>\n" if $opt->{mythtv};
			print XML "\t\t<Name>".encode_entities( $name )."</Name>\n" if $opt->{mythtv};
			for my $this (@_) {
				my $pid = $this->{pid};
				# loop through and find matches for each progname
				if ( $this->{name} eq $name ) {
					my $episode = encode_entities( $this->{episode} );
					my $desc = encode_entities( $this->{desc} );
					my $title = "${episode}";
					$title .= " ($this->{available})" if $this->{available} !~ /^(unknown|)$/i;
					if ( $opt->{fxd} ) {
						print XML "\t\t\t<movie title=\"${title}\">\n";
						print XML "\t\t\t\t<video>\n";
						print XML "\t\t\t\t\t<url id=\"p1\">${pid}.mov<playlist/></url>\n";
						print XML "\t\t\t\t</video>\n";
						print XML "\t\t\t\t<info>\n";
						print XML "\t\t\t\t\t<description>${desc}</description>\n";
						print XML "\t\t\t\t</info>\n";
						print XML "\t\t\t</movie>\n";
					} elsif ( $opt->{mythtv} ) {
						print XML "\t\t<Stream>\n";
						print XML "\t\t\t<Name>${title}</Name>\n";
						print XML "\t\t\t<type>$this->{type}</type>\n";
						print XML "\t\t\t<index>$this->{index}</index>\n";
						print XML "\t\t\t<url>${pid}.mov</url>\n";
						print XML "\t\t\t<Subtitle></Subtitle>\n";
						print XML "\t\t\t<Synopsis>${desc}</Synopsis>\n";
						print XML "\t\t\t<StreamImage>$this->{thumbnail}</StreamImage>\n";
						print XML "\t\t</Stream>\n";
					}
				}
			}			
			print XML "\t\t</container>\n" if $opt->{fxd};
			print XML "\t</Streams>\n" if $opt->{mythtv};
		}
		print XML "\t</container>\n" if $opt->{fxd};
	}


	if ( $opt->{xmlchannels} ) {
		# containers for prog names sorted by channel
		print XML "\t<container title=\"Programmes by Channel\">\n" if $opt->{fxd};
		my %program_index;
		my %program_count;
		my %channels;
		# create hash of unique channel names and hash of programme_name -> index
	        for my $this (@_) {
	        	$program_index{ $this->{name} } = $_;
			$program_count{ $this->{name} }++;
			push @{ $channels{ $this->{channel} } }, $this->{name};
		}
		for my $channel ( sort keys %channels ) {
			print XML "\t\t<container title=\"".encode_entities( $channel )."\">\n" if $opt->{fxd};
			print XML
				"\t<Feed>\n".
				"\t\t<Name>".encode_entities( $channel )."</Name>\n".
				"\t\t<Provider>BBC</Provider>\n".
				"\t\t<Streams>\n" if $opt->{mythtv};
			for my $name ( sort keys %program_index ) {
				# Do we have any of this prog $name on this $channel?
				my $match;
				for ( @{ $channels{$channel} } ) {
					$match = 1 if $_ eq $name;
				}
				if ( $match ) {
					print XML "\t\t\t<container title=\"".encode_entities( $name )." ($program_count{$name})\">\n" if $opt->{fxd};
					#print XML "\t\t<Stream>\n" if $opt->{mythtv};
					for my $this (@_) {
						# loop through and find matches for each progname for this channel
						my $pid = $this->{pid};
						if ( $this->{channel} eq $channel && $this->{name} eq $name ) {
							my $episode = encode_entities( $this->{episode} );
							my $desc = encode_entities( $this->{desc} );
							my $title = "${episode} ($this->{available})";
							if ( $opt->{fxd} ) {
								print XML
									"\t\t\t\t<movie title=\"${title}\">\n".
									"\t\t\t\t\t<video>\n".
									"\t\t\t\t\t\t<url id=\"p1\">${pid}.mov<playlist/></url>\n".
									"\t\t\t\t\t</video>\n".
									"\t\t\t\t\t<info>\n".
									"\t\t\t\t\t\t<description>${desc}</description>\n".
									"\t\t\t\t\t</info>\n".
									"\t\t\t\t</movie>\n";
							} elsif ( $opt->{mythtv} ) {
								print XML 
									"\t\t\t<Stream>\n".
									"\t\t\t\t<Name>".encode_entities( $name )."</Name>\n".
									"\t\t\t\t<index>$this->{index}</index>\n".
									"\t\t\t\t<type>$this->{type}</type>\n".
									"\t\t\t\t<Url>${pid}.mov</Url>\n".
									"\t\t\t\t<StreamImage>$this->{thumbnail}</StreamImage>\n".
									"\t\t\t\t<Subtitle>${episode}</Subtitle>\n".
									"\t\t\t\t<Synopsis>${desc}</Synopsis>\n".
									"\t\t\t</Stream>\n";
							}
						}
					}
					print XML "\t\t\t</container>\n" if $opt->{fxd};
				}
			}
			print XML "\t\t</container>\n" if $opt->{fxd};
			print XML "\t\t</Streams>\n\t</Feed>\n" if $opt->{mythtv};
		}
		print XML "\t</container>\n" if $opt->{fxd};
	}


	if ( $opt->{xmlalpha} ) {
		my %table = (
			'A-C' => '[abc]',
			'D-F' => '[def]',
			'G-I' => '[ghi]',
			'J-L' => '[jkl]',
			'M-N' => '[mn]',
			'O-P' => '[op]',
			'Q-R' => '[qt]',
			'S-T' => '[st]',
			'U-V' => '[uv]',
			'W-Z' => '[wxyz]',
			'0-9' => '[\d]',
		);
		print XML "\t<container title=\"Programmes A-Z\">\n";
		for my $folder (sort keys %table) {
			print XML "\t\t<container title=\"$folder\">\n";
			for my $this (@_) {
				my $pid = $this->{pid};
				my $name = encode_entities( $this->{name} );
				my $episode = encode_entities( $this->{episode} );
				my $desc = encode_entities( $this->{desc} );
				my $title = "${name} - ${episode} ($this->{available})";
				my $regex = $table{$folder};
				if ( $name =~ /^$regex/i ) {
					if ( $opt->{fxd} ) {
						print XML
							"\t\t\t<movie title=\"${title}\">\n".
							"\t\t\t\t<video>\n".
							"\t\t\t\t\t<url id=\"p1\">${pid}.mov<playlist/></url>\n".
							"\t\t\t\t</video>\n".
							"\t\t\t\t<info>\n".
							"\t\t\t\t\t<description>${desc}</description>\n".
							"\t\t\t\t</info>\n".
							"\t\t\t</movie>\n";
					} elsif ( $opt->{mythtv} ) {
						print XML
							"\t\t\t<Stream>\n".
							"\t\t\t\t<Name>${title}</Name>\n".
							"\t\t\t\t<index>$this->{index}</index>\n".
							"\t\t\t\t<type>$this->{type}</type>\n".
							"\t\t\t\t<Url>${pid}.mov</Url>\n".
							"\t\t\t\t<StreamImage>$this->{thumbnail}</StreamImage>\n".
							"\t\t\t\t<Subtitle>${episode}</Subtitle>\n".
							"\t\t\t\t<Synopsis>${desc}</Synopsis>\n".
							"\t\t\t</Stream>\n";
					}
				}
			}
			print XML "\t\t</container>\n";
		}
		print XML "\t</container>\n";
	}

	print XML '</freevo>' if $opt->{fxd};
	print XML '</MediaStreams>' if $opt->{mythtv};
	close XML;
}



# Usage: create_html_file( @prog_objects )
sub create_html_file {
	# Create local web page
	if ( open(HTML, "> $opt->{html}") ) {
		print HTML create_html( @_ );
		close (HTML);
	} else {
		logger "WARNING: Couldn't open html file $opt->{html} for writing\n";
	}
}



# Usage: create_email( @prog_objects )
# Reference: http://sial.org/howto/perl/Net-SMTP/
# Credit: Network Ned, andy <AT SIGN> networkned.co.uk, http://networkned.co.uk
sub create_html_email {
	# Check if we have Net::SMTP installed - might not be for the windows installer
	eval "use Net::SMTP";
	if ($@) {
		main::logger "WARNING: Please download and run latest installer or install the Net::SMTP perl module to use --email options\n";
		return 0;
	};
	my $search_args = shift;
	my $recipient = $opt->{email};
	my $sender = $opt->{emailsender} || 'get_iplayer <>';
	my $smtphost = $opt->{emailsmtp} || 'localhost';
	my @mail_failure;
	my @subject;
	# Set the subject using the currently set cmdline options
	push @subject, "get_iplayer Search Results for: $search_args ( ";
	for my $optkey ( grep !/^email.*/, sort keys %{ $opt_cmdline } ) {
		push @subject, "$optkey='$opt_cmdline->{$optkey}' " if $opt_cmdline->{$optkey};
	}
	push @subject, " )";

	my $message = "MIME-Version: 1.0\n"
		."Content-Type: text/html\n"
		."From: $sender\n"
		."To: $recipient\n"
		."Subject: @subject\n\n\n"
		.create_html( @_ )."\n";
	main::logger "DEBUG: Email message to $recipient:\n$message\n\n" if $opt->{debug};

	my $smtp = Net::SMTP->new($smtphost);
	if ( ! $smtp ) {
		main::logger "ERROR: Could not find or connect to specficied SMTP server\n";
		return 1;
	};

	$smtp->mail( $sender ) || push @mail_failure, "MAIL FROM: $sender";
	$smtp->to( $recipient ) || push @mail_failure, "RCPT TO: $recipient";
	$smtp->data() || push @mail_failure, 'DATA';
	$smtp->datasend( $message ) || push @mail_failure, 'Message Data';
	$smtp->dataend() || push @mail_failure, 'End of DATA';
	$smtp->quit() || push @mail_failure, 'QUIT';

	if ( @mail_failure ) {
		main::logger "ERROR: Sending of email failed with $mail_failure[0]\n";
	}
	return 0;
}



# Usage: create_html( @prog_objects )
sub create_html {
	my @html;
	my %name_channel;
	# Create local web page
	push @html, '<html><head></head><body><table border=1>';
	for my $this ( @_ ) {
		# Skip if pid isn't in index
		my $pid = $this->{pid} || next;
		# Skip if already recorded and --hide option is specified
		if (! defined $name_channel{ "$this->{name}|$this->{channel}" }) {
			push @html, $this->list_entry_html();
		} else {
			push @html, $this->list_entry_html( 1 );
		}
		$name_channel{ "$this->{name}|$this->{channel}" } = 1;
	}
	push @html, '</table></body>';
	return join "\n", @html;
}



# Generic
# Gets the contents of a URL and retries if it fails, returns '' if no page could be retrieved
# Usage <content> = request_url_retry(<ua>, <url>, <retries>, <succeed message>, [<fail message>], <1=mustproxy> );
sub request_url_retry {

	my %OPTS = @LWP::Protocol::http::EXTRA_SOCK_OPTS;
	$OPTS{SendTE} = 0;
	@LWP::Protocol::http::EXTRA_SOCK_OPTS = %OPTS;
	
	my ($ua, $url, $retries, $succeedmsg, $failmsg, $mustproxy) = @_;
	my $res;


	# Use url prepend if required
	if ( defined $opt->{proxy} && $opt->{proxy} =~ /^prepend:/ ) {
		$url = $opt->{proxy}.main::url_encode( $url );
		$url =~ s/^prepend://g;
	}

	# Malformed URL check
	if ( $url !~ m{^\s*http\:\/\/}i ) {
		logger "ERROR: Malformed URL: '$url'\n";
		return '';
	}

	# Disable proxy unless mustproxy is flagged
	main::proxy_disable($ua) if $opt->{partialproxy} && ! $mustproxy;
	my $i;
	logger "INFO: Getting page $url\n" if $opt->{verbose};
	for ($i = 0; $i < $retries; $i++) {
		$res = $ua->request( HTTP::Request->new( GET => $url ) );
		if ( ! $res->is_success ) {
			logger $failmsg;
		} else {
			logger $succeedmsg;
			last;
		}
	}
	# Re-enable proxy unless mustproxy is flagged
	main::proxy_enable($ua) if $opt->{partialproxy} && ! $mustproxy;
	# Return empty string if we failed
	return '' if $i == $retries;

	# Only return decoded content if gzip is used - otherwise this severely slows down stco scanning! Perl bug?
	main::logger "DEBUG: ".($res->header('Content-Encoding') || 'No')." Encoding used on $url\n" if $opt->{debug};
	return $res->decoded_content if defined $res->header('Content-Encoding') && $res->header('Content-Encoding') eq 'gzip';

	return $res->content;
}



# Generic
# Checks if a particular program exists (or program.exe) in the $ENV{PATH} or if it has a path already check for existence of file
sub exists_in_path {
	my $name = shift;
	my $bin = $bin->{$name};
	# Strip quotes around binary if any just for checking
	$bin =~ s/^"(.+)"$/$1/g;
	# If this has a path specified, does file exist
	return 1 if $bin =~ /[\/\\]/ && (-x ${bin} || -x "${bin}.exe");
	# Search PATH
	for (@PATH) {
		return 1 if -x "${_}/${bin}" || -x "${_}/${bin}.exe";
	}
	return 0;
}



# Generic
# Checks history for files that are over 30 days old and asks user if they should be deleted
# "$prog->{pid}|$prog->{name}|$prog->{episode}|$prog->{type}|".time()."|$prog->{mode}|$prog->{filename}\n";
sub purge_downloaded_files {
	my $hist = shift;
	my @delete;
	my @proglist;
	my $days = shift;
			
	# Return if disabled or running in a typically non-interactive mode
	return 0 if $opt->{nopurge} || $opt->{stdout} || $opt->{nowrite} || $opt->{quiet};
	
	for my $pid ( $hist->get_pids() ) {
		my $record = $hist->get_record( $pid );
		if ( $record->{timeadded} < (time() - $days*86400) && $record->{filename} && -f $record->{filename} ) {
			# Calculate the seconds difference between epoch_now and epoch_datestring and convert back into array_time
			my @t = gmtime( time() - $record->{timeadded} );
			push @proglist, "$record->{name} - $record->{episode}, Recorded: $t[7] days $t[2] hours ago";
			push @delete, $record->{filename};
		}
	}
	
	if ( @delete ) {
		main::logger "\nThese programmes should be deleted:\n";
		main::logger "-----------------------------------\n";
		main::logger join "\n", @proglist;
		main::logger "\n-----------------------------------\n";
		main::logger "Do you wish to delete them now (--nopurge will prevent this check) (yes/NO) ?\n";
		my $answer = <STDIN>;
		if ($answer =~ /^yes$/i ) {
			for ( @delete ) {
				main::logger "INFO: Deleting $_\n";
				unlink $_;
			}
			main::logger "Programmes deleted\n";
		} else {
			main::logger "No Programmes deleted\n";
		}
	}
	
	return 0;
}



# Returns url decoded string
sub url_decode {
	my $str = shift;
	$str =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
	return $str;
}



# Returns url encoded string
sub url_encode {
	my $str = shift;
	$str =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
	return $str;
}



# list_unique_element_counts( \%type, $element_name, @matchlist);
# Show channels for currently specified types in @matchlist - an array of progs
sub list_unique_element_counts {
	my $typeref = shift;
	my $element_name = shift;
	my @match_list = @_;
	my %elements;
	logger "INFO: ".(join ',', keys %{ $typeref })." $element_name List:\n" if $opt->{verbose};
	# Get list to count from matching progs
	for my $prog ( @match_list ) {
		my @element;
		# Need to separate the categories
		if ($element_name eq 'categories') {
			@element = split /,/, $prog->{$element_name};
		} else {
			$element[0] = $prog->{$element_name};
		}
		for my $element (@element) {
			$elements{ $element }++;
		}
	}
	# display element + prog count
	logger "$_ ($elements{$_})\n" for sort keys %elements;
	return 0;
}



# Invokes command in @args as a system call (hopefully) without using a shell
#  Can also redirect all stdout and stderr to either: STDOUT, STDERR or unchanged
# Usage: run_cmd( <normal|STDERR|STDOUT>, @args )
# Returns: exit code
sub run_cmd {
	my $mode = shift;
	my @cmd = ( @_ );
	my $rtn;
	my $USE_SYSTEM = 0;
	#my $system_suffix;

	main::logger "\n\nINFO: Command: ".(join ' ', @cmd)."\n\n" if $opt->{verbose};

	# Define what to do with STDOUT and STDERR of the child process
	my $fh_child_out = ">&STDOUT";
	my $fh_child_err = ">&STDERR";

	if ( $mode eq 'STDOUT' ) {
		$fh_child_out = $fh_child_err = ">&STDOUT";
		#$system_suffix = '2>&1';
	} elsif ( $mode eq 'STDERR' ) {
		$fh_child_out = $fh_child_err = ">&STDERR";
		#$system_suffix = '1>&2';
	}

	# Check if we have IPC::Open3 otherwise fallback on system()
	eval "use IPC::Open3";

	# use system(); - probably only likely in win32
	if ($@) {
		main::logger "WARNING: Please download and run latest installer - 'IPC::Open3' is not available\n";
		#push @cmd, $system_suffix;
		my $rtn = system( @cmd );

	# use system() regardless
	} elsif ( $USE_SYSTEM ) {
		#push @cmd, $system_suffix;
		my $rtn = system( @cmd );

	# Use open3()
	} else {

		my $procid;
		# Don't create zombies - unfortunately causes open3 to return -1 exit code regardless!
		##### local $SIG{CHLD} = 'IGNORE';
		# Setup signal handler for SIGTERM/INT/KILL - kill, kill, killlllll
		$SIG{TERM} = $SIG{PIPE} = $SIG{INT} = sub {
			my $signal = shift;
			main::logger "\nINFO: Cleaning up (signal = $signal), killing PID=$procid:";
			for my $sig ( qw/INT TERM KILL/ ) {
				# Kill process with SIGs (try to allow proper handling of kill by child process)
				if ( $opt->{verbose} ) {
					main::logger "\nINFO: $$ killing cmd PID=$procid with SIG${sig}";
				} else {
					main::logger '.';
				}
				kill $sig, $procid;
				sleep 1;
				if ( ! kill 0, $procid ) {
					main::logger "\nINFO: $$ killed cmd PID=$procid\n";
					last;
				}
				sleep 1;
			}
			main::logger "\n";
			exit 0;
		};

		# Don't use NULL for the 1st arg of open3 otherwise we end up with a messed up STDIN once it returns
		$procid = open3( 0, $fh_child_out, $fh_child_err, @cmd );

		# Wait for child to complete
		waitpid( $procid, 0 );
		$rtn = $?;

		# Restore old signal handlers
		$SIG{TERM} = $SIGORIG{TERM};
		$SIG{PIPE} = $SIGORIG{PIPE};
		$SIG{INT} = $SIGORIG{INT};
		#$SIG{CHLD} = $SIGORIG{CHLD};
	}

	# Interpret return code	and force return code 2 upon error      
	my $return = $rtn >> 8;
	if ( $rtn == -1 ) {
		main::logger "ERROR: Command failed to execute: $!\n" if $opt->{verbose};
		$return = 2 if ! $return;
	} elsif ( $rtn & 128 ) {
		main::logger "WARNING: Command executed but coredumped\n" if $opt->{verbose};
		$return = 2 if ! $return;
	} elsif ( $rtn & 127 ) {
		main::logger sprintf "WARNING: Command executed but died with signal %d\n", $rtn & 127 if $opt->{verbose};
		$return = 2 if ! $return;
	}
	main::logger sprintf "INFO: Command exit code %d (raw code = %d)\n", $return, $rtn if $return || $opt->{verbose};
	return $return;
}



# Generic
# Escape chars in string for shell use
sub StringUtils::esc_chars {
	# will change, for example, a!!a to a\!\!a
	$_[0] =~ s/([;<>\*\|&\$!#\(\)\[\]\{\}:'"])/\\$1/g;
}



sub StringUtils::clean_utf8_and_whitespace {
	# Remove non utf8
	$_[0] =~ s/[^\x{21}-\x{7E}\s\t\n\r]//g;
	# Strip beginning/end/extra whitespace
	$_[0] =~ s/\s+/ /g;
	$_[0] =~ s/(^\s+|\s+$)//g;
}



# Generic
# Signal handler to clean up after a ctrl-c or kill
sub cleanup {
	my $signal = shift;
	logger "\nINFO: Cleaning up $0 (got signal $signal)\n"; # if $opt->{verbose};
	unlink $namedpipe;
	unlink $lockfile;
	# Execute default signal handler
	$SIGORIG{$signal}->() if $SIGORIG{$signal};
	exit 1;
}



# Generic
# Make a filename/path sane (optionally allow fwd slashes)
sub StringUtils::sanitize_path {
	my $string = shift;
	my $allow_fwd_slash = shift || 0;

	# Remove fwd slash if reqd
	$string =~ s/\//_/g if ! $allow_fwd_slash;

	# Replace backslashes with _ regardless
	$string =~ s/\\/_/g;
	# Sanitize by default
	$string =~ s/\s+/_/g if (! $opt->{whitespace}) && (! $allow_fwd_slash);
	$string =~ s/[^\w_\-\.\/\s]//gi if ! $opt->{whitespace};
	$string =~ s/[\|\\\?\*\<\"\:\>\+\[\]\/]//gi if $opt->{fatfilename};
	# Truncate multiple '_'
	$string =~ s/_+/_/g;
	return $string;
}



# Uses: global $lockfile
# Lock file detection (<stale_secs>)
# Global $lockfile
sub lockfile {
	my $stale_time = shift || 86400;
	my $now = time();
	# if lockfile exists then quit as we are already running
	if ( -T $lockfile ) {
		if ( ! open (LOCKFILE, $lockfile) ) {
			main::logger "ERROR: Cannot read lockfile '$lockfile'\n";
			exit 1;
		}
		my @lines = <LOCKFILE>;
		close LOCKFILE;

		# If the process is still running and the lockfile is newer than $stale_time seconds
		if ( kill(0,$lines[0]) > 0 && $now < ( stat($lockfile)->mtime + $stale_time ) ) {
				main::logger "ERROR: Quitting - process is already running ($lockfile)\n";
				# redefine cleanup sub so that it doesn't delete $lockfile
				$lockfile = '';
				exit 0;
		} else {
			main::logger "INFO: Removing stale lockfile\n" if $opt->{verbose};
			unlink ${lockfile};
		}
	}
	# write our PID into this lockfile
	if (! open (LOCKFILE, "> $lockfile") ) {
		main::logger "ERROR: Cannot write to lockfile '${lockfile}'\n";
		exit 1;
	}
	print LOCKFILE $$;
	close LOCKFILE;
	return 0;
}



sub expand_list {
	my $list = shift;
	my $search = shift;
	my $replace = shift;
	my @elements = split /,/, $list;
	for (@elements) {
		$_ = $replace if $_ eq $search;
	}
	return join ',', @elements;	
}



sub get_playlist_url {
	my $ua = shift;
	my $url = shift;
	my $filter = shift;
	# Don't recurse more than 5 times
	my $depth = 5;

	# Resolve the MMS url if it is an http ref
	while ( $url =~ /^http/i && $depth ) {
		my $content = main::request_url_retry($ua, $url, 2, '', '');
		# Reference list
		if ( $content =~ m{\[reference\]}i ) {
			my @urls;
			# [Reference]
			# Ref1=http://wm.bbc.co.uk/wms/england/radioberkshire/aod/andrewpeach_thu.wma?MSWMExt=.asf
			# Ref2=http://wm.bbc.co.uk/wms/england/radioberkshire/aod/andrewpeach_thu.wma?MSWMExt=.asf
			for ( split /ref\d*=/i, $content ) {
				#main::logger "DEBUG: LINE: $_\n" if $opt->{debug};
				s/[\s]//g;
				# Rename http:// to mms:// - don't really know why but this seems to be necessary with such playlists
				s|http://|mms://|g;
				push @urls, $_ if m{^(http|mms|rtsp)://};
				main::logger "DEBUG: Got Reference URL: $_\n" if $opt->{debug};
			}
			# use first URL for now??
			$url = $urls[0];

		# ASX XML based playlist
		} elsif ( $content =~ m{<asx}i ) {
			my @urls;
			# <ASX version="3.0">
			#  <ABSTRACT>http://www.bbc.co.uk/</ABSTRACT>
			#  <TITLE>BBC support</TITLE>
			#  <AUTHOR>BBC</AUTHOR>
			#  <COPYRIGHT>(c) British Broadcasting Corporation</COPYRIGHT>
			#  <MoreInfo href="http://www.bbc.co.uk/" />
			#  <Entry>
			#    <ref href="rtsp://wm.bbc.co.uk/wms/england/radioberkshire/aod/andrewpeach_thu.wma" />
			#    <ref href="http://wm.bbc.co.uk/wms/england/radioberkshire/aod/andrewpeach_thu.wma" />
			#    <ref href="rtsp://wm.bbc.co.uk/wms2/england/radioberkshire/aod/andrewpeach_thu.wma" />
			#    <ref href="http://wm.bbc.co.uk/wms2/england/radioberkshire/aod/andrewpeach_thu.wma" />
			#    <MoreInfo href="http://www.bbc.co.uk/" />
			#    <Abstract>BBC</Abstract>
			#  </Entry>
			# </ASX>
			for ( split /</i, $content ) {
				#main::logger "DEBUG: LINE: $_\n" if $opt->{debug};
				# Ignore anything except mms or http from this playlist
				push @urls, $1 if m{ref\s+href=\"((http|$filter)://.+?)\"}i;
			}
			for ( @urls ) {
				main::logger "DEBUG: Got ASX URL: $_\n" if $opt->{debug};
			}
			# use first URL for now??
			$url = $urls[0];

		# RAM format urls
		} elsif ( $content =~ m{rtsp://}i ) {
			my @urls;
			for ( split /[\n\r\s]/i, $content ) {
				main::logger "DEBUG: LINE: $_\n" if $opt->{debug};
				# Ignore anything except $filter or http from this playlist
				push @urls, $1 if m{((http|$filter)://.+?)[\n\r\s]?$}i;
			}
			for ( @urls ) {
				main::logger "DEBUG: Got RAM URL: $_\n" if $opt->{debug};
			}
			# use first URL for now??
			$url = $urls[0];			

		} else {	
			chomp( $url = $content );
		}
		$depth--;
	}

	return $url;
}



# Converts any number words (or numbers) 0 - 99 to a number
sub convert_words_to_number {
	my $text = shift;
	$text = lc($text);
	my $number = 0;
	# Regex for mnemonic numbers
	my %lookup_0_19 = qw(
		zero		0
		one		1
		two		2
		three		3
		four		4
		five		5
		six		6
		seven		7
		eight		8
		nine		9
		ten		10
		eleven		11
		twelve		12
		thirteen	13
		fourteen	14
		fifteen		15
		sixteen		16
		seventeen	17
		eighteen	18
		nineteen	19
	);
	my %lookup_tens = qw(
		twenty	20
		thirty	30
		forty 	40
		fifty	50
		sixty	60
		seventy	70
		eighty	80
		ninety	90
	);
	my $regex_units = '(zero|one|two|three|four|five|six|seven|eight|nine)';
	my $regex_ten_to_nineteen = '(ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)';
	my $regex_tens = '(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)';
	my $regex_numbers = '(\d+|'.$regex_units.'|'.$regex_ten_to_nineteen.'|'.$regex_tens.'((\s+|\-|)'.$regex_units.')?)';
	#print "REGEX: $regex_numbers\n";
	#my $text = 'seventy two'
	$number += $text if $text =~ /^\d+$/;
	my $regex = $regex_numbers.'$';
	if ( $text =~ /$regex/ ) {
		# trailing zero -> nineteen
		$regex = '('.$regex_units.'|'.$regex_ten_to_nineteen.')$';
		$number += $lookup_0_19{ $1 } if $text =~ /($regex)/;
		# leading tens
		$regex = '^('.$regex_tens.')(\s+|\-|_||$)';
		$number += $lookup_tens{ $1 } if $text =~ /$regex/;
	}
	return $number;
}



# Returns a regex string that matches all number words (or numbers) 0 - 99
sub regex_numbers {
	my $regex_units = '(zero|one|two|three|four|five|six|seven|eight|nine)';
	my $regex_ten_to_nineteen = '(ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)';
	my $regex_tens = '(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)';
	return '(\d+|'.$regex_units.'|'.$regex_ten_to_nineteen.'|'.$regex_tens.'((\s+|\-|)'.$regex_units.')?)';
}
