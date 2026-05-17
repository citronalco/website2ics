#!/usr/bin/perl
# 2022 geierb@geierb.de
# AGPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;
use HTML::Strip;

use DateTime::Format::Strptime;
use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::Entry::TimeZone;
use Data::ICal::Entry::TimeZone::Daylight;
use Data::ICal::Entry::TimeZone::Standard;

use Time::HiRes;

use Try::Tiny;
use List::MoreUtils qw(first_index);

use utf8;
use Data::Dumper;
use warnings;

use JSON;

my $htmlStripper=HTML::Strip->new();
my $url="https://backstage.eu";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)

my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%FT%T%z', 'time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

# convert datetime to DTSTART/DTEND property value
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

# convert datetime to DTSTART/DTEND property value for allday events
sub dt2icaldt_fullday {
    my ($dt)=@_;
    return [ $dt->ymd(''),{VALUE=>'DATE'} ];
}


my $mech=WWW::Mechanize->new();
$mech->get($url."/events");

my @eventJSONs=$mech->content()=~/(\{\\"event_id\\":.*?\\"has_seating_plan\\":\w+\})/g;

my @eventList;
foreach my $eventJSON (@eventJSONs) {
    $eventJSON=~s/\\"/\"/g;
    $eventJSON=~s/\\{2}/\\/g;
    my $eventDict=decode_json(Encode::encode("utf-8",$eventJSON));

    my $event;
    next if ($eventDict->{'cancelled'});


    $event->{'ort'} = $eventDict->{'location_name'};
    $event->{'titel'} = $eventDict->{'title'};
    $event->{'titel2'} = $eventDict->{'subtitle'};
    $event->{'kategorie'} = $eventDict->{'category'};
    #$event->{'vorverlauf_aktiv'} = $eventDict->{'presale_active'} ? 1 : 0;
    $event->{'beginn'} = $datumFormat->parse_datetime($eventDict->{'start_time'});
    $event->{'event_id'} = $eventDict->{'event_id'};
    $event->{'image_url'} = $eventDict->{'main_image_path'};


    # mehr Details gibt's auf der Seite des Events
    $event->{'url'}=$url.'/event/'.$event->{'event_id'};

    $mech->get($event->{'url'});
    my ($thisEventJSON)=$mech->content()=~/{\\"data\\":(\{\\"event_id\\":.*\}),\\"descriptionHtml/;
    $thisEventJSON=~s/\\"/\"/g;
    $thisEventJSON=~s/\\{2}/\\/g;
    my $thisEventDict=decode_json(Encode::encode("utf-8",$thisEventJSON));

    $event->{'einlass'} = $datumFormat->parse_datetime($thisEventDict->{'admission_time'});
    $event->{'headline'} = $thisEventDict->{'headline'};
    $event->{'filter_category'} = $thisEventDict->{'filter_category'};
    #$event->{'prices'} = $thisEventDict->{'prices'};	# Steht da was?? NEIN
    $event->{'tickets'} = $thisEventDict->{'external_ticket_links'};


    # Wenn Einlass oder Beginn fehlt: Jeweils durch das Andere ersetzen
    $event->{'einlass'} = $event->{'beginn'}->clone() unless ($event->{'einlass'});
    $event->{'beginn'} = $event->{'einlass'}->clone() unless ($event->{'beginn'});

    # Ende
    $event->{'ende'}=$event->{'beginn'}->clone();
    $event->{'ende'}->add(minutes=>$defaultDauer);

    push(@eventList,$event);
}

# Create Datestamp for dtstamp
my @stamp=localtime;
my $dstamp = sprintf("%d%02d%02dT%02d%02d%02dZ",
    $stamp[5] + 1900,
    $stamp[4] + 1,
    $stamp[3],
    $stamp[2],
    $stamp[1],
    $stamp[0]);

my $calendar=Data::ICal->new();
$calendar->add_properties(method=>"PUBLISH",
        "X-PUBLISHED-TTL"=>"P1D",
        "X-WR-CALNAME"=>"Backstage",
        "X-WR-CALDESC"=>"Veranstaltungen Backstage");

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

    my $description;
    if ($event->{'titel2'})
        { $description.=$event->{'titel2'}." \n\n"; }
    if ($event->{'headline'})
        { $description.=$event->{'headline'}." \n"; }
    if (scalar($event->{'tickets'}) gt 0)
        { foreach (@{$event->{'tickets'}}) { $description.=$_->{'url'}." \n"; }}
    if ($event->{'einlass'})
        { $description.="Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute)." \n"; }

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
        uid=>$uid,
        summary => $event->{'titel'},
        description => $description,
        categories => $event->{'kategorie'},
        dtstart => dt2icaldt($event->{'beginn'}),
        dtend => dt2icaldt($event->{'ende'}),
        dtstamp => $dstamp,
        class => "PUBLIC",
        organizer => "MAILTO:foobar",
        location => $event->{'ort'},
        url => $event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
