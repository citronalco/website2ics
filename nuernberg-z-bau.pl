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

use POSIX qw(strftime);

use Try::Tiny;

use utf8;
use Data::Dumper;
use warnings;


my $url="https://z-bau.com/programm/";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)


my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%Y-%m-%d %H:%M','time_zone'=>'Europe/Berlin');
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
my $root=HTML::TreeBuilder->new();
$root->ignore_unknown(0);	# "article"-Tag wird sonst nicht erkannt
$root->parse_content($mech->content());

# Programm raussuchen
my $programm=$root->look_down('_tag'=>'div','class'=>'programm');
foreach my $article ($programm->look_down('_tag'=>'article','class'=>qr/event/)) {
    my $event;

    $event->{'url'}=$article->attr('data-url');
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


    # URL enthält Datum mit Jahr
    ($event->{'datum'})=$event->{'url'}=~/${url}(\d{4}-\d{2}-\d{2})\//;

    # Einlass
    try {
	my $einlass=$article->look_down('_tag'=>'span','class'=>'event__einlass')->as_trimmed_text;
	$event->{'einlass'}=$datumFormat->parse_datetime($event->{'datum'}." ".$einlass);
    };

    # Beginn
    try {
	my $beginn=$event->{'beginn'}=$article->look_down('_tag'=>'span','class'=>'event__beginn')->as_trimmed_text;
	$event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." ".$beginn);
    };

    # Weder Einlass- noch Beginnuhrzeit? -> Ganztages-Event
    if (!($event->{'einlass'}) and !($event->{'beginn'})) {
	$event->{'fullday'} = 1;
	$event->{'beginn'}=$datumFormat->parse_datetime($event->{'datum'}." 00:00");
	$event->{'ende'}=$datumFormat->parse_datetime($event->{'datum'}." 23:59");
    }
    else {
	if (!($event->{'einlass'}) and ($event->{'beginn'})) { $event->{'einlass'}=$event->{'beginn'}; }
	if (!($event->{'beginn'}) and ($event->{'einlass'})) { $event->{'beginn'}=$event->{'einlass'}; }

	# Ende
	$event->{'ende'}=$event->{'beginn'}->clone();
	$event->{'ende'}->add(minutes=>$defaultDauer);
    }


    try {
	# Abgesagte Events sind zwar im Programm, aber mit anderen Klassen. Müssen nicht extra rausgefiltert werden.
	$event->{'titel'}=$article->look_down('_tag'=>'div','class'=>'event__title')->look_down('class'=>'event__main-title')->as_trimmed_text;
    };
    next unless ($event->{'titel'});

    $event->{'untertitel'}=$article->look_down('_tag'=>'div','class'=>'event__title')->look_down('class'=>'event__sub-title')->as_trimmed_text;
    $event->{'ort'}=$article->look_down('_tag'=>'div','class'=>'event__location')->as_trimmed_text;
    try {
	$event->{'tickets'}=$article->look_down('_tag'=>'div','class'=>'event__tickets')->look_down('_tag'=>'a','class'=>'event__ticket-link')->attr('href');
    };
    $event->{'beschreibung'}=$article->look_down('_tag'=>'div','class'=>'event__info-text')->as_trimmed_text;
    $event->{'eintritt'}=$article->look_down('_tag'=>'div','class'=>'event__eintritt')->as_trimmed_text;

    push(@eventList,$event);
    #print Dumper $event;
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
        "X-WR-CALNAME"=>"Z-Bau",
        "X-WR-CALDESC"=>"Veranstaltungen Z-Bau");

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

    ## Beschreibung bauen
    my $description;
    $description.=$event->{'untertitel'}." \n\n" if ($event->{'untertitel'});
    $description.=$event->{'eintritt'}." \n" if ($event->{'eintritt'});
    $description.="Vorverkauf: ".$event->{'tickets'}." \n" if ($event->{'tickets'});
    $description.="Einlass: ".sprintf("%.2d",$event->{'einlass'}->hour).":".sprintf("%.2d",$event->{'einlass'}->min)." Uhr \n" if ($event->{'einlass'});
    $description.="\n ".$event->{'beschreibung'}." \n";

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'titel'},
	description => $description,
	categories => $event->{'category'},
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
