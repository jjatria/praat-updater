#!/usr/bin/perl -w
use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Config;

# praat-notify
#   A script to check for new versions of the acoustic
#   analysis software praat and mail a notification
#   to a list of specified accounts.
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
	'mailer=s',
	'quiet',
	'subject=s',
	'selfish',
	'to=s',
	'verbose',
	'yes',
);

if (defined $ARGV[0]) {
	pod2usage(	-verbose => 99,
				-sections => "NAME|SYNOPSIS" );
}

if (defined $opt{help}) {
	pod2usage(	-verbose => 99,
				-sections => "NAME|SYNOPSIS|OPTIONS|DESCRIPTION|EXAMPLES|VERSION|AUTHOR|SEE ALSO" );
}

if ((defined $opt{verbose}) && (defined $opt{quiet})) {
	print STDERR "--quiet overidden by --verbose. Please check options to disable this message\n";
}

if (defined $opt{selfish}) {
	print "*Test mode enabled: no emails will be sent*\n" unless (defined $opt{quiet});
}

# Path to config file
my $config_file = defined $opt{config} ? $opt{config} : "$ENV{HOME}/.email.conf";
# Path to version tracking file
my $trackfile = "$ENV{HOME}/.praat-notify_ver";
# URL to access current praat version
my $version_url = "http://www.fon.hum.uva.nl/praat/manual/What_s_new_.html";
# Regex to check for praat version numbers
my $version_regex = "(?'full'([0-9])\.([0-9])(?:\.([0-9]{1,2}))?)";
# Regex to check for valid emails, as described in
# http://www.regular-expressions.info/email.html
my $email_regex = '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4}';
# Subject for praat update e-mail
my $mail_subject = $opt{subject} // 'New version of praat';

my $downloader = "wget";
my $html_dump = "lynx";

my $oldversion = (defined $opt{force}) ? "0.0.00" : "" ;

my $date = &GetTime();
print "$date\n" if (!defined $opt{quiet});

# Make sure configuration file is available
if (! -e $config_file) {
        print STDERR "Configuration file does not exist.\nCreating at $config_file.default. Please check and rename appropriately.\n";
	&CreateDefaultConfig($config_file);
}
print "Configuration file found at $config_file\n" if (defined $opt{verbose});

my %setup;
open(CFG, $config_file)
	or die("Could not open configuration file: $!");
while (<CFG>) {
	chomp;
	my $read = $_;
	if ($read =~ /^([A-Z]+)=(.+)$/) {
		$setup{$1} = $2;
	}
}
close CFG;

print "Read ".keys(%setup)." variable(s) from configuration file\n" if (defined $opt{verbose});

if (! -e $trackfile) {
	# Version tracking file does not exist
	&GenerateDefault();
}

# Attempts to read old version number from $trackfile
# If unable, generates a default file with
# null version number 0.0.0 and retries.
my $body;
if (! defined $opt{force}) {
	EVAL: {
		open(TXT, $trackfile)
			or die("Could not open version track file: $!");
		$body = <TXT>;
		close TXT;

		if (! defined $body){
			# File is blank
			&GenerateDefault(1);
			redo EVAL;
		}

		if ($body =~ /^$version_regex$/) {
			$oldversion = $+{full};
		}

		if ((! defined $oldversion) || ($oldversion !~ /^$version_regex$/)) {
			# File is faulty
			&GenerateDefault(2);
			redo EVAL;
		}
	}
}
undef $body;

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

if (! defined $newestversion) {
	# No praat version in downloaded file
	die ("\nCannot retrieve current version from server.\nCheck settings or try again later.");
}

print "done.\nNewest version: $newestversion\n" if (defined $opt{verbose});

my $check = &CompareVersions($oldversion, $newestversion) if ($newestversion ne "0.0.0");

if ($check > 0) {
	if (! defined $opt{quiet}) {
		print "New version number found: $oldversion\t->\t$newestversion\n";
		print "Updating version number... ";
	}
	open(NEWVER, ">$trackfile")
		or die("Could not create file");
	print NEWVER $newestversion;
	close(NEWVER);
	print "done\n" unless (defined $opt{quiet});

	my $changes = &WhatsNew(@htmldump, $newestversion);
	my @recipients = &ParseRecipients;
	&SendMail($check, $newestversion, $changes, @recipients);
	exit 0;
} else {
	print "Already at newest version. No changes needed.\n" unless (defined $opt{quiet});
	exit 1;
}

