package AIChat::Log;

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use Globals qw(%config @servers);
use Settings ();
use Utils qw(getFormattedDate);

sub _log_append {
    my @log_append;
    push @log_append, "_$config{username}_$config{char}" if $config{logAppendUsername} && $config{username};
    if ($config{logAppendServer} && defined $config{server}) {
        my $server_name = $servers[$config{server}]{name};
        push @log_append, "_$server_name" if $server_name;
    }

    return join '', @log_append;
}

sub log_file_path {
    my $folder = $Settings::logs_folder || 'logs';
    make_path($folder) unless -d $folder;

    my $base_file = File::Spec->catfile($folder, 'aichat.txt');
    my $append = _log_append();
    return substr($base_file, 0, length($base_file) - 4) . "$append.txt";
}

sub log_message {
    my (%args) = @_;

    my $direction = uc($args{direction} || 'IN');
    my $visibility = uc($args{visibility} || 'PRIVATE');
    my $name = $args{sender} || 'Unknown';
    my $label = $direction eq 'OUT' ? 'To' : 'From';
    my $message = defined $args{message} ? $args{message} : '';

    my $timestamp;
    getFormattedDate(time, \$timestamp);

    my $line = sprintf("[%s][%s][%s] %s %s: %s\n", $timestamp, $visibility, $direction, $label, $name, $message);

    my $file = log_file_path();
    open my $fh, '>>:utf8', $file or return;
    print {$fh} $line;
    close $fh;
}

1;
