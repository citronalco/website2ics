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

use List::MoreUtils qw(first_index);

use Try::Tiny;

use utf8;
use Data::Dumper;
use warnings;


my $url="https://www.milla-club.de/";
my @monatsnamen=('jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec');

my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)

my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H:%M','time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);

my $root=HTML::TreeBuilder->new();
$root->ignore_unknown(0);       # "section"-Tag wird sonst nicht erkannt
$root->parse_content($mech->content());

my @eventList;

# Monatsweise durchgehen um "Featured" zu überspringen
foreach my $monthSection ($root->look_down('_tag'=>'section','class'=>'events')) {
    foreach my $eventItem ($monthSection->look_down('_tag'=>'div','class'=>'event__title')) {

	my $event;
	# Unterseite aufrufen
	try {
	    $event->{'url'}=$eventItem->look_down('_tag'=>'a')->attr('href');
	    $mech->get($event->{'url'});
	}
	catch {
	    next;
	};


	my $page=HTML::TreeBuilder->new();
	$page->ignore_unknown(0);       # "article"-Tag wird sonst nicht erkannt
	$page->parse_content($mech->content());

	### Kopfzeile: TITEL MONAT TAG WOCHENTAG HH:MM KATEGORIE
	my $headline=$page->look_down('_tag'=>'div','class'=>"container is-fluid");
	$headline=$headline->look_down('_tag'=>'div','class'=>qr/columns/);
	# Titel
	$event->{'titel'}=$headline->look_down('_tag'=>'h1')->as_trimmed_text();
	# und der Rest
	my ($monatsname,$tag,$wochentag,$stunde,$minute,$kategorien)=$headline->as_HTML()=~/<span class="is-date">\s*(\w\w\w)\s+(\d+)\s*<\/span>\s*<span>(\w+)\s+(\d+)[\.: ](\d+)<\/span>\s*<span>(.*)<\/span>/;
	# Datum - leider fehlt das Jahr
	my $now=DateTime->now();
	my $jahr=$now->strftime("%Y");
	my $monat=1+first_index { $_ eq lc($monatsname) } @monatsnamen;
	$event->{'einlass'}=$datumFormat->parse_datetime($tag.".".$monat.".".$jahr." ".$stunde.":".$minute);
	# wenn z.B. durch Jahreswechsel die so erstellte Einlasszeit zu weit in der Vergangenheit liegt: 1 Jahr dazuzuzählen
	if ($event->{'einlass'}->add(months => -1) < $now) {
	    $event->{'einlass'}=$event->{'einlass'}->add(years => 1);
	}
	$event->{'beginn'}=$event->{'einlass'}->clone();

	@{$event->{'kategorien'}} = split /,\s*/, $kategorien;

	### Fußzeile: Tickets
	my $ticketlink=$page->look_down('_tag'=>'a','class'=>qr/event__tickets/);
	if ($ticketlink) {
	    $event->{'tickets'}=$ticketlink->attr('href');
	}


	## Beschreibungstext ("content")
	my $content=$page->look_down('_tag'=>'div','class'=>'content');
	my $text_html=$content->as_HTML();
	my $text=$content->as_trimmed_text();

	# Beschreibungstext hat normalerweise zwei Teile: Inhaltsbeschreibung und, nach ein paar Tildezeichen, Organisatorisches
	my $orga;
	if ($text=~/(.+?)\~\~\~\~\~\~+(.+)/) {
	    $event->{'beschreibung'}=$1;
	    $orga=$2;
	}
	else {
	    # Ohne Trenner kompletten Text als Beschreibung verwenden..
	    $event->{'beschreibung'}=$text;
	    # ...und versuchen, daraus Einlass, Beginn und Preise rauszufinden
	    $orga=$text;
	}


	# "Organisatorisches" enthält Datum, AK, VVK, Einlass, Beginn usw.
	# Datum von oben wenn möglich überschreiben
	#if ($orga=~/^\s*(\d{2}\.\d{2}\.\d{4})/) {
	#    $event->{'datum'}=$1;
	#}

	if ($orga=~/(VVK:?\s+[\d,\.]+\s€ zzgl\. Geb\.)/) {
	    $event->{'vvk'}=$1;
	}
	if ($orga=~/(AK:?\s+[\d,\.]+\s€)/) {
	    $event->{'ak'}=$1;
	}

	if ($orga=~/Einlass:?\s+(\d+)[:\.](\d+)/) {
	    $event->{'einlass'}->set(hour=>$1, minute=>$2);
	}
	elsif ($orga=~/(\d+)[:\.](\d+) (?:Uhr )?Einlass/) {
	    $event->{'einlass'}->set(hour=>$1, minute=>$2);
	}
	elsif ($orga=~/Einlass:?\s+(\d+)[:\.]/) {	# Minuten "00" wird gelegenlich als "oo" geschrieben...
	    $event->{'einlass'}->set(hour=>$1, minute=>0);
	}
	elsif ($orga=~/(\d+)[:\.].{2} Einlass/) {	# Minuten "00" wird gelegenlich als "oo" geschrieben, und "Einlass" danach
	    $event->{'einlass'}->set(hour=>$1, minute=>0);
	}

	if ($orga=~/Beginn:?\s+(\d+)[:\.](\d+)/) {
	    $event->{'beginn'}->set(hour=>$1, minute=>$2);
	}
	elsif ($orga=~/(\d+)[:\.](\d+) (?:Uhr )?Beginn/) {
	    $event->{'beginn'}->set(hour=>$1, minute=>$2);
	}
	elsif ($orga=~/Beginn:?\s+(\d+)[:\.]/) {	# Minuten "00" wird gelegenlich als "oo" geschrieben...
	    $event->{'beginn'}->set(hour=>$1, minute=>0);
	}
	elsif ($orga=~/(\d+)[:\.].{2} Beginn/) {	# Minuten "00" wird gelegenlich als "oo" geschrieben, und "Beginn" danach
	    $event->{'beginn'}->set(hour=>$1, minute=>0);
	}
	elsif ($orga=~/Beginn:? (\d+) Uhr/) {	# Minuten werden gelegentlich weggelassen
	    $event->{'beginn'}->set(hour=>$1, minute=>0);
	}

	if (!$event->{'einlass'} and !$event->{'beginn'}) {
	    # 15 – 22 Uhr, 15-22:14 Uhr, 14:15 bis 16 Uhr,... - aus HTML kratzen
	    if ($text_html=~/(\d+):?(\d{2})?\s*(?:bis|[\-–]|&ndash;|&dash;)\s*(\d+):?(\d{2})?\s+Uhr/i) {
		$event->{'beginn'}->set(hour=>$1, minute=>($2//"00"));
		$event->{'ende'}->set(hour=>$3, minute=>($4//"00"));
	    }
	}

	# Wenn überhaupt keine Zeitangabe gefunden werden konnte: Als Ganztagesevent eintragen
	if (!$event->{'einlass'} and !$event->{'beginn'}) {
	    #die($event->{'url'});
	    $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." 00:00");
	    $event->{'ende'}=$datumFormat->parse_datetime($event->{'datum'}." 23:59");
	}

	# Fehlende Zeitangaben ergänzen
	$event->{'einlass'}=$event->{'beginn'} unless ($event->{'einlass'});
	$event->{'beginn'}=$event->{'einlass'} unless ($event->{'beginn'});
	unless ($event->{'ende'}) {
	    $event->{'ende'}=$event->{'beginn'}->clone();
	    $event->{'ende'}->add(minutes=>$defaultDauer);
	}

	push (@eventList,$event);
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
        "X-WR-CALNAME"=>"Milla",
        "X-WR-CALDESC"=>"Veranstaltungen Milla");

my $count=0;
foreach my $event (@eventList) {
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);

    my $description;
    if ($event->{'ak'})		{ $description.=$event->{'ak'}." \n"; }
    if ($event->{'vvk'})	{ $description.=$event->{'vvk'}." \n"; }
    if ($event->{'tickets'})	{ $description.="Tickets: ".$event->{'tickets'}." \n"; }
    if ($event->{'einlass'}) {
	$description.="Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute)." \n";
    }
    $description.=" \n".$event->{'beschreibung'}."\n";


    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'titel'},
	description => $description,
	categories => join(", ",@{$event->{'kategorien'}}),
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
	location=>"Milla, Holzstraße 28, 80469 München",
	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
