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

use Try::Tiny;

use utf8;
use Data::Dumper;
use warnings;


my $url="https://strom-muc.de/";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)

my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H.%M','time_zone'=>'Europe/Berlin');
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

my @eventList;

foreach my $eventLink ($mech->find_all_links(url_regex=>qr/${url}event\//)) {
    my $event;

    # URL
    $event->{'url'}=$eventLink->url_abs()->as_string;

    # Ort
    $event->{'ort'}="Strom, Lindwurmstr. 88, 80337 München";

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

    # Tickets
    try {
	$event->{'tickets'}=$mech->find_link('text'=>'Tickets kaufen')->url_abs()->as_string();
    };

    my $root=HTML::TreeBuilder->new_from_content($mech->content());

    # Titel
    $event->{'titel'}=$root->look_down('_tag'=>'h1','class'=>'gdlr-event-title')->as_trimmed_text;
    $event->{'titel'}=~s/([\w'’]+)/\u\L$1/g;

    # Kategorie
    $event->{'kategorie'}=$root->look_down('_tag'=>'div','class'=>'gdlr-event-location')->as_trimmed_text;
    $event->{'kategorie'}=~s/([\w'’]+)/\u\L$1/g;

    # Beschreibung
    try {
	$event->{'beschreibung'}=$root->look_down('_tag'=>'div','class'=>'gdlr-event-content')->as_text;
	$event->{'beschreibung'}=~s/Der Inhalt ist nicht verfügbar.*?Bitte erlaube Cookies, indem du auf Übernehmen im Banner klickst.//;

        # Ersetze Unicode-Linebreaks durch normale
        $event->{'beschreibung'}=~s/\R/\n/g;
        # Nichtdruckbare Zeichen (^H usw) ausfiltern
        $event->{'beschreibung'}=~s/[^[:print:]]+//g;
    };

    my $infoWrapper=$root->look_down('_tag'=>'div','class'=>'gdlr-event-info-wrapper');
    # Datum
    try {
	my $datum=$infoWrapper->look_down('_tag'=>'div','class'=>'gdlr-info-date gdlr-info',
		sub {
		    $_[0]->as_text=~/^Datum:/
		}
	)->as_trimmed_text;
	$datum=~/Datum: (\d+\.\d+\.\d+)/;
	$event->{'datum'}=$1;
    };
    # Verschoben?
    try {
	my $verschoben=$infoWrapper->look_down('_tag'=>'div','class'=>'event-status-wrapper',
		sub {
		    $_[0]->as_text=~/^Verschoben auf den/
		}
	    )->as_trimmed_text;
	$verschoben=~/Verschoben auf den (\d+\.\d+\.\d+)/;
	$event->{'datum'}=$1;
    };

    # Abgesagt?
    next if ($infoWrapper->look_down('_tag'=>'div','class'=>'event-status-wrapper',
		sub {
		    $_[0]->as_text=~/^Abgesagt/i
		}
	    ));

    # Verlegt?
    next if ($infoWrapper->look_down('_tag'=>'div','class'=>'event-status-wrapper',
		sub {
		    $_[0]->as_text=~/^Verlegt/i
		}
	    ));


    # Ohne Datum kein Kalendereintrag
    next unless $event->{'datum'};

    # Uhrzeit
    try {
	my $uhrzeit=$infoWrapper->look_down('_tag'=>'div','class'=>'gdlr-info-time gdlr-info',
		sub {
		    $_[0]->as_text=~/^Uhrzeit:/
		}
	    )->as_trimmed_text;

	# "Einlass: HH.MM Uhr / Beginn: HH.MM Uhr"
	# "Einlass & Beginn: HH.MM Uhr"
	if ($uhrzeit=~/ (\d{1,2})[\.:](\d{1,2}) .+(\d{1,2})[\.:](\d{1,2}) Uhr/i) {
	    $event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.".".$2);
	    $event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$3.".".$4);
	}
	else {
	    if ($uhrzeit=~/Einlass.*(\d{1,2})[\.:](\d{1,2}) Uhr/i) {
		$event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.".".$2);
	    }
	    if ($uhrzeit=~/Beginn.*(\d{1,2})[\.:](\d{1,2}) Uhr/i) {
		$event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$1.".".$2);
	    }
	}

	$event->{'ende'}=$event->{'beginn'}->clone();
	$event->{'ende'}->add(minutes=>$defaultDauer);

	if (!$event->{'beginn'}) {
	    $event->{'beginn'}=$event->{'einlass'}->clone() if ($event->{'einlass'});
	}
    }
    catch {
	$event->{'fullday'}=1;
	$event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." 00.00");
	$event->{'ende'}=$datumFormat->parse_datetime($event->{'datum'}." 23.59");
    };

    try {
	my $veranstalter=$infoWrapper->look_down('_tag'=>'div','class'=>'gdlr-info-time gdlr-info',
		sub {
		    $_[0]->as_text=~/^Veranstalter:/
		}
	    )->as_trimmed_text;
	$veranstalter=~s/^Veranstalter: //;
	$event->{'veranstalter'}=$veranstalter;
    };

    # Eintrittspreis
    try {
	$event->{'preis'}=$infoWrapper->look_down('_tag'=>'div','class'=>'event-status-wrapper',
	        sub {
		    $_[0]->as_text=~/EUR/
		}
	    )->as_trimmed_text;
    };

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
        "X-WR-CALNAME"=>"Strom",
        "X-WR-CALDESC"=>"Veranstaltungen Strom");

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
    if ($event->{'preis'})	{ $description.=$event->{'preis'}." \n"; }
    if ($event->{'tickets'})	{ $description.="Tickets: ".$event->{'tickets'}." \n"; }
    if ($event->{'einlass'}) {
	$description.="Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute)." \n";
    }
    $description.=" \n".$event->{'beschreibung'}."\n";

    if ($event->{'veranstalter'}) {
	$description.=" \n Veranstalter: ".$event->{'veranstalter'}." \n";
    }

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
