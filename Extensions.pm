package Extensions;
use strict;
use warnings;
use utf8;
sub icon {
  my $t = shift;
# WORKAROUND: gpsbabel 1.9.0 drops 'extensions' tags in 'wpt' elements
  return (exists $t->{extensions} ? $t->{extensions}[0] : $t)->{'kashmir3d:icon'}[0];
}
sub line_color {
  my $t = shift;
  return $t->{extensions}[0]->{'kashmir3d:line_color'}[0];
}
sub line_size {
  my $t = shift;
  return $t->{extensions}[0]->{'kashmir3d:line_size'}[0];
}
sub line_style {
  my $t = shift;
  return $t->{extensions}[0]->{'kashmir3d:line_style'}[0];
}
1;
