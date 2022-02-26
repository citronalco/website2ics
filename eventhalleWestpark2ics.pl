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
use Time::HiRes;

use Try::Tiny;

use utf8;
#use Data::Dumper;
use warnings;


my $url="https://www.eventhalle-westpark.de/das-programm";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)

my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H.%M','time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);


my @eventList;
# alle event-links auslesen..
my @eventLinks=$mech->content()=~/class=\"thumbnail event event-clickable\" onclick=\"showModal\(\d+,\s*\'(https:\/\/www\.eventhalle-westpark.de\/.+?)\'\);\"/g;
# ...und durchgehen
foreach my $eventLink (@eventLinks) {
    my $event;

    my $ok=eval { $mech->get($eventLink); }; # sometimes some links are broken
    next unless ($ok);

    my ($name,$genre,$datum,$kurztext,$einlass,$beginn,$vorverkauf,$abendkasse,$langtext,$ort,$veranstalter);

    my $root=HTML::TreeBuilder->new_from_content($mech->content());

    # Name
    $name=($root->look_down('_tag'=>'h4','class'=>'modal-title'))->as_trimmed_text;
    $event->{'name'}=$name;

    my $tree=$root->look_down('_tag'=>'table','class'=>'table table-condensed detail-table');

    # Datum
    $datum=($tree->look_down('_tag'=>'td',
				    sub {
					$_[0]->as_text=~/Datum:/
				    }
			    )->right)->as_trimmed_text;


    # Einlass und Beginn stehen in einer Zeile
    my $einlassBeginn=($tree->look_down('_tag'=>'td',
				    sub {
					$_[0]->as_text=~/Einlass:/
				    }
			    )->right)->as_trimmed_text;
    ($event->{'einlass'})=$einlassBeginn=~/^(\d+\.\d+) Uhr/;
    ($event->{'beginn'})=$einlassBeginn=~/(\d+\.\d+) Uhr$/;
    $event->{'einlass'}=$datumFormat->parse_datetime($datum." ".$event->{'einlass'});
    $event->{'beginn'}=$datumFormat->parse_datetime($datum." ".$event->{'beginn'});

    # Ende=Beginn+$defaultDauer
    $event->{'ende'}=$event->{'beginn'}->clone();
    $event->{'ende'}->add(minutes=>$defaultDauer);

    # Preise für Vorverkauf und Abendkasse stehen in einer Zeile
    try {
	my $ticketPreis=($tree->look_down('_tag'=>'td',
				    sub {
					$_[0]->as_text=~/Ticketpreis:/
				    }
			    )->right)->as_trimmed_text;
	($event->{'vorverkauf'})=$ticketPreis=~/^([\d\.\,]+ €)/;
	($event->{'abendkasse'})=$ticketPreis=~/Abendkasse: ([\d\.,]+ €)/;
    };

    # Der Ort fehlt ab und zu
    try {
	$event->{'ort'}=($tree->look_down('_tag'=>'td',
				    sub { 
				      $_[0]->as_text=~/Location:/
				    }
			    )->right)->as_trimmed_text;
    }
    catch {
	try {
	    my $locationAlert=($tree->look_down('_tag'=>'td','class'=>'location-alert'))->as_trimmed_text;
	    ($event->{'ort'})=$locationAlert=~/Die Veranstaltung findet in folgender Location statt: (.+$)/;
	}
    };

    # Beschreibung
    try {
	$event->{'description'}=($root->look_down('_tag'=>'div','id'=>'beschreibung'))->as_text;
    };

    # Stil
    $event->{'genre'}=($tree->look_down('_tag'=>'td',
				    sub {
					$_[0]->as_text=~/Stil:/
				    }
			    )->right)->as_trimmed_text;

    # Sonstiges
    try {
	$event->{'sonstiges'}=($tree->look_down('_tag'=>'td',
				    sub {
					$_[0]->as_text=~/Sonstiges:/
				    }
			    )->right)->as_trimmed_text;
    };

    # Veranstalter
    $event->{'veranstalter'}=($tree->look_down('_tag'=>'td',
				    sub {
					$_[0]->as_text=~/Veranstalter:/
				    }
			    )->right)->as_trimmed_text;

    # URL
    $event->{'url'}=($mech->uri())->as_string;

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

my $count=0;
foreach my $event (@eventList) {
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);

    my $description;
    $description.="Genre: ".$event->{'genre'}." \n";
    if ($event->{'vorverkauf'})	{ $description.="Vorverkauf: ".$event->{'vorverkauf'}." \n"; }
    if ($event->{'abendkasse'})	{ $description.="Abendkasse: ".$event->{'abendkasse'}." \n"; }
    $description.="Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute);
    if ($event->{'sonstiges'})	{ $description.="Sonstiges: ".$event->{'sonstiges'}." \n"; }
    $description.=" \n\n".$event->{'description'};

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	categories=>$event->{'genre'},
	summary => $event->{'name'},
	description => $description,
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
	#duration=>"PT3H",
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
#	organizer=>"CN=\"".$event->{'veranstalter'}."\"",
	organizer=>"MAILTO:foobar",
	location=>$event->{'ort'},
	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}

print $calendar->as_string;
