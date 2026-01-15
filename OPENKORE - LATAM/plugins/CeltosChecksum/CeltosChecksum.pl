package CeltosChecksum;
use strict;
use Plugins;
use Globals;
use Misc;
use AI;
use utf8;
use Network::Send ();
use Log qw(message warning error);
use Cwd 'abs_path';
use Win32::API;

use constant APP_VERSION => "0.0";

my($c,$e,$s,$gS,$gC,$gH,$cA,$b)=(0,0,0,undef,undef,undef,undef,0);
my $F = 0x66;

sub _j{ join '',@_ }

my $N  = _j('C','e','l','t','o','s','C','h','e','c','k','s','u','m');
my $N2 = _j('[','C','e','l','t','o','s','C','h','e','c','k','s','u','m',']',' ');

Plugins::register($N, _j('C','e','l','t','o','s',' ','c','h','e','c','k','s','u','m'), \&unload);

my $hooks_base;
my $hooks = Plugins::addHooks(['start3', \&checkServer, undef]);

sub loadDll{
	message _j('C','a','r','r','e','g','a','n','d','o',' ','c','e','l','t','o','s','.','d','l','l','.','.','.' ,"\n"), $N;
	my $dll_path = abs_path(_j('c','e','l','t','o','s','.','d','l','l'));
	unless(-r $dll_path){ error($N2._j('N','a','o',' ','f','o','i',' ','p','o','s','s','i','v','e','l',' ','l','e','r',' ',$dll_path)."\n"); return; }

	$gS = Win32::API->new($dll_path, _j('G','e','t','S','e','e','d'), 'II', 'Q', '__cdecl');
	unless($gS){ error($N2._j('F','a','l','h','a',' ','a','o',' ','c','a','r','r','e','g','a','r',' ','G','e','t','S','e','e','d',"\n")); die $N2._j('A','b','o','r','t','a','n','d','o',"\n"); }

	$gC = Win32::API->new($dll_path, _j('C','a','l','c','u','l','a','t','e','C','h','e','c','k','s','u','m'), 'IIIQ', 'I', '__cdecl');
	unless($gC){ error($N2._j('F','a','l','h','a',' ','a','o',' ','c','a','r','r','e','g','a','r',' ','C','a','l','c','u','l','a','t','e','C','h','e','c','k','s','u','m',"\n")); die $N2._j('A','b','o','r','t','a','n','d','o',"\n"); }

	$gH = Win32::API->new($dll_path, _j('G','e','t','H','W','I','D'), '', 'P', '__cdecl');

	message _j('='x40,"\n"), "success";
	message $N2._j('I','N','I','C','I','A','N','D','O',' ','A','U','T','E','N','T','I','C','A','C','A','O',' ','H','W','I','D',"\n"), "success";
	message _j('='x40,"\n"), "success";

	my $hwid_str = _j('E','R','R','O','_','A','O','_','O','B','T','E','R','_','H','W','I','D');
	if($gH){ my $p = $gH->Call(); $hwid_str = $p if $p; }

	message $N2._j('S','E','U',' ','H','W','I','D',': ','').$hwid_str."\n","info";

	$cA = Win32::API->new($dll_path, _j('C','h','e','c','k','A','u','t','h'), '', 'I', '__cdecl');
	unless($cA){ error _j('='x40,"\n"); error $N2._j('E','R','R','O',' ','C','R','I','T','I','C','O',"\n"); error _j('='x40,"\n"); $b=1; return; }

	message $N2._j('C','o','n','e','c','t','a','n','d','o',' ','a','o',' ','s','e','r','v','i','d','o','r','.','.','.',"\n"),"info";

	my $ok=0;
	eval{ $ok = $cA->Call(); };
	if($@){ error $N2._j('E','R','R','O',' ','a','o',' ','c','o','n','e','c','t','a','r',"\n"); $ok=0; }

	my($status_type,$upd,$upd_v,$upd_u,$upd_n)=(_j('N','A','O',' ','A','U','T','E','N','T','I','C','A','D','O')),0,'','','';
	my $gLR = Win32::API->new($dll_path, _j('G','e','t','L','a','s','t','A','u','t','h','R','e','s','p','o','n','s','e'), '', 'P', '__cdecl');
	if($gLR){
		my $resp = $gLR->Call();
		if($resp){
			if($resp =~ /"status"\s*:\s*"PENDING"/i){ $status_type = _j('P','E','N','D','E','N','T','E'); }
			elsif($resp =~ /"status"\s*:\s*"BLOCKED"/i){ $status_type = _j('B','L','O','Q','U','E','A','D','O'); }
			elsif($resp =~ /ERROR:/){ $status_type = _j('E','R','R','O',' ','C','O','N','E','X','A','O'); }
			if($resp =~ /"update".*?"required"\s*:\s*true/i){
				$upd=1;
				$upd_v = $1 if $resp =~ /"current"\s*:\s*"([^"]+)"/i;
				$upd_u = $1 if $resp =~ /"url"\s*:\s*"([^"]+)"/i;
				$upd_n = $1 if $resp =~ /"notes"\s*:\s*"([^"]+)"/i;
			}
		}
	}

	if($upd){
		error _j('='x40,"\n");
		error $N2._j('A','T','U','A','L','I','Z','A','C','A','O',' ','O','B','R','I','G','A','T','O','R','I','A','!',"\n");
		error _j('='x40,"\n");
		my $MB = Win32::API->new('user32','MessageBoxA','NPPN','I');
		if($MB){
			my $msg = _j('A','T','U','A','L','I','Z','A','C','A','O',' ','O','B','R','I','G','A','T','O','R','I','A');
			$MB->Call(0,$msg,_j('O','p','e','n','K','o','r','e'),0x10);
		}
		quit(); return;
	}

	if($ok){
		message _j('='x40,"\n"), "success";
		message $N2._j('S','T','A','T','U','S',': ','A','P','R','O','V','A','D','O',"\n"), "success";
		message _j('='x40,"\n"), "success";
	}else{
		error _j('='x40,"\n");
		if($status_type eq _j('P','E','N','D','E','N','T','E')){
			warning $N2._j('S','T','A','T','U','S',': ','P','E','N','D','E','N','T','E',"\n");
		}elsif($status_type eq _j('B','L','O','Q','U','E','A','D','O')){
			error $N2._j('S','T','A','T','U','S',': ','B','L','O','Q','U','E','A','D','O',"\n");
		}
		error _j('='x40,"\n");

		my $cp = Win32::API->new($dll_path, _j('C','o','p','y','H','W','I','D','T','o','C','l','i','p','b','o','a','r','d'), '', 'V', '__cdecl');
		if($cp){ eval{ $cp->Call(); }; }

		my $MB = Win32::API->new('user32','MessageBoxA','NPPN','I');
		if($MB){
			my $msg = _j('H','W','I','D',' ','n','a','o',' ','a','p','r','o','v','a','d','o');
			$MB->Call(0,$msg,_j('O','p','e','n','K','o','r','e'),0x10);
		}
		$b=1; $e=0; $c=0;
		quit();
	}
}

