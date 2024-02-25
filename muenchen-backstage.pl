#!/usr/bin/perl
# 2022 geierb@geierb.de
# AGPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;
use HTML::Strip;

use DateTime::Format::Strptime;
use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::Entry::TimeZone;
use Data::ICal::Entry::TimeZone::Daylight;
use Data::ICal::Entry::TimeZone::Standard;

use Time::HiRes;

use Try::Tiny;
use List::MoreUtils qw(first_index);

use utf8;
#use Data::Dumper;
use warnings;

use JSON;

my $htmlStripper=HTML::Strip->new();
my @months=("januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember");
my $url="https://backstage.eu/veranstaltungskalender";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)

my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%m/%d/%Y %H:%M','time_zone'=>'Europe/Berlin');
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
$mech->get($url);

my ($var_vevent)=$mech->content()=~/var vaevents\s*=\s*(\[\s*.*\])\s*;/;
my $vevents=decode_json($var_vevent);

my @eventList;
for my $vevent (@{$vevents}) {
    my $event;

    # Wenn kein vevent->time und ein Badge ("abgesagt", "verlegt",...) -> überspringen
    if ($vevent->{'time'} eq "" and defined($vevent->{'badge'})) {
	next;
    }

    # URL
    $event->{'url'}=$vevent->{'url'};
    #print $event->{'url'}."\n";

    # Titel
    $event->{'titel'}=$vevent->{'name'};
    $event->{'titel'}=~s/([\w'’]+)/\u\L$1/g;

    # Genre - deaktiviert, enthält zu viel Müll
    #$event->{'genre'}=$htmlStripper->parse($vevent->{'description'});

    # Ort
    $event->{'ort'}=$vevent->{'venue'};

    # Beginn
    $event->{'beginn'}=$datumFormat->parse_datetime($vevent->{'date'}." ".$vevent->{'time'});

    # Event-Seite laden
    my $ok=eval { $mech->get($event->{'url'}); }; # sometimes some links are broken
    next unless ($ok);

    my $root=HTML::TreeBuilder->new_from_content($mech->content());

    my $info=$root->look_down('_tag'=>'div','class'=>'product-info-main');
    # Kategorie ("Live", "Public Viewing",...)

    my $categoryLink = $event->{'kategorie'}=$info->look_down('_tag'=>'a','class'=>'ox-product-page__category-link');
    if ($categoryLink) {
	$event->{'kategorie'}=$categoryLink->as_trimmed_text;
    }
    else {
	$event->{'kategorie'}="unbekannt";
    }

    my $innerInfo=$info->look_down('_tag'=>'div','class'=>'page-title-wrapper product');

    # Untertitel
    try {
	my $subtitle=$innerInfo->look_down('_tag'=>'h1','class'=>'page-title')->right()->as_trimmed_text;
        $event->{'titel'}.=" - ".$subtitle;
    };

    my $essentialInfo=$info->look_down('_tag'=>'div','class'=>'product-info-essential');
    # Preis und Link zu Tickets
    try {
	my $link=$event->{'ticketUrl'}=$mech->find_link('url'=>'#bstickets');
	$event->{'preis'}=$link->text();
	$event->{'tickets'}=$link->url_abs()->as_string;
    };

    # Veranstalter
    $event->{'veranstalter'}=$essentialInfo->look_down('_tag'=>'div','class'=>'product attribute eventpresenter')->look_down('_tag'=>'div','class'=>'value')->as_trimmed_text;

    # Einlass - FIXME: Richtigen Tag suchen!
    my $datumzeit;
    my @rows=$essentialInfo->look_down('_tag'=>'strong','class'=>'type',
	sub {
	    $_[0]->as_text=~/^Veranstaltungsdatum/
	})->right();

    # richtige Zeile bei den Veranstaltungsdaten suchen
    my $f=0;
    for my $row (@rows) {
	$datumzeit=$row->as_trimmed_text;
	my ($day,$monthname,$year,$beginnHH,$beginnMM,$einlassHH,$einlassMM)=$datumzeit=~/\w+ (\d{1,2})\. (\w+) (\d{4})Beginn(\d{1,2})[:\.](\d{2}) UhrEinlass\D*(\d{1,2})[:\.]0?(\d{2}) Uhr/;
	my $month=1+first_index { $_ eq lc($monthname) } @months;
	my $d = sprintf("%0.2d/%0.2d/%d",$month,$day,$year);
	next unless ($d=~$vevent->{'date'});

	# Beginn nochmal setzen, gelegentlich fehlt der in vevent. Dann muss aber das Datum stimmen!
	unless ($event->{'beginn'}) {
	    $event->{'beginn'}=$datumFormat->parse_datetime($month."/".$day."/".$year." ".$beginnHH.":".$beginnMM) unless($event->{'beginn'});
	}

	# Einlass
	try {
	    $event->{'einlass'}=$event->{'beginn'}->clone();
	    $event->{'einlass'}->set_hour($einlassHH);
	    $event->{'einlass'}->set_minute($einlassMM);
	};
	last;
    }

    # Ende
    $event->{'ende'}=$event->{'beginn'}->clone();
    $event->{'ende'}->add(minutes=>$defaultDauer);

    # Beschreibung
    try {
	$event->{'beschreibung'}=$info->look_down('_tag'=>'div','id'=>'description')->as_trimmed_text;
	# Ersetze Unicode-Linebreaks durch normale
	$event->{'beschreibung'}=~s/\R/\n/g;
	# Nichtdruckbare Zeichen (^H usw) ausfiltern
	$event->{'beschreibung'}=~s/[^[:print:]]+//g;
    };

    unless ($event->{'beginn'}) {
	next;
    }

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
        "X-WR-CALNAME"=>"Backstage",
        "X-WR-CALDESC"=>"Veranstaltungen Backstage");

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
    #if ($event->{'genre'})
    #	{ $description.="Genre: ".$event->{'genre'}." \n\n"; }
    if ($event->{'kurzbeschreibung'})
	{ $description.=$event->{'kurzbeschreibung'}." \n\n"; }
    if ($event->{'preis'})
	{ $description.=$event->{'preis'}." \n"; }
    if ($event->{'tickets'})
	{ $description.=$event->{'tickets'}." \n"; }
    if ($event->{'einlass'})
	{ $description.="Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute)." \n"; }

    if ($event->{'beschreibung'})
	{ $description.=" \n".$event->{'beschreibung'}." \n\n"; }


    if ($event->{'veranstalter'}) {
	$description.="Veranstalter: ".$event->{'veranstalter'};
    }

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'titel'},
	description => $description,
	categories => $event->{'kategorie'},
	dtstart => dt2icaldt($event->{'beginn'}),
	dtend => dt2icaldt($event->{'ende'}),
	dtstamp => $dstamp,
	class => "PUBLIC",
	organizer => "MAILTO:foobar",
	location => $event->{'ort'},
	url => $event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
