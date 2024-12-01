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
use File::Basename;
use JSON;

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
  print STDERR "Usage: $script <CID>\n";
  exit 1;
}
my $cid = $ARGV[0]; # コンテントID

my $file = "$content/$cid.json";
open my $in, '<:raw', $file or die "Can't open '$file' $!";
my $text = do { local $/; <$in> };
close $in;

my $resource = decode_json($text);

print <<'EOS';
set -eu
TMOZ=$(mktemp -d moz.XXXXXX)
trap 'rm -rf $TMOZ' EXIT
function squoosh () {
# source width height target
  local s=$1 w=$2 h=$3 t=$4
  local x=${s##*/}
  local b=${x%.*}
  sharp --quality 75 --mozjpeg --input $s --output $t.jpg  -- resize $w $h
  sharp --quality 45           --input $s --output $t.avif -- resize $w $h
}
function squoosh_crop () {
# source width height target
  local s=$1 w=$2 h=$3 t=$4
  local x=${s##*/}
  local b=${x%.*}
  # calculate LCD
  local p=$w q=$h
  local r=$[$p%$q]
  while [ $r -gt 0 ]; do
    p=$q q=$r r=$[$p%$q]
  done
  p=$[$w/$q]
  q=$[$h/$q]
  convert $s -gravity center -crop "$p:$q^+0+0" $TMOZ/$b.jpeg
  sharp --quality 75 --mozjpeg --input $TMOZ/$b.jpeg --output $t.jpg -- resize $w $h
  rm -f $TMOZ/$b.jpeg
}
EOS

my $C = 'R000'; # 🔖：RICOH GRⅢの場合
my $D = "$content/$cid";
my $S = $resource->{cover}->{file};
my $T = $resource->{cover}->{hash};
my $P = dirname($S) . '/' . $C . (basename($S) =~ s/^S//r);

print <<EOS;
mkdir -p $D/2x
squoosh $S 120 90 $D/S$T
squoosh $S 240 180 $D/2x/S$T
squoosh_crop $P 320 180 $D/W$T
squoosh_crop $P 320 240 $D/F$T
squoosh_crop $P 240 240 $D/Q$T
EOS

foreach my $sect (@{$resource->{section}}) {
  foreach my $img (@{$sect->{photo}}) {
    my $S = $img->{file};
    my $T = $img->{hash};
    my ($W, $H) = ($img->{width} > $img->{height}) ? (270, 180) : (180, 270);
    print "squoosh $S $W $H $D/$T\n";
    $W *= 2;
    $H *= 2;
    print "squoosh $S $W $H $D/2x/$T\n";
  }
}
__END__
