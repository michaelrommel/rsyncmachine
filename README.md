rsyncmachine.pl
===============

`rsyncmachine.pl` is a perl script that automates backups using rsync which
runs as hourly cron jobs and creates snapshots of the source directories
at that time. By hard-linking files that have not been changed to the
previous backup files `rsyncmachine.pl` keeps consumed diskspace at a minimum.
Obviously this will work only on filesystems that support hard-links,
like various linux filesystems. It has been used successfully on ext4.

`rsyncmachine.pl` will create incremental backups using rsync's hard
links mechanism via --link-dest, as opposed to similar solutions which
create a local hard-linked copy via `cp -al` first and then specify
the `--delete` option to rsync to clean up removed files. 

The default intervals for retained backups are similar to settings of
other backup applications and can be changed in the configuration file.


## Version ##

This documentation refers to `rsyncmachine.pl` version 0.11.0

## Synopsis ##

    rsyncmachine.pl [--help|--version|--growlregister|--man] configurationfile

    Options
        --help          Print a brief help message.
        --version       Print the version number.
        --growlregister Sends the growl registration packet to the growl server.
        --man           Print the complete pod documentation. Note that
                        this will only work, if you have the perldoc
                        program available on your system.

    Arguments
        configurationfile
	        Contains the settings for an instance of this program.

## Details ##

`rsyncmachine.pl` will per default create backups as follows:

- hourly backups for the past 24 hours
- daily backups for the past 30 days
- weekly backups for all previous months until the disk is full

`rsyncmachine.pl` copies the files from remote servers or local
directories to a local directory defined in the configuration file.
Multiple source locations gan be given, even from multiple hosts. 

Before actually transferring the files `rsyncmachine.pl` determines the
amount of space needed and -- if that is not available -- it successively
deletes the oldest oldest backups. The last one is preserved though and
an error generated, if there is still not enough space.

The directories for the backups, configuration and logfiles, as well as
the values of retained backups can be changed in a configuration file,
some values that should not normally be changed are defined in global
variables at the beginning of this script.


## Dependencies ##

`rsyncmachine.pl` makes extensive use of existing modules from CPAN.
Here is the list of the used modules that should be either in the
default perl installation on a standard ubuntu, if you install the main
perl interpreter or that are packaged separately:

    File::Path
    File::Basename
    Carp
    Getopt::Long
    Pod::Usage
    Switch
    English
    Filesys::DiskSpace
    DateTime
    Log::Log4perl
    Readonly
    RRDs
    Try::Tiny
    LockFile::Simple
    IO::Socket::INET
    Config::JSON

Typically those modules a prepackaged, to install them e.g. for ubuntu:

    apt-get install libswitch-perl
    apt-get install libfilesys-diskspace-perl
    apt-get install libdatetime-perl
    apt-get install liblog-log4perl-perl
    apt-get install libreadonly-perl
    apt-get install librrdtool-oo-perl
    apt-get install libtry-tiny-perl
    apt-get install liblockfile-simple-perl
    apt-get install libio-socket-ip-perl
    apt-get install libconfig-json-perl


## Configuration File ##

The configuration file uses a JSON structure to define some global
parameters, as well as the source directories or modules which you
would like to backup.

The configuration file and it´s parameters are described in detail
in [configuration](./doc/config.md).

An [example configuration file](./conf/rsyncmachine.conf) can be found
in the [conf/](./conf/) subdirectory.

For further information have a look at more program
[features](./doc/features.md).


<!--
vim:tw=72:sw=4:ai:si
-->
