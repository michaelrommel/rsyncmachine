rsyncmachine
============

rsyncmachine is a perl script that automates backups using rsync which
runs as hourly cron jobs and creates snapshots of the source directories
at that time. By hard-linking files that have not been changed to the
previous backup files rsyncmachine keeps consumed diskspace at a minimum.
Obviously this will work only on filesystems that support hard-links,
like various linux filesystems. It has been used successfully on ext4.

rsyncmachine will create incremental backups using rsync's hard
links mechanism via --link-dest, as opposed to similar solutions which
create a local hard-linked copy via `cp -al` first and then specify
the `--delete` option to rsync to clean up removed files. 

The default intervals for retained backups are similar to settings of
other backup applications and can be changed in the configuration file.


## Version ##

This documentation refers to rsyncmachine version 0.10.7

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

rsyncmachine will per default create backups as follows:

- hourly backups for the past 24 hours
- daily backups for the past 30 days
- weekly backups for all previous months until the disk is full

`rsyncmachine.pl` copies the files from remote servers or local
directories to a local directory defined in the configuration file.
Multiple source locations gan be given, even from multiple hosts. 

If you have not backed up for a longer time rsyncmachine determines the
amount of space needed and if that is not available it successively
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

The configuration file uses a JSON structure to define some globale
parameters, as well as the source directories or modules which you
would like to backup.

The source syntax supported by this program are all standard rsync
parameter declarations, plus one extended syntax:

1. /path/to/be/backed/up/
1. rsync://[user@]host.fqdn.tld[:port]/module/
1. [user@]host.fqdn.tld::module/
1. [user@]host.fqdn.tld:/path/to/be/backed/up/
1. user#\<nnn\>@host.fqdn.tld:/path/to/be/backed/up/

Variant 1) is just a regular copy on the same host.

Variant 2) is using a direct tcp connection to a rsync daemon on 
the source computer, typically on port 873, but a different port can
be specified as well.

Variant 3) is a different way of 2), same functionality, but without the
ability to specify the port of the remote daemon.

Variant 4) is using ssh per default as standard transport mechanism to
connect to the source system and transporting the rsync data stream. rsync
uses the supplied username for both the ssh login and for rsync to
determine the access to the path. Note that rsync per default does not 
provide you with a method of specifying a different port to connect to.

Therfore variant 5) is a hack, whereby a ssh port number is provided
as extension to the username separated by a hash and followed by only
digits. It is unlikely that this will create a difficulty for real world
applications and you can change it in the source code, but you should be
aware that a source path of `test#123@my.host.tld:/tmp/file.txt` would 
actually try to connect to a ssh daemon on port 123 logging in as user
"test" instead of logging into port 22 as user "test#123".

Wherever a host.fqdn.tld is specified, a short hostname may also be used
provided that your name resolver is able to find the source host by that
short name. In any case for the resulting target backup directory the 
.fqdn.tld is stripped, to create shorter directory names. 

*Attention:* Beware of clashes, where you would like to backup from 
host1.domain.com and from host1.domain.org in the same instance of 
rsyncmachine and using exactly the same module or path name to 
backup - this would result in identical directories and probably 
clobber your backup.

Please note the trailing slashes, this means, that the contents of the
directory given as source is copied into one subdirectory of the backup
location with an "escaped" directory name, replacing / with _ etc.

An example configuration file can be found in the conf/ subdirectory.

For further information, you can read more about the 
[features](./doc/features.md).


<!--
vim:tw=72:sw=4:ai:si
-->
