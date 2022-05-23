#!/usr/bin/perl
# 2013,2018,2022 geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;

use DateTime::Format::Strptime;
use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Time::HiRes;

use List::MoreUtils qw(first_index);

use Try::Tiny;

use utf8;
use Data::Dumper;
use warnings;


my $url="https://www.brightyoga.de/offene-stunden-wochenplan/";

my $ort="Bright Yoga, Griesmühlstraße 2, Ingolstadt";
my $beschreibungsUrl="https://www.brightyoga.de/termine/kursbeschreibungen/";


my @dayNames=("sonntag", "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag");
my $today=DateTime->now('time_zone'=>'Europe/Berlin');

binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);


my @eventList;
# alle Tage durchgehen
my $root=HTML::TreeBuilder->new();
$root->ignore_unknown(0);       # "time"-Tag wird sonst nicht erkannt
$root->parse_content($mech->content());


foreach my $column ($root->look_down('_tag'=>'div','class'=>'mptt-column')) {
    # Wochentag
    my $day=$column->look_down('class'=>'mptt-column-title')->as_trimmed_text;

    my $date=$today->clone;
    my $dow=first_index { $_ eq lc($day) } @dayNames;
    $date->add(days=>($dow - $date->day_of_week) %7);

    foreach my $entry ($column->look_down('class'=>'mptt-list-event')) {
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
	$event->{'title'}=$entry->look_down('class'=>'mptt-event-title')->as_trimmed_text;

	# Anmeldelink
	$event->{'url'}=$entry->look_down('class'=>'mptt-event-link')->attr('href');
	# Freie Plätze
	#$event->{'emptyseats'}=$entry->look_down('class'=>'event-attendance')->as_trimmed_text;

	# Anzahl der freien Plätze steht nicht mehr in der Terminübersicht, daher auf Anmeldeseite wechseln
	$mech->get($event->{'url'});
	my $loginRoot=HTML::TreeBuilder->new();
	$loginRoot->ignore_unknown(0);       # "time"-Tag wird sonst nicht erkannt
	$loginRoot->parse_content($mech->content());
	try {
	    $event->{'emptyseats'}=$loginRoot->look_down('_tag'=>'p','class'=>'availability')->as_trimmed_text;
	} catch {
	    # z.B. "Feiertag. Kurs findet nicht statt"
	    # Sicherheitshalbernoch auf "Anmelden"-Knopf prüfen
	    next unless ($mech->find_link(text=>'Anmelden'));
	};

	# Subtitel
	try {
	    $event->{'subtitle'}=$entry->look_down('class'=>'event-subtitle')->as_trimmed_text;
	};
	# User
	$event->{'trainer'}=$entry->look_down('class'=>'event-user')->as_trimmed_text;

	# Stream oder Studio?
	if ($event->{'title'}=~/Stream\)/i) {
	    $event->{'location'}="Livestream";
	    $event->{'emptyseats'}="Ohne Teilnehmerbegrenzung";
	}
	elsif ($event->{'title'}=~/Studio\)/i) {
	    $event->{'location'}="Studio";
	}
	push(@eventList,$event);
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
	dtstart => DateTime::Format::ICal->format_datetime($event->{'start'}->set_time_zone('UTC')),
#	duration=>'PT3H',
	dtend => DateTime::Format::ICal->format_datetime($event->{'end'}->set_time_zone('UTC')),
	dtstamp=>$dstamp,
	class=>"PUBLIC",
        organizer=>'MAILTO:patricia@brightyoga.de',
	location=>$event->{'location'},
	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
