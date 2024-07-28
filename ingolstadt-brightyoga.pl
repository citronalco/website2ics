#!/usr/bin/perl
# 2013,2018,2022 geierb@geierb.de
# AGPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;

use DateTime::Format::Strptime;
use DateTime::Format::ICal;
use DateTime::Format::ISO8601;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::Entry::TimeZone;
use Data::ICal::Entry::TimeZone::Daylight;
use Data::ICal::Entry::TimeZone::Standard;

use Time::HiRes;

use List::MoreUtils qw(first_index);

use Try::Tiny;

use utf8;
use Data::Dumper;
use warnings;


my @urls=(
    { 'url' => "https://www.brightyoga.de/offene-stunden-wochenplan/", 'ort' => "Bright Yoga, Griesmühlstraße 2, Ingolstadt" },
    { 'url' => "https://www.brightyoga.de/offene-stunden-wochenplan-stream/", 'ort' => "Livestream" } );

my $beschreibungsUrl="https://www.brightyoga.de/termine/kursbeschreibungen/";

my $ajaxUrl="https://www.brightyoga.de/wp-admin/admin-ajax.php";


my @dayNames=("sonntag", "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag");
my $today=DateTime->now('time_zone'=>'Europe/Berlin');
my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H:%M','time_zone'=>'Europe/Berlin');
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

my @eventList;
foreach my $u (@urls) {
    $mech->get($u->{'url'}) or die($!);

    my $root=HTML::TreeBuilder->new();
    $root->ignore_unknown(0);       # "time"-Tag wird sonst nicht erkannt
    $root->parse_content($mech->content());

    # "Category" rausfinden
    my $category=$root->look_down('_tag'=>'div', class=>'cbs-pagination')->look_down('_tag'=>'a')->attr('data-category');

    # Kalenderseite holen
    $mech->get($ajaxUrl."?action=cbs_action_week&category=".$category);

    # Kalenderseite auswerten
    $root->parse_content($mech->content());
    # alle Tage durchgehen
    foreach my $column ($root->look_down('_tag'=>'div','class'=>'cbs-timetable-column')) {
	# "Wochentag"
	#my $day=$column->look_down('class'=>'cbs-timetable-column-title')->as_trimmed_text;
	#my $date=$today->clone;
	#my $dow=first_index { $_ eq lc($day) } @dayNames;
	#$date->add(days=>($dow - $date->day_of_week) %7);

	# "Wochentag (DD.MM.YYYY)
	my $dmy=$column->look_down('class'=>'cbs-timetable-column')->look_down('_tag'=>'time')->attr('datetime');
	my $date=DateTime::Format::ISO8601->parse_datetime($dmy);

	foreach my $entry ($column->look_down('_tag'=>'li')) {
	    my $event;

	    # Beginn
	    my $startTime=$entry->look_down('class'=>'timeslot-start')->as_trimmed_text;
	    $startTime=~/(\d+).(\d+)/;
	    $event->{'start'}=$date->clone;
	    $event->{'start'}->set_hour($1);
	    $event->{'start'}->set_minute($2);
	    $event->{'start'}->set_second(0);

	    # Ende
	    my $endTime=$entry->look_down('class'=>'timeslot-end')->as_trimmed_text;
	    $endTime=~/(\d+).(\d+)/;
	    $event->{'end'}=$date->clone;
	    $event->{'end'}->set_hour($1);
	    $event->{'end'}->set_minute($2);
	    $event->{'end'}->set_second(0);

	    # Titel
	    $event->{'title'}=$entry->look_down('_tag'=>'a')->attr('title');

	    # Anmeldelink
	    $event->{'url'}=$entry->look_down('_tag'=>'a')->attr('href');

	    # Freie Plätze
	    #$event->{'emptyseats'}=$entry->look_down('class'=>'event-attendance')->as_trimmed_text;

	    # Anzahl der freien Plätze steht nicht mehr in der Terminübersicht, daher auf Anmeldeseite wechseln
	    $mech->get($event->{'url'});
	    my $loginRoot=HTML::TreeBuilder->new();
	    $loginRoot->ignore_unknown(0);       # "time"-Tag wird sonst nicht erkannt
	    $loginRoot->parse_content($mech->content());

	    # Spalte mit passendem Datum suchen
	    my @spalten=$loginRoot->look_down('_tag'=>'div','class'=>'slide');
	    foreach my $spalte (@spalten) {

		# "MONTAG, 15.3.2022"
		my $datestring=$spalte->look_down('_tag'=>'h3')->as_trimmed_text;
		$datestring=~s/(^\D+,\s+)//;

		my $columndate=$datumFormat->parse_datetime($datestring." 00:00");
		if ($event->{'start'}->ymd eq $columndate->ymd) {
		    try {
			# Abgesagte Veranstaltungen haben keine availability
			$event->{'emptyseats'}=$spalte->look_down('_tag'=>'p','class'=>'availability')->as_trimmed_text;
		    }
		    catch { };
		    last;
		}
	    }
	    next unless defined($event->{'emptyseats'});

	    # Subtitel
	    try {
		$event->{'subtitle'}=$entry->look_down('class'=>'event-subtitle')->as_trimmed_text;
	    };
	    # User
	    $event->{'trainer'}=$entry->look_down('class'=>qr/trainer.*/)->as_trimmed_text;

	    # Stream oder Studio?
	    $event->{'location'}=$u->{'ort'};
	    if ($event->{'location'}=~/Livestream/) {
		$event->{'emptyseats'}="Ohne Teilnehmerbegrenzung";
	    }

	    # Keine doppelten Einträge erzeugen
	    my $identical=0;
	    foreach my $e (@eventList) {
		$identical=1;
		foreach my $k (keys %$e) {
		    if ($e->{$k} ne $event->{$k}) {
			$identical=0;
			last;
		    }
		}
		last if ($identical==1);
	    }
	    push(@eventList,$event) if ($identical==0);
	}
    }
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
	"X-PUBLISHED-TTL"=>"PT1H",
	"X-WR-CALNAME"=>"Bright Yoga",
	"X-WR-CALDESC"=>"Offene Stunden bei Bright Yoga");

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
    # Build description
    my @desc;
    push(@desc, $event->{'subtitle'}) if ($event->{'subtitle'});
    push(@desc, "Mit <b>".$event->{'trainer'}."</b>") if ($event->{'trainer'});
    push(@desc, $event->{'emptyseats'}) if ($event->{'emptyseats'});
    push(@desc, "<a href='".$beschreibungsUrl."'>Beschreibung</a> <a href='".$event->{'url'}."'>Anmeldung</a>");
    my $description=join("<p/>",@desc);

    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'title'},
	description => $description,
	dtstart => ($event->{'fullday'}) ? dt2icaldt_fullday($event->{'start'}) : dt2icaldt($event->{'start'}),
	dtend => ($event->{'fullday'}) ? dt2icaldt_fullday($event->{'end'}) : dt2icaldt($event->{'end'}),
	dtstamp=>$dstamp,
	class=>"PUBLIC",
	organizer=>'MAILTO:patricia@brightyoga.de',
	location=>$event->{'location'},
	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}

die("Keine Einträge") if (($count==0) and not (($today->month==12 and $today->day>20) or ($today->month==1 and $today->day<10)));

print $calendar->as_string;
