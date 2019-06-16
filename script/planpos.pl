#!/perl

use 5.22.0;
use strict;
no warnings qw/experimental/;
use feature qw/state switch/;

use utf8;
use FindBin qw/$Bin/;
use lib ("$Bin/../lib");
use Getopt::Long qw/GetOptions/;
use Pod::Usage qw/pod2usage/;
use DateTime;
use Term::ANSIColor;

use Readonly;

use Astro::Montenbruck::Time qw/jd_cent jd2lst $SEC_PER_CEN jd2unix/;
use Astro::Montenbruck::Time::DeltaT qw/delta_t/;
use Astro::Montenbruck::MathUtils qw/frac hms/;
use Astro::Montenbruck::CoCo qw/:all/;
use Astro::Montenbruck::NutEqu qw/obliquity/;
use Astro::Montenbruck::Ephemeris qw/find_positions/;
use Astro::Montenbruck::Ephemeris::Planet qw/@PLANETS/;
use Astro::Montenbruck::Helpers qw/
    parse_datetime parse_geocoords format_geo hms_str dms_or_dec_str dmsz_str
    hms_str $LOCALE/;

my $man    = 0;
my $help   = 0;
my $use_dt = 1;
my $time   = DateTime->now()->set_locale($LOCALE)->strftime('%F %T');
my @place;
my $format = 'S';
my $coords = 1;

sub print_data {
    my ($title, $data) = @_;
    print colored( sprintf('%-20s', $title), 'white' );
    print colored(': ', 'white');
    unless ($data =~ /^[-+]/) {
        $data = " $data";
    }
    say colored( $data, 'bright_white');
}

sub ecliptic_to_horizontal {
    my ($lambda, $beta, $eps, $lst, $theta) = @_;
    my ($alpha, $delta) = ecl2equ( $lambda, $beta, $eps );
    my $h = $lst * 15 - $alpha; # hour angle, arc-degrees
    equ2hor( $h, $delta, $theta);
}

sub convert_lambda {
    my ($target, $dec) = @_;

    given ($target) {
        sub { dms_or_dec_str( $_[0], decimal => $dec ) }
            when 1;
        sub { dmsz_str( $_[0], decimal => $dec ) }
            when 2;
        sub {
            my ($alpha) = ecl2equ( @_[0..2] );
            hms_str( $alpha / 15, decimal => $dec )
        }   when 3;
        sub {
            my ($alpha) = ecl2equ( @_[0..2] );
            dms_or_dec_str( $alpha, decimal => $dec )
        }   when 4;
        sub {
            my ( $az ) = ecliptic_to_horizontal(@_);
            hms_str( $az / 15, decimal => $dec )
        }   when 5;
        sub {
            my ( $az ) = ecliptic_to_horizontal(@_);
            dms_or_dec_str( $az, decimal => $dec )
        }   when 6;
    }
}

sub convert_beta {
    my ($target, $dec) = @_;

    my $format = sub {
        dms_or_dec_str($_[0], decimal => $dec, places => 2, sign => 1)
    };

    given( $target ) {
        sub {  $format->( $_[1] ) }
            when [1, 2];
        sub {
            my ($alpha, $delta) = ecl2equ( @_[0..2] );
            $format->( $delta )
        }  when [3, 4];
        sub {
            my ( $az, $alt ) = ecliptic_to_horizontal(@_);
            $format->( $alt )
        }  when [5, 6];
    }
}

sub print_position {
    my ($id, $lambda, $beta, $delta, $motion, $obliq, $lst, $lat) = @_;
    my $decimal = uc $format eq 'D';

    state $convert_lambda = convert_lambda($coords, $decimal);
    state $convert_beta   = convert_beta($coords, $decimal);
    state $format_motion  = sub {
        dms_or_dec_str($_[0], decimal => uc $format eq 'D', places => 2, sign => 1 );
    };

    print colored( sprintf('%-10s', $id), 'white' );
    print colored( $convert_lambda->($lambda, $beta, $obliq, $lst, $lat), 'bright_yellow' );
    print "   ";
    print colored( $convert_beta->($lambda, $beta, $obliq, $lst, $lat), 'bright_yellow' );
    print "   ";
    print colored( sprintf( '%07.4f', $delta ), 'bright_yellow' );
    print "   ";
    print colored( $format_motion->($motion), 'bright_yellow' );
    print "\n";
}

