#!/usr/bin/perl
# 2022 geierb@geierb.de
# AGPLv3

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


my $url="https://www.der-hirsch.com/programm.html";
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
foreach my $eventLink ($mech->find_all_links('url_regex'=>qr/^https:\/\/www.der-hirsch.com\/konzert-details\/.+/)) {
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

    my $root=HTML::TreeBuilder->new_from_content($mech->content())->look_down('_tag'=>'div','class'=>'centered-wrapper-inner');

    ### Großer Block rechts: Titel, Untertitel, Beschreibung
    my $bRechts=$root->look_down('_tag'=>'div','class'=>qr/column_start rechteSpalte/)
	    ->look_down('_tag'=>'div','class'=>'mod_eventreader block')
		->look_down('_tag'=>'div','class'=>qr/event block/);

    # Beschreibung
    $event->{'beschreibung'}=$bRechts->look_down('_tag'=>'div','class'=>'ce_text block')->as_trimmed_text();

    # Titel
    $event->{'titel'}=$bRechts->look_down('_tag'=>'h1')->as_trimmed_text();
    try {
	# "Oberzeile" zu Titel hinzufügen
	$event->{'titel'}.=" - ".$bRechts->look_down('_tag'=>'p','class'=>'eventOberzeile')->as_trimmed_text();
    };
    try {
	# "Unterzeile" zu Titel hinzufügen
	$event->{'titel'}.=" - ".$bRechts->look_down('_tag'=>'p','class'=>'eventUnterzeile')->as_trimmed_text();
    };
    try {
	# "Support" zu Titel hinzufügen
	$event->{'titel'}.=" - ".$bRechts->look_down('_tag'=>'p','class'=>'eventSupport')->as_trimmed_text();
    };
    $event->{'titel'}=~s/([\w'’]+)/\u\L$1/g;


    ### Info-Block links: Datum, Einlass, Beginn, Ort, Preis, Ticket-Link, Veranstalter
    my $bLinks=$root->look_down('_tag'=>'div','class'=>qr/column_start linkeSpalte/)
	    ->look_down('_tag'=>'div','class'=>'mod_eventreader block')
		->look_down('_tag'=>'div','class'=>qr/event block/);

    # Rote Hinweisbox
    try {
	$event->{'alert'}=$bLinks->look_down('_tag'=>'p','class'=>'redbg-bold')->as_trimmed_text();
    };
    # "Abgesagt" -> Veranstaltung überspringen
    next if (($event->{'alert'}) and ($event->{'alert'}=~/^abgesagt$/i));

    # Datum
    my $datumLong=$bLinks->look_down('_tag'=>'h2')->as_trimmed_text();
    my ($datum)=$datumLong=~/^\w\w\. (\d{2}\.\d{2}\.\d{4})/;

    # Einlass + Beginn, Bestuhlung
    my $einlassBeginn=$bLinks->look_down('_tag'=>'p','class'=>undef,sub {
	    $_[0]->as_trimmed_text()=~/Beginn:/
	})->as_trimmed_text();
    if ($einlassBeginn=~/^Einlass: (\d{2}:\d{2}) Uhr/) {
	$event->{'einlass'}=$datumFormat->parse_datetime($datum." ".$1);
    }
    if ($einlassBeginn=~/Beginn: (\d{2}:\d{2}) Uhr/) {
	$event->{'beginn'}=$datumFormat->parse_datetime($datum." ".$1);
    }
    if (!$event->{'einlass'}) { $event->{'einlass'}=$event->{'beginn'}; }
    if (!$event->{'beginn'}) { $event->{'beginn'}=$event->{'einlass'}; }

    # Ort
    $event->{'ort'}=$bLinks->look_down('_tag'=>'p','class'=>'smallfont', sub {
	    $_[0]->as_trimmed_text()!~/Veranstalter:/
	})->as_trimmed_text();
    $event->{'ort'}=~s/ > /, /;

    # Veranstalter
    try {
	my $veranstalterHTML=$bLinks->look_down('_tag'=>'p','class'=>'smallfont', sub {
		$_[0]->as_trimmed_text()=~/Veranstalter:/
	    })->as_HTML;
	$veranstalterHTML=join(", ",split(/<br\s*\/?>/,$veranstalterHTML));
	$event->{'veranstalter'}=HTML::TreeBuilder->new_from_content($veranstalterHTML)->as_trimmed_text();
	$event->{'veranstalter'}=~s/^Veranstalter:, //;
    };

    # Eintrittspreise
    try {
	my $preisHTML=$bLinks->look_down('_tag'=>'p','class'=>undef,sub {
		$_[0]->as_trimmed_text()=~/€/
	    })->as_HTML;
	$preisHTML=join(", ",split(/<br\s*\/?>/,$preisHTML));
	$event->{'preis'}=HTML::TreeBuilder->new_from_content($preisHTML)->as_trimmed_text();
    };

    # Ticket-Link:
    try {
	$event->{'tickets'}=$mech->find_link(text=>'TICKETS')->url_abs()->as_string;
    };

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
        "X-WR-CALNAME"=>"Hirsch",
        "X-WR-CALDESC"=>"Veranstaltungen Hirsch");

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

    ### Beschreibung zusammenbauen
    my $description;
    $description.=$event->{'alert'}." \n\n" if ($event->{'alert'});
    $description.=$event->{'preis'}." \n" if ($event->{'preis'});
    $description.="Tickets: ".$event->{'tickets'}." \n" if ($event->{'tickets'});
    $description.="Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute). " \n";
    $description.=" \n".$event->{'beschreibung'}." \n\n";
    $description.= "Veranstalter: ".$event->{'veranstalter'} if ($event->{'veranstalter'});

    # Ende festlegen
    $event->{'ende'}=$event->{'beginn'}->clone();
    $event->{'ende'}->add(minutes=>$defaultDauer);

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'titel'},
	description => $description,
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
