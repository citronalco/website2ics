#!/usr/bin/perl
# 2022 geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;
use HTML::FormatText;

use DateTime::Format::Strptime;
use DateTime::Format::ICal;
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


my $url="https://www.milla-club.de/";
my @monatsnamen=('jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec');

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
	$event->{'start'}=$datumFormat->parse_datetime($tag.".".$monat.".".$jahr." ".$stunde.":".$minute);

	# Datum testen: Wenn's z.B. den 29.2. nicht gibt, ein Jahr dazu zählen
	try {
	    my $dummy=$event->{'start'}->strftime("%Y-%m-%d");
	}
	catch {
	    $event->{'start'}=$datumFormat->parse_datetime($tag.".".$monat.".".($jahr+1)." ".$stunde.":".$minute);
	};

	# wenn z.B. durch Jahreswechsel die so erstellte Einlasszeit zu weit in der Vergangenheit liegt: 1 Jahr dazuzählen
	if ($event->{'start'} < $now->add(months => -1)) {
	    $event->{'start'}->add(years => 1);
	}
	@{$event->{'kategorien'}} = split /,\s*/, $kategorien;

	### Fußzeile: Tickets
	my $ticketlink=$page->look_down('_tag'=>'a','class'=>qr/event__tickets/);
	if ($ticketlink) {
	    $event->{'tickets'}=$ticketlink->attr('href');
	}


	## Beschreibungstext ("content")
	my $content=$page->look_down('_tag'=>'div','class'=>'content');
	my $text_html=$content->as_HTML();

	#my $text=$content->as_trimmed_text();
	my $formatter=HTML::FormatText->new(leftmargin=>0, rightmargin=>1000);
	my $text=$content->format($formatter);

	# Beschreibungstext hat normalerweise zwei Teile: Inhaltsbeschreibung und, nach ein paar Tildezeichen, Organisatorisches
	my $orga;
	if ($text=~/(.+?)\n*\~\~\~\~\~\~+\n*(.+)/s) {
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
	if ($orga=~/(VVK:?\s+[\d,\.]+\s€ zzgl\. Geb\.)/) {
	    $event->{'vvk'}=$1;
	}
	if ($orga=~/(AK:?\s+[\d,\.]+\s€)/) {
	    $event->{'ak'}=$1;
	}

	if (my ($h,$m)=$orga=~/Einlass:?\s+(\d{1,2})[:\.]?(\d{0,2})/) {
	    $event->{'einlass'}=$event->{'start'}->clone();
	    if ($h eq "24") {
		$event->{'einlass'}->set(hour=>0, minute=>$m);
		$event->{'einlass'}->add(days=>1);
	    }
	    else {
		$event->{'einlass'}->set(hour=>$h, minute=>($m or "0"));
	    }
	}
	if (my ($h,$m)=$orga=~/Beginn:?\s+(\d{1,2})[:\.]?(\d{0,2})/) {
	    $event->{'beginn'}=$event->{'start'}->clone();
	    if ($h eq "24") {
		$event->{'beginn'}->set(hour=>0, minute=>$m);
		$event->{'beginn'}->add(days=>1);
	    }
	    else {
		$event->{'beginn'}->set(hour=>$h, minute=>($m or "0"));
	    }
	}

	if (!$event->{'einlass'} and !$event->{'beginn'}) {
	    # 15 – 22 Uhr, 15-22:14 Uhr, 14:15 bis 16 Uhr,... - aus HTML kratzen
	    if ($text_html=~/(\d+):?(\d{2})?\s*(?:bis|[\-–]|&ndash;|&dash;)\s*(\d+):?(\d{2})?\s+Uhr/i) {
		$event->{'beginn'}=$event->{'start'}->clone();
		$event->{'beginn'}->set(hour=>$1, minute=>($2//"0"));
		$event->{'ende'}->set(hour=>$3, minute=>($4//"0"));
	    }
	}

	# Wenn überhaupt keine Zeitangabe gefunden werden konnte: Als Ganztagesevent eintragen
	if (!$event->{'einlass'} and !$event->{'beginn'}) {
	    $event->{'fullday'}=1;
	    $event->{'ende'}=$event->{'start'}->clone();
	}

	# Fehlende Zeitangaben ergänzen
	unless ($event->{'ende'}) {
	    $event->{'ende'}=($event->{'beginn'} or $event->{'einlass'})->clone();
	    $event->{'ende'}->add(minutes=>$defaultDauer) unless ($event->{'fullday'});
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
	dtstamp => $dstamp,
	class => "PUBLIC",
	organizer => "MAILTO:foobar",
	location => "Milla, Holzstraße 28, 80469 München",
	url => $event->{'url'},
    );

    if ($event->{'fullday'}) {
	$eventEntry->add_properties(
	    dtstart => dt2icaldt_fullday($event->{'beginn'} or $event->{'einlass'} or $event->{'start'}),
	    dtend => dt2icaldt_fullday($event->{'ende'}),
	);
    }
    else {
	$eventEntry->add_properties(
	    dtstart => dt2icaldt($event->{'beginn'} or $event->{'einlass'} or $event->{'start'}),
	    dtend => dt2icaldt($event->{'ende'}),
	);
    }

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
