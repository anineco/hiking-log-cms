package ToGeoJSON;

use strict;
use warnings;
use utf8;

use POSIX qw(Inf);

# bounding box
my ($min_lon, $min_lat, $max_lon, $max_lat);

sub update_bounding_box {
  my ($lon, $lat) = @_;

  $min_lon = $lon if ($min_lon > $lon);
  $min_lat = $lat if ($min_lat > $lat);
  $max_lon = $lon if ($max_lon < $lon);
  $max_lat = $lat if ($max_lat < $lat);
}

sub get_point_feature {
  my $pt = shift; # wpt or rtept
  my $icon = Extensions::icon($pt);
  my ($lon, $lat) = (0 + $pt->{lon}, 0 + $pt->{lat});
  update_bounding_box($lon, $lat);
  my $feature = {
    type => 'Feature',
    properties => {
      name => $pt->{name}[0],
      _iconUrl => IconLut::IconUrl($icon),
      _iconSize => IconLut::IconSize($icon),
      _iconAnchor => IconLut::IconAnchor($icon)
    },
    geometry => {
      type => 'Point',
      coordinates => [$lon, $lat]
    }
  };
  if ($pt->{cmt}[0]) {
    foreach (split /,/, $pt->{cmt}[0]) {
      my ($key, $value) = split /=/;
      if ($key !~ /^[[:blank:]]*$/) { # using POSIX character class
        $feature->{properties}->{$key} = $value;
      }
    }
  }
  return $feature;
}

my %dash = (
# kashmir3d:line_style => dashArray
  11 => [4,2],        # short dash
  12 => [6,2],        # long dash
  13 => [1,2],        # dot
  14 => [1,2,5,2],    # dot-dash (one dot chain)
  15 => [1,2,1,2,6,2] # dot-dot-dash (two-dot chain)
);

sub get_linestring_properties {
  my $t = shift; # trk or rte
  Extensions::line_color($t) =~ /^(..)(..)(..)$/;
  my $c = "#$3$2$1";
  my $w = 0 + ($main::param{line_size} || Extensions::line_size($t));
  my $properties = {
    name => $t->{name}[0],
    _color => $c,
    _weight => $w,
    _opacity => 0 + $main::param{opacity}
  };
  my $s = $dash{$main::param{line_style} || Extensions::line_style($t)};
  if ($s) {
    $properties->{_dashArray} = join ',', map { '' . ($_ * $w) } @{$s};
  }
  return $properties;
}

sub get_linestring_feature {
  my ($segment, $tag, $properties) = @_; # trkseg or rte
  my $feature = {
    type => 'Feature',
    properties => $properties,
    geometry => {
      type => 'LineString',
      coordinates => []
    }
  };
  foreach (@{$segment->{$tag}}) { # trkpt or rtept
    my ($lon, $lat) = (0 + $_->{lon}, 0 + $_->{lat});
    update_bounding_box($lon, $lat);
    push @{$feature->{geometry}->{coordinates}}, [$lon, $lat];
  }
  return $feature;
}

sub convert {
  my $gpx = shift;
  my $geojson = {
    type => 'FeatureCollection',
    features => []
  };

  ($min_lon, $min_lat, $max_lon, $max_lat) = (Inf, Inf, -Inf, -Inf);

  # Waypoint
  foreach my $wpt (@{$gpx->{gpx}[0]->{wpt}}) {
    push @{$geojson->{features}}, get_point_feature($wpt);
  }

  # Route
  foreach my $rte (@{$gpx->{gpx}[0]->{rte}}) {
    foreach my $rtept (@{$rte->{rtept}}) {
      next if (Extensions::icon($rtept) eq '903001'); # skip blank icon
      push @{$geojson->{features}}, get_point_feature($rtept);
    }
    my $properties = get_linestring_properties($rte);
    push @{$geojson->{features}}, get_linestring_feature($rte, 'rtept', $properties);
  }

  # Track
  foreach my $trk (@{$gpx->{gpx}[0]->{trk}}) {
    my $properties = get_linestring_properties($trk);
    foreach my $trkseg (@{$trk->{trkseg}}) {
      push @{$geojson->{features}}, get_linestring_feature($trkseg, 'trkpt', $properties);
    }
  }

  $geojson->{bbox} = [$min_lon, $min_lat, $max_lon, $max_lat];

  return $geojson;
}

1;
