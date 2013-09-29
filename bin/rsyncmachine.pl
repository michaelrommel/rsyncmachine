#! /usr/bin/perl -w

# used basic modules
use strict;
use version; our $VERSION = qv('0.10.7');
use charnames qw( :full );
use File::Path qw(remove_tree);
use File::Basename;
use Carp;
use Getopt::Long;
use Pod::Usage;
use Switch;
use English qw( -no_match_vars );

# used further modules, install via apt-get
# apt-get install libfilesys-diskspace-perl
# apt-get install libdatetime-perl
# apt-get install liblog-log4perl-perl
# apt-get install libreadonly-perl
# apt-get install librrdtool-oo-perl
# apt-get install libtry-tiny-perl
# apt-get install liblockfile-simple-perl
# apt-get install libio-socket-ip-perl
# apt-get install libconfig-json-perl
use Filesys::DiskSpace;
use DateTime;
use Log::Log4perl qw(get_logger :levels);
use Readonly;
use RRDs;
use Try::Tiny;
use LockFile::Simple qw(lock trylock unlock);
use IO::Socket::INET;
use Config::JSON;

#
# setup global configuration variables and constants
#

# flag for registering the growl notifications, needs to be declared 
# before parsing the commandline
my $growl_registration = 0;

# process commandline arguments
parse_commandline();

# read in the configuration file from first argument, has been
# checked, that it has been supplied
my $config;
try { 
    $config = Config::JSON->new( $ARGV[0] );
} catch {
    print "Could not open/read/parse the configuration file, exiting!\n";
    exit 1;
};

# set the variable from the config parser
Readonly my $BACKUP_CONFIGURATION_PATH 
                                => $config->get("BACKUP_CONFIGURATION_PATH");
Readonly my $BACKUP_LOG_PATH    => $config->get("BACKUP_LOG_PATH");
Readonly my $BACKUP_ROOT        => $config->get("BACKUP_ROOT");
Readonly my $GROWL_HOST         => $config->get("GROWL_HOST");
Readonly my $GROWL_PWD          => $config->get("GROWL_PWD");
Readonly my $GROWL_DESCR        => $config->get("GROWL_DESCR");

# number of retained backups
Readonly my $DAYS_TO_KEEP       => $config->get("DAYS_TO_KEEP");
Readonly my $HOURS_TO_KEEP      => $config->get("HOURS_TO_KEEP");

# time zone setting, because we want the directories to be named with
# timestamps in local time
Readonly my $TIMEZONE           => $config->get("TIMEZONE");

# directories to backup in absolute notation, all with trailing / !!!
Readonly my @DIRS_TO_BACKUP     => @{$config->get("DIRS_TO_BACKUP")};

Readonly my $PROGRESSEXT        => ".inProgress";
Readonly my $PARTIALEXT         => ".partial";
Readonly my $RRDDATABASE        => "rsyncmachine.rrd";
Readonly my $RSYNCLOCKFILE      => "rsyncmachine";

# contains the real directory name of the latest backup
my $latest;
# contains the real directory name of this backup
my $this_backup_directory;
# temporary directory name, while backup is in progress
my $inprogress_dir_name;
my $directory_name;

# global rsync options (original options tried: -avxHSAX)
#Readonly my $GLOBAL_RSYNC_OPTIONS => "--stats --numeric-ids -avxHS";
Readonly my $GLOBAL_RSYNC_OPTIONS => 
    "--log-file-format=\"%B %U %10l %M %i %f %L\" " .
    "--stats --numeric-ids -axHS";

# per directory rsync arguments
my $rsync_arguments_for_dir;
my $rsync_logfile;

# miscellaneous options for debugging purposes
Readonly my $SIMULATE_LOW_DISKSPACE => 0;
my $available_space_increment_factor = 2;

# get the epoch seconds for the start of this backup
my $epoch_of_backup_start = time();
my $epoch_of_oldest_backup;

# global statistics of this backup
my %statistics = ();

# start with empty checkpoint interval lists
my @checkpoint_list = ();
# contains interval checkpoints in human readable format
my @checkpoint_list_human = ();

# list of existing backup directories to keep
my @keep_list = ();
# list of existing backup directories to remove before/after this backup
my @thinning_list = ();

# global error flag
my $error_occurred = 0;
my $error_description = "";
my $one_source_succeeded = 0;

#
# setup logging and notifications
#

# prepare logfile hook function
Readonly my $LOGGER_CONFIG
            => "$BACKUP_CONFIGURATION_PATH/rsyncmachine_logging.conf";
sub getLogfileName {
    return( "$BACKUP_LOG_PATH/rsyncmachine.log" );
}
Log::Log4perl->init( $LOGGER_CONFIG );
my $logger = get_logger( "main" );

# start logging
$logger->info( "Welcome to rsyncmachine, today is " . 
    get_human_friendly_timestring(time()) );

# try to use Net::Growl or GrowlClient, which is self installed, no ubuntu
# package and not strictly necessary for rsyncmachine, so make it optional
# Note: Net::Growl version 0.99 has a bug in line 130, where the wrong
# flags are given for a 'sticky' notification, should be: $flags |= 0x100;
my $growl = 1;
try {
    #require Net::Growl;
    require Net::GrowlClient;
} catch { 
    $growl = 0;
};

