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

	# Ativa checksum quando em primeiro pacote e IDs conhecidos
	if ( $counter == 0 ) {
		if ( $messageID eq '0B1C' ) {
			warning "Checksum enabled on first.\n";
			$enabled = 1;
		}

		if ( $messageID eq $messageSender->{packet_lut}{map_login} ) {
			warning "Checksum enabled on map login.\n";
			$enabled = 1;
			$messageSender->sendPing();
		}
	}

	# Apenas no map e com checksum habilitado, anexa o byte do servidor
	if ( $::net->getState() >= 4 ) {
		if ( $enabled ) {
			$$msg .= pack( "C", calc_checksum( $$msg ) );
		}
	}

	# Incrementa sempre (wrap 12 bits), conforme fluxo oficial
	$counter = ( $counter + 1 ) & 0xFFF;
}

1;