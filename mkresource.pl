#!/usr/bin/env -S perl -CA
# mkresource.pl - create resource JSON file

use strict;
use warnings;
use utf8;
use open qw(:utf8 :std);

use Config::Tiny;
use Encode;
use File::Basename;
use Image::ExifTool qw(ImageInfo);
use JSON;
use List::Util qw(min);
use POSIX qw(round hypot Inf);
use Time::Piece;
use Time::Seconds;
use XML::Simple qw(:strict);

use constant ICON_SUMMIT => 952015; # kashmir3d:icon

# load configuration file
my $cf = Config::Tiny->read('config.ini');
my $content = $cf->{_}->{content};
my $material_gpx = $cf->{material}->{gpx};
my $material_img = $cf->{material}->{img};

# parse command line argument
if ($#ARGV != 1) {
  my $script = basename($0);
  die "Usage: $script <CID> <title>";
}
my $cid = $ARGV[0]; # content ID
my $title = $ARGV[1];

my $resource = { cid => $cid, title => $title };

# load GPX files
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
    if ($item->{icon} == ICON_SUMMIT) {
      foreach my $cmt (split /,/, $wpt->{cmt}[0]) {
        my ($key, $value) = split /=/, $cmt;
        if ($key eq '標高') { # 'elevation'
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
        $t += 9 * ONE_HOUR; # transfer UTC to JST
        push @{$trkpts}, {
          lon => 0 + $trkpt->{lon},
          lat => 0 + $trkpt->{lat},
          time => $t->datetime
        };
      }
    }
  }
}

# extract session info. from GPS data
sub read_section {
  my @files = @_; # GPX files
  my @wpts = ();
  my @trkpts_unsorted = ();

  # read track points and waypoints
  foreach my $file (@files) {
    read_gpx($file, \@trkpts_unsorted, \@wpts);
  }
  my @trkpts = sort { $a->{time} cmp $b->{time} } @trkpts_unsorted;

  # for each track point, find the nearest waypoint
  foreach my $p (@trkpts) {
    my $dmin = Inf;
    my $n = -1;
    for (my $i = 0; $i <= $#wpts; $i++) {
      my $q = $wpts[$i];
      # HACK: compute rough estimate of distance in degree
      my $d = hypot($q->{lon} - $p->{lon}, $q->{lat} - $p->{lat});
      if ($dmin > $d) {
        $dmin = $d;
        $n = $i;
      }
    }
    $p->{d} = $dmin;
    $p->{n} = $n;
  }

  for (my $i = 0; $i <= $#trkpts; $i++) {
    my $p0 = $trkpts[$i - ($i > 0)];
    my $p1 = $trkpts[$i];
    my $p2 = $trkpts[$i + ($i < $#trkpts)];
    my $nearest = -1;
    if ($p0->{n} == $p1->{n} && $p2->{n} == $p1->{n}) {
      if (min($p0->{d}, $p1->{d}, $p2->{d}) < 0.0004) { # NOTE: equivalent to 40m
        $nearest = $p1->{n};
      }
    }
    $p1->{nearest} = $nearest;
  }

  #  create timeline
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
      if ($q->{icon} == ICON_SUMMIT) {
        if (exists $q->{ele}) {
          $item->{ele} = $q->{ele};
          push @summits, $q->{name};
        }
      }
      push @timeline, $item;
    }
  }

  my @t = split /T/, $timeline[0]->{timespan}[0];
  return {
    title => $title || join('〜', @summits),
    date => $t[0],
    timespan => [ $timeline[0]->{timespan}[0], $timeline[-1]->{timespan}[1] ],
    timeline => \@timeline
  };
}

# set source GPX files and file name of routemap
foreach my $track (glob "$material_gpx/$cid/trk*.gpx") {
  next unless ($track =~ m|/trk([0-9]?)\.gpx$|);
  my $c = $1;
  my @files = glob "$material_gpx/$cid/???$c.gpx"; # rte, trk, wpt
  die 'no GPX files' if ($#files < 0);
  my $section = read_section(@files);
  $section->{gpx} = \@files;
  $section->{routemap} = "routemap$c.geojson";
  push @{$resource->{section}}, $section;
}

# set start and end date to resource
if (exists $resource->{section}) {
  $resource->{date} = {
    start => $resource->{section}[0]->{date},
    end => $resource->{section}[-1]->{date}
  };
} else {
  my $ymd = $cid =~ s/(..)(..)(..)/20$1-$2-$3/r;
  $resource->{date} = { start => $ymd, end => $ymd };
  $resource->{section} = [ { timespan => [ $ymd . 'T00:00:00', $ymd . 'T23:59:59' ] } ];
}

# set cover image to resource
my %hash = ();
my @covers = glob "$material_img/$cid/cover/*";
die "no cover image" if ($#covers < 0);
my $file = $covers[0];
my $base = basename($file);
my $key = $base =~ s/^.*([0-9]{4})\..*$/$1/r;
$resource->{cover} = { file => $file, hash => $key };
$hash{$key} = 1;

# load photo's metadata
my @photos_unsorted = ();
foreach my $file (glob "$material_img/$cid/*[0-9][0-9][0-9][0-9].*") {
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
  # shorten photo filename to 4-digit number
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

# assign photo to section by timestamp
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

# output resource JSON
my $json = "$content/$cid.json";
open(my $out, '>', $json) or die "Can't open $json: $!";
print $out to_json($resource, { pretty => 1 }), "\n";
close($out);
__END__
