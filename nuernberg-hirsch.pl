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

use Try::Tiny;

use utf8;
use Data::Dumper;
use warnings;


my $url="https://www.der-hirsch.com/programm.html";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)


my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H:%M','time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

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
		->look_down('_tag'=>'div','class'=>'event block');

    # Beschreibung
    $event->{'description'}=$bRechts->look_down('_tag'=>'div','class'=>'ce_text block')->as_trimmed_text();

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


    ### Info-Block links: Datum, Einlass, Beginn, Ort, Preis, Ticket-Link, Veranstalter
    my $bLinks=$root->look_down('_tag'=>'div','class'=>qr/column_start linkeSpalte/)
	    ->look_down('_tag'=>'div','class'=>'mod_eventreader block')
		->look_down('_tag'=>'div','class'=>'event block');

    # Rote Hinweisbox
    try {
	$event->{'alert'}=$bLinks->look_down('_tag'=>'p','class'=>'redbg-bold')->as_trimmed_text();
    };
    # "Abgesagt" -> Veranstaltung überspringen
    next if (($event->{'alert'}) and ($event->{'alert'}=~/^abgesagt$/i));

    # Datum
    my $datumLong=$bLinks->look_down('_tag'=>'h2')->as_trimmed_text();
    my ($datum)=$datumLong=~/^\w\w\. (\d{2}\.\d{2}\.\d{4})$/;

    # Einlass + Beginn, Bestuhlung
    my $einlassBeginn=$bLinks->look_down('_tag'=>'p','class'=>undef,sub {
	    $_[0]->as_trimmed_text()=~/Beginn:/
	})->as_trimmed_text();
    $einlassBeginn=~/^Einlass: (\d{2}:\d{2}) UhrBeginn: (\d{2}:\d{2}) Uhr(.+)$/;

    $event->{'einlass'}=$datumFormat->parse_datetime($datum." ".$1);
    $event->{'beginn'}=$datumFormat->parse_datetime($datum." ".$2);

    # Ort
    $event->{'ort'}=$bLinks->look_down('_tag'=>'p','class'=>'smallfont', sub {
	    $_[0]->as_trimmed_text()!~/Veranstalter:/
	})->as_trimmed_text();
    $event->{'ort'}=~s/ > /, /;

    # Veranstalter
    my $veranstalterHTML=$bLinks->look_down('_tag'=>'p','class'=>'smallfont', sub {
	    $_[0]->as_trimmed_text()=~/Veranstalter:/
	})->as_HTML;
    $veranstalterHTML=join(", ",split(/<br\s*\/?>/,$veranstalterHTML));
    $event->{'veranstalter'}=HTML::TreeBuilder->new_from_content($veranstalterHTML)->as_trimmed_text();
    $event->{'veranstalter'}=~s/^Veranstalter:, //;

    # Eintrittspreise
    my $preisHTML=$bLinks->look_down('_tag'=>'p','class'=>undef,sub {
	    $_[0]->as_trimmed_text()=~/€/
	})->as_HTML;
    $preisHTML=join(", ",split(/<br\s*\/?>/,$preisHTML));
    $event->{'preis'}=HTML::TreeBuilder->new_from_content($preisHTML)->as_trimmed_text();

    # Ticket-Link:
    try {
	$event->{'tickets'}=$mech->find_link(text=>'TICKETS')->url_abs()->as_string;
    };

    ### Beschreibung zusammenbauen
    my @descTop;
    push(@descTop, $event->{'alert'}) if ($event->{'alert'});
    if (scalar(@descTop)>0) {
	$event->{'description'}=join(" \n",@descTop)." \n\n".$event->{'description'};
    }

    my @descBottom=(
	"Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute),
	$event->{'preis'}
    );
    push(@descBottom, "Tickets: ".$event->{'tickets'}) if ($event->{'tickets'});
    push(@descBottom, "Veranstalter: ".$event->{'veranstalter'});

    if (scalar(@descBottom)>0) {
	$event->{'description'}.=" \n\n".join(" \n",@descBottom);
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
        "X-WR-CALNAME"=>"Hirsch",
        "X-WR-CALDESC"=>"Veranstaltungen Hirsch");

my $count=0;
foreach my $event (@eventList) {
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);

    # Ende festlegen
    $event->{'ende'}=$event->{'beginn'}->clone();
    $event->{'ende'}->add(minutes=>$defaultDauer);

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'name'},
	description => $event->{'description'},
	categories => $event->{'category'},
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
