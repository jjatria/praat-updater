#!/usr/bin/perl -w
use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Config;

# praat-updater
#   A script to check for new versions of the acoustic
#   analysis software praat and mail a notification
#   to a specified account.
#
# Written by Jose J. Atria
# Version 0.2 - In progress
# Latest revision: May 9th, 2011 @Santiago, CL
# Send comments and or bugs to jjatria [at] gmail [dot] com
#
# Released under the GNU General Public License.
# This is Free Software.
#
# Requirements:
#   sendemail (install from repositories)
#   lynx (install from repositories)
#
# To-Do
# - tidy up code
# - improve cross-platform compatibility

my %opt = ();

GetOptions (
  \%opt,
  'config=s',
  'force',
  'help|?',
  'keep=s',
  'send-notification=s',
  'no-update',
  'path=s',
  'quiet',
  'verbose',
  'yes',
);

if (defined $opt{help}) {
  pod2usage(-verbose  => 99,
            -sections => "NAME|SYNOPSIS|OPTIONS|DESCRIPTION|EXAMPLES|VERSION|AUTHOR|SEE ALSO" );
}

# Check operating system
# Note that there are certain issues with using %Config
# as stated in http://perldoc.perl.org/perlport.html
my $architecture = 'uname -m';
open CMD, "$architecture 2>&1 |"
  or die("Could not execute $architecture: $!");
chomp($architecture = <CMD>);
close CMD;
# Path to config file
my $config_file = (defined $opt{config}) ? $opt{config} : "$ENV{HOME}/.email.conf";
# Paths from environment
my @envpaths = split(":", $ENV{PATH});
# Path to output file
my $trackfile = "$ENV{HOME}/.oldpraatver";
# URL to access current praat version
my $version_url = "http://www.fon.hum.uva.nl/praat/manual/What_s_new_.html";
# Regex to check for praat version numbers
my $version_regex = "(?'full'([0-9])\.([0-9])(?:\.([0-9]{1,2}))?)";
# Regex to check for valid emails, as described in
# http://www.regular-expressions.info/email.html
my $email_regex = '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4}';
# Subject for praat update e-mail
my $mail_subject = 'New version of praat';

my $downloader = "wget";
my $html_dump = "lynx";

my $oldversion = (defined $opt{force}) ? "0.0.00" : "" ;

# Make sure configuration file is available
if ((defined $opt{'send-notification'}) && (! -e $config_file)) {
  print STDERR "Configuration file does not exist. Creating at $config_file.default\n";
  &CreateDefaultConfig($config_file);
}
print "Configuration file found at $config_file\n" if ((defined $opt{verbose}) && (defined $opt{'send-notification'}));

my %SETUP;
if (defined $opt{'send-notification'}) {
  open(FILE, $config_file)
    or die("Could not open configuration file: $!");
  while (<FILE>) {
    chomp;
    my $read = $_;
    if ($read =~ /^([A-Z]+)=(.+)$/) {
      $SETUP{$1} = $2;
    }
  }
  close FILE;
}
print "Read ".keys(%SETUP)." variable(s) from configuration file\n" if ((defined $opt{verbose}) && (defined $opt{'send-notification'}));

if (! -e $trackfile) {
  # File does not exist
  &GenerateDefault();
}

# Attempts to read old version number from $trackfile
# If unable, generates a default file with
# null version number 0.0.0 and retries.
my $a;
if (! defined $opt{force}) {
  EVAL: {
    open(TXT, $trackfile)
      or die("Could not open version track file: $!");
    $a = <TXT>;
    close TXT;

    if (! defined $a){
      # File is blank
      &GenerateDefault(1);
      redo EVAL;
    }

    if ($a =~ /^$version_regex$/) {
      $oldversion = $+{full};
    }

    if ((! defined $oldversion) || ($oldversion !~ /^$version_regex$/)) {
      # File is faulty
      &GenerateDefault(2);
      redo EVAL;
    }
  }
}
undef $a;
print "Found tracked version number at $trackfile: $oldversion\n" if (defined $opt{verbose});
print "Querying server for newest version... " if (defined $opt{verbose});
my $cmd = "$html_dump -dump $version_url 2>&1 |";
open CMD, "$cmd"
  or die("Could not execute $cmd: $!");
