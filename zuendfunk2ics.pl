#!/usr/bin/perl
# 2013,2018 geierb@geierb.de
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

use utf8;
use warnings;

my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)

my $url="http://www.br.de/radio/bayern2/sendungen/zuendfunk/veranstaltungen-praesentationen/index.html";

# Gegen "wide character"-Warnungen
binmode STDOUT, ":utf8";

my $datumZeitFormat=DateTime::Format::Strptime->new('pattern'=>'%A, %d. %B %Y, %H:%M Uhr','time_zone'=>'Europe/Berlin','locale'=>'de_DE');

my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);

my @events;
foreach my $monthPage ($mech->find_all_links(text=>'Alle Termine des Monats')) {
    $mech->get($monthPage);

    my $tree=HTML::TreeBuilder->new_from_content($mech->content());
    my @eventTrees=$tree->look_down('_tag'=>'div','class'=>'detail_calendar_item');

    foreach my $event (@eventTrees) {
	my $e;

	# Kurztext
	$e->{'kurztext'}=($event->look_down('_tag'=>'p','class'=>'calendar_text'))->as_trimmed_text;

	# Beginn
	my $datumZeit=($event->look_down('_tag'=>'p','class'=>'calendar_time'))->as_trimmed_text;
	$e->{'beginn'}=$datumZeitFormat->parse_datetime($datumZeit);
	$e->{'beginn'}=$datumZeitFormat->parse_datetime($datumZeit.", 20:00 Uhr") unless ($e->{'beginn'});	# wenn keine uhrzeit angegeben: 20:00 als start annehmen

	# Ende=Beginn+3h
	$e->{'ende'}=$e->{'beginn'}->clone();
	$e->{'ende'}->add(minutes=>$defaultDauer);

	my $calendar_headlineTree=$event->look_down('class'=>'calendar_headline');
	# Link
	my ($link)=($mech->uri=~m[(^http://[^/]+)/]);
	$link.=($calendar_headlineTree->look_down('_tag'=>'a'))->attr('href');
	$e->{'url'}=$link;
	# Ort
	$e->{'ort'}=($calendar_headlineTree->look_down('_tag'=>'span','class'=>'calendar_overline'))->as_trimmed_text;
	# Name
	$e->{'name'}=($calendar_headlineTree->look_down('_tag'=>'span','class'=>'calendar_title'))->as_trimmed_text;

	push(@events,$e);
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
	"X-PUBLISHED-TTL"=>"P1D",
	"X-WR-CALNAME"=>"Zündfunk",
	"X-WR-CALDESC"=>"Zündfunk Veranstaltungstipps");

my $count=0;
foreach my $event (@events) {
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);


    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'name'},
	description => $event->{'kurztext'},
	dtstart => DateTime::Format::ICal->format_datetime(
	    DateTime->new(
		year=>$event->{'beginn'}->year,
		month=>$event->{'beginn'}->month,
		day=>$event->{'beginn'}->day,
		hour=>$event->{'beginn'}->hour,
		minute=>$event->{'beginn'}->min,
		second=>0,
		time_zone=>'Europe/Berlin'
	    )
	),
#	duration=>'PT3H',
	dtend => DateTime::Format::ICal->format_datetime(
	    DateTime->new(
		year=>$event->{'ende'}->year,
		month=>$event->{'ende'}->month,
		day=>$event->{'ende'}->day,
		hour=>$event->{'ende'}->hour,
		minute=>$event->{'ende'}->min,
		second=>0,
		time_zone=>'Europe/Berlin'
	    )
	),
	dtstamp=>$dstamp,
	class=>"PUBLIC",
        organizer=>"MAILTO:foobar",
	location=>$event->{'ort'},
	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}

print $calendar->as_string;
