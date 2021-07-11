#!/usr/bin/perl
# geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;

use DateTime;

use Data::ICal;
use Data::ICal::Entry::Event;

use Try::Tiny;

use utf8;
use warnings;

#use Data::Dumper;

# KAP94 already provides basic information in ics format via a hidden link
# This script filters out simple "belegt" events, sets location to the full address and adds the description

my $calendar=Data::ICal->new();
$calendar->add_properties(method=>"PUBLISH",
    "X-PUBLISHED-TTL"=>"P1D",
    "X-WR-CALNAME"=>"KAP94",
    "X-WR-CALDESC"=>"KAP94 Veranstaltungen");

# avoid "wide character" warnings
binmode STDOUT, ":utf8";
my $mech=WWW::Mechanize->new();
my $date=DateTime->now;

my $MAXMONTHS=6;
for (my $month=0;$month<$MAXMONTHS;$month++) {
    my $url="http://www.kap94.de/events/".$date->strftime("%Y-%m")."/?ical=1";

    $mech->get($url) or die($!);
    #print $url."\n";

    my $kap94calendar=Data::ICal->new(data=>$mech->content());
    foreach my $entry (@{$kap94calendar->entries}) {

	# skip entries without data
	unless (($entry->property('summary')) and ($entry->property('url')) and ($entry->property('description'))) {
	    #print Dumper $entry;
	    #exit;
	    next;
	}

	# skip simple "belegt" events
	next if ($entry->property('summary')->[0]->value=~/^belegt$/);

	my $url=$entry->property('url')->[0]->value;
	
	my $description=$entry->property('description')->[0]->value;
	# if no description but event's url given, get description from url
	if ((!$description) and ($url)) {
	    try {
		$mech->get($url);
		my $tree=HTML::TreeBuilder->new_from_content($mech->content());
		$entry->add_properties(
		    'description'=>join("\n", map { $_->as_trimmed_text(extra_chars=>'\xA0'); } $tree->look_down('_tag'=>'div','id'=>'event-single-content')->find('p'))
		);
	    };
	}
        # fix location
	$entry->add_properties('location'=>"KAP94, Jahnstr. 1a, 85049 Ingolstadt");
	$calendar->add_entry($entry);
    }
    $date->add(months=>1);
}

print $calendar->as_string;
