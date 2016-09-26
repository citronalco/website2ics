#!/usr/bin/perl
# 2015 geierb@geierb.de
# GPLv3

# Todo: beginn, einlass, titel und kurzinfo von programmübersicht laden.

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


my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H:%M','time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);


my @events;

my $programmTree=HTML::TreeBuilder->new;
$programmTree->ignore_unknown(0);
$programmTree->parse($mech->content());
foreach my $articleTree ($programmTree->look_down('_tag'=>'article')) {
    my $event;

    #### linke Spalte
    my $h=$articleTree->look_down('_tag'=>'div',class=>'programmMeta') or die($mech->uri()->as_string);

    # Datum
    if ($h->as_trimmed_text()=~/^(\d{2})\D(\d{2})\D(\d{2,4})/) {
	if (length($3) eq 2) {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".20".$3." 00:00");
	}
	else {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".".$3." 00:00");
	}
	$event->{'enddatum'}=$event->{'startdatum'};
#print "A: ".$event->{'startdatum'}."\n";
    }
    elsif ($h->as_trimmed_text()=~/^(\d{2})\.?\-(\d{2})\.(\d{2})\.(\d{2,4})/) {
	if (length($3) eq 2) {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".20".$3." 00:00");
	}
	else {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".".$3." 00:00");
	}
	$event->{'enddatum'}=$datumFormat->parse_datetime($2.".".$3.".".$4." 00:00");
#print "B: ".$event->{'startdatum'}."\n";
    }
    elsif ($h->as_trimmed_text()=~/^(\d{2})\.(\d{2})\.?\-(\d{2})\.(\d{2})\.(\d{2,4})/) {
	if (length($3) eq 2) {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".20".$3." 00:00");
	}
	else {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".".$3." 00:00");
	}
	$event->{'enddatum'}=$datumFormat->parse_datetime($3.".".$4.".".$5." 00:00");
#print "C: ".$event->{'startdatum'}."\n";
    }

    # Einlasszeit
    if (my ($einlasszeit)=$h->as_trimmed_text()=~/Einlass (\d{2}:\d{2})/) {
	if (($einlasszeit) and ($einlasszeit=~/24:00/)) {
	    $event->{'einlass'}=$datumFormat->parse_datetime($event->{'startdatum'}->day.".".$event->{'startdatum'}->month.".".$event->{'startdatum'}->year." 00:00");
	    $event->{'einlass'}->add(days=>1);
	}
	else {
	    $event->{'einlass'}=$datumFormat->parse_datetime($event->{'startdatum'}->day.".".$event->{'startdatum'}->month.".".$event->{'startdatum'}->year." ".$einlasszeit);
	}
    }

    # Beginn
    if (my ($beginnzeit)=$h->as_trimmed_text()=~/Beginn (\d{2}:\d{2})/) {
	if (($beginnzeit) and ($beginnzeit=~/24:00/)) {
	    $event->{'beginn'}=$datumFormat->parse_datetime($event->{'startdatum'}->day.".".$event->{'startdatum'}->month.".".$event->{'startdatum'}->year." 00:00");
	    $event->{'beginn'}->add(days=>1);
	}
	else {
	    $event->{'beginn'}=$datumFormat->parse_datetime($event->{'startdatum'}->day.".".$event->{'startdatum'}->month.".".$event->{'startdatum'}->year." ".$beginnzeit);
	}
    }

#    print Dumper  $event;exit;

    ##### link zu "Mehr Informationen" folgen
    my $moreLink=$articleTree->look_down('_tag'=>'a','class'=>'more')->attr('href');
    $mech->get($moreLink);

    my $root=HTML::TreeBuilder->new_from_content($mech->content());

    my $tree=$root->look_down('_tag'=>'div','id'=>'content');


    #### rechte Spalte
    $h=$root->look_down('class'=>'articleContent') or die();
    # Name
    $event->{'name'}=$h->look_down('_tag'=>'h2')->as_trimmed_text();

    # beschreibung
    $event->{'description'}=join("\n",map { $_->as_trimmed_text(extra_chars=>'\xA0'); } $h->find('p'));

    # URL
    $event->{'url'}=		($mech->uri())->as_string;

    # Ort
    $event->{'ort'}=		"Kulturzentrum neun, Elisabethstr. 9a, 85051 Ingolstadt";



    push(@events,$event);
}

#print Dumper @events;
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
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);


#    $event->{'datum'}=~/(\d\d)\D(\d\d)\D(\d\d\d\d)/ or next;	# TODO: Mehrtägige Events! Auch oben berücksichtigen!! (17.-19.03.2016 oder 30.06.-02.07.2016)
    # wenn weder beginn noch einlass gegeben ist ganztages-event bauen
#    my $startTime="$3$2$1";
#    my $endTime=$startTime;
    my ($startTime,$endTime);

    if ($event->{'beginn'}) {
	$startTime=Date::ICal->new(
	    year=>$event->{'beginn'}->year,
	    month=>$event->{'beginn'}->month,
	    day=>$event->{'beginn'}->day,
	    hour=>$event->{'beginn'}->hour,
	    min=>$event->{'beginn'}->min,
	    sec=>0
	)->ical;
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
	$event->{'ende'}=$event->{'einlass'}->clone();
	$event->{'ende'}->add(minutes=>$defaultDauer);
    }
    elsif ($event->{'startdatum'}) {
	$startTime=sprintf("%.4d",$event->{'startdatum'}->year).sprintf("%.2d",$event->{'startdatum'}->month).sprintf("%.2d",$event->{'startdatum'}->day);
    }


    # Einlass und Beginn zu Beschreibung dazu
    if ($event->{'beginn'}) {
	$event->{'description'}="Beginn: ".sprintf("%.2d",$event->{'beginn'}->hour).":".sprintf("%.2d",$event->{'beginn'}->min)." Uhr ".$event->{'description'}." ";
    }
    if ($event->{'einlass'}) {
	$event->{'description'}="Einlass: ".sprintf("%.2d",$event->{'einlass'}->hour).":".sprintf("%.2d",$event->{'einlass'}->min)." Uhr ".$event->{'description'}." ";
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
    elsif ($event->{'enddatum'}) {
	my $e=$event->{'enddatum'};
	$e->add(days=>1);	# full day events: end date is day after event
	$endTime=sprintf("%.4d",$e->year).sprintf("%.2d",$e->month).sprintf("%.2d",$e->day);
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

