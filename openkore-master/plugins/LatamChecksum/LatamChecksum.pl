package LatamChecksum;

use strict;
use Plugins;
use Globals;
use Misc;
use AI;
use utf8;
use Network::Send ();
use Log           qw(message warning error debug);
use IO::Socket::INET;
use Time::HiRes qw(usleep);

my $counter = 0;
my $enabled = 0;

# TCP checksum server configuration
my $TIMEOUT = 1000;

Plugins::register( "LatamChecksum", "Latam checksum", \&unload );

my $hooks = Plugins::addHooks(
	['start3',                \&checkServer, undef],
);
my $base_hooks;

sub checkServer {
	my $master = $masterServers{ $config{master} };
	if ( grep { $master->{serverType} eq $_ } qw(ROla) ) {
		$base_hooks = Plugins::addHooks(
			[ 'serverDisconnect/fail',    \&serverDisconnect, undef ],
			[ 'serverDisconnect/success', \&serverDisconnect, undef ],
			[ 'Network::serverSend/pre',  \&serverSendPre,    undef ]
		);
	}
}

sub unload {
	Plugins::delHooks( $base_hooks );
	Plugins::delHooks( $hooks ) if ( $hooks );
}

sub calc_checksum {
	my ( $data ) = @_;
	
	# Create socket connection
	my $socket = IO::Socket::INET->new(
		PeerHost => $config{ip_socket},
		PeerPort => $config{port_socket},
		Proto    => 'tcp',
		Timeout  => $TIMEOUT
	);
	
	unless ($socket) {
		error "LatamChecksum: Failed to connect to checksum server!\n";
		return 0; # Return 0 as fallback checksum
	}

	# Send data to server with current counter value (12-bit)
	my $packet = $data . pack("N", ($counter & 0xFFF));
	
	unless (print $socket $packet) {
		error "LatamChecksum: Failed to send data to checksum server - $!\n";
		$socket->close();
		return 0;
	}
	
	# Read checksum response
	my $response;
	my $bytes_read = sysread($socket, $response, 1); # Expecting 1 byte checksum
	$socket->close();
	
	unless (defined $bytes_read && $bytes_read == 1) {
		error "LatamChecksum: Failed to read checksum from server\n";
		return 0;
	}
	
	my $checksum = unpack("C", $response);
	
	return $checksum;
}

sub serverDisconnect {
	warning "Checksum disabled on server disconnect.\n";
	$enabled = 0;
	$counter = 0;
}

sub serverSendPre {
	my ( $self, $args ) = @_;
	my $msg       = $args->{msg};
	my $messageID = uc( unpack( "H2", substr( $$msg, 1, 1 ) ) ) . uc( unpack( "H2", substr( $$msg, 0, 1 ) ) );

	return if ( ref($::net) eq 'Network::XKore' );

	if ( $::net->getState() >= 4 ) {
		if ( $counter == 0 ) {
			if ( $messageID eq $messageSender->{packet_lut}{map_login} ) {
				warning "[LatamChecksum] Checksum enabled on map login.\n";
				$enabled = 1;
				$messageSender->sendPing();
			} else {
				warning "[LatamChecksum] Generating new seed...\n";
				$enabled = 1;
				$$msg .= pack( "C", calc_checksum( $$msg ) );
			}
		} else {
			$$msg .= pack( "C", calc_checksum( $$msg ) );
		}
		$counter = ($counter + 1) & 0xFFF;
		my $packet = unpack("H*", $$msg);
		debug("[LatamChecksum] Packet: $packet\n");
	}
}

1;