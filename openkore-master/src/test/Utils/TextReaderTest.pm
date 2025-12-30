package Utils::TextReaderTest;

use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use Test::More;
use Utils::TextReader;

sub start {
my $data_dir = File::Spec->catdir($RealBin, 'data');
my $parent = File::Spec->catfile($data_dir, 'parent.txt');
my $create_if_missing = File::Spec->catfile($data_dir, 'create_if_missing.txt');
my $create_if_missing_child = File::Spec->catfile($data_dir, 'create_if_missing_child.txt');

subtest '!include support' => sub {
my $reader = Utils::TextReader->new($parent);

		is( $reader->readLine, "parent A\n" );
		is( $reader->readLine, "child\n" );
		is( $reader->readLine, "parent B\n" );
		is( $reader->readLine, "a\n" );
		is( $reader->readLine, "child\n" );
		is( $reader->readLine, "parent C\n" );
		is( $reader->readLine, undef );

		is( $reader->eof, 1 );
		done_testing();
	};

	subtest 'hide_includes=0' => sub {
my $reader = Utils::TextReader->new($parent, { hide_includes => 0 });

		is( $reader->readLine, "parent A\n" );
		is( $reader->readLine, "!include child.txt\n" );
		is( $reader->readLine, "child\n" );
		is( $reader->readLine, "parent B\n" );
		is( $reader->readLine, "!include child/a.txt\n" );
		is( $reader->readLine, "a\n" );
		is( $reader->readLine, "!include ../child.txt\n" );
		is( $reader->readLine, "child\n" );
		is( $reader->readLine, "parent C\n" );
		is( $reader->readLine, undef );

		is( $reader->eof, 1 );
		done_testing();
	};

	subtest 'process_includes=0' => sub {
my $reader = Utils::TextReader->new($parent, { process_includes => 0 });

		is( $reader->readLine, "parent A\n" );
		is( $reader->readLine, "!include child.txt\n" );
		is( $reader->readLine, "parent B\n" );
		is( $reader->readLine, "!include child/a.txt\n" );
		is( $reader->readLine, "parent C\n" );
		is( $reader->readLine, undef );

		is( $reader->eof, 1 );
		done_testing();
	};

subtest '!include_create_if_missing support' => sub {
my $reader = Utils::TextReader->new($create_if_missing);

# Make sure the referenced child doesn't exist.
unlink $create_if_missing_child;
ok( !-e $create_if_missing_child );

# Processing the file should create the referenced child.
$reader->readLine while !$reader->eof;
ok( -e $create_if_missing_child );
done_testing();
};
}

1;
