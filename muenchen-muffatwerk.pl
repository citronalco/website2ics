#!/usr/bin/perl
# 2022 geierb@geierb.de
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

use POSIX qw(strftime);

use Try::Tiny;

use utf8;
#use Data::Dumper;
use warnings;


my $url="https://www.muffatwerk.de/de/events";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)


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

$mech->get($url) or die($!);
foreach my $eventLink ($mech->find_all_links(url_regex=>qr/\/de\/events\/view\//)) {
    my $event;

    # URL
    $event->{'url'}=$eventLink->url_abs()->as_string;
    #print $event->{'url'}."\n";

    # Bereits vorhandene überspringen
    my $found=0;
    foreach my $e (@eventList) {
        if ($e->{'url'} eq $event->{'url'}) {
	    $found=1;
	    last;
	}
    }
    next if $found==1;
    # Event-Seite laden
    my $ok=eval { $mech->get($eventLink); }; # sometimes some links are broken
    next unless ($ok);

    my $root=HTML::TreeBuilder->new_from_content($mech->content())->look_down('id'=>'content');

    # Datum - üblicherweise fehlt das Jahr
    # Bei mehrtägigen Veranstaltungen: Nur den ersten angezeigten Tag nehmen, Folgetage haben je eigene Webseiten
    my $now=DateTime->now();

    $event->{'beginn'}=$now->clone();
    #$event->{'ende'}=$now->clone();
    $event->{'fullday'}=1;

    my $datum=$root->look_down('_tag'=>'div','class'=>'entry-data side left')->as_trimmed_text;
    # "Heute"
    if ($datum=~/heute/i) {
	# passt schon
    }
    # "Morgen"
    elsif ($datum=~/morgen/i) {
	$event->{'beginn'}->add(days=>1);
	#$event->{'ende'}->add(days=>1);
    }
    # "25.03&26.03."
    elsif ($datum=~/^\s*(\d{2})\.(\d{2})\&(\d{2})\.(\d{2})/i) {
	$event->{'beginn'}->set(day=>$1,month=>$2);
	#$event->{'ende'}->set(day=>$1,month=>$3);
    }
    # "25. bis 27.08."
    elsif ($datum=~/^\s*(\d{2})\.?bis(\d{2})\.(\d{2})/i) {
	$event->{'beginn'}->set(day=>$1,month=>$3);
	#$event->{'ende'}->set(day=>$1,month=>$3);
    }
    # "25.08. bis 03.09."
    elsif ($datum=~/^\s*(\d{2})\.(\d{2})\.?bis(\d{2})\.(\d{2})/i) {
	$event->{'beginn'}->set(day=>$1,month=>$2);
	#$event->{'ende'}->set(day=>$1,month=>$2);
    }
    # "Di25.08.22"
    elsif ($datum=~/^\w{2}(\d{2})\.(\d{2})(\d{2})/) {
	$event->{'beginn'}->set(day=>$1,month=>$2,year=>"20".$3);
	#$event->{'ende'}->set(day=>$1,month=>$2,year="20".$3);
    }
    # "15./17./18./19.05."
    elsif ($datum=~/^(\d+)\.(?:\/\d+\.)+(\d+)\.$/) {
	$event->{'beginn'}->set(day=>$1,month=>$2);
	#$event->{'ende'}->set(day=>$1,month=>$2);
    }
    # "25.08.22"
    elsif ($datum=~/^(\d{2})\.(\d{2})\.(\d{2})/) {
	$event->{'beginn'}->set(day=>$1,month=>$2,year=>"20".$3);
	#$event->{'ende'}->set(day=>$1,month=>$2,year="20".$3);
    }

    # "Montag ab 12 Uhr geöffnet" oder: "ab 12 Uhr" (wenn "heute" oder "morgen")  -> Biergarten, usw., keine echte Verantstaltung, überspringen
    elsif ($datum=~/^\D*ab\d+Uhr/i) {
	next;
    }
    else {
	die("Unbekanntes Datumsformat: ".$datum."\n".$event->{'url'}."\n");
	#next;
    }

    # wenn z.B. durch Jahreswechsel die so erstellte Einlasszeit zu weit in der Vergangenheit liegt: 1 Jahr dazuzuzählen
    if ($event->{'beginn'} < $now->add(months => -1)) {
        $event->{'beginn'}=$event->{'beginn'}->add(years => 1);
    }



    # Kategorie
    $event->{'kategorie'}=$root->look_down('_tag'=>'div','class'=>'entry-data side right')->as_trimmed_text;
    # Name
    $event->{'titel'}=$root->look_down('_tag'=>'h1',class=>qr/entry-data center/)->as_trimmed_text;
    # Untertitel
    try {
	$event->{'titel'}.=" - ".$root->look_down('_tag'=>'div','class'=>'entry entry-normal opened')->look_down('_tag'=>'div','class'=>'entry-content')->look_down('_tag'=>'h4')->as_trimmed_text;
    };
    # Beschreibung
    try {
	$event->{'beschreibung'}=$root->look_down('_tag'=>'div','class'=>'entry entry-normal opened')->look_down('_tag'=>'div','class'=>'entry-content')->look_down('_tag'=>'div','class'=>undef)->as_trimmed_text;
    };


    ## Infobox
    my $infobox=$root->look_down('_tag'=>'div','class'=>'entry entry-normal opened')->look_down('_tag'=>'div','class'=>'entry-content')->look_down('_tag'=>'p','class'=>'entry-info');

    # Zeilen in Infobox bei "br" aufteilen, "sup" durch Leerzeichen ersetzen, dannn HTML-Tags entfernen
    my @additionalDescription;

    my (@infolines)=split(/<br\s*\/>/,$infobox->as_HTML());
    foreach (@infolines) {
	$_ =~s/<\/?sup>/ /gi;
    }
    my @infos = map { HTML::TreeBuilder->new_from_content($_)->as_trimmed_text } @infolines;

    # Erste Zeile: Nochmal Datum, überspringen
    shift(@infos);

    # Kategorie steht in zweiter Zeile
    $event->{'kategorie'}=$infos[0];
    shift(@infos);

    # Restliche Info-Zeilen
    foreach (@infos) {
	next if ($_=~/^\s*$/);
	if ($_=~/Einlass: (\d+)(?:\D(\d+))?.*?\s*Uhr\s*Beginn: (\d+)(?:\D(\d+))?\s*Uhr/) {
	    $event->{'einlass'}=$event->{'beginn'}->clone();
	    $event->{'einlass'}->set(hour=>$1,minute=>($2//"00"));
	    $event->{'beginn'}->set(hour=>$3,minute=>($4//"00"));
	    undef($event->{'fullday'});
	}
	elsif ($_=~/^\s*Ort: (.+)$/) {
	    $event->{'ort'}=$1;
	}
	else {
	    push(@additionalDescription,$_);
	}
    }

    # Ticket-Link
    try {
	push(@additionalDescription,"Tickets: ".$mech->find_link(text=>'Tickets')->url_abs()->as_string);
    };

    $event->{'beschreibung'}=join(" \n\n",
	(
	    join(" \n",@additionalDescription),
	    $event->{'beschreibung'}//"")
	);

    # Ende festlegen
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
        "X-WR-CALNAME"=>"Muffatwerk",
        "X-WR-CALDESC"=>"Veranstaltungen Muffatwerk");

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
    if ($event->{'einlass'}) {
	$description.="Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute)."\ n";
    }
    $description.=" \n".$event->{'beschreibung'};


    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'titel'},
	description => $description,
	categories => $event->{'kategorie'},
	dtstart => ($event->{'fullday'}) ? dt2icaldt_fullday($event->{'beginn'}) : dt2icaldt($event->{'beginn'}),
	dtend => ($event->{'fullday'}) ? dt2icaldt_fullday($event->{'ende'}) : dt2icaldt($event->{'ende'}),
	dtstamp=>$dstamp,
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
