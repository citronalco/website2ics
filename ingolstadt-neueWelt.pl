#!/usr/bin/perl
# 2024 geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;
use HTML::TreeBuilder;

use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::Entry::TimeZone;
use Data::ICal::Entry::TimeZone::Daylight;
use Data::ICal::Entry::TimeZone::Standard;

use Try::Tiny;

use utf8;
#use Data::Dumper;
use warnings;


my $url="https://www.neuewelt-ingolstadt.de/";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)

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
$mech->get($url);
my $root=HTML::TreeBuilder->new_from_content($mech->content());
my $programm=$root->look_down('_tag'=>'div', 'id'=>'content');

my @eventList;
for my $vevent ($programm->look_down('_tag'=>'div', 'class'=>'zeile')) {
    my $event;

    # Ort
    $event->{'ort'}="Neue Welt, Griesbadgasse 7, 85049 Ingolstadt";

    # Datum steht im id-Tag
    my ($day, $month, $year) = $vevent->{'id'}=~/^(\d{2})(\d{2})(\d{4})_/;

    # URL
    $event->{'url'} = $url.'#'.$vevent->{'id'};

    my $spalte_content = $vevent->look_down('_tag'=>'div', 'class'=>'spalte_content');

    # Titel
    $event->{'titel'} = $spalte_content->look_down('_tag'=>'h3')->as_trimmed_text;

    # Beschreibung
    my @info = $spalte_content->look_down('_tag'=>'div')->look_down('_tag'=>'div', 'id'=>qr/^\d+$/)->descendants();
    $event->{'beschreibung'} = join("\n", map { $_->as_trimmed_text } @info );
    # Beschreibungstext filtern
    $event->{'beschreibung'} =~s/\[Zuklappen\]//;
    $event->{'beschreibung'} =~s/^\n*//g;
    $event->{'beschreibung'} =~s/\n*$//g;

    # Einlass
    if ($event->{'beschreibung'}=~/Einlass: (\d+)\D?(\d*) Uhr/) {
	$event->{'einlass'}=DateTime->new(year=>$year, month=>$month, day=>$day, hour=>0, minute=>0, time_zone=>'Europe/Berlin');
	if ($1) {
	    $event->{'einlass'}->set_hour($1);
	}
	if ($2) {
	    $event->{'einlass'}->set_minute($2);
	}
    }

    # Beginn
    if ($event->{'beschreibung'}=~/Beginn: (\d+)\D?(\d*) Uhr/) {
	$event->{'beginn'}=DateTime->new(year=>$year, month=>$month, day=>$day, hour=>0, minute=>0, time_zone=>'Europe/Berlin');
	if ($1) {
	    $event->{'beginn'}->set_hour($1);
	}
	if ($2) {
	    $event->{'beginn'}->set_minute($2);
	}
    }

    # Wenn Einlass oder Beginn fehlt: Jeweils durch das Andere ersetzen
    $event->{'einlass'} = $event->{'beginn'}->clone() unless ($event->{'einlass'});
    $event->{'beginn'} = $event->{'einlass'}->clone() unless ($event->{'beginn'});

    # VVK-Link
    try {
	$event->{'ticketUrl'} = $spalte_content->look_down('_tag'=>'a', sub{$_[0]->as_trimmed_text()=~/Jetzt den Online-VVK nutzen/})->attr('href');
    };

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

    my $description = $event->{'beschreibung'};
    if ($event->{'ticketUrl'}) {
	$description.="\n\n".$event->{'ticketUrl'};
    }

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
