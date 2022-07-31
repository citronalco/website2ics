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


my $url="https://www.milla-club.de/category/event/";
my @monatsnamen=('jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec');

my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)

my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H:%M','time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);
my $root=HTML::TreeBuilder->new_from_content($mech->content());

my @eventList;

foreach my $eventBox ($root->look_down('_tag'=>'div','class'=>'preview-box-wrapper')) {
    my $event;

    ## Titel, URL, Kategorie
    my $titleLink=$eventBox->look_down('_tag'=>'h3','class'=>'post-title');
    ($event->{'kategorie'},$event->{'titel'})=$titleLink->as_trimmed_text()=~/(.+): (.+)/;
    $event->{'titel'}=$titleLink->as_trimmed_text() unless ($event->{'titel'});
    $event->{'url'}=$titleLink->look_down('_tag'=>'a')->attr('href');

    ## Datum
    my $year=$eventBox->look_down('_tag'=>'span','class'=>'post-date-year')->as_trimmed_text();
    # Monatsnummer aus Monatsname
    my $monthname=$eventBox->look_down('_tag'=>'span','class'=>'post-date-month')->as_trimmed_text();
    my $month=1+first_index { $_ eq lc($monthname) } @monatsnamen;
    # Tag
    my $day=$eventBox->look_down('_tag'=>'span','class'=>'post-date-day')->as_trimmed_text();
    $event->{'datum'}=$day.".".$month.".".$year;

    ## Tickets
    try {
	$event->{'tickets'}=$eventBox->look_down('_tag'=>'div','class'=>'reserve')->look_down('_tag'=>'a')->attr('href');
    };

    ## Unterseite aufrufen
    try {
	$mech->get($event->{'url'});
    }
    catch {
	next;
    };
    my $page=HTML::TreeBuilder->new();
    $page->ignore_unknown(0);       # "article"-Tag wird sonst nicht erkannt
    $page->parse_content($mech->content());

    ## Beschreibungstext
    my $text_html=$page->look_down('_tag'=>'div','class'=>'text-wrapper')->as_HTML();
    my $text=$page->look_down('_tag'=>'div','class'=>'text-wrapper')->as_trimmed_text();

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

    # "Organisatorisches" enthält AK, VVK, Einlass, Beginn usw.
    if ($orga=~/(VVK:?\s+[\d,\.]+\s€ zzgl\. Geb\.)/) {
        $event->{'vvk'}=$1;
    }
    if ($orga=~/(AK:?\s+[\d,\.]+\s€)/) {
        $event->{'ak'}=$1;
    }

    if ($orga=~/Einlass:?\s+(\d+)[:\.](\d+)/) {
        $event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":".$2);
    }
    elsif ($orga=~/(\d+)[:\.](\d+) (?:Uhr )?Einlass/) {
        $event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":".$2);
    }
    elsif ($orga=~/Einlass:?\s+(\d+)[:\.]/) {	# Minuten "00" wird gelegenlich als "oo" geschrieben...
        $event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":00");
    }
    elsif ($orga=~/(\d+)[:\.].{2} Einlass/) {	# Minuten "00" wird gelegenlich als "oo" geschrieben, und "Einlass" danach
        $event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":00");
    }

    if ($orga=~/Beginn:?\s+(\d+)[:\.](\d+)/) {
        $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":".$2);
    }
    elsif ($orga=~/(\d+)[:\.](\d+) (?:Uhr )?Beginn/) {
        $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":".$2);
    }
    elsif ($orga=~/Beginn:?\s+(\d+)[:\.]/) {	# Minuten "00" wird gelegenlich als "oo" geschrieben...
        $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":00");
    }
    elsif ($orga=~/(\d+)[:\.].{2} Beginn/) {	# Minuten "00" wird gelegenlich als "oo" geschrieben, und "Beginn" danach
        $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":00");
    }
    elsif ($orga=~/Beginn:? (\d+) Uhr/) {	# Minuten werden gelegentlich weggelassen
        $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":00");
    }

    if (!$event->{'einlass'} and !$event->{'beginn'}) {
	# 15 – 22 Uhr, 15-22:14 Uhr, 14:15 bis 16 Uhr,... - aus HTML kratzen
	if ($text_html=~/(\d+):?(\d{2})?\s*(?:bis|[\-–]|&ndash;|&dash;)\s*(\d+):?(\d{2})?\s+Uhr/i) {
	    $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.":".($2//"00"));
	    $event->{'ende'}=$datumFormat->parse_datetime($event->{'datum'}." ".$3.":".($4//"00"));
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
	location=>"Milla, Holzstraße 28, 80469 München",
	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
