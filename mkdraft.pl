#!/usr/bin/env -S perl -CA
# mkdraft.pl - create draft html file of hiking log

use strict;
use warnings;
use utf8;
use open qw(:utf8 :std);

use Config::Tiny;
use JSON;
use Math::Trig qw(pi deg2rad);
use Text::Xslate;
use Time::Piece;

# days of the week in Japanese
Time::Piece::day_list(qw(日 月 火 水 木 金 土));

# load configuration file
my $cf = Config::Tiny->read('config.ini');
my $content = $cf->{_}->{content};
my $material_gpx = $cf->{material}->{gpx};
my $material_img = $cf->{material}->{img};

# parse command line argument
if ($#ARGV < 0) {
  my $script = basename($0);
  die "Usage: $script CID";
}
my $cid = $ARGV[0]; # content ID

# load resource json
my $file = "$content/$cid.json";
open(my $in, '<:raw', $file) or die "Can't open $file: $!";
my $text = do { local $/; <$in> };
close($in);
my $resource = decode_json($text);

# convert start and end date to ISO8601 period
sub datespan {
  my $date = shift;
  my ($start, $end) = ($date->{start}, $date->{end});
  my ($ys, $ms, $ds) = split(/-/, $start);
  my ($ye, $me, $de) = split(/-/, $end);
  if ($ys ne $ye) {
    return "$start/$end";
  }
  if ($ms ne $me) {
    return "$start/$me-$de";
  }
  if ($ds ne $de) {
    return "$start/$de";
  }
  return $start;
}

# Convert start and end date object to Japanese period
sub datejp {
  my ($s, $e) = @_; # Time::Piece object
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

# round time to nearest 5-minute interval
sub round_time {
  my $t = shift; # Time::Piece object
  my $s = 60 * ($t->minute % 5) + $t->sec;
  if ($s > 150 || $s == 150 && $t->minute % 2 == 1) {
    $t += 300;
  }
  $t -= $s;
  return $t;
}

# create timeline
sub gen_timeline {
  my $points = shift;
  my $ret = '';
  for (my $i = 0; $i <= $#{$points}; $i++) {
    my $p = $points->[$i];
    if ($i > 0) {
      $ret .= ' …';
    }
    $ret .= $p->{name};
    if (exists $p->{ele}) {
      $ret .= '(' . $p->{ele} . ')';
    }
    my $s = round_time(Time::Piece->strptime($p->{timespan}[0], '%FT%T'));
    my $e = round_time(Time::Piece->strptime($p->{timespan}[1], '%FT%T'));
    my $t = $i > 0 ? $s : $e;
    $ret .= sprintf ' %d:%02d', $t->hour, $t->minute;
    if ($i > 0 && $i < $#{$points}) {
      my $diff = $e - $s;
      if ($diff->minutes >= 10) {
        $ret .= sprintf '〜%d:%02d', $e->hour, $e->minute;
      }
    }
  }
  return $ret;
}

# convert latitude and longitude to Web Mercator coordinates
sub trans {
  my ($lon, $lat) = @_;
  my $wpx = ($lon + 180) / 360;
  my $s = sin(deg2rad($lat));
  my $wpy = 0.5 - (1 / (4 * pi)) * log((1 + $s) / (1 - $s));
  return ($wpx, $wpy);
}

# Calculate center coordinates and zoom level
sub center {
  my ($min_lon, $min_lat, $max_lon, $max_lat) = @_; # bounding box
# center coordinates
  my $lon = sprintf("%.6f", 0.5 * ($max_lon + $min_lon));
  my $lat = sprintf("%.6f", 0.5 * ($max_lat + $min_lat));
# zoom level
  my @min_wp = trans($min_lon, $max_lat); # north-west corner
  my @max_wp = trans($max_lon, $min_lat); # south-east corner
  my $wx = 256 * ($max_wp[0] - $min_wp[0]);
  my $wy = 256 * ($max_wp[1] - $min_wp[1]);
# TODO: map size is fixed as 580 x 400 in pixel
  my $xw = 580 / $wx;
  my $yw = 400 / $wy;
  my $w = $xw < $yw ? $xw : $yw;
  my $zoom = int(log($w) / log(2));
  $zoom = 16 if $zoom > 16;
  return ($lat, $lon, $zoom);
}

# create URL for routemap
sub gen_routemap {
  my $routemap = shift;
  my $file = "$content/$cid/$routemap";
  open(my $in, '<:raw', $file) or die "Can't open $file: $!";
  my $text = do { local $/; <$in> };
  close($in);
  my $json = decode_json($text);
  die "missing 'bbox' in $file"  unless exists $json->{bbox};
  my ($lat, $lon, $zoom) = center(@{$json->{bbox}});
  return "routemap.html?lat=$lat&lon=$lon&zoom=$zoom&url=$cid/$routemap";
}

# set photo information
sub gen_photo {
  my $photos = shift;
  my $ret = [];
  for (my $i = 0; $i <= $#{$photos}; $i += 2) {
    my $p0 = $photos->[$i];
    my $p1 = $photos->[$i + 1];
    my ($w0, $h0) = $p0->{width} > $p0->{height} ? (270, 180) : (180, 270);
    my ($w1, $h1) = $p1->{width} > $p1->{height} ? (270, 180) : (180, 270);
    push @$ret, {
      base0 => $p0->{hash}, w0 => $w0, h0 => $h0, cap0 => $p0->{caption},
      base1 => $p1->{hash}, w1 => $w1, h1 => $h1, cap1 => $p1->{caption}
    };
  }
  return $ret;
}

# Create section
sub gen_section {
  my $sect = shift;
  my $ret = [];
  foreach my $s (@{$sect}) {
    push @$ret, {
      title => $s->{title},
      date => $s->{date},
      timeline => gen_timeline($s->{timeline}),
      routemap => gen_routemap($s->{routemap}),
      photo => gen_photo($s->{photo})
    };
  }
  return $ret;
}

# set template variables
my $s = Time::Piece->strptime($resource->{date}->{start}, '%F');
my $e = Time::Piece->strptime($resource->{date}->{end}, '%F');
my $now = localtime;
my $vars = {
  site_name => $cf->{template}->{site_name},
  site_url => $cf->{template}->{site_url},
  author_name => $cf->{template}->{author_name},
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
my $html = "$content/$cid.html";
open(my $out, '>', $html) or die "Can't open '$html' $!";
print $out $tx->render('template/tozan.html', $vars);
close($out);
__END__