if (! $growl ) {
	$logger->info( "No Net::Growl or GrowlClient module installed" );
} else {
    if( $growl_registration ) {
        # send the registration packet and exit cleanly
        $growl = Net::GrowlClient->init(
            'CLIENT_PEER_HOST'          => $GROWL_HOST,
            'CLIENT_PASSWORD'           => $GROWL_PWD,
            'CLIENT_TYPE_REGISTRATION'  => 0, #md5 auth
            'CLIENT_TYPE_NOTIFICATION'  => 1, #md5 auth
            'CLIENT_CRYPT'              => 0, #no crypt 
            'CLIENT_APPLICATION_NAME'   => "rsyncmachine",
            'CLIENT_NOTIFICATION_LIST'  => [
                    "Information", "Warning",
                    "Error", "Critical" ]
            ) or die "Cannot register growl, error: $!\n";
        print "\nGrowl registration sent, you can now configure your server.\n"
            . "4 different types of alerts are configurable.\n\n";
        $logger->info( "Only registration for growl requested, exiting." );
        exit 0;
    } else {
        $growl = Net::GrowlClient->init(
            'CLIENT_PEER_HOST'          => $GROWL_HOST,
            'CLIENT_PASSWORD'           => $GROWL_PWD,
            'CLIENT_TYPE_REGISTRATION'  => 0, #md5 auth
            'CLIENT_TYPE_NOTIFICATION'  => 1, #md5 auth
            'CLIENT_CRYPT'              => 0, #no crypt 
            'CLIENT_APPLICATION_NAME'   => "rsyncmachine",
            'CLIENT_SKIP_REGISTER'      => 1,
            ) or $logger->info( "Growl failed to initialise" ); 
    }
}

#
# main
#

# check for any parallel processes and exit, if there are any
my $lockobject = LockFile::Simple->make( 
	-format => "%f.lock", 
	-hold => 36000,	# consider a lockfile as stale after 10 hours
	-delay => 180,	# wait 3 minutes between checks for parallel running process
	-max => 5,	# try for 5 times to acquire a lock, otherwise give up 
	-warn => 0,	# no need to warn, nobody is looking anyway
	-stale => 1,	# enable stale lockfile detection
	-autoclean => 1 );
if( ! $lockobject->lock( "$BACKUP_LOG_PATH/$RSYNCLOCKFILE" ) ) {
        die "Cannot acquire lockfile, another process still running, aborting!\n";
};

# initialize timestamps and directories
try { 
    init();
} catch {
    $logger->error( "Could not initialize, error: " . $_ );
    exit 1;
};

$logger->info( "Successfully initialized" );

# get the sorted list of existing backup directories
my @existing_dirs = get_sorted_list_of_existing_backup_dirs();

# intervals, which define the user-set backup timeline
create_checkpoint_list_for( @existing_dirs );

$logger->info( "Created checkpoint list with "
             . scalar(@checkpoint_list) . " entries" );

# creates the lists for keeping/removing directories after the backup
# or before, if space is insufficient to start the backup
create_thinning_list_for( @existing_dirs );

$logger->info( "Created thinning list: "
             . "keep " . scalar(@keep_list) 
             . ", remove " . scalar(@thinning_list) );

# determin overall space requirements
my $needed_bytes = calculate_required_space();

# check free space on backup drive
my $free_bytes = available_backup_space();

$logger->info( "Backup space needed:    $needed_bytes" );
$logger->info( "Backup space available: $free_bytes" );

# start pre-thinning if needed
if( $free_bytes < $needed_bytes ) {
    if( $error_occurred ) {
        $logger->error( "Pre-thinning needed, but errors have been "
                    .   "encountered, not deleting anything, aborting!" );
        die "Not enough space on backup drive and pre-thinning "
          . "not allowed, aborting!\n";
    } else {
        $logger->info( "Pre-thinning backup to free space..." );
        if (pre_thinning( $needed_bytes ) == 1) {
            # success
            $logger->info( "Pre-thinning successful" );
        } else {
            # pre-thinning was not successful
            rmdir $inprogress_dir_name;
            $logger->error( "Not enough space on backup drive, aborting!" );
            die "Not enough space on backup drive, aborting!\n";
        }
    }
} else {
	$logger->info( "No pre-thinning needed, enough space available" );
}

$statistics{"oldest_backup_age"} = 
    int(($epoch_of_backup_start-$epoch_of_oldest_backup)/(3600*24));

# enough space on the backup device to continue
foreach $directory_name (@DIRS_TO_BACKUP) {

    my %stats_of_this_directory = ();

    my $success = try {
        %stats_of_this_directory = 
              do_backup_of_directory( $directory_name );
    } catch {
        $logger->error( "Error backing up, " . $_ );
        $error_occurred = 1;
        # do not die, try to accomplish the other directories
        return;
    };
    
    if ($success) {
        # remember that at least one backup dir succeeded
        $one_source_succeeded = 1;
        $logger->info( "Backed up $directory_name" );
        $logger->debug( "Statistics of $directory_name:" );
        foreach my $key ( keys(%stats_of_this_directory) ) {
            $statistics{$key} += $stats_of_this_directory{$key};
            $logger->debug( "$key: $stats_of_this_directory{$key}" );
        }
    }

}

# backup finished

