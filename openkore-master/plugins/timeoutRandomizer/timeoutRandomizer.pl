package OpenKore::Plugins::timeoutRandomizer;

use strict;
use warnings;

use Globals qw(%timeout);
use Log qw(message warning);
use Plugins;
use Scalar::Util qw(looks_like_number);
use Settings;
use Utils ();

our $VERSION = '1.0';

my %configured_ranges;
my $control_handle;
my $hooks;
my %missing_reported;
my $orig_timeOut;
my $override_installed = 0;

BEGIN {
        $orig_timeOut = Utils->can('timeOut');
}

Plugins::register('timeoutRandomizer', 'Randomize configured timeouts within ranges', \&unload, \&reload);

$hooks = Plugins::addHooks(
        ['pos_load_timeouts.txt', \&on_timeouts_loaded, undef],
        ['start3',                \&on_start,           undef],
);

sub on_start {
        if (!defined $control_handle) {
                $control_handle = Settings::addControlFile('timeout_randomizer.txt',
                        loader => [\&load_range_file], mustExist => 0, autoSearch => 1);
        }

        Settings::loadByHandle($control_handle) if defined $control_handle;
        apply_ranges();
}

if ($orig_timeOut) {
        no warnings 'redefine';
        *Utils::timeOut = sub ($;$) {
                my ($r_time, $timeout_value) = @_;

                if (!defined $timeout_value && ref($r_time) eq 'HASH') {
                        _maybe_randomize($r_time);
                }

                return $orig_timeOut->($r_time, $timeout_value);
        };
        $override_installed = 1;
} else {
        warning "[timeoutRandomizer] Could not locate Utils::timeOut; plugin is disabled.\n";
}

sub load_range_file {
        my ($file) = @_;

        %configured_ranges = ();

        unless (defined $file && -f $file) {
                message "[timeoutRandomizer] No timeout_randomizer.txt found; plugin is idle.\n", 'system';
                return 1;
        }

        open my $fh, '<', $file or do {
                warning sprintf "[timeoutRandomizer] Could not read %s: %s\n", $file, $!;
                return 0;
        };

        my $line_no = 0;
        while (my $line = <$fh>) {
                $line_no++;
                $line =~ s/\x{FEFF}//g;
                $line =~ s/#.*$//;
                $line =~ s/^\s+//;
                $line =~ s/\s+$//;
                next unless length $line;

                my ($name, $rest) = $line =~ /^(\S+)\s*(.*)$/;
                unless (defined $name && length $name) {
                        warning sprintf "[timeoutRandomizer] Invalid line %d in %s\n", $line_no, $file;
                        next;
                }

                my ($min, $max) = _parse_range($rest // '');
                unless (defined $min && defined $max) {
                        warning sprintf "[timeoutRandomizer] Invalid range for '%s' on line %d in %s\n", $name, $line_no, $file;
                        next;
                }

                $configured_ranges{$name} = { min => $min, max => $max };
        }

        close $fh;

        apply_ranges();

        return 1;
}

sub _parse_range {
        my ($expr) = @_;
        return unless defined $expr;

        my $normalized = $expr;
        $normalized =~ s/\.\./ /g;
        $normalized =~ s/,/ /g;
        $normalized =~ s/\s+/ /g;
        $normalized =~ s/^\s+//;
        $normalized =~ s/\s+$//;

        return unless length $normalized;

        my @parts = split /\s+/, $normalized;
        if (@parts == 1) {
                return _validate_number($parts[0]), _validate_number($parts[0]);
        }

        my ($min, $max) = @parts[0, 1];
        $min = _validate_number($min);
        $max = _validate_number($max);

        return unless defined $min && defined $max;

        return ($min, $max);
}

sub _validate_number {
        my ($value) = @_;
        return unless defined $value;
        return $value if looks_like_number($value);
        return;
}

sub on_timeouts_loaded {
        apply_ranges();
}

sub apply_ranges {
        foreach my $name (keys %configured_ranges) {
                my $entry = $timeout{$name};
                if (ref $entry eq 'HASH') {
                        my ($min, $max) = @{ $configured_ranges{$name} }{qw(min max)};
                        ($min, $max) = ($max, $min) if defined $min && defined $max && $max < $min;

                        my $meta = $entry->{timeout_randomizer} ||= {};
                        @$meta{qw(min max name)} = ($min, $max, $name);
                        delete @$meta{qw(initialized last_time)};
                        delete $missing_reported{$name};
                } else {
                        next if $missing_reported{$name};
                        warning sprintf "[timeoutRandomizer] Timeout '%s' is not defined in timeouts.txt; waiting for it to become available.\n", $name;
                        $missing_reported{$name} = 1;
                }
        }

        foreach my $name (keys %timeout) {
                next if exists $configured_ranges{$name};
                my $entry = $timeout{$name};
                next unless ref $entry eq 'HASH';
                delete $entry->{timeout_randomizer};
                delete $missing_reported{$name};
        }
}

sub _maybe_randomize {
        my ($entry) = @_;

        my $meta = $entry->{timeout_randomizer};
        return unless $meta;

        my ($min, $max) = @$meta{qw(min max)};
        return unless defined $min && defined $max;
        ($min, $max) = ($max, $min) if $max < $min;

        my $time      = $entry->{time};
        my $last_time = $meta->{last_time};
        my $needs_new = !$meta->{initialized};

        if (!$needs_new) {
                if (defined $time) {
                        $needs_new = !defined($last_time) || $last_time != $time;
                } else {
                        $needs_new = defined $last_time;
                }
        }

        return unless $needs_new;

        my $value = $min;
        $value = $min + rand($max - $min) if $max > $min;

        $entry->{timeout} = $value;
        $meta->{last_time} = $time;
        $meta->{initialized} = 1;
}

sub reload {
        Settings::loadByHandle($control_handle) if defined $control_handle;
        apply_ranges();
}

sub unload {
        Plugins::delHooks($hooks) if $hooks;
        Settings::removeFile($control_handle) if defined $control_handle;

        if ($override_installed) {
                no warnings 'redefine';
                *Utils::timeOut = $orig_timeOut;
                $override_installed = 0;
        }
}

1;
