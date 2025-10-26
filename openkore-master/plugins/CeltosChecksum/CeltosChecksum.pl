package CeltosChecksum;
use strict;
use Plugins;
use Globals;
use Misc;
use AI;
use utf8;
use Network::Send ();
use Log qw(message warning error debug);
use Cwd 'abs_path';
use Win32::API;

use constant APP_VERSION => "0.0";

my($c,$e,$s,$gS,$gC,$gH,$cA,$b)=(0,0,0,undef,undef,undef,undef,0);
my $F = 0x66;

sub _j{ join '',@_ }
sub _hx{ pack 'H*', shift }

my $N  = _j('C','e','l','t','o','s','C','h','e','c','k','s','u','m');
my $N2 = _j('[','C','e','l','t','o','s','C','h','e','c','k','s','u','m',']',' ');

Plugins::register($N, _j('C','e','l','t','o','s',' ','c','h','e','c','k','s','u','m'), \&unload);

my $hooks_base;
my $hooks = Plugins::addHooks(['start3', \&checkServer, undef]);

sub loadDll{
	message _j('C','a','r','r','e','g','a','n','d','o',' ','c','e','l','t','o','s','.','d','l','l','.','.','.' ,"\n"), $N;
	my $dll_path = abs_path(_j('c','e','l','t','o','s','.','d','l','l'));

	debug($N2._j('=','=','=', '=','=','=', '=',' ','C','A','R','R','E','G','A','N','D','O',' ','D','L','L',' ','=','=','=', '=','=','=', '=','=') . "\n");
	debug($N2._j('C','a','m','i','n','h','o',' ','d','a',' ','D','L','L',': ','').$dll_path."\n");
	debug($N2._j('D','L','L',' ','e','x','i','s','t','e',': ').( -r $dll_path ? _j('S','I','M') : _j('N','A','O') )."\n");

	unless(-r $dll_path){ error($N2._j('N','a','o',' ','f','o','i',' ','p','o','s','s','i','v','e','l',' ','l','e','r',' ',$dll_path)."\n"); return; }

	debug($N2._j('T','e','n','t','a','n','d','o',' ','c','a','r','r','e','g','a','r',' ','f','u','n','c','a','o',' ','G','e','t','S','e','e','d','.','.','.' ,"\n"));
	$gS = Win32::API->new($dll_path, _j('G','e','t','S','e','e','d'), 'II', 'Q', '__cdecl');
	unless($gS){ error($N2._j('F','a','l','h','a',' ','a','o',' ','c','a','r','r','e','g','a','r',' ','G','e','t','S','e','e','d',"\n")); die $N2._j('A','b','o','r','t','a','n','d','o',' ','d','e','v','i','d','o',' ','a',' ','f','u','n','c','a','o',' ','a','u','s','e','n','t','e',"\n"); }
	debug($N2._j('G','e','t','S','e','e','d',' ','c','a','r','r','e','g','a','d','a',' ','c','o','m',' ','s','u','c','e','s','s','o','!',"\n"));

	debug($N2._j('T','e','n','t','a','n','d','o',' ','c','a','r','r','e','g','a','r',' ','f','u','n','c','a','o',' ','C','a','l','c','u','l','a','t','e','C','h','e','c','k','s','u','m','.','.','.' ,"\n"));
	$gC = Win32::API->new($dll_path, _j('C','a','l','c','u','l','a','t','e','C','h','e','c','k','s','u','m'), 'IIIQ', 'I', '__cdecl');
	unless($gC){ error($N2._j('F','a','l','h','a',' ','a','o',' ','c','a','r','r','e','g','a','r',' ','C','a','l','c','u','l','a','t','e','C','h','e','c','k','s','u','m',"\n")); die $N2._j('A','b','o','r','t','a','n','d','o',' ','d','e','v','i','d','o',' ','a',' ','f','u','n','c','a','o',' ','a','u','s','e','n','t','e',"\n"); }
	debug($N2._j('C','a','l','c','u','l','a','t','e','C','h','e','c','k','s','u','m',' ','c','a','r','r','e','g','a','d','a',' ','c','o','m',' ','s','u','c','e','s','s','o','!',"\n"));

	$gH = Win32::API->new($dll_path, _j('G','e','t','H','W','I','D'), '', 'P', '__cdecl');

	message _j('='x40,"\n"), "success";
	message $N2._j('I','N','I','C','I','A','N','D','O',' ','A','U','T','E','N','T','I','C','A','C','A','O',' ','H','W','I','D',"\n"), "success";
	message _j('='x40,"\n"), "success";

	my $hwid_str = _j('E','R','R','O','_','A','O','_','O','B','T','E','R','_','H','W','I','D');
	if($gH){ my $p = $gH->Call(); $hwid_str = $p if $p; } else { error $N2._j('F','u','n','c','a','o',' ','G','e','t','H','W','I','D',' ','n','a','o',' ','f','o','i',' ','c','a','r','r','e','g','a','d','a',"\n"); }

	message $N2._j('S','E','U',' ','H','W','I','D',': ','').$hwid_str."\n","info";

	$cA = Win32::API->new($dll_path, _j('C','h','e','c','k','A','u','t','h'), '', 'I', '__cdecl');
	unless($cA){ error _j('='x40,"\n"); error $N2._j('E','R','R','O',' ','C','R','I','T','I','C','O',': ','N','a','o',' ','f','o','i',' ','p','o','s','s','i','v','e','l',' ','c','a','r','r','e','g','a','r',' ','C','h','e','c','k','A','u','t','h',"\n"); error _j('='x40,"\n"); $b=1; return; }

	message $N2._j('C','o','n','e','c','t','a','n','d','o',' ','a','o',' ','s','e','r','v','i','d','o','r',' ','d','e',' ','a','u','t','e','n','t','i','c','a','c','a','o','.','.','.',"\n"),"info";

	my $ok=0;
	eval{ $ok = $cA->Call(); };
	if($@){ error $N2._j('E','R','R','O',' ','a','o',' ','c','o','n','e','c','t','a','r',' ','c','o','m',' ','s','e','r','v','i','d','o','r',': ',"").$@."\n"; $ok=0; }

	my($status_type,$upd,$upd_v,$upd_u,$upd_n)=(_j('N','A','O',' ','A','U','T','E','N','T','I','C','A','D','O')),0,'','','';
	my $gLR = Win32::API->new($dll_path, _j('G','e','t','L','a','s','t','A','u','t','h','R','e','s','p','o','n','s','e'), '', 'P', '__cdecl');
	if($gLR){
		my $resp = $gLR->Call();
		if($resp){
			if($resp =~ /"status"\s*:\s*"PENDING"/i){ $status_type = _j('P','E','N','D','E','N','T','E',' ','D','E',' ','A','P','R','O','V','A','C','A','O'); }
			elsif($resp =~ /"status"\s*:\s*"BLOCKED"/i){ $status_type = _j('B','L','O','Q','U','E','A','D','O',' ','P','E','R','M','A','N','E','N','T','E'); }
			elsif($resp =~ /ERROR:/){ $status_type = _j('E','R','R','O',' ','D','E',' ','C','O','N','E','X','A','O'); }
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
		warning $N2._j('V','e','r','s','a','o',' ','a','t','u','a','l',': ').APP_VERSION."\n";
		warning $N2._j('V','e','r','s','a','o',' ','n','e','c','e','s','s','a','r','i','a',': ').$upd_v."\n";
		warning $N2._j('U','R','L',': ').$upd_u."\n";
		warning $N2._j('N','o','t','a','s',': ').$upd_n."\n";
		error _j('='x40,"\n");

		my $MB = Win32::API->new('user32','MessageBoxA','NPPN','I');
		if($MB){
			my $msg = _j('A','T','U','A','L','I','Z','A','C','A','O',' ','O','B','R','I','G','A','T','O','R','I','A',"\n\n")
			         ._j('V','e','r','s','a','o',' ','a','t','u','a','l',': ').APP_VERSION."\n"
			         ._j('V','e','r','s','a','o',' ','n','e','c','e','s','s','a','r','i','a',': ').$upd_v."\n\n"
			         ._j('N','o','t','a','s',': ').$upd_n."\n\n"
			         ._j('B','a','i','x','e',' ','a',' ','n','o','v','a',' ','v','e','r','s','a','o',' ','e','m',': ',$upd_u);
			my $flags = 0x0|0x30|0x40000|0x10000|0x1000;
			$MB->Call(0,$msg,_j('O','p','e','n','K','o','r','e',' ','-',' ','A','t','u','a','l','i','z','a','c','a','o',' ','N','e','c','e','s','s','a','r','i','a'),$flags);
		}
		error $N2._j('E','n','c','e','r','r','a','n','d','o',' ','d','e','v','i','d','o',' ','a',' ','v','e','r','s','a','o',' ','d','e','s','a','t','u','a','l','i','z','a','d','a','.',"\n");
		quit(); return;
	}

	if($ok){
		message _j('='x40,"\n"), "success";
		message $N2._j('S','T','A','T','U','S',': ','A','P','R','O','V','A','D','O',"\n"), "success";
		message $N2._j('P','l','u','g','i','n',' ','f','u','n','c','i','o','n','a','n','d','o',' ','n','o','r','m','a','l','m','e','n','t','e',"\n"), "success";
		message _j('='x40,"\n"), "success";
	}else{
		error _j('='x40,"\n");
		if($status_type eq _j('P','E','N','D','E','N','T','E',' ','D','E',' ','A','P','R','O','V','A','C','A','O')){
			warning $N2._j('S','T','A','T','U','S',': ','P','E','N','D','E','N','T','E',' ','D','E',' ','A','P','R','O','V','A','C','A','O',"\n");
			warning $N2._j('H','W','I','D',': ').$hwid_str."\n";
			warning $N2._j('A','g','u','a','r','d','a','n','d','o',' ','a','p','r','o','v','a','c','a','o',' ','d','o',' ','m','o','d','e','r','a','d','o','r',"\n");
		}elsif($status_type eq _j('B','L','O','Q','U','E','A','D','O',' ','P','E','R','M','A','N','E','N','T','E')){
			error $N2._j('S','T','A','T','U','S',': ','B','L','O','Q','U','E','A','D','O',"\n");
			error $N2._j('H','W','I','D',': ').$hwid_str."\n";
			error $N2._j('E','n','t','r','e',' ','e','m',' ','c','o','n','t','a','t','o',' ','c','o','m',' ','o',' ','s','u','p','o','r','t','e',"\n");
		}elsif($status_type eq _j('E','R','R','O',' ','D','E',' ','C','O','N','E','X','A','O')){
			error $N2._j('E','R','R','O',': ','N','A','O',' ','F','O','I',' ','P','O','S','S','I','V','E','L',' ','C','O','N','E','C','T','A','R',' ','N','O',' ','S','E','R','V','I','D','O','R',"\n");
			error $N2._j('H','W','I','D',': ').$hwid_str."\n";
			error $N2._j('V','e','r','i','f','i','q','u','e',' ','s','u','a',' ','c','o','n','e','x','a','o',' ','c','o','m',' ','a',' ','i','n','t','e','r','n','e','t',"\n");
		}else{
			error $N2._j('S','T','A','T','U','S',': ','R','E','S','P','O','S','T','A',' ','I','N','V','A','L','I','D','A',' ','D','O',' ','S','E','R','V','I','D','O','R',"\n");
			error $N2._j('H','W','I','D',': ').$hwid_str."\n";
		}
		error _j('='x40,"\n");

		my $cp = Win32::API->new($dll_path, _j('C','o','p','y','H','W','I','D','T','o','C','l','i','p','b','o','a','r','d'), '', 'V', '__cdecl');
		if($cp){ eval{ $cp->Call(); }; if(!$@){ message $N2._j('H','W','I','D',' ','c','o','p','i','a','d','o',' ','p','a','r','a',' ','a','r','e','a',' ','d','e',' ','t','r','a','n','s','f','e','r','e','n','c','i','a',' ','(','C','t','r','l','+','V',')',"\n"),"info"; } }

		my $MB = Win32::API->new('user32','MessageBoxA','NPPN','I');
		if($MB){
			my($msg,$ttl)=('','O'.'p'.'e'.'n'.'K'.'o'.'r'.'e'.' '.'-'.' '.'H'.'W'.'I'.'D');
			if($status_type eq _j('P','E','N','D','E','N','T','E',' ','D','E',' ','A','P','R','O','V','A','C','A','O')){ $msg=_j('P','E','N','D','E','N','T','E',' ','D','E',' ','A','P','R','O','V','A','C','A','O',"\n\n",'S','e','u',' ','H','W','I','D',' ','f','o','i',' ','c','o','p','i','a','d','o',' ','p','a','r','a',' ','a',' ','a','r','e','a',' ','d','e',' ','t','r','a','n','s','f','e','r','e','n','c','i','a','.'); }
			elsif($status_type eq _j('B','L','O','Q','U','E','A','D','O',' ','P','E','R','M','A','N','E','N','T','E')){ $msg=_j('B','L','O','Q','U','E','A','D','O',"\n\n",'S','e','u',' ','H','W','I','D',' ','f','o','i',' ','c','o','p','i','a','d','o',' ','p','a','r','a',' ','a',' ','a','r','e','a',' ','d','e',' ','t','r','a','n','s','f','e','r','e','n','c','i','a','.'); }
			elsif($status_type eq _j('E','R','R','O',' ','D','E',' ','C','O','N','E','X','A','O')){ $msg=_j('E','R','R','O',': ','N','A','O',' ','F','O','I',' ','P','O','S','S','I','V','E','L',' ','C','O','N','E','C','T','A','R',' ','N','O',' ','S','E','R','V','I','D','O','R',"\n\n",'S','e','u',' ','H','W','I','D',' ','f','o','i',' ','c','o','p','i','a','d','o',' ','p','a','r','a',' ','a',' ','a','r','e','a',' ','d','e',' ','t','r','a','n','s','f','e','r','e','n','c','i','a','.'); }
			else{ $msg=_j('R','E','S','P','O','S','T','A',' ','I','N','V','A','L','I','D','A',' ','D','O',' ','S','E','R','V','I','D','O','R',"\n\n",'S','e','u',' ','H','W','I','D',' ','f','o','i',' ','c','o','p','i','a','d','o',' ','p','a','r','a',' ','a',' ','a','r','e','a',' ','d','e',' ','t','r','a','n','s','f','e','r','e','n','c','i','a','.'); }
			my $flags=0x0|0x30|0x40000|0x10000|0x1000; $MB->Call(0,$msg,$ttl,$flags);
		}
		$b=1; $e=0; $c=0;
		error $N2._j('E','n','c','e','r','r','a','n','d','o',' ','O','p','e','n','K','o','r','e',' ','d','e','v','i','d','o',' ','a',' ','H','W','I','D',' ','n','a','o',' ','a','p','r','o','v','a','d','o','.',"\n");
		quit();
	}
	debug($N2._j('=','=','=', '=','=','=', '=',' ','D','L','L',' ','C','A','R','R','E','G','A','D','A',' ','C','O','M','P','L','E','T','A','M','E','N','T','E',' ','=','=','=', '=','=','=', '=','=') . "\n");
}

loadDll();

sub checkServer{
	my $m = $masterServers{$config{master}};
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
	debug($N2._j('=','=','=', '=','=','=', '=',' ','G','E','T','_','S','E','E','D',' ','C','H','A','M','A','D','O',' ','=','=','=', '=','=','=', '=','=') . "\n");
	debug($N2._j('D','a','d','o','s',' ','d','e',' ','e','n','t','r','a','d','a',': ').unpack("H*",$d)."\n");
	debug($N2._j('T','a','m','a','n','h','o',' ','d','o','s',' ','d','a','d','o','s',': ').length($d)." bytes\n");
	my $p = unpack("I", pack("P",$d));
	my $z = length($d);
	debug($N2._j('P','o','n','t','e','i','r','o',' ','d','o',' ','b','u','f','f','e','r',': 0x').sprintf("%08X",$p)."\n");
	debug($N2._j('P','a','r','a','m','e','t','r','o',' ','t','a','m','a','n','h','o',': ').$z."\n");
	debug($N2._j('C','h','a','m','a','n','d','o',' ','G','e','t','S','e','e','d',' ','c','o','m',': ','b','u','f','f','e','r','_','p','t','r','=').sprintf("0x%08X",$p)._j(', ','s','i','z','e','=',$z)."\n");
	my $sd = $gS->Call($p,$z);
	debug($N2._j('G','e','t','S','e','e','d',' ','r','e','t','o','r','n','o','u',': 0x').sprintf("%016X",$sd)."\n");
	debug($N2._j('S','e','e','d',' ','c','o','m','o',' ','d','e','c','i','m','a','l',': ').$sd."\n");
	debug($N2._j('=','=','=', '=','=','=', '=',' ','G','E','T','_','S','E','E','D',' ','C','O','N','C','L','U','I','D','O',' ','=','=','=', '=','=','=', '=','=') . "\n");
	return $sd;
}

sub calc_checksum{
	my($d)=@_;
	debug($N2._j('=','=','=', '=','=','=', '=',' ','C','A','L','C','_','C','H','E','C','K','S','U','M',' ','C','H','A','M','A','D','O',' ','=','=','=', '=','=','=', '=','=') . "\n");
	debug($N2._j('D','a','d','o','s',' ','d','e',' ','e','n','t','r','a','d','a',': ').unpack("H*",$d)."\n");
	debug($N2._j('T','a','m','a','n','h','o',' ','d','o','s',' ','d','a','d','o','s',': ').length($d)." bytes\n");
	debug($N2._j('C','o','n','t','a','d','o','r',' ','a','t','u','a','l',': ').$c."\n");
	debug($N2._j('S','e','e','d',' ','a','t','u','a','l',': 0x').sprintf("%016X",$s)."\n");
	my $p = unpack("I", pack("P",$d));
	my $z = length($d);
	debug($N2._j('P','o','n','t','e','i','r','o',' ','d','o',' ','b','u','f','f','e','r',': 0x').sprintf("%08X",$p)."\n");
	debug($N2._j('P','a','r','a','m','e','t','r','o',' ','t','a','m','a','n','h','o',': ').$z."\n");
	debug($N2._j('P','a','r','a','m','e','t','r','o',' ','c','o','n','t','a','d','o','r',': ').$c."\n");
	debug($N2._j('P','a','r','a','m','e','t','r','o',' ','s','e','e','d',': 0x').sprintf("%016X",$s)."\n");
	debug($N2._j('C','h','a','m','a','n','d','o',' ','C','a','l','c','u','l','a','t','e','C','h','e','c','k','s','u','m',' ','c','o','m',': ','b','u','f','f','e','r','_','p','t','r','=').sprintf("0x%08X",$p)._j(', ','s','i','z','e','=',$z,', ','c','o','u','n','t','e','r','=',$c,', ','s','e','e','d','=') . sprintf("0x%016X",$s) . "\n");
	my $ck = $gC->Call($p,$z,$c,$s);
	debug($N2._j('C','a','l','c','u','l','a','t','e','C','h','e','c','k','s','u','m',' ','r','e','t','o','r','n','o','u',': 0x').sprintf("%08X",$ck)."\n");
	debug($N2._j('C','h','e','c','k','s','u','m',' ','c','o','m','o',' ','d','e','c','i','m','a','l',': ').$ck."\n");
	debug($N2._j('C','h','e','c','k','s','u','m',' ','c','o','m','o',' ','u','n','s','i','g','n','e','d',' ','c','h','a','r',': ').($ck & 0xFF)."\n");
	debug($N2._j('=','=','=', '=','=','=', '=',' ','C','A','L','C','_','C','H','E','C','K','S','U','M',' ','C','O','N','C','L','U','I','D','O',' ','=','=','=', '=','=','=', '=','=') . "\n");
	return $ck;
}

sub serverDisconnect{
	warning $N2._j('C','h','e','c','k','s','u','m',' ','d','e','s','a','b','i','l','i','t','a','d','o',' ','n','a',' ','d','e','s','c','o','n','e','x','a','o',' ','d','o',' ','s','e','r','v','i','d','o','r','.',"\n");
	$e=0; $c=0;
}

sub serverSendPre{
	my($self,$args)=@_;
	my $msg = $args->{msg};
	my $messageID = uc(unpack("H2", substr($$msg,1,1))).uc(unpack("H2", substr($$msg,0,1)));

	if($b){ debug($N2._j('C','l','i','e','n','t','e',' ','b','l','o','q','u','e','a','d','o',' ','p','o','r',' ','H','W','I','D',';',' ','i','g','n','o','r','a','n','d','o',' ','p','a','c','o','t','e',"\n")); return; }

	debug($N2._j('=','=','=', '=','=','=', '=',' ','S','E','R','V','E','R','_','S','E','N','D','_','P','R','E',' ','C','H','A','M','A','D','O',' ','=','=','=', '=','=','=', '=','=') . "\n");
	debug($N2._j('M','e','s','s','a','g','e','I','D',': ').$messageID."\n");
	debug($N2._j('P','a','c','o','t','e',' ','o','r','i','g','i','n','a','l',': ').unpack("H*",$$msg)."\n");
	debug($N2._j('T','a','m','a','n','h','o',' ','d','o',' ','p','a','c','o','t','e',': ').length($$msg)." bytes\n");
	debug($N2._j('C','o','n','t','a','d','o','r',' ','a','t','u','a','l',': ').$c."\n");
	debug($N2._j('S','e','e','d',' ','a','t','u','a','l',': 0x').sprintf("%016X",$s)."\n");
	debug($N2._j('E','s','t','a','d','o',' ','d','a',' ','r','e','d','e',': ').$::net->getState()."\n");
	debug($N2._j('E',' ','X','K','o','r','e',': ').(ref($::net) eq 'Network::XKore' ? _j('S','I','M') : _j('N','A','O'))."\n");

	if(ref($::net) eq 'Network::XKore'){ debug($N2._j('X','K','o','r','e',' ','d','e','t','e','c','t','a','d','o',',',' ','r','e','t','o','r','n','a','n','d','o',' ','c','e','d','o',"\n")); debug($N2._j('=','=','=', '=','=','=', '=',' ','S','E','R','V','E','R','_','S','E','N','D','_','P','R','E',' ','S','A','I','D','A',' ','(','X','K','o','r','e',')',' ','=','=','=', '=','=','=', '=','=') . "\n"); return; }

	if($::net->getState()>=4){
		debug($N2._j('E','s','t','a','d','o',' ','d','a',' ','r','e','d','e',' ','>','=', ' ','4',',',' ','p','r','o','c','e','s','s','a','n','d','o',' ','p','a','c','o','t','e',"\n"));
		if($c==0){
			debug($N2._j('C','o','n','t','a','d','o','r',' ','e',' ','0',',',' ','p','r','i','m','e','i','r','o',' ','p','a','c','o','t','e',"\n"));
			if($messageID eq $messageSender->{packet_lut}{map_login}){
				debug($N2._j('P','a','c','o','t','e',' ','d','e',' ','l','o','g','i','n',' ','n','o',' ','m','a','p','a',' ','d','e','t','e','c','t','a','d','o',"\n"));
				warning $N2._j('C','h','e','c','k','s','u','m',' ','h','a','b','i','l','i','t','a','d','o',' ','n','o',' ','l','o','g','i','n',' ','d','o',' ','m','a','p','a','.',"\n");
				$e=1; $messageSender->sendPing();
			}else{
				debug($N2._j('P','a','c','o','t','e',' ','n','a','o','-','e','-','l','o','g','i','n',',',' ','g','e','r','a','n','d','o',' ','s','e','e','d',"\n"));
				warning $N2._j('G','e','r','a','n','d','o',' ','n','o','v','o',' ','s','e','e','d','.','.','.',"\n");
				$e=1;
				my $rb;
				if(defined $F){ $rb = $F & 0xFF; warning sprintf($N2._j('M','O','D','O',' ','T','E','S','T','E',': ','f','o','r','c','a','n','d','o',' ','p','r','i','m','e','i','r','o',' ','b','y','t','e',' ','a','l','e','a','t','o','r','i','o',' ','=',' ','0','x','%','0','2','X',"\n"),$rb); $F=undef; }
				else{ $rb = int(rand(256)); }
				debug($N2._j('B','y','t','e',' ','a','l','e','a','t','o','r','i','o',' ','g','e','r','a','d','o',': ','0','x').sprintf("%02X",$rb)."\n");
				$$msg .= chr($rb);
				debug($N2._j('P','a','c','o','t','e',' ','a','p','o','s',' ','a','d','i','c','i','o','n','a','r',' ','b','y','t','e',' ','a','l','e','a','t','o','r','i','o',': ').unpack("H*",$$msg)."\n");
				debug($N2._j('T','a','m','a','n','h','o',' ','d','o',' ','p','a','c','o','t','e',' ','a','p','o','s',' ','b','y','t','e',' ','a','l','e','a','t','o','r','i','o',': ').length($$msg)." bytes\n");
				$s = get_seed($$msg);
				debug($N2._j('S','e','e','d',' ','g','e','r','a','d','o',' ','e',' ','a','r','m','a','z','e','n','a','d','o',': ','0','x').sprintf("%016X",$s)."\n");
			}
		}else{
			debug($N2._j('C','o','n','t','a','d','o','r',' ','>',' ','0',',',' ','c','a','l','c','u','l','a','n','d','o',' ','c','h','e','c','k','s','u','m',"\n"));
			debug($N2._j('P','a','c','o','t','e',' ','a','n','t','e','s',' ','d','o',' ','c','h','e','c','k','s','u','m',': ').unpack("H*",$$msg)."\n");
			debug($N2._j('T','a','m','a','n','h','o',' ','d','o',' ','p','a','c','o','t','e',' ','a','n','t','e','s',' ','d','o',' ','c','h','e','c','k','s','u','m',': ').length($$msg)." bytes\n");
			my $ck = calc_checksum($$msg);
			debug($N2._j('C','h','e','c','k','s','u','m',' ','c','a','l','c','u','l','a','d','o',': ','0','x').sprintf("%08X",$ck)."\n");
			debug($N2._j('B','y','t','e',' ','d','o',' ','c','h','e','c','k','s','u','m',' ','p','a','r','a',' ','a','d','i','c','i','o','n','a','r',': ','0','x').sprintf("%02X",$ck & 0xFF)."\n");
			$$msg .= pack("C",$ck);
			debug($N2._j('P','a','c','o','t','e',' ','a','p','o','s',' ','a','d','i','c','i','o','n','a','r',' ','c','h','e','c','k','s','u','m',': ').unpack("H*",$$msg)."\n");
			debug($N2._j('T','a','m','a','n','h','o',' ','d','o',' ','p','a','c','o','t','e',' ','a','p','o','s',' ','c','h','e','c','k','s','u','m',': ').length($$msg)." bytes\n");
		}
		$c = ($c+1) & 0xFFF;
		debug($N2._j('C','o','n','t','a','d','o','r',' ','a','t','u','a','l','i','z','a','d','o',' ','p','a','r','a',': ').$c."\n");
		debug($N2._j('P','a','c','o','t','e',' ','f','i','n','a','l',': ').unpack("H*",$$msg)."\n");
		debug($N2._j('T','a','m','a','n','h','o',' ','d','o',' ','p','a','c','o','t','e',' ','f','i','n','a','l',': ').length($$msg)." bytes\n");
	}else{
		debug($N2._j('E','s','t','a','d','o',' ','d','a',' ','r','e','d','e',' ','<',' ','4',',',' ','n','a','o',' ','p','r','o','c','e','s','s','a','n','d','o',"\n"));
	}
	debug($N2._j('=','=','=', '=','=','=', '=',' ','S','E','R','V','E','R','_','S','E','N','D','_','P','R','E',' ','C','O','N','C','L','U','I','D','O',' ','=','=','=', '=','=','=', '=','=') . "\n");
}

1;