if( ! $error_occurred ) {

    $logger->info( "Renaming finished directory" );
    rename( "$inprogress_dir_name", "$this_backup_directory" );

    # now let the symlink point to this backup directory
    $logger->info( "Linking \"Latest\"" );
    unlink( "Latest" );
    symlink( "$this_backup_directory/", "Latest" );

    # post thinning removes no longer needed old backups, where backups
    # are consolidated, e.g. when daily backups are present, and only
    # weekly backups shall be kept
    post_thinning();

} else {

    if( $one_source_succeeded ) {
        # at least one source backup was successful
        $logger->info( "Renaming partially finished directory" );
        rename( "$inprogress_dir_name", 
                "$this_backup_directory" . "$PARTIALEXT" );
        $logger->error( "An error has occurred, 'Latest' still points to "
                    .   "the last completely successful directory!" );
    } else {
        # all backups failed, probably the source is down
        # do not fail with error code 1 and do not keep the directory
        $logger->info( "Removing empty directory" );
        rmdir( "$inprogress_dir_name" );
        $logger->error( "Empty backup, 'Latest' still points to "
                    .   "the last completely successful directory!" );
    }

}


$statistics{"disk_free"}=available_backup_space();

# report statistics
try { 
    process_statistics();
} catch {
    # an error during statistics - not fatal
    $logger->warn( "Error while processing statistics: $_" );
};

# sensible return code and logging in case of errors
if ($error_occurred) {
    $logger->error( "Backup had *errors* on: " .
        get_human_friendly_timestring(time()) );
    if( $growl ) {
        # this notification is a sticky notification, but some themes
        # do not support sticky notificatins, e.g. Bezel, MusicVideo
        $growl->notify(
            'notification'  => "Error",
            'title'         => "rsync Backup " . 
                substr( get_human_friendly_timestring(time()), -8 ),
            'message'       => "Backup error: " . $GROWL_DESCR
                . "\n" . $error_description,
            'priority'      => 1,
            'sticky'        => 1,
        );
    }
} else {
    $logger->info( "Backup finished on: " .
        get_human_friendly_timestring(time()) );
    if( $growl ) {
        $growl->notify(
            'notification'  => "Information",
            'title'         => "rsync Backup " . 
                substr( get_human_friendly_timestring(time()), -8 ),
            'message'       => "Backup successful: " . $GROWL_DESCR,
            'priority'      => 0,
            'sticky'        => 0,
        );
    }
}

$lockobject->unlock( "$BACKUP_LOG_PATH/$RSYNCLOCKFILE" );
exit ($one_source_succeeded ? $error_occurred : 0);



#
# functions
#


sub parse_commandline {

    my $programname = basename( $0 );
    
    # processing commandline options and early exit
    my $help = 0;
    my $ver = 0;
    my $greg = 0;
    my $man = 0;

    GetOptions( help => \$help, 
                version => \$ver,
                growlregister => \$greg,
                man => \$man, 
              ) or pod2usage();

    if ($help) {
        pod2usage(
            -exitstatus => 1, 
            -verbose => 1 );
    }

    if ($ver) {
        print "$programname: version $VERSION\n";
        exit 0;
    }

    if ($man) {
        pod2usage(
            -exitstatus => 1, 
            -verbose => 2 );
    }

    if ($greg) {
        $growl_registration = 1;
    }

    if( $#ARGV != 0 ) {
        pod2usage(
            -message => "\n$programname: missing configuration file argument\n",
            -exitstatus => 1, 
            -verbose => 0 );
    }

}



sub init {

    my $logger = get_logger( "init" );

    # save time of backup start for further use
    my $curtimesecs = time();

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
        = localtime($curtimesecs);
    $year+=1900;        # make 4-digit years
    $mon++;             # make months start from 1

    # change into backup directory
    chdir $BACKUP_ROOT or croak "Cannot change to backup directory!";

    # check for symlink to latest backup
    if( -l "Latest" && -d "Latest" ) {
        $logger->debug( "Latest backup directory exists" );
    } else {
        croak "Latest backup dir link does not exist or "
             . "points to non-existent directory!";
    }

    $latest = readlink "Latest" or 
        croak "Error reading link to latest backup!";
    # remove trailing slash
    $latest =~ s{/$}{}xms;
    $logger->debug( "Latest is: $latest" );

    # set preliminary oldest backup date, gets overwritten, in case
    # we find more recent backup dirs lateron
	$epoch_of_oldest_backup = get_epoch_from_dir_name($latest);
    $logger->debug( "Latest backup is from: " . 
        get_human_friendly_timestring($epoch_of_oldest_backup) );

    # create the final filename for new backup directory
    $this_backup_directory = sprintf( "%04d-%02d-%02d-%02d%02d%02d",
        $year, $mon, $mday,    $hour, $min, $sec );
    # create filename for backup directory during the backup
    $inprogress_dir_name = $this_backup_directory . $PROGRESSEXT;

    # create new dir in progress
    if( -d "$inprogress_dir_name" ) {
        $logger->warn( "Strange, new directory already exists? " 
                    . $inprogress_dir_name );
    } else {
        mkdir $inprogress_dir_name or croak "Can't create new backup dir";
    }

    $logger->info( "Backup initialized on $this_backup_directory" );

}


