#!/usr/bin/perl
# 2015 geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;

use DateTime::Format::Strptime;
use Data::ICal;
use Data::ICal::Entry::Event;
use Date::ICal;
use Time::HiRes;

use Try::Tiny;

use utf8;
use Data::Dumper;
use warnings;


my $defaultDauer=119;	# angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)
my $url="http://www.neun-ingolstadt.de/programm/";


my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d-%m-%Y %H:%M','time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);

# alle links aus dem Kalender auslesen
my @eventLinks=$mech->find_all_links(text=>'MEHR INFORMATIONEN');

my @events;
foreach my $eventLink (@eventLinks) {
    my $event;
    $mech->get($eventLink);
    my $root=HTML::TreeBuilder->new_from_content($mech->content());

    my $tree=$root->look_down('_tag'=>'div','id'=>'content');

    #### linke Spalte
    my $h=$tree->look_down('_tag'=>'div',class=>'programmMeta') or die();

    # Datum
    ($event->{'datum'})=$h->as_trimmed_text()=~/^(\d{2}-\d{2}-\d{4})/;

    # Einlass
    if (my ($einlass)=$h->as_trimmed_text()=~/Einlass (\d{2}:\d{2}) Uhr/) {
	if (($einlass) and ($einlass=~/24:00/)) {
	    $event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." 00:00 Uhr");
	    $event->{'einlass'}->add(days=>1);
	}
	else {
	    $event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." ".$einlass);
	}
    }

    # Beginn
    if (my ($beginn)=$h->as_trimmed_text()=~/Beginn (\d{2}:\d{2}) Uhr/) {
	if (($beginn) and ($beginn=~/24:00/)) {
	    $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." 00:00 Uhr");
	    $event->{'beginn'}->add(days=>1);
	}
	else {
	    $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$beginn);
	}
    }

    #### rechte Spalte
    $h=$root->look_down('class'=>'articleContent') or die();
    # Name
    $event->{'name'}=$h->look_down('_tag'=>'h2')->as_trimmed_text();

    # beschreibung
    ($event->{'description'})=$h->as_trimmed_text();
    $event->{'description'}=~s/^\s*$event->{'name'}\s*$//;	# todo: name ist immer noch in der beschtreibung!!! besser führendes <h2>..</h2> raus!

    # URL
    $event->{'url'}=		($mech->uri())->as_string;

    # Ort
    $event->{'ort'}=		"Kulturzentrum neun, Elisabethstr. 9a, 85051 Ingolstadt";

    # Prüfen ob alle nötig Infos da
#    unless ($event->{'datum'} && $event->{'name'} && $event->{'description'} && $event->{'datum'}) {
#	print STDERR Dumper $event;
#	exit;
#    }

#    print STDERR Dumper $event;
    push(@events,$event);
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
	"X-WR-CALNAME"=>"Kulturzentrum neun",
	"X-WR-CALDESC"=>"Veranstaltungen Kulturzentrum neun");

my $count=0;
foreach my $event (@events) {

#    if ($event->{'einlass'}) { print STDERR $event->{'name'}.": ".$event->{'einlass'}."\n"; }


    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);


    $event->{'datum'}=~/(\d\d)\-(\d\d)\-(\d\d\d\d)/;

    # wenn weder beginn noch einlass gegeben ist ganztages-event bauen
    my $startTime="$3$2$1";
    my $endTime=$startTime;

    if ($event->{'beginn'}) {
	$startTime=Date::ICal->new(
	    year=>$event->{'beginn'}->year,
	    month=>$event->{'beginn'}->month,
	    day=>$event->{'beginn'}->day,
	    hour=>$event->{'beginn'}->hour,
	    min=>$event->{'beginn'}->min,
	    sec=>0
	)->ical;
	$event->{'description'}="Beginn: ".$event->{'beginn'}->hour.":".$event->{'beginn'}->min." Uhr ".$event->{'description'};
	$event->{'ende'}=$event->{'beginn'}->clone();
	$event->{'ende'}->add(minutes=>$defaultDauer);
    }
    elsif ($event->{'einlass'}) {
	$startTime=Date::ICal->new(
	    year=>$event->{'einlass'}->year,
	    month=>$event->{'einlass'}->month,
	    day=>$event->{'einlass'}->day,
	    hour=>$event->{'einlass'}->hour,
	    min=>$event->{'einlass'}->min,
	    sec=>0
	)->ical;
	$event->{'description'}="Einlass: ".$event->{'einlass'}->hour.":".$event->{'einlass'}->min." Uhr ".$event->{'description'};
	$event->{'ende'}=$event->{'einlass'}->clone();
	$event->{'ende'}->add(minutes=>$defaultDauer);
    }

    if ($event->{'ende'}) {
	$endTime=Date::ICal->new(
	    year=>$event->{'ende'}->year,
	    month=>$event->{'ende'}->month,
	    day=>$event->{'ende'}->day,
	    hour=>$event->{'ende'}->hour,
	    min=>$event->{'ende'}->min,
	    sec=>0
	)->ical;
    }

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'name'},
	description => $event->{'description'},
#	dtstart=>$startTime->ical,
#	dtend=>$endTime->ical,
	dtstart=>$startTime,
	dtend=>$endTime,
#	duration=>"PT3H",
	dtstamp=>$dstamp,
	class=>"PUBLIC",
	location=>$event->{'ort'},
	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}

print $calendar->as_string;

