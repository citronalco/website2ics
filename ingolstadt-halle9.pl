#!/usr/bin/perl
# 2015,2018 geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;

use DateTime::Format::Strptime;
use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::Entry::TimeZone;
use Data::ICal::Entry::TimeZone::Daylight;
use Data::ICal::Entry::TimeZone::Standard;

use Time::HiRes;

use Try::Tiny;

use utf8;
#use Data::Dumper;
use warnings;


my $defaultDauer=119;	# angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)
my $url="http://www.neun-ingolstadt.de/programm/";


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
$mech->get($url) or die($!);

my @events;

my $programmTree=HTML::TreeBuilder->new;
$programmTree->ignore_unknown(0);
$programmTree->parse($mech->content());
foreach my $articleTree ($programmTree->look_down('_tag'=>'article')) {
    my $event;

    #### linke Spalte
    my $h=$articleTree->look_down('_tag'=>'div',class=>'programmMeta') or die($mech->uri()->as_string);

    # DD-MM-DD-MM-YYYY
    if ($h->as_trimmed_text()=~/^(\d{1,2})\D(\d{1,2})\D(\d{1,2})\D(\d{1,2})\D(\d{2,4})/) {
	if (length($5) eq 2) {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".20".$5." 00:00");
	    $event->{'enddatum'}=$datumFormat->parse_datetime($3.".".$4.".".$5." 00:00");
	}
	else {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".".$5." 00:00");
	    $event->{'enddatum'}=$datumFormat->parse_datetime($3.".".$4.".".$5." 00:00");
	}
    }

    # DD/DD-MM-YYYY
    elsif ($h->as_trimmed_text()=~/^(\d{1,2})\D{1,2}(\d{1,2})\D(\d{1,2})\D(\d{2,4})/) {
	if (length($4) eq 2) {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$3.".20".$4." 00:00");
	    $event->{'enddatum'}=$datumFormat->parse_datetime($2.".".$3.".20".$4." 00:00");
	}
	else {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$3.".".$4." 00:00");
	    $event->{'enddatum'}=$datumFormat->parse_datetime($2.".".$3.".".$4." 00:00");
	}
    }

    # DD-MM-YYYY DD-MM-YYYY
    elsif ($h->as_trimmed_text()=~/^(\d{1,2})\D(\d{1,2})\D(\d{2,4})\s+(\d{1,2})\D(\d{1,2})\D(\d{2,4})/) {
	if (length($3) eq 2) {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".20".$3." 00:00");
	}
	else {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".".$3." 00:00");
	}
	if (length($6) eq 2) {
	    $event->{'enddatum'}=$datumFormat->parse_datetime($4.".".$5.".20".$6." 00:00");
	}
	else {
	    $event->{'enddatum'}=$datumFormat->parse_datetime($4.".".$5.".".$6." 00:00");
	}
    }

    # DD-MM-YYYY
    elsif ($h->as_trimmed_text()=~/^(\d{1,2})\D(\d{1,2})\D(\d{2,4})/) {
	if (length($3) eq 2) {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".20".$3." 00:00");
	}
	else {
	    $event->{'startdatum'}=$datumFormat->parse_datetime($1.".".$2.".".$3." 00:00");
	}
    }
    else {
	print STDERR Dumper $h->as_trimmed_text();
	die();
	#next;
    }
    unless ($event->{'enddatum'}) {
	$event->{'enddatum'}=$event->{'startdatum'}->clone();
    }

    # Zeit Einlass
    if (my ($stunde,$minute)=$h->as_trimmed_text()=~/Einlass (?:ab )?(\d{2}):(\d{2})/) {
	$event->{'einlass'}=$event->{'startdatum'}->clone();
	if ($stunde=~/24/) {
	    $event->{'einlass'}->set(hour=>0, minute=>$minute);
	    $event->{'einlass'}->add(days=>1);
	}
	else {
	    $event->{'einlass'}->set(hour=>$stunde,minute=>$minute);
	}
	$event->{'ende'}=$event->{'einlass'}->clone();
	$event->{'ende'}->add(minutes=>$defaultDauer);
    }

    # Zeit Beginn
    if (my ($stunde,$minute)=$h->as_trimmed_text()=~/Beginn (?:ab )?(\d{2}):(\d{2})/) {
	$event->{'beginn'}=$event->{'startdatum'}->clone();
	if ($stunde=~/24/) {
	    $event->{'beginn'}->set(hour=>0, minute=>$minute);
	    $event->{'beginn'}->add(days=>1);
	}
	else {
	    $event->{'beginn'}->set(hour=>$stunde,minute=>$minute);
	}
	$event->{'ende'}=$event->{'beginn'}->clone();
	$event->{'ende'}->add(minutes=>$defaultDauer);
    }

    unless ($event->{'beginn'} or $event->{'einlass'}) {
	# keine Startzeit -> Ganztages-Event
	$event->{'fullday'}=1;
    }


    ##### Link zu "Mehr Informationen" folgen
    my $moreLink=$articleTree->look_down('_tag'=>'a','class'=>'more')->attr('href');
    $mech->get($moreLink);

    my $root=HTML::TreeBuilder->new_from_content($mech->content());

    my $tree=$root->look_down('_tag'=>'div','id'=>'content');


    #### rechte Spalte
    $h=$root->look_down('class'=>'articleContent') or die();
    # Name
    $event->{'name'}=$h->look_down('_tag'=>'h2')->as_trimmed_text();

    # Beschreibung
    $event->{'description'}=join("\n",map { $_->as_trimmed_text(extra_chars=>'\xA0'); } $h->find('p'));

    # URL
    $event->{'url'}=($mech->uri())->as_string;

    # Ort
    $event->{'ort'}="Kulturzentrum neun, Elisabethstr. 9a, 85051 Ingolstadt";


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
	"X-WR-CALDESC"=>"Veranstaltungen Kulturzentrum neun",
);