sub set_rsync_arguments_for_dir {

	my ($directory_name, $dryrun) = @_;

	my $logfile_option	= q{};
	my $exclude_option	= q{};
	my $linkdest_option	= q{};
	my $ssh_option  	= q{};

	if ($directory_name =~ m{[^/]"}) {
        my $logger = get_logger("set_options");
        $logger->warn( "No trailing slash on directory $directory_name!" );
    }

    my %source = parse_source( $directory_name );

    # create escaped data directory name
    # start with the path
    my $escaped_dir_name = "$source{'path'}";
    # replace slashes with underscores
    $escaped_dir_name   =~ s{/}{_}gxms;
    # replace dots with the string dot
    $escaped_dir_name   =~ s{\.}{dot}gxms;
    # remove leading and trailing undersore(s)
    $escaped_dir_name   =~ s{_*(.*)_|$}{$1};
    # prepend the hostname_ if any
    $escaped_dir_name = ($source{'host'} eq "" ? "" : "$source{'host'}_" ) .
                         $escaped_dir_name;

	my $excludefile = "$BACKUP_CONFIGURATION_PATH"
			. "/exclude_$escaped_dir_name.txt";
	# if no exclude file exists, omit complete option
	if( -f "$excludefile" ) {
		$exclude_option = "--exclude-from=$excludefile";
	}

	my $linkdest_path = "$BACKUP_ROOT"
			  . "/Latest/$escaped_dir_name/";
	# if the linkdest directory does not exist, default is a full sync
	if( -d "$linkdest_path" ) {
		$linkdest_option = "--link-dest=$linkdest_path";
	}

    # if we have used the non-standard notation of a non-standard ssh port
    # now we have to mangle the original directory name from the config file
    if( $source{'nonstdsshport'} eq "yes" ) {
        $logger->info( "Using ssh on non-standard port: $source{'port'}" );
        $directory_name =~ s{#[0-9]+@}{@};
        $ssh_option = "-e \"ssh -p$source{'port'}\"";
    }

	$rsync_logfile = "$BACKUP_LOG_PATH"
                     . "/backup_$escaped_dir_name.log";
    if( ! $dryrun ) {
        $logfile_option = "--log-file=$rsync_logfile";
    }

    # note trailing spaces to separate the arguments
	$rsync_arguments_for_dir
        = "$GLOBAL_RSYNC_OPTIONS "
        . "$ssh_option $logfile_option $exclude_option $linkdest_option "
        . "$directory_name "
        . "$BACKUP_ROOT/$inprogress_dir_name/$escaped_dir_name/"
        ;

}


sub available_backup_space {
	
	my ($fs_type, $fs_desc, $used, $available, $fused, $favail) =
        df $BACKUP_ROOT;

    my $logger = get_logger( "diskspace" );
    if ( $SIMULATE_LOW_DISKSPACE == 1 ) {
        # used to simulate an increasing disk space
        $available_space_increment_factor *= 3;
        $available = 1024 * $available_space_increment_factor;
        $logger->debug( "Simulated free disk space" );
    }
    $available = 1024 * $available;
    $logger->info( "Free disk space: $available" );
    return $available;
	
}


sub calculate_required_space {

    my $logger = get_logger( "calc_space" );

    # determine space needed in a dry run 
    $logger->debug( "Calculating backup space needed" );

    my $running_sum = 0;
    my $bytes = 0;

    foreach my $dirtobackup (@DIRS_TO_BACKUP) {
        
        try { 
            $bytes = calculate_needed_space_for_dir( $dirtobackup );
        } catch {
            $bytes = 0;
        };
        $running_sum += $bytes;
        $logger->debug( "Running sum: $running_sum" );

    }
    
    return $running_sum;

}


sub calculate_needed_space_for_dir {

	my ($directory_name) = @_;

    my $logger = get_logger( "rsync_dry" );

    if( ! source_check( $directory_name ) ) {
        # set global error flag to prevent pre-thinning 
        $error_occurred = 1;
        $logger->warn( "Remote daemon could not be contacted, "
                    .  "skipping $directory_name!" );
        croak( "Remote daemon could not be contacted, "
            .  "skipping $directory_name" );
    }

    # second argument to the function, chooses the dryrun settings without
    # the logfile of rsync
	set_rsync_arguments_for_dir( $directory_name, 1 );
	my $cmd = "/usr/bin/rsync 2>&1 --dry-run $rsync_arguments_for_dir";

	$logger->debug( "Executing: $cmd" );
	my $output = qx{$cmd};

    if ( ($? >> 8) != 0 ) {
        $logger->warn( "rsync dry-run failed: " .
                get_rsync_err_explanation( $? >> 8 ) );
        croak ( "rsync dry-run failed, code " . ($? >> 8) );
    } else {
        $logger->debug( "Command returned status $?" );
        if ($logger->is_trace()) {
            $logger->trace( "rsync dry-run returned the following:\n$output" );
        }

        my ($bytes) = $output 
                    =~ m/^Total [\N{SPACE}] transferred [\N{SPACE}] 
                        file [\N{SPACE}] size:\s+ ([0-9]+) \s+ bytes.*$/xms;

        if( ! defined($bytes) ) {
            $logger->warn(
                "Could not determine needed space for: $directory_name"
                );
            croak( "Could not parse output of dry-run!" );
        }

        $logger->info( "$directory_name needs $bytes for backup" );
        return $bytes;
    }

}


sub parse_source {

    my ($directory_name) = @_;

    my %source = ();

    switch( $directory_name ) {
        case m{rsync://} {
                # here it is allowed to specify a portnumber, too
                ( $source{'user'}, $source{'fqdn'},
                  $source{'port'}, $source{'path'} ) =
                    $directory_name =~
                    m{rsync://(?:([^@]*)@)?([^/:]+)(?::([0-9]+))?/(.*)};
                $source{'port'} = (defined($source{'port'}) ?
                    $source{'port'} : 873);
            }
        case m{::} {
                # set the default portnumber
                $source{'port'} = 873; 
                ( $source{'user'}, $source{'fqdn'}, $source{'path'} ) = 
                    $directory_name =~ m{(?:([^@]*)@)?([^/]+)::(.*)};
            }
        case m{:} {
                $source{'port'} = 22; 
                ( $source{'user'}, $source{'fqdn'}, $source{'path'} ) = 
                    $directory_name =~ m{(?:([^@]*)@)?([^/]+):(.*)};
                # non-default specification of a portnumber for the ssh daemon
                # note, that this probibits usernames with a # followed by digits
                if( $source{'user'} =~ m{#[0-9]+} ) {
                    # there is a ssh portnumber encoded in the path
                    ($source{'user'}, $source{'port'}) =
                        $source{'user'} =~ m{([^#]*)#(.*)$};
                    # set a flag indicating the non-standard port
                    $source{'nonstdsshport'} = "yes";
                }
            }
        else { 
                $source{'path'} = $directory_name;
            }
    }

    # make sure, each item is defined, even to an empty string
    foreach my $item ( 'user', 'fqdn', 'port', 'path', 'nonstdsshport' ) {
        $source{$item} = (defined($source{$item}) ? $source{$item} : "");
    }

    # create additional short hostname, stripping off a domain
    $source{'host'} = $source{'fqdn'};
    $source{'host'} =~ s{^([^\.]+).*$}{$1}gxms;

    return %source;

}


sub source_check {

    my ($directory_name) = @_;

    my $msg;
    my $success;

    my $logger = get_logger( "source_check" );

    $logger->debug( "Parsing source $directory_name" );
    my %source = parse_source( $directory_name );

    foreach my $item ( 'user', 'fqdn', 'host', 'port', 'path' ) {
        $msg .= "$item=[$source{$item}] ";
    }
    $logger->debug( "Result: $msg" );

    if( $source{'fqdn'} eq "" ) {
        # local source, can backup directly, return success
        $success = 1;
    } else {
        $logger->debug( "Connecting to source $directory_name" );
        $success = check_source_connectivity( $source{'fqdn'}, 
                                              $source{'port'} );

        if( $success ) {
            $logger->info( "Remote daemon connection "
                        .  "($source{'fqdn'}:$source{'port'}) successful" );
        } 
    }

    return $success;

}


sub check_source_connectivity {

	my ($fqdn, $port ) = @_;

    my $socket = IO::Socket::INET->new(
            PeerAddr => $fqdn, 
            PeerPort => $port, 
            Proto => 'tcp' );

    if( $socket ) {
        shutdown($socket, 2);
        return 1; 
    } else { 
        return 0; 
    }

}


sub do_backup_of_directory {

    my ($directory_name) = @_;

    my %stats_of_this_dir = ();

    my $logger = get_logger( "rsync" );
	$logger->debug( "Backing up $directory_name" );

    if( ! source_check( $directory_name ) ) {
        # set global error flag to prevent thinning and deleting of
        # directories since that may cause older directories to vanish
        $error_occurred = 1;
        $error_description .= ($error_description ne "" ? ", " : "" ) .
            "no daemon";
        $logger->warn( "Remote daemon could not be contacted, "
                    .  "skipping $directory_name!" );
        croak( "Remote daemon could not be contacted, "
            .  "skipping $directory_name" );
    }

    # this time, the dryrun argument #2 is zero, choosing the logs
	set_rsync_arguments_for_dir( $directory_name, 0 );

    # capture standard error together with stdout
	my $cmd = "/usr/bin/rsync 2>&1 $rsync_arguments_for_dir ";

	$logger->debug( "Executing: $cmd" );
	my $output = qx{$cmd};

    # $? & 127 would give us the signal, which the process died from
    if ( ($? >> 8) != 0 ) {
        # set global error flag to prevent thinning and deleting of
        # directories since that may cause older directories to vanish
        $error_occurred = 1;
        $error_description .= ($error_description ne "" ? ", " : "" ) .
            "rsync failed";
        $logger->warn( "rsync failed: " .
                get_rsync_err_explanation( $? >> 8 ) );
        croak ( "rsync failed, code " . ($? >> 8) );
    } else {
        $logger->debug( "Command returned status $?" );
        if ($logger->is_trace()) {
            $logger->trace( "rsync returned the following:\n$output" );
        }

        # extract and return statistics
        # use of the /x parameter allows to break up the expression
        # into multiple lines, but we must specify the spaces explicitly
        ($stats_of_this_dir{"total_files"}) = $output 
                    =~ m/^Number [\N{SPACE}] of [\N{SPACE}] 
                        files:\s+ ([0-9]+) $/xms;
        ($stats_of_this_dir{"transferred_files"}) = $output 
                    =~ m/^Number [\N{SPACE}] of [\N{SPACE}] 
                        files [\N{SPACE}] transferred:\s+ ([0-9]+) $/xms;
        ($stats_of_this_dir{"total_size"}) = $output 
                    =~ m/^Total [\N{SPACE}] 
                        file [\N{SPACE}] size:\s+ ([0-9]+) \s+ bytes.*$/xms;
        ($stats_of_this_dir{"transferred_size"}) = $output 
                    =~ m/^Total [\N{SPACE}] transferred [\N{SPACE}] 
                        file [\N{SPACE}] size:\s+ ([0-9]+) \s+ bytes.*$/xms;
        return %stats_of_this_dir;
    }
}


# FIXME: remove this in the next version, not needed anymore, rsync handles this
sub append_rsync_log {

    my ($logfile_name, $output) = @_;

    open my $RSYNCLOG, '>>', $logfile_name 
        or croak "Could not open '$logfile_name': $OS_ERROR";
    print {$RSYNCLOG} $output
        or croak "Could not write to '$logfile_name': $OS_ERROR";
    close $RSYNCLOG
        or croak "Could not close '$logfile_name': $OS_ERROR";

    return;

}


sub get_epoch_from_dir_name {

	my ($directory_name) = @_;

    # parse directory name (YYYY-MM-DD-hhmmss)
	my ($year, $month, $day, $hour, $minute, $second) 
        = ($directory_name =~ /(\d+)-(\d+)-(\d+)-(\d\d)(\d\d)(\d\d)/);

	my $dt = DateTime->new( 
		year        => $year,
		month       => $month,
		day         => $day,
		hour        => $hour,
		minute      => $minute,
		second      => $second,
		time_zone   => $TIMEZONE,
        );
	
    return $dt->epoch();

}


sub get_sorted_list_of_existing_backup_dirs {

	opendir DIR, $BACKUP_ROOT;
	my @existing_dirs = sort grep {
        /^[^.]*$/           # omit dot files
        && -d "$_"          # must be a directory
        && ! -l "$_"        # must not be a symlink (="Latest")
        && $_ ne $latest    # must not be the target of "Latest"
        } readdir( DIR );
	closedir( DIR );

    my $logger = get_logger( "dir_scan" );
    $logger->info( "Number of earlier backup directories: ". scalar(@existing_dirs) );
    if ( $logger->is_debug() and ($#existing_dirs >= 0) ) {
        $logger->debug( "Existing earlier backup directories (<>Latest):\n@existing_dirs" );
    }

    return @existing_dirs;

}


sub get_human_friendly_timestring {


	my ($epoch) = @_;

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = 
		localtime($epoch);

	$year+=1900; $mon++;

	return sprintf( "%04d-%02d-%02d %02d:%02d:%02d",
                    $year, $mon, $mday, $hour, $min, $sec );

}


sub create_checkpoint_list_for {

    my (@existing_dirs) = @_;

    my $logger = get_logger( "thinning" );

    # check for empty directory
    if( $#existing_dirs < 0 ) {
        $logger->info( "No old directories available "
                     . "(checkpoint creation)." );
        return;
    }

	# get oldest timestamp as cutoff
	my $oldest_dir = $existing_dirs[0];
	$epoch_of_oldest_backup = get_epoch_from_dir_name($oldest_dir);

	# create scheduled intervals for comparison
	# in each interval only the youngest directory shall remain
	my $counthours  = -1;
	my $countdays   = int($HOURS_TO_KEEP / 24);
	my $countweeks  = int($DAYS_TO_KEEP / 7);

    # temporary string object for human readable date/timestrings
    my $tmpdtstring;
	# temporary datetime object for truncation
	my $tmpdt;

    # add 3600 seconds to "now", then truncate back to an hour
    # will result in a timestamp for the end of this hour
    $tmpdt = DateTime->from_epoch(
            epoch => $epoch_of_backup_start + 3600,
            time_zone  => $TIMEZONE );
	my $nexthour = $tmpdt->truncate(to=>'hour')->epoch();

    # add 24 hours to "now", then truncate back to a day
    # will result in a timestamp for the end of this day
	$tmpdt = DateTime->from_epoch(
            epoch => $epoch_of_backup_start + 3600*24,
            time_zone  => $TIMEZONE );
	my $nextday = $tmpdt->truncate(to=>'day')->epoch();

    # add 7 days to "now", then truncate back to a week
    # will result in a timestamp for the end of this week
	$tmpdt = DateTime->from_epoch(
            epoch => $epoch_of_backup_start + 3600*24*7,
            time_zone  => $TIMEZONE );
	my $nextweek = $tmpdt->truncate(to=>'week')->epoch();

    # start at the end of this hour
	my $checkpoint = $nexthour;

    # terminate loop, when the checkpoint is older than the oldest directory
	while( $checkpoint > $epoch_of_oldest_backup ) {
		if( $counthours < $HOURS_TO_KEEP ) {
			# increase kept-hours counter
			$counthours++;
            # the checkpoint to compare is older, i.e. lower epoch seconds
			$checkpoint = $nexthour - $counthours * 3600;
			push @checkpoint_list, $checkpoint;
			my $tmpdtstring = sprintf(
                                "%10d - %d hours - %s",
                                $checkpoint,
                                $counthours,
                                get_human_friendly_timestring($checkpoint) );
			push @checkpoint_list_human, $tmpdtstring;
		} elsif( $countdays < $DAYS_TO_KEEP ) {
			# increase kept-days counter
			$countdays++;
			$checkpoint = $nextday - $countdays * 24 * 3600;
			push @checkpoint_list, $checkpoint;
			my $tmpdtstring = sprintf(
                                "%10d - %d days - %s",
                                $checkpoint,
                                $countdays,
                                get_human_friendly_timestring($checkpoint) );
			push @checkpoint_list_human, $tmpdtstring;
		} else {
			# increase counter by weeks
			$countdays += 7;
			$checkpoint = $nextweek - $countdays * 24 * 3600;
			push @checkpoint_list, $checkpoint;
			my $tmpdtstring = sprintf(
                                "%10d ~ %d weeks - %s",
                                $checkpoint,
                                $countdays/7,
                                get_human_friendly_timestring($checkpoint) );
			push @checkpoint_list_human, $tmpdtstring;
		}
	}

    $logger->debug( sprintf( "Number of intervals: %d\n", $#checkpoint_list) );

    return;

}

	
sub create_thinning_list_for {

    # argument is the list of existing backup directories
    my (@existing_dirs) = @_;

    my $logger = get_logger( "thinning" );

    # check for empty directory
    if( $#existing_dirs < 0 ) {
        $logger->info( "No old directories available "
                     . "(thinning list creation)." );
        return;
    }

    # set counter to zero
	my $checkpoint_index = 0;
    $logger->debug( "Next checkpoint: "
                    . "$checkpoint_list_human[$checkpoint_index]" );

    # process the directories in REVERSE order, youngest first
	foreach my $backup_directory (sort {$b cmp $a} @existing_dirs) {

		my $next_directory = 0;
		my $backup_time = get_epoch_from_dir_name( $backup_directory );
		
		while ( $next_directory == 0 ) {
            # if this backup is older than the beginning of the next interval
			if( $backup_time < $checkpoint_list[$checkpoint_index] ) {
				# now check, if it is also older than the next+1 interval
				if( $backup_time < $checkpoint_list[$checkpoint_index+1] ) {
					# we have no backups for this interval
                    # increment the checkpoint_index after the if()
                    # not setting next=1 means we start the comparison again
                    # with the next interval 
				} else {
					# falls in this interval, push the directory on the keep
                    # list
					push( @keep_list, $backup_directory );
					my $log_string = sprintf( "%10d %-18s keep backup\n", 
						                        $backup_time,
                                                $backup_directory,
                                            );
                    $logger->debug( $log_string );
                    # in addition to moving to the next interval, we also jump
                    # to the next directory in the foreach loop
					$next_directory = 1;
				}
                # increment index, i.e. the beginning of the next older 
                # interval (=lower number of epoch seconds) 
				$checkpoint_index++;
                $logger->debug( "Next checkpoint: "
                                . "$checkpoint_list_human[$checkpoint_index]" );
			} else {
				# this backup is younger than the beginning of the next
                # interval, we intend to find a backup in, discard it
				push @thinning_list, $backup_directory;
                my $log_string = sprintf( "%10d %-18s remove backup\n", 
                                            $backup_time,
                                            $backup_directory,
                                        );
                $logger->info( $log_string );
                # next directory in foreach loop
				$next_directory = 1;
			}
		}
	}
}


sub pre_thinning {

	my ($needed_bytes) = @_;	

	my ($full_pathname, $free_bytes, $backup_directory);

	my $enough_space = 0;

	my $goto_aggressive_remove = 0;

    my $logger = get_logger( "pre-thinning" );

	# first try to normally thin out the backups
	while ( ($enough_space == 0) && ($goto_aggressive_remove == 0) ) {
        # get the first directory off the thinning list, i.e.
        # usually the youngest directory first
		$backup_directory = shift @thinning_list;

        # if a directory could be obtained
		if( defined($backup_directory) ) {
            $enough_space = remove_directory_report_space(
                $backup_directory,
                $needed_bytes,
            );
		} else {
			# we should thin out, but have nothing more to delete
            # now we have to go over to hard removing old backups
			$logger->info( "Removed obsolete backups, starting to "
                         . "delete oldest backups" );
			$goto_aggressive_remove = 1;
		}
	}

	if ($enough_space == 1) {
        return 1;   # remove was successful
    }

	my $remove_is_unsuccessful = 0;

	# now we still need more space to make the next backup
	# so we need to remove older backups
	while ( ($enough_space == 0) && ($remove_is_unsuccessful == 0) ) {
        # get the oldest backup off the keeplist, i.e.
        # usually the oldest at the end of the list
		# note that the latest backup is not in the keeplist or thinning list
		$backup_directory = pop @keep_list;

        # if a directory could be obtained
		if( defined( $backup_directory ) ) {
            $enough_space = remove_directory_report_space(
                $backup_directory,
                $needed_bytes,
            );
		} else {
			# we should thin out, but have nothing more to delete
			$logger->warn( "Nothing more to thin out, "
                         . "still not enough space!" );
			$remove_is_unsuccessful = 1;
		}

	}

    return ($enough_space == 1 );

}


sub remove_directory_report_space {

    my ($backup_directory, $needed_bytes ) = @_;

    my $logger = get_logger( "rm_dir" );

    # construct full pathname
    my $full_pathname = "$BACKUP_ROOT/$backup_directory/";
    remove_backup( $full_pathname );

    if ($needed_bytes > 0) {
        # check for needed bytes, to start the backup asap
        my $free_bytes = available_backup_space();
        $logger->debug( "Free space: $free_bytes" );
        if( $free_bytes > $needed_bytes ) {
            $logger->info( "Ending pre-thinning." );
            return 1;
        } else {
            # in pre-thinning, report still needed space
            return 0;
        }
    }
    # in post-thinning mode without space requirements
    return 1;
}


sub post_thinning {

    my $logger = get_logger( "post-thinning" );

    $logger->info( "Starting post-thinning." );

	foreach my $backup_directory (@thinning_list) {
		# thinninglist may already be shorter, due to pre-thinning
        remove_directory_report_space( $backup_directory, 0 );
	};

    $logger->info( "Ending post-thinning." );

}


sub remove_backup {

	my ($fullpath) = @_;

	my $err;

    my $logger = get_logger( "rm_dir" );

	$logger->debug( "Removing directory $fullpath" );
	remove_tree( $fullpath, {error => \$err} );
	if( @$err) {
		for my $diag (@$err) {
			my ($file, $message) = %$diag;
			if ($file eq '') {
				$logger->warn( "Error removing directory $fullpath, "
                    . "error: $message" );
			} else {
				$logger->warn( "Error removing file $file "
                    . "in directory $fullpath, error: $message" );
			}
		}
	}
	$logger->debug( "Directory $fullpath removed successfully." );
	
}


sub process_statistics {

    my $data_points = $epoch_of_backup_start . ":";
    my $rrdupdate_template = q{};

    $logger->info( "Statistics of this backup:" );
    foreach my $key ( keys(%statistics) ) {
        $logger->info( "$key: $statistics{$key}" );
        $rrdupdate_template .= "$key:";
        $data_points .= "$statistics{$key}:";
    }

    chop $rrdupdate_template;
    chop $data_points;

    $logger->debug( "rrd_template: $rrdupdate_template" );
    $logger->debug( "rrd_data_points: $data_points" );

    RRDs::update( "$BACKUP_LOG_PATH/$RRDDATABASE",
        "--template",
        $rrdupdate_template,
        $data_points,
    );

    my $rrd_error=RRDs::error;
    if ($rrd_error) {
        croak( "RRD: $rrd_error" );
    }
}

sub get_rsync_err_explanation {

    my ($code) = @_;

    my %exit_desc = (
       '0' =>  "Success",
       '1' =>  "Syntax or usage error",
       '2' =>  "Protocol incompatibility",
       '3' =>  "Errors selecting input/output files, dirs",
       '4' =>  "Requested action not supported: an attempt was made to " .
               "manipulate  64-bit files on a platform that cannot support " .
               "them; or an option was specified that is supported by the " .
               "client and not by the server.",
       '5' =>  "Error starting client-server protocol",
       '6' =>  "Daemon unable to append to log-file",
       '10'=>  "Error in socket I/O",
       '11'=>  "Error in file I/O",
       '12'=>  "Error in rsync protocol data stream",
       '13'=>  "Errors with program diagnostics",
       '14'=>  "Error in IPC code",
       '20'=>  "Received SIGUSR1 or SIGINT",
       '21'=>  "Some error returned by waitpid()",
       '22'=>  "Error allocating core memory buffers",
       '23'=>  "Partial transfer due to error",
       '24'=>  "Partial transfer due to vanished source files",
       '25'=>  "The --max-delete limit stopped deletions",
       '30'=>  "Timeout in data send/receive",
    );

    return $exit_desc{$code};

}


# Section for perldoc

__END__

=head1 NAME

rsyncmachine.pl - incremental rsync backups using hard links

=head1 VERSION

This documentation refers to rsyncmachine version $VERSION

=head1 SYNOPSIS

rsyncmachine.pl [--help|--version|--growlregister|--man] configurationfile

=head1 OPTIONS

=over 2

=item B<--help   >
Print a brief help message.

=item B<--version>
Print the version number.

=item B<--growlregister>
Sends the growl registration packet to the growl server.

=item B<--man    >
Print the complete pod documentation. Note that this will only work, if you
have the perldoc program available on your system.

=back

=head1 ARGUMENTS

=over 4

=item B<configurationfile>

Contains the settings for an instance of this program.

=back

=head1 DESCRIPTION

B<rsyncmachine.pl> will create incremental backups using rsync's hard links
mechanism via --link-dest. The default intervals for retained backups are
similar to settings of other backup applications and can be changed in the
configuration file.

rsyncmachine.pl will per default create backups as follows:

=over 2

=item - 
hourly backups for the past 24 hours

=item - 
daily backups for the past 30 days

=item - 
weekly backups for all previous months until the disk is full

=back

B<rsyncmachine.pl> copies the files from remote servers or local directories
to a local directory defined in the configuration file. Multiple source
locations gan be given, even from multiple hosts. The source syntax supported
by this program are:

=over 2

=item -
rsync://[user@]host.fqdn.tld/module/

=item -
[user@]host.fqdn.tld::module/

=item -
[user@]host.fqdn.tld:/path/to/be/backed/up/

=item -
/path/to/be/backed/up/

=back

Please note the trailing slashes, this means, that the contents of the
directory given as source is copied into one subdirectory of the backup
location with an "escaped" directory name, replacing / with _ etc.

If you have not backed up for a longer time rsyncmachine determines the
amount of space needed and if that is not available it successively deletes
the oldest oldest backups. The last one is preserved though and an error
generated, if there is still not enough space.

The directories for the backups, configuration and logfiles, as well as the
values of retained backups can be changed in a configuration file, some
values that should not normally be changed are defined in global variables at
the beginning of this script.

=cut

# vim:textwidth=78:shiftwidth=4:tabstop=4:expandtab:shiftround:autoindent:si
