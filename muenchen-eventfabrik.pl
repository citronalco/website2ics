#!/usr/bin/perl
# 2024 geierb@geierb.de
# AGPLv3

use strict;
use warnings;
use utf8;

use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;

use JSON;
use DateTime::Format::ISO8601;
use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::Entry::TimeZone;
use Data::ICal::Entry::TimeZone::Daylight;
use Data::ICal::Entry::TimeZone::Standard;

#use Data::Dumper;

binmode STDOUT, ":utf8";

my $url="https://www.eventfabrik-muenchen.de/events/page/";

# Function: convert datetime to DTSTART/DTEND property value
sub dt2icaldt {
    my ($dt)=@_;
    my $icalformatdt=DateTime::Format::ICal->format_datetime($dt);
    if (my ($id,$string)=$icalformatdt=~/^TZID=(.+?):(.+)$/) {
        return [ $string, {TZID => $id} ];
    }
    else {
        return $icalformatdt;
    }
}

my $mech=WWW::Mechanize->new(autocheck => 0);
my $page=1;

# Mapping location-Url zu Location-Name
my %orte;
$mech->get($url.$page."/");
my $root=HTML::TreeBuilder->new_from_content($mech->content())
    ->look_down('_tag'=>'a', 'href'=>"https://www.eventfabrik-muenchen.de/eventlocations/", sub{$_[0]->as_trimmed_text()=~/^Locations$/})
    ->look_up('_tag'=>'li')
    ->look_down('_tag'=>'ul');

foreach my $item ($root->look_down('_tag'=>'li')) {
    my $link=$item->look_down('_tag'=>'a');

    $orte{$link->attr('href')."#location"}=$link->as_trimmed_text;
}

# run through all pages
my @eventList;
while ($mech->status == 200) {
    $mech->get($url.$page."/") or die($!);

    # extract yoast-schema-graph
    my $root=HTML::TreeBuilder->new_from_content($mech->content())
	->look_down('_tag'=>'head')
	->look_down('_tag'=>'script', 'type'=>'application/ld+json', 'class'=>'yoast-schema-graph');
    my $data = JSON->new->decode(@{$root->content}[0]);

    foreach my $item (@{$data->{'@graph'}}) {
	next unless $item->{'@type'} eq 'Event';

	my $event;
	$event->{'url'} = $item->{'url'};
	$event->{'einlass'} = DateTime::Format::ISO8601->parse_datetime($item->{'doorTime'});
	$event->{'beginn'} = DateTime::Format::ISO8601->parse_datetime($item->{'startDate'});
	$event->{'ende'} = DateTime::Format::ISO8601->parse_datetime($item->{'endDate'});
	$event->{'titel'} = $item->{'name'};
	$event->{'beschreibung'} = $item->{'description'};
	$event->{'preis'} = $item->{'offers'}->{'price'}." ".$item->{'offers'}->{'priceCurrency'};
	$event->{'vvkUrl'} = $item->{'offers'}->{'url'};
	$event->{'veranstalter'} = $item->{'organizer'}[0]->{'name'};
	if ($item->{'location'}[0]->{'id'}) {
	    $event->{'ort'} = $orte{$item->{'location'}[0]->{'id'}};
	}
	else { $event->{'ort'} = ""; }

	push(@eventList,$event);
    };
    $page++;
    $mech->get($url.$page."/");
};

# Create Datestamp for dtstamp
my @stamp=localtime;
my $dtstamp = sprintf("%d%02d%02dT%02d%02d%02dZ",
    $stamp[5] + 1900,
    $stamp[4] + 1,
    $stamp[3],
    $stamp[2],
    $stamp[1],
    $stamp[0]);

my $calendar=Data::ICal->new();
$calendar->add_properties(
    method=>"PUBLISH",
    "X-PUBLISHED-TTL"=>"P1D",
    "X-WR-CALNAME"=>"Eventfabrik München",
    "X-WR-CALDESC"=>"Veranstaltungen handWERK, Mariss-Jansons-Platz, Container Collective, Knödelplatz, WERK7 Theater, Technikum, TonHalle",
);

# Add VTIMEZONE
my $tz="Europe/Berlin";
my $vtimezone=Data::ICal::Entry::TimeZone->new();
$vtimezone->add_properties(tzid=>$tz);

my $tzDaylight=Data::ICal::Entry::TimeZone::Daylight->new();
$tzDaylight->add_properties(
    tzoffsetfrom => "+0100",
    tzoffsetto  => "+0200",
    dtstart     => "19700329T020000",
    tzname      => "CEST",
    rrule       => "FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU"
);
$vtimezone->add_entry($tzDaylight);

my $tzStandard=Data::ICal::Entry::TimeZone::Standard->new();
$tzStandard->add_properties(
    tzoffsetfrom => "+0200",
    tzoffsetto  => "+0100",
    dtstart     => "19701025T030000",
    tzname      => "CET",
    rrule       => "FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"
);
$vtimezone->add_entry($tzStandard);

$calendar->add_entry($vtimezone);


my $count=0;
foreach my $event (@eventList) {
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
        uid=>$uid,
        summary => $event->{'titel'},
        description => $event->{'beschreibung'}." \n\n"
	    ."Tickets: ".$event->{'preis'}." (".$event->{'vvkUrl'}.") \n"
	    ."Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute)." \n\n"
	    ."Veranstalter: ".$event->{'veranstalter'},
        dtstart => dt2icaldt($event->{'beginn'}),
#       duration=>'PT3H',
        dtend => dt2icaldt($event->{'ende'}),
        dtstamp=>$dtstamp,
        class=>"PUBLIC",
        organizer=>"MAILTO:foobar",
        location=>$event->{'ort'},
        url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
