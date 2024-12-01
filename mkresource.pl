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
use Encode;
use File::Basename;
use Image::ExifTool qw(ImageInfo);
use JSON;
use List::Util qw(min);
use POSIX qw(round hypot DBL_MAX);
use Time::Piece;
use Time::Seconds;
use XML::Simple qw(:strict);

#
# 設定ファイルを読み込む
#
my $cf = Config::Tiny->read('config.ini');
my $content = $cf->{_}->{content};
my $material_gpx = $cf->{material}->{gpx};
my $material_img = $cf->{material}->{img};

#
# コマンド行オプション
#
if ($#ARGV < 0) {
  my $script = basename($0);
  print STDERR "Usage: $script <CID> [<title>]\n";
  exit 1;
}
my $cid = $ARGV[0]; # コンテントID
my $title;
if ($#ARGV > 0) {
  $title = $ARGV[1];
}

#
# 山行記録
#
my $resource = { cid => $cid };

#
# GPXファイルを読み込む
#
my $xs = XML::Simple->new(
  ForceArray => 1,
  KeepRoot => 1,
  KeyAttr => [],
  XMLDecl => '<?xml version="1.0" encoding="UTF-8"?>'
);

sub read_gpx {
  my ($file, $trkpts, $wpts) = @_;

  my $root = $xs->XMLin($file) or die "Can't parse $file: $!";
  foreach my $wpt (@{$root->{gpx}[0]->{wpt}}) {
    my $item = {
      lon => 0 + $wpt->{lon},
      lat => 0 + $wpt->{lat},
      icon => 0 + $wpt->{extensions}[0]->{'kashmir3d:icon'}[0],
      name => $wpt->{name}[0]
    };
    if ($item->{icon} == 952015) { # 山頂
      foreach my $cmt (split /,/, $wpt->{cmt}[0]) {
        my ($key, $value) = split /=/, $cmt;
        if ($key eq '標高') {
          $item->{ele} = $value;
          last;
        }
      }
    }
    push @{$wpts}, $item;
  }
  foreach my $trk (@{$root->{gpx}[0]->{trk}}) {
    foreach my $trkseg (@{$trk->{trkseg}}) {
      foreach my $trkpt (@{$trkseg->{trkpt}}) {
        my $t = Time::Piece->strptime($trkpt->{time}[0], '%FT%TZ');
        $t += 9 * ONE_HOUR; # JST に変更
        push @{$trkpts}, {
          lon => 0 + $trkpt->{lon},
          lat => 0 + $trkpt->{lat},
          time => $t->datetime
        };
      }
    }
  }
}