my @htmldump = <CMD>;
close CMD;

print "... "  if (defined $opt{verbose});

my $newestversion;
FINDVER: foreach (@htmldump) {
  $newestversion = $+{full} if $_ =~ /$version_regex/;
  if (defined $newestversion) {
    last FINDVER;
  }
}

if (! defined $newestversion){
  # No praat version in downloaded file
  die ("Cannot retrieve current version from server.\nCheck settings or try again later.");
}

print "done.\nNewest version: $newestversion\n" if (defined $opt{verbose});

my $check = &CompareVersions($oldversion, $newestversion) if ($newestversion ne "0.0.0");

if ($check > 0) {
  if (! defined $opt{quiet}) {
    print "New version number found: $oldversion\t->\t$newestversion\n";
    print "Updating version number... ";
  }
  open(OUTPUT, ">$trackfile")
    or die("Could not create file");
  print OUTPUT $newestversion;
  close(OUTPUT);
  print "done\n" if (! defined $opt{quiet});

  &UpdatePraat if (! defined $opt{'no-update'});

  if (defined $opt{'send-notification'}) {
    my $changes = &WhatsNew(@htmldump, $newestversion);
    my @recipients = &ParseRecipients;
    &SendMail($newestversion, $changes, @recipients);
  }
} else {
  print "Already at newest version. No changes needed.\n";
  #if (defined $opt{verbose});
}

## Subroutines ##

sub SendMail {
  my $version = shift(@_);
  my $changes = shift(@_);
  my $bcc = shift(@_);
  if (@_) {
    $bcc .= ", ";
    $bcc .= join(", ", @_) if (@_);
  }
  my $subject = $mail_subject;
  my $body = "praat v.$version is now available.\n\n$changes\n\nYou can download the latest version from http://www.fon.hum.uva.nl/praat/\n";

  print "Mailing new version number...\n" if ((defined $opt{'send-notification'}) && (! defined $opt{quiet}));
  
  my $cmd = 'sendemail -s smtp.gmail.com:587 -o tls=auto -m "'.$body.'"';
  $cmd .= ' -u "'.$subject.'" -bcc "'.$bcc.'"';
  $cmd .= ' -xu '.$SETUP{USERNAME}.'@gmail.com -xp '.$SETUP{PASSWORD}.' -f '.$SETUP{USERNAME}.'@gmail.com';

  # Sending email with sendemail
  !system $cmd
    or die("Could not execute $cmd: $!");
}

sub GetTime {
  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
  # Pad with a zero
  $sec = substr("0$sec", -2);
  $min = substr("0$min", -2);
  $hour = substr("0$hour", -2);
  my @months = qw{ Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec };
  my @days = qw { Mon Tue Wed Thu Fri Sat Sun };
  my $result = "$months[$mon] $mday $hour:$min:$sec";
  $result;
}

sub GenerateDefault {
  my $msg = "Version record does not exist";
  if (defined $_[0]) {
    $msg = "Version record is blank" if ($_[0] == 1);
    $msg = "Faulty version record" if ($_[0] > 1);
  }
  print STDERR "$msg. Creating version record... ";
  open(OUTPUT, ">$trackfile")
    or die("Could not create file");
  print OUTPUT "0.0.0";
  close(OUTPUT);
  print STDERR "done.\n";
}

sub CompareVersions {
  my $old = $_[0];
  my $new = $_[1];
  $old =~ /$version_regex/;
  my $old1 = $2;
  my $old2 = (defined $3) ? $3 : 0;
  my $old3 = (defined $4) ? $4 : 0;
  $new =~ /$version_regex/;
  my $new1 = $2;
  my $new2 = (defined $3) ? $3 : 0;
  my $new3 = (defined $4) ? $4 : 0;

  # Return 3 if it's a minor release
  return 3 if (($new3 > $old3) && ($new2 >= $old2) && ($new1 >= $old1));
  # Return 2 if it's a medium release
  return 2 if (($new2 > $old2) && ($new1 >= $old1));
  # Return 1 if it's a major release
  return 1 if ($new1 > $old1);
}

