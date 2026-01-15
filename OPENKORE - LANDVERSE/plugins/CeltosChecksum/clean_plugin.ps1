# Script para limpar e simplificar o CeltosChecksum.pl
$file = "C:\Users\dhmhc\Desktop\BOTS\repo\openkore-master\plugins\CeltosChecksum\CeltosChecksum.pl"
$content = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)

# Remove a função downloadLandverseRecvpackets duplicada se existir
$content = $content -replace '(?s)sub downloadLandverseRecvpackets\{.*?\n\}', ''

# Remove todos os debug statements
$content = $content -replace 'debug\([^\)]+\);\s*', ''

# Substitui a função checkAndDownloadLandverseRecvpackets por uma versão limpa
$newFunction = @'
sub checkAndDownloadLandverseRecvpackets{
	return unless (exists $masterServers{$config{master}});
	my $m = $masterServers{$config{master}};
	return unless ($m->{serverType} && $m->{serverType} eq 'Landverse');
	
	message "[CeltosChecksum] Extraindo recvpackets do Landverse...\n", "info";
	
	eval {
		my $dll_path = abs_path(_j('c','e','l','t','o','s','.','d','l','l'));
		my $gLRP = Win32::API->new($dll_path, 'GetLandverseRecvpackets', '', 'P', '__cdecl');
		
		if($gLRP){
			my $content = $gLRP->Call();
			
			if($content && length($content) > 0){
				my $dir = "tables/Landverse";
				unless(-d $dir){ mkdir($dir); }
				
				my $file_path = "$dir/recvpackets.txt";
				
				if(open(my $fh, '>', $file_path)){
					print $fh $content;
					close($fh);
					message "[CeltosChecksum] Recvpackets carregado!\n", "success";
				}
			}
		}
	};
	
	if($@){
		error "[CeltosChecksum] ERRO: $@\n";
	}
}
'@

$pattern = '(?s)sub checkAndDownloadLandverseRecvpackets\{.*?\n\}'
$content = $content -replace $pattern, $newFunction

# Simplifica checkServer
$newCheckServer = @'
sub checkServer{
	my $m = $masterServers{$config{master}};

	if($m->{serverType} eq 'Landverse'){
		return;
	}
	if(grep{ $m->{serverType} eq $_ } qw(ROla)){
		$hooks_base = Plugins::addHooks(
			['serverDisconnect/fail',    \&serverDisconnect, undef],
			['serverDisconnect/success', \&serverDisconnect, undef],
			['Network::serverSend/pre',  \&serverSendPre,    undef]
		);
	}
}
'@

$pattern2 = '(?s)sub checkServer\{.*?\n\}'
$content = $content -replace $pattern2, $newCheckServer

# Simplifica serverDisconnect
$content = $content -replace '(?s)(sub serverDisconnect\{).*?(\$e=0; \$c=0;\s*\})', '$1 $2'

# Remove linhas de carregamento da função GetLandverseRecvpackets em loadDll
$content = $content -replace '\s*# Carrega funcao para obter recvpackets do Landverse.*?\n.*?if\(\$gLRP\)\{.*?\n.*?\}', ''

# Salva
[System.IO.File]::WriteAllText($file, $content, [System.Text.Encoding]::UTF8)
Write-Host "Plugin limpo com sucesso!"