# Add VTIMEZONE
my $tz="Europe/Berlin";
my $vtimezone=Data::ICal::Entry::TimeZone->new();
$vtimezone->add_properties(tzid=>$tz);

my $tzDaylight=Data::ICal::Entry::TimeZone::Daylight->new();
$tzDaylight->add_properties(
    tzoffsetfrom => "+0100",
    tzoffsetto	=> "+0200",
    dtstart	=> "19700329T020000",
    tzname	=> "CEST",
    rrule	=> "FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU"
);
$vtimezone->add_entry($tzDaylight);

my $tzStandard=Data::ICal::Entry::TimeZone::Standard->new();
$tzStandard->add_properties(
    tzoffsetfrom => "+0200",
    tzoffsetto	=> "+0100",
    dtstart	=> "19701025T030000",
    tzname	=> "CET",
    rrule	=> "FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"
);
$vtimezone->add_entry($tzStandard);

$calendar->add_entry($vtimezone);


my $count=0;
foreach my $event (@events) {
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);

    # Einlass zu Beschreibung dazu
    if ($event->{'einlass'}) {
	$event->{'description'}="Einlass: ".sprintf("%.2d",$event->{'einlass'}->hour).":".sprintf("%.2d",$event->{'einlass'}->min)." Uhr \n\n".$event->{'description'}." ";
    }

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'name'},
	description => $event->{'description'},
	dtstamp=>$dstamp,
	class=>"PUBLIC",
        organizer=>"MAILTO:foobar",
	location=>$event->{'ort'},
	url=>$event->{'url'},
    );
    if (defined($event->{'fullday'})) {
	$eventEntry->add_properties(
	    dtstart=>dt2icaldt_fullday($event->{'startdatum'}),
	    dtend=>dt2icaldt_fullday($event->{'enddatum'}),
	);
    }
    else {
	$eventEntry->add_properties(
	    dtstart=>dt2icaldt($event->{'beginn'} or $event->{'einlass'}),
	    dtend=>dt2icaldt($event->{'ende'}),
        );
    }

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;

