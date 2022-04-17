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
use Time::HiRes;

use POSIX qw(strftime);

use Try::Tiny;

use utf8;
use Data::Dumper;
use warnings;


my $url="https://www.muffatwerk.de/de/events";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)


my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H:%M','time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

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

    # Datum
    my $datum=$root->look_down('_tag'=>'div','class'=>'entry-data side left')->as_trimmed_text;
    # "Heute"
    if ($datum=~/heute/i) {
	$event->{'datum'}=strftime "%d.%m.%Y", localtime();
    }
    # "Morgen"
    elsif ($datum=~/morgen/i) {
	$event->{'datum'}=strftime "%d.%m.%Y", localtime(time()+24*60*60);
    }
    # "25. bis 27.08." - Mehrtägige Veranstaltung: Nur den ersten angezeigten Tag nehmen, Folgetage haben je eigene Webseiten
    elsif ($datum=~/^\s*(\d{2})\.?bis(\d{2})\.(\d{2})/i) {
	$event->{'datum'}=$1.".".$3.".".strftime "%Y", localtime();
    }
    # "25.08. bis 03.09." -  Mehrtägige Veranstaltung: Nur den ersten angezeigten Tag nehmen, Folgetage haben je eigene Webseiten
    elsif ($datum=~/^\s*(\d{2})\.(\d{2})\.?bis(\d{2})\.(\d{2})/i) {
	$event->{'datum'}=$1.".".$2.".".strftime "%Y", localtime();
    }
    # "Di 25.08.22"
    elsif ($datum=~/\w{2}(\d{2})\.(\d{2})(\d{2})/) {
	$event->{'datum'}=$1.".".$2.".20".$3;
    }
    # 15./17./18./19.05. - Mehrtägige Veranstaltung: Nur den ersten angezeigten Tag nehmen, Folgetage haben je eigene Webseiten
    elsif ($datum=~/^(\d+)\.(?:\/\d+\.)+(\d+)\.$/) {
	$event->{'datum'}=$1.".".$2.".".strftime "%Y", localtime();
    }
    # "Montag ab 12 Uhr geöffnet" oder: "ab 12 Uhr" (wenn "heute" oder "morgen")  -> Biergarten, usw., keine echte Verantstaltung, überspringen
    elsif ($datum=~/^\D*ab\d+Uhr/i) {
	next;
    }
    else {
	#die("Unbekanntes Datumsformat: ".$datum."\n".$event->{'url'}."\n");
	next;
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
	    $event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":".($2//"00"));
	    $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$3.":".($4//"00"));
	}
	elsif ($_=~/^\s*Ort: (.+)$/) {
	    $event->{'ort'}=$1;
	}
	else {
	    push(@additionalDescription,$_);
	}
    }
    if (!$event->{'einlass'} and !$event->{'beginn'}) {
	$event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." 00:00");
	$event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." 00:00");
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

    # Ende festlegen
    $event->{'ende'}=$event->{'beginn'}->clone();
    $event->{'ende'}->add(minutes=>$defaultDauer);


    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'titel'},
	description => $description,
	categories => $event->{'kategorie'},
	dtstart => DateTime::Format::ICal->format_datetime(
	    DateTime->new(
		year=>$event->{'beginn'}->year,
		month=>$event->{'beginn'}->month,
		day=>$event->{'beginn'}->day,
		hour=>$event->{'beginn'}->hour,
		minute=>$event->{'beginn'}->min,
		second=>0,
		#time_zone=>'Europe/Berlin'
	    )
	),
	dtend => DateTime::Format::ICal->format_datetime(
	    DateTime->new(
		year=>$event->{'ende'}->year,
		month=>$event->{'ende'}->month,
		day=>$event->{'ende'}->day,
		hour=>$event->{'ende'}->hour,
		minute=>$event->{'ende'}->min,
		second=>0,
		#time_zone=>'Europe/Berlin'
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
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