sub WhatsNew {
  my $new;
  my $currentversion = pop(@_);
  chomp(my @lines = @_);
  my $txt = join("\n", @lines);
  @lines = split(/\n{2,}/, $txt);
  LOOP: foreach (@lines) {
    if ($_ =~ /$currentversion/) {
      $new = $_;
      last LOOP;
    }
  }
  return $new;
}

sub ParseRecipients {
  my @recipients;
  my @tmp = split(",", $opt{'send-notification'});
  foreach (@tmp) {
    push(@recipients, $_) if ($_ =~ /$email_regex/i);
  }
  return @recipients;
}

sub UpdatePraat {
  my $praatpath;
  my $praatfullpath;
  my $cmd;
  my $praaturl;
  if (defined $opt{path}) {
    # Check if user given path is a directory, and make sure it is formatted properly
    chomp($praatpath = $opt{path});
    if (-d $praatpath) {
      my $check = substr($praatpath, -1);
      if ($check ne '/') {
        $praatpath .= '/';
      } 
      $praatfullpath = $praatpath.'praat';
    } else {
      $praatfullpath = $praatpath;
      my $a = rindex($praatpath, '/');
      $praatpath = substr($praatpath, 0, $a);
    }
    # Check if path to praat is in $PATH
    my $pathcheck = 0;
    foreach (@envpaths) {
      $pathcheck = 1 if ($praatpath eq $_.'/');
    }
    if ($pathcheck == 0) {
      print STDERR 'Specified path is not in $PATH. Aborting...'."\n";
      exit 1;
    }
    # Check if praat exists at the user specified path and offer to create it
    if (! -e $praatfullpath) {
      print "$praatfullpath does not exist. Would you like to create it? [Y/n] " if (! defined $opt{quiet});
      my $yes = &InputYN("y");
      exit 0 unless $yes;
    }
  } else {
    # If user did not specify path to praat, attempt to detect it
    $cmd = "which praat";
    open CMD, "$cmd 2>&1 |"
            or die ("Could not execute $cmd: $!");
    $praatfullpath = <CMD>;
    close CMD;
    chomp $praatfullpath;
    # If unable to detect it, offer to install it
    if (! defined $praatfullpath) {
      print "praat does not seem to be installed. Would you like to install it? [Y/n] " if (! defined $opt{quiet});
      my $yes = &InputYN("y");
      # User rejects installation
      unless ($yes) {
        print "Aborting...\n" if (! defined $opt{quiet});
        exit 0;
      } else {
        # If requested to install it, ask for a proper path to do so
        my $counter = 0;
        # List paths in $PATH as options
        foreach (@envpaths) {
          print "[$counter] $_\n";
          ++$counter;
        }
        print '['.$counter."] Other\n" if (! defined $opt{quiet});
        INSTALLCHOICE: {
          print "Where should I try to install it? [0-$counter] (default=[0]) " if (! defined $opt{quiet});
          my $installchoice;
          if (defined $opt{quiet}) {
            $installchoice = "0\n";
          } else {
            $installchoice = (defined $opt{yes}) ? "0" : <STDIN>;
            chomp $installchoice;
          }
          $installchoice = 0 if ($installchoice =~ /^$/);
          # If user correctly selects an option, assign that as a path
          if (($installchoice =~ /^\d$/i) && (($installchoice >= 0) && ($installchoice <= $#envpaths))) {
            $praatpath = $envpaths[$installchoice];
            # Make sure path is well formatted
            my $check = substr($praatpath, -1);
            if ($check ne '/') {
              $praatpath .= '/';
            } 
            $praatfullpath = $praatpath.'praat';
          } elsif ($installchoice == $#envpaths+1) {
            # If user opts to input another path, use that one
            print "Please specify the new path for praat: ";
            chomp ($praatpath = <STDIN>);
            # Check if it is a directory, or exit
            if (! -d $praatpath) {
              print STDERR "Specified path is not a directory. Please try again.\n";
              exit 1;
            }
            # Check if path to praat is in $PATH
            my $pathcheck = 0;
            foreach (@envpaths) {
              $pathcheck = 1 if ($praatpath eq $_.'/');
            }
            if ($pathcheck == 0) {
              print 'Specified path is not in $PATH. Is this ok? [Y/n] ';
              my $yes = &InputYN("y");
              # User rejects path that is not in $PATH
              unless ($yes) {
                print "Aborting...\n" if (! defined $opt{quiet});
                exit 0;
              }
            }
            # Make sure path is well formatted
            my $check = substr($praatpath, -1);
            if ($check ne '/') {
              $praatpath .= '/';
            } 
            $praatfullpath = $praatpath.'praat';
          } else {
            # If user fails to input an option, redo
            redo INSTALLCHOICE;
          }
        }
      }
    } else {
      my $i = rindex($praatfullpath, '/');
      $praatpath = substr($praatfullpath, 0, $i+1);
    }
  }

  if (! -w $praatpath) {
    print STDERR "Do not have permission to write to $praatpath. Change path or user and try again\n";
    exit 1;
  }

  print "Installing in $praatfullpath\n" if (defined $opt{verbose});
  print "Everything seems to be OK. Proceed with installation? [Y/n] " if (! defined $opt{quiet});
  my $yes = &InputYN("y");
  exit 0 unless $yes;

  print "Installing...\n" if (! defined $opt{quiet});

  my $shortversion = $newestversion . "00";
  $shortversion =~ tr/\.//d;
  $shortversion = substr("$shortversion", 0, 4);

  if ($architecture eq "i686") {
    $praaturl = 'http://www.fon.hum.uva.nl/praat/praat'.$shortversion.'_linux32.tar.gz';
  } elsif ($architecture eq "x86_64") {
    $praaturl = 'http://www.fon.hum.uva.nl/praat/praat'.$shortversion.'_linux64.tar.gz';
  }

  my $lastslash = rindex($praaturl, "/");
  my $tarballfilename = substr($praaturl, $lastslash+1);
  my $tarballpath;
  if (defined $opt{keep}) {
    $tarballpath = $opt{keep};
    if (-d $tarballpath) {
      my $check = substr($tarballpath, -1);
      if ($check ne '/') {
        $tarballpath .= '/';
      } 
    } else {
      print STDERR "Path for --keep is not a valid directory. Please try again.\n";
      exit 1;
    }
  } else {
    $tarballpath = $praatpath;
  }
  my $tarballfullpath = $tarballpath.$tarballfilename;

  my $uselocaltarball = 0;
  if (-e $tarballfullpath) {
    print "Archive exists at ".$tarballfullpath."\n" if (! defined $opt{quiet});
    print "Install from local file? [y/N] " if (! defined $opt{quiet});
    my $no = &InputYN("n");
    if ($no) {
      print "Replace with fresh archive? [Y/n] " if (! defined $opt{quiet});
      my $yes = &InputYN("y");
      unless ($yes) {
        print "Aborting...\n" if (! defined $opt{quiet});
        exit 0;
      } else {
        $uselocaltarball = 0;
      }
    } else {
      $opt{keep} = $tarballpath if (! defined $opt{keep});
      $uselocaltarball = 1;
    }
  }

  if ($uselocaltarball == 0) {
    print "Downloading from $praaturl...\n" if (defined $opt{verbose});

    $cmd = "wget $praaturl -O ".$tarballfullpath;
    $cmd .= " -q" if (! defined $opt{verbose});
    !system $cmd
      or die("Could not execute $cmd: $!");
    print "Downloaded archive $tarballfilename\n" if (defined $opt{verbose});
  }

  if (-e $praatfullpath) {
    $cmd = "mv $praatfullpath $praatfullpath.old";
    !system $cmd
      or die("Could not execute $cmd: $!");
  }
  print "Made a backup of $praatfullpath to $praatfullpath.old\n" if (defined $opt{verbose});

  print "Extracting archive... " if (defined $opt{verbose});
  $cmd = "tar -zxvf ".$tarballfullpath." -C $praatpath";
  !system $cmd
    or die("Could not execute $cmd: $!");
  print "done\n" if (defined $opt{verbose});

  if (! defined $opt{keep}) {
    unlink $tarballfullpath or warn "Could not delete file: $!";
  }
}

sub CreateDefaultConfig {
  # If config file is not found, and is required
  # for e-mail notification, create a default version
  open(OUTPUT, "+>$_[0].default")
    or die("Could not create default version of config file. Are the permissions set correctly?");
  print OUTPUT "# Configuration file for praat-updater\n";
  print OUTPUT '# Make sure to rename it to "'.$_[0].'" as stated'."\n";
  print OUTPUT "# in the script.\n\n";
  print OUTPUT "USERNAME=yourgmailusername\n";
  print OUTPUT "PASSWORD=yourgmailpassword\n";
  close(OUTPUT);
  exit 0;
}

sub InputNumber {
  # $default holds the default value
  my $default = $_[0];
}

sub InputYN {
  my $default = $_[0];
  my $input;
  if (defined $opt{quiet}) {
    $input = (defined $opt{yes}) ? "Y" : "N";
  } else {
    $input = (defined $opt{yes}) ? "Y" : <STDIN>;
    chomp $input;
  }
  print "$input\n" if ((defined $opt{yes}) && (! defined $opt{quiet}));
  if ($input =~ /^($default|$)/i) {
    return 1;
  } else {
    return 0;
  }
}

__END__

=head1 NAME

praat-updater - A script to check for new versions of praat

=head1 SYNOPSIS

praat-updater [OPTIONS]

=head1 OPTIONS

=over 8

=item B<-c>, B<--config>

Specify path to configuration file. The file holds information required by I<sendemail> to send e-mail notifications of new available versions, if B<--send-notification> is set.

=item B<-f>, B<--force>

Do not check most recent version against latest version on records. If this option is set, B<praat-updater> will update praat - or notify of the availability of a new version, depending on the desired behaviour - no matter what version is currently installed.

=item B<-?>, B<--help>

Show this usage information.

=item B<-k>, B<--keep>

Do not delete the I<What's New> file downloaded from the praat website. This option is set automatically if B<--local> is set.

=item B<-l> I<FILE>, B<--local>=I<FILE>

Do not download anything from praat's servers. If this option is set, I<FILE> is used to check the latest version as if it were the I<What's New> file with praat's latest changes, no new version of praat is installed, and no e-mail notifications are sent. Used mainly for testing.

=item B<-s> I<RECIPIENTS>, B<--send-notification>=I<RECIPIENTS>

Send an e-mail notification to I<RECIPIENTS> if a new version has been found, with the latest changes and a link to the praat website. I<RECIPIENTS> can be an e-mail address, or a list of recipients separted by commas.

=item B<-p> I<PATH>, B<--path>=I<PATH>

Path to the currently installed version of praat. If not specified, B<praat-updater> will attempt to find it by making a system call to L<which> or an equivalent service.

=item B<-q>, B<--quiet>

Print no information to STDOUT. In this mode, all prompts will be handled automtically.

=item B<-v>, B<--verbose>

Print progress information to STDOUT.

=item B<--yes>

Assume L<yes> on every prompt. Use with B<extreme> caution!

=back

=head1 DESCRIPTION

The script checks the website of acoustic analysis software L<praat> for new versions and updates the software if a newer version has been found. If so desired, it can also send an e-mail notification to a list of recipients with useful information about the latest release, as well as a link to the website to facilitate the updating process.

For the time being, it has only been tested under GNU/Linux, but support for other platforms is on the to-do list.

It is still very much a work in progress.

=head1 EXAMPLES

=item praat-updater --path=/home/user/bin -y -v -s paul@praat.com,david@praat.com -k /home/user/praat/oldversions >> logfile

Recommended usage for a cronjob that checks for new versions at regular intervals and installs a new version of praat when available at the designated path, and then sends an e-mail notification about the update to a number of specified accounts. If not piped to a logfile, B<--verbose> can be replaced with B<--quiet> to eliminate output to STDOUT.

=item sudo praat-updater -f -p /usr/bin -y

Without user interaction, replace whatever version of praat is installed in the specified folder with a new one. If B<--path> is omitted, the script will use the path of the installed version, or ask the user for a path to install. In this case, B<--yes> would make the script default to the first path in $PATH.

=head1 VERSION

Version 0.1-alpha - May 3rd, 2011

=head1 AUTHOR

Jose Joaquin Atria <jjatria@gmail.com>

=head1 SEE ALSO

B<sendemail>, B<praat> 
