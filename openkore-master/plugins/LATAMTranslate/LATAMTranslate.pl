# ====================
# LATAMTranslate v2
# Plugin author: Rubim, UnknownXD
# Plugin modified by: roxleopardo, billabong93
# ====================

package LATAMTranslate;

use strict;
use Plugins;
use Globals;
use Settings;
use Utils;
use Actor;
use utf8;
use Log qw(message debug error);
use JSON::Tiny qw(from_json to_json);
use Translation qw(T TF);

our %strings_cache;

our $RE_TOKEN_BLOB = qr{
    \x1C
    (
        [^\x1C]*       
        (?: \x1C [^\x1C]* \x1C [^\x1C]* )*
    )
    \x1C
}x;

my $base_hooks;
my $plugin_path = $Plugins::current_plugin_folder;

load();
my $hooks = Plugins::addHooks(
    ['start3', \&load, undef],
);

Plugins::register('LATAMTranslate', 'Fixes issues with localized strings.', \&unload);

# ===============================
# PLUGIN INIT & CLEANUP
# ===============================

sub load {
    my $master = $masterServers{ $config{master} };
    if (grep { $master->{serverType} eq $_ } qw(ROla)) {
        $base_hooks = Plugins::addHooks(
            ['actor_setName', \&setName, undef],
            ['packet_pre/public_chat', \&publicChatPre, undef],
            ['packet_pre/local_broadcast', \&localBroadcastPre, undef],
            ['packet_pre/system_chat', \&systemChatPre, undef],
            ['packet_pre/npc_talk', \&npcTalkPre, undef],
            ['packet_pre/npc_talk_responses', \&npcTalkRespPre, undef],
            ['packet/npc_talk_responses', \&npcTalkRespPost, undef],
			['Command_pre/talk', \&latam_pre_talk_cmd, undef],
        );
        loadJSON();
    }
}

sub unload {
    Plugins::delHooks($hooks) if $hooks;
    Plugins::delHooks($base_hooks) if $base_hooks;
    %strings_cache = ();
}

# ===============================
# LOAD JSON STRINGS
# ===============================

sub loadJSON {
    message "Loading strings.json...\n", "LATAMTranslate";
    %strings_cache = ();

    my $file = "$plugin_path/strings.json";
    unless (-r $file) {
        error("[LATAMTranslate] Can't read $file\n");
        return;
    }

    open my $fh, '<', $file or do {
        error("[LATAMTranslate] Failed to open $file: $!\n");
        return;
    };

    local $/;
    my $json_text = <$fh>;
    close $fh;

    my $data = eval { from_json($json_text) };
    if ($@ || ref($data) ne 'HASH') {
        error("[LATAMTranslate] Failed to parse JSON: $@\n");
        return;
    }

    %strings_cache = %{$data};
    my $count = scalar keys %strings_cache;
    message "[LATAMTranslate] Loaded $count actor names from strings.json\n", "LATAMTranslate";
}

# ===============================
# CORE TRANSLATION LOGIC
# ===============================

sub translate_token {
    my ($token) = @_;

    if (exists $strings_cache{$token}) {
        my $string = $strings_cache{$token};
        utf8::decode($string);
        return $string;
    } else {
        my $hex = unpack("H*", $token);
        message("[LATAMTranslate] Missing token: $token (hex: $hex)\n");
        return "[MISSING:$token]";
    }
}

sub translate_composite_token {
    my ($blob) = @_;
    my @parts = split(/\x1D|\x{2194}/, $blob);
    my $id = shift @parts;

    unless (exists $strings_cache{$id}) {
        return translate_token($blob);
    }

    my $template = $strings_cache{$id};
    for my $i (0 .. $#parts) {
        my $arg = $parts[$i] // '';
        if ($arg =~ /^\x1C([[:print:]]+?)\x1C$/) {
            $arg = translate_token($1);
        }
        $template =~ s/\{\Q$i\E\}/$arg/g;
    }

    return $template;
}

