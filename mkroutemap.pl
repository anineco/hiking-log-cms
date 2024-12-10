#!/usr/bin/env -S perl -CA

use strict;
use warnings;
use utf8;
use open qw(:utf8 :std);

use Config::Tiny;
#use Data::Dumper;
#{
#  no warnings 'redefine';
#  *Data::Dumper::qquote = sub { return shift; };
#  $Data::Dumper::Useperl = 1;
#}
use File::Basename;
use File::Slurp;
use JSON;
use XML::Simple qw(:strict);

use FindBin;
use lib $FindBin::Bin;
use Extensions;
use ToGeojson;
require IconLut;

#
# 設定ファイルを読み込む
#
my $cf = Config::Tiny->read('config.ini');
my $content = $cf->{_}->{content};
my $material_gpx = $cf->{material}->{gpx};
my $material_img = $cf->{material}->{img};

#
# 変換パラメータ
#
our %param = (
  line_style => 13,
  line_size => 3,
  opacity => 0.5,
  xt_error => 0.005, # allowable cross-track error in kilometer
);

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
my $text = read_file($file);
my $resource = decode_json($text);

my $xs = XML::Simple->new(
  ForceArray => 1,
  KeepRoot => 1,
  KeyAttr => [],
  XMLDecl => '<?xml version="1.0" encoding="UTF-8"?>'
);

my $js = JSON->new->utf8(0); # disable UTF-8 encoding

foreach my $s (@{$resource->{section}}) {
  my $input = join(' -f ', @{$s->{gpx}});
  my $cmd = "gpsbabel -t -i gpx -f $input -x simplify,error=$param{xt_error}k -o gpx,gpxver=1.1 -F -";
  open(my $in, '-|', $cmd);
  my $xml = $xs->XMLin($in);
  close($in);
  my $geojson = ToGeoJSON::convert($xml);
  #  print $js->encode($geojson), "\n";
  open(my $out, '>', "$content/$cid/" . $s->{routemap});
  print $out $js->encode($geojson), "\n";
  close($out);
}

__END__