## Subroutines ##

sub SendMail {
	# Check return values from &CompareVersions for release codes
	my $release = shift(@_);
	my $version = shift(@_);
	my $changes = shift(@_);
	my $bcc = shift(@_);
	if (@_) {
		$bcc .= ", ";
		$bcc .= join(", ", @_);
	}
	my $subject = $mail_subject;
	my $body = "praat v.$version is now available.\n\n$changes\n\nYou can download the latest version from http://www.fon.hum.uva.nl/praat/\n";

	print "Mailing new version number...\n" unless (defined $opt{quiet});

	my $cmd = 'sendemail -s smtp.gmail.com:587 -o tls=yes -m "'.$body.'"';
	$cmd .= ' -u "'.$subject.'" -bcc "'.$bcc.'"';
	$cmd .= ' -xu '.$setup{USERNAME}.'@gmail.com -xp '.$setup{PASSWORD}.' -f '.$setup{USERNAME}.'@gmail.com';

	# Sending email with sendemail
	unless (defined $opt{selfish}) {
		!system $cmd
			or die("Could not execute $cmd: $!");
	}
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
	my @to = split(",", $opt{'to'});
	foreach (@to) {
		push(@recipients, $_) if ($_ =~ /$email_regex/i);
	}
	return @recipients;
}

sub CreateDefaultConfig {
	# If config file is not found, and is required
	# for e-mail notification, create a default version
	open(OUTPUT, "+>$_[0].default")
		or die("Could not create default version of config file. Are permissions set correctly?");
	print OUTPUT "# Configuration file for praat-updater\n";
	print OUTPUT '# Make sure to rename it to "'.$_[0].'" as stated'."\n";
	print OUTPUT "# in the script.\n\n";
	print OUTPUT "USERNAME=yourgmailusername\n";
	print OUTPUT "PASSWORD=yourgmailpassword\n";
	close(OUTPUT);
	exit 0;
}

__END__

=head1 NAME

praat-notify - A script to check for new versions of praat and notify users

=head1 SYNOPSIS

praat-notify [OPTIONS]

=head1 OPTIONS

=over 8

=item B<-c>, B<--config>

Specify path to configuration file. The file holds information required by I<sendemail> to send e-mail notifications of new available versions, if B<--send-notification> is set.

=item B<-f>, B<--force>

Do not check most recent version against latest version on records. If this option is set, B<praat-updater> will skip the version check and send a notification to the addresses specified in B<--to> regardless of what version is the most recient.

=item B<-?>, B<--help>

Show this usage information.

=item B<-t> I<RECIPIENTS>, B<--to>=I<RECIPIENTS>

Specify an e-mail notification to I<RECIPIENTS> if a new version has been found, with the latest changes and a link to the praat website. I<RECIPIENTS> can be an e-mail address, or a list of recipients separted by commas.

=item B<-q>, B<--quiet>

Print no information to STDOUT. This option is overidden by B<-verbose>.

=item B<-v>, B<--verbose>

Print progress information to STDOUT.

=back

=head1 DESCRIPTION

The script checks the website of acoustic analysis software L<praat> for new versions and updates the software if a newer version has been found. If so desired, it can also send an e-mail notification to a list of recipients with useful information about the latest release, as well as a link to the website to facilitate the updating process.

For the time being, it has only been tested under GNU/Linux, but support for other platforms is on the to-do list.

It is still very much a work in progress.

=head1 EXAMPLES

=item praat-updater -v -s paul@praat.com,david@praat.com >> logfile

Recommended usage for a cronjob that checks for new versions at regular intervals and installs a new version of praat when available at the designated path, and then sends an e-mail notification about the update to a number of specified accounts. If not piped to a logfile, B<--verbose> can be replaced with B<--quiet> to eliminate output to STDOUT.

=head1 VERSION

Version 0.1-alpha - May 3rd, 2011

=head1 AUTHOR

Jose Joaquin Atria <jjatria@gmail.com>

=head1 SEE ALSO

B<sendemail>, B<praat> 
