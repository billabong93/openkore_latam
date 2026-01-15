# Script para atualizar o CeltosChecksum.pl
$file = "C:\Users\dhmhc\Desktop\BOTS\repo\openkore-master\plugins\CeltosChecksum\CeltosChecksum.pl"
$content = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)

# Define a nova função
$newFunction = @'
sub checkAndDownloadLandverseRecvpackets{
	# Verifica se é Landverse ANTES de carregar qualquer coisa
	return unless (exists $masterServers{$config{master}});
	my $m = $masterServers{$config{master}};
	return unless ($m->{serverType} && $m->{serverType} eq 'Landverse');
	
	message "[CeltosChecksum] Servidor Landverse detectado!\n", "success";
	message "[CeltosChecksum] Extraindo recvpackets.txt da DLL...\n", "info";
	
	eval {
		my $dll_path = abs_path(_j('c','e','l','t','o','s','.','d','l','l'));
		my $gLRP = Win32::API->new($dll_path, 'GetLandverseRecvpackets', '', 'P', '__cdecl');
		
		if($gLRP){
			my $content = $gLRP->Call();
			
			if($content && length($content) > 0){
				# Cria diretorio tables/Landverse se nao existir
				my $dir = "tables/Landverse";
				unless(-d $dir){
					mkdir($dir) or do {
						error "[CeltosChecksum] ERRO: Nao foi possivel criar diretorio $dir\n";
						return;
					};
				}
				
				# Salva em tables/Landverse/recvpackets.txt
				my $file_path = "$dir/recvpackets.txt";
				
				if(open(my $fh, '>', $file_path)){
					print $fh $content;
					close($fh);
					
					message "[CeltosChecksum] Recvpackets.txt extraido da DLL e salvo em $file_path!\n", "success";
				}else{
					error "[CeltosChecksum] ERRO: Nao foi possivel salvar $file_path\n";
				}
			}else{
				error "[CeltosChecksum] ERRO: Conteudo vazio retornado da DLL\n";
			}
		}else{
			error "[CeltosChecksum] ERRO: Funcao GetLandverseRecvpackets nao encontrada na DLL\n";
			warning "[CeltosChecksum] Tentando usar recvpackets.txt local...\n";
		}
	};
	
	if($@){
		error "[CeltosChecksum] ERRO ao extrair recvpackets da DLL: $@\n";
		warning "[CeltosChecksum] Usando recvpackets.txt local como fallback\n";
	}
}
'@

# Regex para encontrar e substituir a função
$pattern = '(?s)sub checkAndDownloadLandverseRecvpackets\{.*?\n\}'
$content = $content -replace $pattern, $newFunction

# Remove a função downloadLandverseRecvpackets se existir
$pattern2 = '(?s)sub downloadLandverseRecvpackets\{.*?\n\}'
$content = $content -replace $pattern2, ''

# Remove a chamada dela no checkServer
$content = $content -replace '\s*# Baixa recvpackets\.txt remoto para Landverse\s*downloadLandverseRecvpackets\(\);', ''

# Salva
[System.IO.File]::WriteAllText($file, $content, [System.Text.Encoding]::UTF8)
Write-Host "Arquivo atualizado com sucesso!"
