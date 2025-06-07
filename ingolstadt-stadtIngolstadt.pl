#!/usr/bin/perl
# 2025 geierb@geierb.de
# AGPLv3

use strict;
use warnings;
use utf8;

use WWW::Mechanize;

use JSON;
use DateTime::Format::ISO8601;
use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::Entry::TimeZone;
use Data::ICal::Entry::TimeZone::Daylight;
use Data::ICal::Entry::TimeZone::Standard;

use Data::Dumper;
use Try::Tiny;


binmode STDOUT, ":utf8";

my $url="https://www.ingolstadt.live/entdecken-erleben/events-touren/eventkalender/?date=thisMonth";

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

$mech->get($url) or die($!);
my ($eventJSON)=$mech->content()=~/<script>self\.__next_f\.push\(\[1,\"(\[\{\\"\@context\\":\\"https:\/\/schema\.org\\",\\"\@type\\":\\"Event\\".+?)\"\]\)<\/script>/;

$eventJSON=~s/\\"/\"/g;
$eventJSON=~s/\\{2}/\\/g;
my $data=decode_json(Encode::encode("utf-8",$eventJSON));

my @eventList;
foreach my $item (@{$data}) {
    #print Dumper $item;

    my $event;
    $event->{'titel'} = $item->{'name'};

    # fix startDate
    my $startDate=$item->{'startDate'};
    if ($startDate=~/^\d{4}\-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/) {
	# 2025-05-21T20:00:00 -> ok
    }
    elsif ($startDate=~/^\d{4}\-\d{2}-\d{2}T\d{2}:\d{2}$/) {
	# 2025-05-21T20:00 -> ok
    }
    elsif ($startDate=~/^(\d{4}\-\d{2}-\d{2})T\d{2}:\d{2}:\d{2}\.000ZT(\d{2}:\d{2})$/) {
	# 2025-05-21T22:00:00.000ZT10:30 -> 10:30
	$startDate=$1."T".$2;
    }
    elsif ($startDate=~/^(\d{4}\-\d{2}-\d{2})T\d{2}:\d{2}:\d{2}\+00:00T(\d{2}:\d{2})$/) {
	# 2025-05-22T10:00:00+00:00T20:00 -> 20:00
	$startDate=$1."T".$2;
    }
    elsif ($startDate=~/^(\d{4}\-\d{2}-\d{2})T\d{2}:\d{2}:\d{2}T(\d{2}:\d{2})$/) {
	#2025-05-17T15:00:00T15:00 -> 15:00
	$startDate=$1."T".$2;
    }
    else {
	print "Unbekanntes Datumsformat: ".$item->{'startDate'}." \t".$item->{'name'}."\n";
    }
    $event->{'beginn'} = DateTime::Format::ISO8601->parse_datetime($startDate);

    $event->{'beschreibung'} = $item->{'description'};
    $event->{'veranstalter'} = $item->{'organizer'}->{'name'};

    if ($item->{'isAccessibleForFree'}) {
	$event->{'preis'} = "kostenlos";
    }
    else {
	$event->{'preis'} = $item->{'offers'}[0]->{'price'}." ".$item->{'offers'}[0]->{'priceCurrency'};
    }

    try {
	$event->{'vvkUrl'} = $item->{'offers'}[0]->{'url'};
    };

    unless ($item->{'location'}->{'address'}->{'streetAddress'}=~/^undefined undefined$/) {
	$event->{'ort'} = $item->{'location'}->{'name'}.", ".
	    $item->{'location'}->{'address'}->{'streetAddress'}.", ".
	    $item->{'location'}->{'address'}->{'postalCode'}." ".
	    $item->{'location'}->{'address'}->{'addressLocality'};
    }

    push(@eventList, $event);
}

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
    "X-WR-CALNAME"=>"Ingolstadt",
    "X-WR-CALDESC"=>"Veranstaltungskalender Ingolstadt.live",
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

    $event->{'ende'}=$event->{'beginn'}->clone();
    $event->{'ende'}->add(minutes=>120);

    my $description;
    $description.= $event->{'beschreibung'}." \n\n" if ($event->{'beschreibung'});

    if ($event->{'preis'}=~"kostenlos") { $description.="Eintritt kostenlos\n"; }
    else { $description.="Tickets: ".$event->{'preis'}."\n"; }

    $description.="Vorverkauf: ".$event->{'vvkUrl'}."\n" if ($event->{'vvkUrl'});
    $description.="Veranstalter: ".$event->{'veranstalter'} if ($event->{'veranstalter'});


    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
        uid=>$uid,
        summary => $event->{'titel'},
        description => $description,
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