sub _translate_blob {
    my ($blob) = @_;
    return (index($blob, "\x1D") >= 0 || $blob =~ /\x{2194}/)
        ? translate_composite_token($blob)
        : translate_token($blob);
}

sub _translate_tokens_inplace {
    my ($sref) = @_;
    return unless defined $$sref;
    return unless index($$sref, "\x1C") >= 0;
    $$sref =~ s/$RE_TOKEN_BLOB/_translate_blob($1)/gex;
}

sub _translate_args_field {
    my ($args, $field) = @_;
    my $val = $args->{$field};
    return unless defined $val;
    _translate_tokens_inplace(\$val);
    $args->{$field} = $val;
}

# ===============================
# HOOKS HANDLERS
# ===============================

sub setName {
    my (undef, $args) = @_;
    my $name = $args->{new_name};
    return unless defined $name;

    my $orig = $name;
    _translate_tokens_inplace(\$name);
    return if $name eq $orig;
    return if $name =~ /\[MISSING:/;

    $args->{new_name} = $name;
    $args->{return}   = 1;
}

sub npcTalkPre {
    my (undef, $args) = @_;
    _translate_args_field($args, 'msg');
}

sub npcTalkRespPre {
    my (undef, $args) = @_;
    my $raw = $args->{RAW_MSG};
    return unless defined $raw;

    $raw =~ s/^.*?\x1C//s;
    my @tokens = split(/[\x1C:]/, $raw);
    my @translated;

    for my $t (@tokens) {
        $t =~ s/^\s+|\s+$//g;
        next if $t eq '' || $t !~ /[[:print:]]/;
        push @translated, _translate_blob($t);
    }

    if (@translated && $translated[-1] =~ /^\[MISSING:/) {
        $translated[-1] = "Cancelar Conversa";
    }

    $args->{responses} = \@translated;
}

sub npcTalkRespPost {
    my (undef, $args) = @_;
    return unless defined $args->{responses};
    my $responses = $args->{responses};
    return unless @$responses;

    # Adiciona "Fechar" no final, se necessário
    if ($responses->[-1] !~ /Cancelar Conversa|Fechar/i) {
        push @$responses, "Finalizar Conversa";
    }

    # Exibe respostas traduzidas
	message "------------[LATAMTranslate]------------\n";
    message "[#] Respostas:\n";
    for my $i (0 .. $#{$responses}) {
        next unless defined $responses->[$i];
        my $txt = $responses->[$i];
        $txt =~ s/\^[0-9A-Fa-f]{6}//g;  # Remove códigos
        message sprintf("[%d] %s\n", $i, $txt);
    }
    message "----------------------------------------\n";

    my $npc_name = "NPC"; 
    my $npc_index = 0;
    my $binID_found = 0;

    if (defined $::talk{ID}) {
        my $npc = Actor::get($::talk{ID});
        
        if (defined $npc) {
            $npc_name = $npc->{name} // $npc->{charName} // "NPC";
            $npc_name =~ s/ \(\d+\)$//;
            if (defined $npc->{binID}) {
                $npc_index = $npc->{binID};
                $binID_found = 1;
            }
        }
    }

    $npc_name = $::talk{name} // $npc_name;

    if (!$binID_found && defined $::talk{ID}) {
		$npc_index = unpack('C', substr($::talk{ID}, 0, 1));
    }

	if (!defined $Globals::latam_last_resp_notice_time || time - $Globals::latam_last_resp_notice_time > 0.5) {
    
		message TF("NPC %s (%d): Digite 'talk resp #' para escolher uma resposta.\n",
        $npc_name, $npc_index), "ai_npcTalk";
    
    	$Globals::latam_last_resp_notice_time = time;
    	$Globals::latam_last_resp_npc = $npc_name;
    }
}

sub publicChatPre {
    my (undef, $args) = @_;
    _translate_args_field($args, 'message');
}

sub localBroadcastPre {
    my (undef, $args) = @_;
    _translate_args_field($args, 'message');
}

sub systemChatPre {
    my (undef, $args) = @_;
    _translate_args_field($args, 'message');
}

1;
