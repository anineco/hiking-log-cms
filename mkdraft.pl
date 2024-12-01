#!/usr/bin/env -S perl -CA

use strict;
use warnings;
use utf8;
use open qw(:utf8 :std);

use Config::Tiny;
use Data::Dumper;
{
  no warnings 'redefine';
  *Data::Dumper::qquote = sub { return shift; };
  $Data::Dumper::Useperl = 1;
}
use JSON;
use Math::Trig qw(pi deg2rad);
use Text::Xslate;
use Time::Piece;

Time::Piece::day_list(qw(日 月 火 水 木 金 土));

#
# 設定ファイルを読み込む
#
my $cf = Config::Tiny->read('config.ini');
my $content = $cf->{_}->{content};
my $material_gpx = $cf->{material}->{gpx};
my $material_img = $cf->{material}->{img};

sub datespan {
  my $date = shift;
  my ($start, $end) = ($date->{start}, $date->{end});
  my ($s0, $s1, $s2) = split(/-/, $start);
  my ($e0, $e1, $e2) = split(/-/, $end);
  if ($s0 ne $e0) {
    return "$start/$end";
  }
  if ($s1 ne $e1) {
    return "$start/$e1-$e2";
  }
  if ($s2 ne $e2) {
    return "$start/$e2";
  }
  return $start;
}

sub datejp {
  my ($s, $e) = @_;
  my ($start, $end);
  $start = sprintf '%d年%d月%d日（%s）', $s->year, $s->mon, $s->mday, $s->wdayname;
  if ($s->year ne $e->year) {
    $end = sprintf '%d年%d月%d日（%s）', $e->year, $e->mon, $e->mday, $e->wdayname;
  } elsif ($s->mon ne $e->mon) {
    $end = sprintf '%d月%d日（%s）', $e->mon, $e->mday, $e->wdayname;
  } elsif ($s->mday ne $e->mday) {
    $end = sprintf '%d日（%s）', $e->mday, $e->wdayname;
  } else {
    $end = '';
  }
  return { start => $start, end => $end };
}

sub round_time {
  my $t = shift; # Time::Piece object
  my $s = 60 * ($t->minute % 5) + $t->sec;
  if ($s < 150 || $s == 150 && $t->minute % 2 == 0) {
    $t -= $s;
  } elsif ($s > 150 || $s == 150 && $t->minute % 2 == 1) {
    $s = 300 - $s;
    $t += $s;
  }
  return $t;
}

sub gen_timeline {
  my $points = shift;
  my $ret = '';
  for (my $i = 0; $i <= $#{$points}; $i++) {
    my $p = $points->[$i];
    my $s = Time::Piece->strptime($p->{timespan}[0], '%FT%T');
    my $e = Time::Piece->strptime($p->{timespan}[1], '%FT%T');
    if ($i > 0) {
      $ret .= ' …';
    }
    $ret .= $p->{name};
    my $t = round_time($i > 0 ? $s : $e);
    if (exists $p->{ele}) {
      $ret .= '(' . $p->{ele} . ')';
    }
    $ret .= sprintf ' %d:%02d', $t->hour, $t->minute;
    next if ($i == 0 || $i == $#{$points});
    my $diff = $e - $s;
    if ($diff->minutes >= 5) {
      my $t = round_time($e);
      $ret .= sprintf '〜%d:%02d', $t->hour, $t->minute;
    }
  }
  return $ret;
}

#
# 経緯度 → Webメルカトル座標
#
sub trans {
  my ($lon, $lat) = @_;
  my $wpx = ($lon + 180) / 360;
  my $s = sin(deg2rad($lat));
  my $wpy = 0.5 - (1 / (4 * pi)) * log((1 + $s) / (1 - $s));
  return ($wpx, $wpy);
}

#
# ルート地図の中心座標、ズームレベル
#
sub center {
  my ($max_lon, $min_lon, $max_lat, $min_lat) = @_;

# 中心座標
  my $lat = sprintf("%.6f", 0.5 * ($max_lat + $min_lat));
  my $lon = sprintf("%.6f", 0.5 * ($max_lon + $min_lon));
# Webメルカトル座標に変換
  my @min_wp = trans($min_lon, $max_lat);
  my @max_wp = trans($max_lon, $min_lat);
# ズームレベルを計算
  my $wx = 256 * ($max_wp[0] - $min_wp[0]);
  my $wy = 256 * ($max_wp[1] - $min_wp[1]);
  my $xw = 580 / $wx;
  my $yw = 400 / $wy;
  my $w = $xw < $yw ? $xw : $yw;
  my $zoom = int(log($w) / log(2));
  $zoom = 16 if $zoom > 16;
  return ($lat, $lon, $zoom);
}

#
# コマンド行オプション
#
if ($#ARGV < 0) {
  my $script = basename($0);
  print STDERR "Usage: $script <CID>\n";
  exit 1;
}
my $cid = $ARGV[0]; # コンテントID

sub gen_photo {
  my $photos = shift;
  my $ret = [];
  for (my $i = 0; $i <= $#{$photos}; $i += 2) {
    my $p = $photos->[$i];
    my $q = $photos->[$i + 1];
    my ($w0, $h0) = $p->{width} > $p->{height} ? (270, 180) : (180, 270);
    my ($w1, $h1) = $q->{width} > $q->{height} ? (270, 180) : (180, 270);
    push @$ret, {
      base0 => $p->{hash},
      w0 => $w0,
      h0 => $h1,
      cap0 => $p->{caption},
      base1 => $q->{hash},
      w1 => $w1,
      h1 => $h1,
      cap1 => $q->{caption}
    };
  }
  return $ret;
}

sub gen_section {
  my $sect = shift;
  my $ret = [];
  foreach my $s (@{$sect}) {
    my ($lat, $lon, $zoom) = center(@{$s->{bound}});
    push @$ret, {
      title => $s->{title},
      date => $s->{date},
      timeline => gen_timeline($s->{timeline}),
      lat => $lat,
      lon => $lon,
      zoom => $zoom,
      url => $s->{routemap},
      photo => gen_photo($s->{photo})
    };
  }
  return $ret;
}

my $file = "$content/$cid.json";
open my $in, '<:raw', $file or die "Can't open '$file' $!";
my $text = do { local $/; <$in> };
close $in;

my $resource = decode_json($text);
my $s = Time::Piece->strptime($resource->{date}->{start}, '%F');
my $e = Time::Piece->strptime($resource->{date}->{end}, '%F');
my $now = localtime;

my $vars = {
  description => 'なんとか、かんとか。',
  title => $resource->{title},
  cid => $resource->{cid},
  cover => $resource->{cover}->{hash},
  datespan => datespan($resource->{date}),
  pubdate => $now->strftime('%F'),
  date => $resource->{date},
  datejp => datejp($s, $e),
  section => gen_section($resource->{section}),
  lm_year => $now->year,
  year => $s->year
};

my $tx = Text::Xslate->new(syntax => 'TTerse', verbose => 2);
print $tx->render('template/tozan.html', $vars);

__END__