sub read_section {
  my @files = @_; # GPX files
  my ($max_lon, $min_lon, $max_lat, $min_lat) = (-180, 180, -90, 90);
  my sub maxmin {
    my ($lon, $lat) = @_;
    $max_lon = $lon if ($max_lon < $lon);
    $min_lon = $lon if ($min_lon > $lon);
    $max_lat = $lat if ($max_lat < $lat);
    $min_lat = $lat if ($min_lat > $lat);
  }

  my @wpts = ();
  my @trkpts_unsorted = ();

  foreach my $file (@files) {
    read_gpx($file, \@trkpts_unsorted, \@wpts);
  }

  my @trkpts = sort { $a->{time} cmp $b->{time} } @trkpts_unsorted;

  #
  # 緯度・経度の最大・最小を求める
  #
  foreach my $p (@trkpts) {
    maxmin($p->{lon}, $p->{lat});
  }
  foreach my $p (@wpts) {
    maxmin($p->{lon}, $p->{lat});
  }
  my $bound = [ $max_lon, $min_lon, $max_lat, $min_lat ];

  #
  # 最寄のウェイポイントを求める
  #
  foreach my $p (@trkpts) {
    my $dmin = DBL_MAX;
    my $n = -1;
    for (my $i = 0; $i <= $#wpts; $i++) {
      my $q = $wpts[$i];
      my $d = hypot($q->{lon} - $p->{lon}, $q->{lat} - $p->{lat});
      if ($dmin > $d) {
        $dmin = $d;
        $n = $i;
      }
    }
    $p->{d} = $dmin;
    $p->{n} = $n;
  }

  #
  # 平滑化
  #
  for (my $i = 0; $i <= $#trkpts; $i++) {
    my $p0 = $trkpts[$i - ($i > 0)];
    my $p1 = $trkpts[$i];
    my $p2 = $trkpts[$i + ($i < $#trkpts)];
    my $nearest = -1;
    if ($p0->{n} == $p1->{n} && $p2->{n} == $p1->{n}) {
      if (min($p0->{d}, $p1->{d}, $p2->{d}) < 0.0004) { # 約40m
        $nearest = $p1->{n};
      }
    }
    $p1->{nearest} = $nearest;
  }

  #
  # 行程を作成
  #
  my @timeline = ();
  my @summits = ();

  my $start;
  my $end;

  for (my $i = 0; $i <= $#trkpts; $i++) {
    my $p = $trkpts[$i];
    my $n1 = $p->{nearest};
    next if ($n1 < 0);
    my $n0 = ($i == 0)        ? -1 : $trkpts[$i - 1]->{nearest};
    my $n2 = ($i == $#trkpts) ? -1 : $trkpts[$i + 1]->{nearest};
    if ($n1 != $n0) {
      $start = $p->{time};
    }
    if ($n1 != $n2) {
      $end = $p->{time};
      my $q = $wpts[$n1];
      my $item = {
        name => $q->{name},
        timespan => [ $start, $end ]
      };
      if ($q->{icon} == 952015) { # 山頂
        if (exists $q->{ele}) {
          $item->{ele} = $q->{ele};
          push @summits, $q->{name};
        }
      }
      push @timeline, $item;
    }
  }

  #
  # セクションを作成
  #
  my @t = split /T/, $timeline[0]->{timespan}[0];
  return {
    title => $title || join('〜', @summits),
    date => $t[0],
    timespan => [ $timeline[0]->{timespan}[0], $timeline[-1]->{timespan}[1] ],
    timeline => \@timeline,
    bound => $bound
  };
}

foreach my $map (glob "$material_gpx/$cid/routemap*.geojson") {
  my $base = basename($map);
  my $c = $base =~ s/^routemap(.*)\.geojson$/$1/r;
  my @files = glob "$material_gpx/$cid/???$c.gpx";
  die 'no GPX files' if ($#files < 0);
  my $section = read_section(@files);
  $section->{gpx} = \@files;
  $section->{routemap} = "routemap$c.geojson";
  push @{$resource->{section}}, $section;
}
if (exists $resource->{section}) {
  $resource->{title} = join('・', map { $_->{title} } @{$resource->{section}});
  $resource->{date} = { start => $resource->{section}[0]->{date}, end => $resource->{section}[-1]->{date} };
} else {
  my $ymd = $cid =~ s/(..)(..)(..)/20$1-$2-$3/r;
  $resource->{title} = 'タイトル';
  $resource->{date} = { start => $ymd, end => $ymd };
  $resource->{section} = [ { timespan => [ $ymd . 'T00:00:00', $ymd . 'T23:59:59' ] } ];
}

#
# 表紙画像
#
my %hash = ();
my @covers = glob "$material_img/$cid/S[0-9][0-9][0-9][0-9].*";
if ($#covers < 0) {
  @covers = glob "$material_img/$cid/????[0-9][0-9][0-9][0-9](1).*";
  die "no cover image" if ($#covers < 0);
}
my $file = $covers[0];
my $base = basename($file);
my $key = $base =~ s/^.*([0-9]{4})(\(1\))?\..*$/$1/r;
$resource->{cover} = { file => $file, hash => $key };
$hash{$key} = 1;

#
# 写真情報を読み込む
#
my @photos_unsorted = ();
foreach my $file (glob "$material_img/$cid/????[0-9][0-9][0-9][0-9].*") {
  my $base = basename($file);
  my $info = ImageInfo($file);
  my $t = Time::Piece->strptime($info->{DateTimeOriginal}, '%Y:%m:%d %T');
  my $item = {
    file => $file,
    time => $t->datetime,
    width => $info->{ImageWidth},
    height => $info->{ImageHeight},
    caption => decode_utf8($info->{Title}) || $base
  };
  my $key = $base =~ s/^....(....)\..*$/$1/r;
  if (exists $hash{$key} && $key ne $resource->{cover}->{hash}) {
    for (my $i = 0; $i <= 26; $i++) {
      die 'hash Error' if ($i == 26);
      my $c = chr(97 + $i);
      unless (exists $hash{$key . $c}) {
        $key .= $c;
        last;
      }
    }
  }
  $hash{$key} = 1;
  $item->{hash} = $key;
  push @photos_unsorted, $item;
}
my @photos = sort { $a->{time} cmp $b->{time} } @photos_unsorted;

#
# 写真をセクションに振り分け
#
my $n = $#{$resource->{section}};
foreach my $photo (@photos) {
  my $t = $photo->{time};
  for (my $i = 0; $i <= $n; $i++) {
    my $section = $resource->{section}[$i];
    if ($i == $n || $t le $section->{timespan}[1]) {
      push @{$section->{photo}}, $photo;
      last;
    }
    my $t1 = Time::Piece->strptime($section->{timespan}[1], '%FT%T');
    my $t2 = Time::Piece->strptime($resource->{section}[$i + 1]->{timespan}[0], '%FT%T');
    my $tc = $t1 + ($t2 - $t1) / 2;
    if ($t le $tc->datetime) {
      push @{$section->{photo}}, $photo;
      last;
    }
  }
}

#
# JSON出力
#
my $json = "$content/$cid.json";
open(my $out, '>', $json) or die "Can't open '$json' $!";
print $out to_json($resource, { pretty => 1 }), "\n";
close($out);
__END__
