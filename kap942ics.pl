#!/usr/bin/perl
# geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;

use Data::ICal;
use Data::ICal::Entry::Event;

use utf8;
use warnings;

# KAP94 already provides basic information in ics format via a hidden link
# This script filters out simple "belegt" events, sets location to the full address and adds the description
my $url="http://www.kap94.de/events/?ical=1";

# avoid "wide character" warnings
binmode STDOUT, ":utf8";

my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);

my $kap94calendar=Data::ICal->new(data=>$mech->content());
my $calendar=Data::ICal->new();
$calendar->add_properties(method=>"PUBLISH",
	"X-PUBLISHED-TTL"=>"P1D",
	"X-WR-CALNAME"=>"KAP94",
	"X-WR-CALDESC"=>"KAP94 Veranstaltungen");

foreach my $entry (@{$kap94calendar->entries}) {
    # skip simple "belegt" events
    next if ($entry->property('summary')->[0]->value=~/^belegt$/);

    my $url=$entry->property('url')->[0]->value;
    my $description=$entry->property('description')->[0]->value;
    # if no description but event's url given, get description from url
    if ((!$description) and ($url)) {
	$mech->get($url);
	my $tree=HTML::TreeBuilder->new_from_content($mech->content());
	$entry->add_properties('description'=>join("\n",map { $_->as_trimmed_text(extra_chars=>'\xA0'); } $tree->look_down('_tag'=>'div','id'=>'event-single-content')->find('p')));
    }
    # fix location
    $entry->add_properties('location'	=>"KAP94, Westliche Ringstr. 91, 85049 Ingolstadt");
    $calendar->add_entry($entry);
}

print $calendar->as_string;