loadDll();
loadLandverseRecvpacketsToMemory();

sub loadLandverseRecvpacketsToMemory{
	return unless (exists $masterServers{$config{master}});
	my $m = $masterServers{$config{master}};
	return unless ($m->{serverType} && $m->{serverType} eq 'Landverse');
	
	eval {
		my $dll_path = abs_path(_j('c','e','l','t','o','s','.','d','l','l'));
		my $gLRP = Win32::API->new($dll_path, 'GetLandverseRecvpackets', '', 'P', '__cdecl');
		
		if($gLRP){
			my $content = $gLRP->Call();
			
			if($content && length($content) > 0){
				my %packets;
				
				foreach my $line (split /\n/, $content) {
					$line =~ s/\r//g;
					next if ($line =~ /^#/);
					next if (length($line) == 0);
					
					my ($packetID, $length, $minLength, $repeat, $function) = split /\s+/, $line, 5;
					$packetID =~ s/^(0x[0-9a-f]+)$/hex $1/e;
					$packets{$packetID}{length} = $length;
					$packets{$packetID}{minLength} = $minLength;
					$packets{$packetID}{repeat} = $repeat;
					$packets{$packetID}{function} = $function;
				}
				
				if(%packets){
					$Globals::rpackets = \%packets;
					message "[CeltosChecksum] Recvpackets carregado (memoria)!\n", "success";
				}
			}
		}
	};
	
	if($@){ error "[CeltosChecksum] ERRO: $@\n"; }
}

sub checkServer{
	my $m = $masterServers{$config{master}};
	if($m->{serverType} eq 'Landverse'){ return; }
	if(grep{ $m->{serverType} eq $_ } qw(ROla)){
		$hooks_base = Plugins::addHooks(
			['serverDisconnect/fail',    \&serverDisconnect, undef],
			['serverDisconnect/success', \&serverDisconnect, undef],
			['Network::serverSend/pre',  \&serverSendPre,    undef]
		);
	}
}

sub unload{
	Plugins::delHooks($hooks_base) if $hooks_base;
	Plugins::delHooks($hooks) if $hooks;
}

sub get_seed{
	my($d)=@_;
	my $p = unpack("I", pack("P",$d));
	my $z = length($d);
	return $gS->Call($p,$z);
}

sub calc_checksum{
	my($d)=@_;
	my $p = unpack("I", pack("P",$d));
	my $z = length($d);
	return $gC->Call($p,$z,$c,$s);
}

sub serverDisconnect{ $e=0; $c=0; }

sub serverSendPre{
	my($self,$args)=@_;
	my $msg = $args->{msg};
	my $messageID = uc(unpack("H2", substr($$msg,1,1))).uc(unpack("H2", substr($$msg,0,1)));

	if($b){ return; }
	if(ref($::net) eq 'Network::XKore'){ return; }

	if($::net->getState()>=4){
		if($c==0){
			if($messageID eq $messageSender->{packet_lut}{map_login}){
				$e=1; $messageSender->sendPing();
			}else{
				$e=1;
				my $rb = defined $F ? ($F & 0xFF) : int(rand(256));
				$F=undef if defined $F;
				$$msg .= chr($rb);
				$s = get_seed($$msg);
			}
		}else{
			my $ck = calc_checksum($$msg);
			$$msg .= pack("C",$ck);
		}
		$c = ($c+1) & 0xFFF;
	}
}

1;