sub print_header {
    my $target = shift;
    my $tmpl;
    my @titles;
    given ($target) {
        when (1) {
            $tmpl = '%-7s   %-11s   %-10s  %-10s %-10s';
            @titles = qw/planet lambda beta dist motion/
        }
        when (2) {
            $tmpl = '%-7s   %-11s   %-10s  %-10s %-10s';
            @titles = qw/planet zodiac beta dist motion/
        }
        when (3) {
            $tmpl = '%-7s   %-9s   %-10s  %-10s %-10s';
            @titles = qw/planet alpha delta dist motion/
        }
        when (4) {
            $tmpl = '%-7s   %-11s   %-10s  %-10s %-10s';
            @titles = qw/planet alpha delta dist motion/
        }
        when (5) {
            $tmpl = '%-7s   %-10s  %-9s   %-8s   %-10s';
            @titles = qw/planet azimuth altitude dist motion/
        }
        when (6) {
            $tmpl = '%-7s   %-11s   %-9s   %-8s   %-10s';
            @titles = qw/planet azimuth altitude dist motion/
        }
    }
    say colored( sprintf($tmpl, @titles), 'white    ' )
}


# Parse options and print usage if there is a syntax error,
# or if usage was explicitly requested.
GetOptions(
    'help|?'        => \$help,
    'man'           => \$man,
    'time:s'        => \$time,
    'place:s{2}'    => \@place,
    'dt!'           => \$use_dt,
    'format:s'      => \$format,
    'coordinates:i' => \$coords,

) or pod2usage(2);

pod2usage(1) if $help;
pod2usage(-verbose => 2) if $man;


die "Unknown coordinates format: \"$format\"!" unless $format =~ /^D|S$/i;

my $local = parse_datetime($time);
print_data('Local Time', $local->strftime('%F %T %Z'));
my $utc;
if ($local->time_zone ne 'UTC') {
    $utc   = $local->clone->set_time_zone('UTC');
    print_data('Universal Time', $utc->strftime('%F %T'));
} else {
    $utc = $local;
}
print_data('Julian Day', sprintf('%.6f', $utc->jd));

my $t = jd_cent($utc->jd);
if ($use_dt) {
    # Universal -> Dynamic Time
    my $delta_t = delta_t($utc->jd);
    print_data('Delta-T', sprintf('%05.2fs.', $delta_t));
    $t += $delta_t / $SEC_PER_CEN;
}

push @place, ('51N28', '000W00') unless @place;
my ($lat, $lon) = parse_geocoords(@place);
print_data('Place', format_geo($lat, $lon));

# Local Sidereal Time
my $lst = jd2lst($utc->jd, $lon);
print_data('Sidereal Time', hms_str($lst));

# Ecliptic obliquity
my $obliq = obliquity($t);
print_data(
    'Ecliptic Obliquity',
    dms_or_dec_str(
        $obliq,
        places  => 2,
        sign    => 1,
        decimal => $format eq 'D'
    )
);
print "\n";

print_header($coords);
find_positions(
    $t,
    \@PLANETS,
    sub { print_position(@_, $obliq, $lst, $lat) },
    with_motion => 1
);



__END__

=pod

=encoding UTF-8

=head1 NAME

planpos — calculate planetary positions for given time and place.

=head1 SYNOPSIS

  planpos [options]

=head1 OPTIONS

=over 4

=item B<--help>

Prints a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<--time>

Date and time, either a I<calendar entry> in format C<YYYY-MM-DD HH:MM Z> or
C<YYYY-MM-DD HH:MM Z>, or a floating-point I<Julian Day>:

  --datetime "2019-06-08 12:00 +0300"
  --datetime date="2019-06-08 09:00 UTC"
  --datetime date=2458642.875 mode=JD

Calendar entries must be enclosed in quotes. Optional B<"Z"> stands for time
zone, short name or offset from UTC. C<"+00300"> in the example above means
I<"3 hours eastward">.

=item B<--place> — the observer's location. Contains 2 elements:

=over

=item * latitude in C<DD(N|S)MM> format, B<N> for North, B<S> for South.

=item * longitude in C<DDD(W|E)MM> format, B<W> for West, B<E> for East.

=back

E.g.: C<--place=51N28, 0W0> for I<Greenwich, UK>.

=item B<--coordinates> — type and format of coordinates to display:

=over

=item * B<1> — Ecliptical, angular units (default)

=item * B<2> — Ecliptical, zodiac

=item * B<3> — Equatorial, time units

=item * B<4> — Equatorial, angular units

=item * B<5> — Horizontal, time units

=item * B<6> — Horizontal, angular units

=back

=item B<--format> format of numbers:

=over

=item * B<D> decimal: arc-degrees or hours

=item * B<S> sexadecimal: degrees (hours), minutes, seconds

=back

=back

=head1 DESCRIPTION

B<planpos> computes planetary positions for current moment or given
time and place.


=cut
