package Net::NTP::Packet;

use strict;
use warnings;

my @ntp_fields = qw/byte1 stratum poll precision/;
push @ntp_fields, qw/delay delay_fb disp disp_fb ident/;
push @ntp_fields, qw/ref_time ref_time_fb/;
push @ntp_fields, qw/org_time org_time_fb/;
push @ntp_fields, qw/recv_time recv_time_fb/;
push @ntp_fields, qw/trans_time trans_time_fb/;

sub new {
    my $class = shift;
    my(%param) = @_;

    my %self = ();

    foreach my $k (qw/leap version mode stratum poll precision rootdelay rootdisp refid reftime org rec xmt dst keyid dgst/) {
       $self{$k} = delete $param{$k};
    }

    if (keys %param) {
        die "unknown fields: ", join(", ", keys %param);
    }
    return bless \%self, $class;
}

sub new_client_packet {
    my $class = shift;
    my $xmttime = shift || die "a transmit time is required.";
    return $class->new(
        version => 4,
        mode    => 3,
        org     => $xmttime,
        leap    => 0,
        stratum => 0,
        poll    => 4,
        precision => 0,
        rootdelay => 0,
        rootdisp => 0,
        refid => '',
        reftime => 0,
        rec => 0,
        xmt => 0,
        dst => 0,
        keyid => '',
        dgst => '',
    );
}

use constant NTP_ADJ => 2208988800;

sub encode {
    my $self = shift;
    my $t1 = $self->{org};
    my $client_adj_localtime = $t1 + NTP_ADJ;
    my $client_frac_localtime = _frac2bin($client_adj_localtime);
    # LI=0, VN=4, MODE=3
    return pack("B8 C3 N9 N B32", '00011011', (0) x 3, (0) x 9, int($client_adj_localtime), $client_frac_localtime);
}

sub decode {
    my $class = shift;
    my $data = shift || die "decode() needs data.";
    my $timestamp = shift || die "decode() takes a timestamp.";

    my %tmp_pkt;
    @tmp_pkt{qw/byte1 stratum poll precision delay delay_fb disp disp_fb ident ref_time ref_time_fb org_time org_time_fb recv_time recv_time_fb trans_time trans_time_fb/} = unpack("a C2 c n B16 n B16 H8 N B32 N B32 N B32 N B32", $data);

    return $class->new(
        leap => (unpack("C", $tmp_pkt{byte1} & "\xC0") >> 6),
        version => (unpack("C", $tmp_pkt{byte1} & "\x38") >> 3),
        mode => unpack("C", $tmp_pkt{byte1} & "\x07"),
        stratum => $tmp_pkt{stratum},
        poll => $tmp_pkt{poll},
        precision => $tmp_pkt{precision},
        rootdelay => _bin2frac($tmp_pkt{delay_fb}),
        rootdisp => $tmp_pkt{disp},
        refid => _unpack_refid($tmp_pkt{stratum}, $tmp_pkt{ident}),
        reftime => $tmp_pkt{ref_time} + _bin2frac($tmp_pkt{ref_time_fb}) - NTP_ADJ,
        org => $tmp_pkt{org_time} + _bin2frac($tmp_pkt{org_time_fb}) - NTP_ADJ,
        rec => $tmp_pkt{recv_time} + _bin2frac($tmp_pkt{recv_time_fb}) - NTP_ADJ,
        xmt => $tmp_pkt{trans_time} + _bin2frac($tmp_pkt{trans_time_fb}) - NTP_ADJ,
        dst => $timestamp,
        keyid => '',
        dgst => '',
    );
}

sub _unpack_refid {
    my ($stratum, $raw_id) = @_;
    if ($stratum < 2) {
        return unpack("A4", pack("H8", $raw_id));
    }
    return sprintf("%d.%d.%d.%d", unpack("C4", pack("H8", $raw_id)));
}

sub _frac2bin {
    my $frac = shift;
    my $bin = '';
    while (length($bin) < 32) {
        $frac *= 2;
        my $bit = int($frac);
        $bin .= $bit;
        $frac -= $bit;
    }
    return $bin;
}

sub _bin2frac {
    my $bin = shift;
    my @bits = split //, $bin;
    my $frac = 0;
    while (@bits) {
        $frac = ($frac + pop @bits) / 2;
    }
    return $frac;
}

1;
