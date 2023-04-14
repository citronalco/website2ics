#!/usr/bin/perl
# 2013,2018,2022 geierb@geierb.de
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


my $url="https://www.eventhalle-westpark.de/programm-tickets/";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)

my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H.%M','time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);


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


my @eventList;
# alle event-links auslesen..
my @eventLinks=$mech->find_all_links(class=>'event-box-title mb-1 box-link');

# ...und durchgehen
foreach my $eventLink (@eventLinks) {

    my $ok=eval { $mech->get($eventLink); }; # sometimes some links are broken
    next unless ($ok);

    my $event;

    # URL
    $event->{'url'}=($mech->uri())->as_string;
    #print "URL: ".$event->{'url'}."\n";

    my $root=HTML::TreeBuilder->new_from_content($mech->content());

    # Name
    $event->{'title'}=$root->look_down('id'=>'eventName')->as_trimmed_text;
    # Untertitel
    $event->{'subtitle'}=$root->look_down('id'=>'eventSubtitle')->as_trimmed_text;
    # -> Titel
    $event->{'name'}=join(": ",grep $_,$event->{'title'},$event->{'subtitle'});

    # Datum
    my $datum=($root->look_down('id'=>'eventDate'))->as_trimmed_text;

    try {
	# Einlass
	my $einlass=($root->look_down('id'=>'eventStarttime'))->as_trimmed_text;
	my ($einlass_h,$einlass_m)=$einlass=~/(\d{1,2})[\.:](\d{1,2})/;
	$event->{'einlass'}=$datumFormat->parse_datetime($datum." ".$einlass_h.".".$einlass_m);
	# Beginn
	my $beginn=($root->look_down('id'=>'eventStagetime'))->as_trimmed_text;
	my ($beginn_h,$beginn_m)=$beginn=~/(\d{1,2})[\.:](\d{1,2})/;
	$event->{'beginn'}=$datumFormat->parse_datetime($datum." ".$beginn_h.".".$beginn_m);
    };
    # Events ohne Uhrzeit sind abgesagte Events
    unless ($event->{'einlass'}) {
	if ($mech->content=~/(abgesagt)|(verlegt)/i) {
	    next;
	}
	else {
	    die("Keine Startzeit: ".$event->{'url'});
	}
    }

    # Ende=Beginn+$defaultDauer
    $event->{'ende'}=$event->{'beginn'}->clone();
    $event->{'ende'}->add(minutes=>$defaultDauer);

    # Genre
    $event->{'genre'}=$root->look_down('id'=>'eventGenre')->as_trimmed_text;

    # Ort
    $event->{'ort'}=($root->look_down('id'=>'eventLocation'))->as_trimmed_text;

    # Veranstalter
    $event->{'veranstalter'}=($root->look_down('id'=>'eventOrganizer'))->as_trimmed_text;

    # Preis VVK
    try {
	$event->{'vorverkauf'}=$root->look_down('id'=>'eventPrice')->as_trimmed_text
    }
    catch {
	 $event->{'vorverkauf'}="ohne Vorverkauf";
    };

    # Preis AK
    try {
	$event->{'abendkasse'}=$root->look_down('id'=>'eventPriceAk')->as_trimmed_text;
    } catch {
	$event->{'abendkasse'}="ohne Abendkasse";
    };

    # Eintrittskarten-Link
    try {
	$event->{'ticketUrl'}=$mech->find_link(text_regex=>qr/Ticket kaufen/)->url_abs();
    } catch {
	if ($root->look_down('_tag'=>'button', 'title'=>'In den Warenkorb')) {
	    $event->{'ticketUrl'}=$event->{'url'};
	}
    };

    # Bestuhlt?
    for my $fact ($root->look_down('_tag'=>'div', 'class'=>'event-stage-facts row')) {
	if ($fact->as_trimmed_text=~/^Bestuhlt (ja|nein)/i) {
	    if ($1=~/ja/i) {
		$event->{'bestuhlt'}=1;
	    }
	    else {
		$event->{'bestuhlt'}=0;
	    }
	}
    }

    # Beschreibung
    $event->{'description'}=$root->look_down('id'=>'eventDescription')->as_text;

    push (@eventList,$event);
#    print Dumper $event;
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
        "X-WR-CALNAME"=>"Eventhalle Westpark",
        "X-WR-CALDESC"=>"Veranstaltungen Eventhalle Westpark");

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
    if ($event->{'vorverkauf'})	{ $description.="Vorverkauf: ".$event->{'vorverkauf'}." \n"; }
    if ($event->{'abendkasse'})	{ $description.="Abendkasse: ".$event->{'abendkasse'}." \n"; }
    if ($event->{'ticketUrl'} )	{ $description.="Kartenvorverkauf: ".$event->{'ticketUrl'}." \n"; }
    $description.="Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute)." \n";
    if ($event->{'bestuhlt'})	{ 
	if ($event->{'bestuhlt'} eq 1) {
	    $description.="Bestuhlung: Ja\n";
	}
	else {
	    $description.="Bestuhlung: Nein\n";
	}
    }
    $description.=" \n".$event->{'description'};

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	categories=>$event->{'genre'},
	summary => $event->{'name'},
	description => $description,
	dtstart => dt2icaldt($event->{'beginn'}),
	#duration=>"PT3H",
	dtend => dt2icaldt($event->{'ende'}),
	dtstamp=>$dstamp,
	class=>"PUBLIC",
#	organizer=>"CN=\"".$event->{'veranstalter'}."\"",
	organizer=>"MAILTO:foobar",
	location=>$event->{'ort'},
	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
