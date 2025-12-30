# Unit test for FileParsers
package FileParsersTest;
use strict;

use FindBin qw($RealBin);
use File::Spec;
use Test::More;
use FileParsers;
use Globals;
use Misc;
use File::Copy;

use constant NOT_CONFIGURED_ITEM => 'Random Item';

sub start {
	subtest 'FileParsers' => sub { SKIP: {
binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

my $data_dir = $RealBin;
my $config_dir = File::Spec->catdir($RealBin, 'data');
my $items_file = File::Spec->catfile($data_dir, 'items.txt');
my $item_slot_file = File::Spec->catfile($data_dir, 'itemslotcounttable.txt');
my $items_control_file = File::Spec->catfile($data_dir, 'items_control.txt');
my $pickupitems_file = File::Spec->catfile($data_dir, 'pickupitems.txt');
my $write_config_file = File::Spec->catfile($config_dir, 'write_config.txt');
my $write_config_out_file = File::Spec->catfile($config_dir, 'write_config.out.txt');
my $write_config_a_file = File::Spec->catfile($config_dir, 'write_config_a.txt');

		my $items = do {
			use utf8;
			{
				501 => q(Red Potion),
				512 => q(Apple),
				528 => q(Monster's Feed),
				1207 => q(Main Gauche),
				1208 => q(Main Gauche),
				2784 => q(Caixinha "Noite Feliz"),
				12080 => q(Коктейль 'Дыхание дракона'),
				12153 => q(Bowman Scroll 1),
			}
		};

		my $itemSlotCount = {qw(
			1207 3
			1208 4
		)};

		subtest 'tables' => sub {
for ($items_file) {
parseROLUT($_, \%items_lut);
is_deeply(\%items_lut, $items, $_);
}

for ($item_slot_file) {
parseROLUT($_, \%itemSlotCount_lut);
is_deeply(\%itemSlotCount_lut, $itemSlotCount, $_);
}
			done_testing();
		} or skip 'failed to load tables', 1;

		# 502 - unknown item
		my %item_names = map {$_ => itemName({nameID => $_, cards => pack('v*', (0)x4)})} 502, keys %items_lut;
		my @item_names_part = map {[map {$item_names{$_}} @$_]} List::MoreUtils::part {$_ == 1208} keys %item_names;

subtest 'items_control.txt' => sub {
parseItemsControl($items_control_file, \%items_control);

			is(items_control(NOT_CONFIGURED_ITEM)->{keep}, 9, 'all');
			is(items_control($_,$_)->{keep}, 2, $_) for @{$item_names_part[0]};
			is(items_control($_,$_)->{keep}, 22, $_) for @{$item_names_part[1]};
			done_testing();
		};

subtest 'pickupitems.txt' => sub {
parseDataFile_lc($pickupitems_file, \%pickupitems);

			is(pickupitems(NOT_CONFIGURED_ITEM), 1, 'all');
			is(pickupitems($_), 2, $_) for grep {!/Bowman Scroll 1/} @{$item_names_part[0]};
			is(pickupitems($_), -1, $_) for @{$item_names_part[1]};
			done_testing();
		};

subtest 'writeDataFileIntact' => sub {
my $config = {};
parseConfigFile($write_config_file, $config);

			my $expected = {
				parent_child_unchanged => 2,
				parent_child_changed => 2,
				block_0 => 'a',
				block_0_test => 1,
				block_1 => 'b',
				block_1_test => 2,
				leading => 'tab a',
				no_val_unchanged => undef,
				no_val_changed => undef,
				child_unchanged => 1,
				child_changed => 1,
				# TODO: Fix this? Not allowing tabs between key and value is probably a bug.
				"tab\ta" => undef,
			};
			is_deeply($config, $expected);

			$config->{parent_child_changed}++;
			$config->{block_0} = 'A';
			$config->{block_0_test}++;
			$config->{block_1} = 'B';
			$config->{block_1_test}++;
			$config->{no_val_changed}++;
			$config->{child_changed}++;

File::Copy::cp $write_config_file => $write_config_out_file;
writeDataFileIntact($write_config_out_file, $config);

my $reader = Utils::TextReader->new( $write_config_out_file, { hide_includes => 0 } );
			is( $reader->readLine, "parent_child_unchanged 2\n" );
			is( $reader->readLine, "parent_child_changed 3\n" );
			is( $reader->readLine, "block A {\n" );
			is( $reader->readLine, "\ttest 2\n" );
			is( $reader->readLine, "}\n" );
is( $reader->readLine, "!include write_config_a.txt\n" );
			is( $reader->readLine, "parent_child_unchanged 2\n" );
			is( $reader->readLine, "parent_child_changed 2\n" );
			is( $reader->readLine, "block b {\n" );
			is( $reader->readLine, "  test 2\n" );
			is( $reader->readLine, "}\n" );
			is( $reader->readLine, "child_unchanged 1\n" );
			is( $reader->readLine, "child_changed 1\n" );
			is( $reader->readLine, "leading tab a\n" );
			is( $reader->readLine, "leading tab a\n" );
			is( $reader->readLine, "tab\ta\n" );
			is( $reader->readLine, "no_val_unchanged\n" );
			is( $reader->readLine, "no_val_changed 1\n" );
			is( $reader->readLine, "child_changed 2\n" );
			is( $reader->readLine, "parent_child_changed 3\n" );
			is( $reader->eof, 1 );

unlink $write_config_out_file;
			done_testing();
		};
	}
	done_testing();
	}
	
}

1;
