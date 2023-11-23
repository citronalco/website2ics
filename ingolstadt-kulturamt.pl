#!/usr/bin/perl
# geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;

use DateTime;

use Data::ICal;
use Data::ICal::Entry::Event;

use utf8;
use warnings;

# Kulturamt Ingolstadt already provides basic information in ics format, but only for single months

my $calendar=Data::ICal->new();
$calendar->add_properties(method=>"PUBLISH",
    "X-PUBLISHED-TTL"=>"P1D",
    "X-WR-CALNAME"=>"Kulturamt Ingolstadt",
    "X-WR-CALDESC"=>"Kulturamt Ingolstadt Veranstaltungen");

# avoid "wide character" warnings
binmode STDOUT, ":utf8";
my $mech=WWW::Mechanize->new();

my $date=DateTime->now;
my $MAXMONTHS=12;
for (my $month=0;$month<$MAXMONTHS;$month++) {
    my $url="https://www.kulturamt-ingolstadt.de/veranstaltungen/monat/".$date->strftime("%Y-%m")."/?ical=1";

    $mech->get($url) or die($!);

    # Data::ICal::Entry does not understand REFRESH-INTERVAL, so filter that out
    my @filtered;
    my @lines=split /\n/, $mech->content();
    foreach (@lines) {
	push(@filtered,$_) unless $_=~/^refresh-interval/i;
    }

    my $kaCalendar=Data::ICal->new(data=>join("\n", @filtered));
    # if there are no events this month, no ical without entries, but unfortunately an empty document is returned
    next unless $kaCalendar;

    foreach my $entry (@{$kaCalendar->entries}) {
	$calendar->add_entry($entry);
    }
    $date->add(months=>1);
}

print $calendar->as_string;
